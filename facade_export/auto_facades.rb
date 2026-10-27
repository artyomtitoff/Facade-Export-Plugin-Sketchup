# encoding: utf-8
# Экспорт фасадов — автоматический поиск фасадов («Автоматический вывод фасада»).
# Автор: Артем Титов (motivate_rt)
#
# Что делает кнопка:
#   1. смотрит на геометрию того контекста, в котором сейчас пользователь
#      (открытая группа/компонент) или на всю модель — камера не важна;
#   2. группирует вертикальные грани по направлению нормали и оставляет
#      основные фасады (по площади);
#   3. для каждого фасада строит параллельную камеру и кадр по выбранному
#      соотношению сторон (по умолчанию 3:4, длинная сторона — из настроек);
#   4. создаёт секущую плоскость параллельно фасаду — она убирает из кадра
#      лишнюю геометрию (внутренние дворы, соседние крылья), сам фасад цел;
#   5. создаёт сцены: в каждой видна только своя плоскость и своя камера;
#   6. отдаёт окну упрощённые превью фасадов и план здания сверху.
#
# Сцены и плоскости временные: после экспорта они удаляются
# (настройка auto.delete_scenes), исходное состояние разрезов возвращается.

module FacadeExport
  class AutoFacades
    Z_AXIS = Geom::Vector3d.new(0, 0, 1)

    BUCKET_DEG = 10.0        # шаг группировки нормалей
    VERTICAL_TOL = 0.2       # насколько нормаль должна быть горизонтальной
    MAX_POLYGONS = 300       # сколько полигонов отдаём в окно на один фасад
    MAX_POINTS = 24          # максимум точек в одном полигоне превью
    MAX_DEPTH = 32           # глубина обхода групп/компонентов
    PREVIEW_SCALE = 1000.0   # координаты превью — целые 0..1000
    PLAN_GRID = 32           # сетка схемы сверху (32 × 32 клетки)
    PLAN_MAX_FILL = 400      # сколько горизонтальных граней заливать в схеме

    # Найденный фасад.
    #   normal    — наружу от фасада; direction — куда смотрит камера (=-normal);
    #   points    — мировые точки граней (для кадра и превью);
    #   polygons  — упрощённые полигоны превью в координатах 0..1000.
    Facade = Struct.new(
      :index, :normal, :direction, :points, :area, :aspect, :name, :page_name,
      :selected, :image_width, :image_height, :camera, :section_plane, :page,
      :polygons
    )

    def self.detect(model, settings = nil)
      new(model, settings).detect
    end

    # Размер кадра в пикселях: длинная сторона — export.width (9999),
    # вторая — по соотношению (по умолчанию 3:4).
    def self.image_size(aspect, export_settings)
      longest = export_settings['width'].to_i
      longest = Config::MIN_IMAGE_SIDE if longest < Config::MIN_IMAGE_SIDE
      longest = Config::MAX_IMAGE_SIDE if longest > Config::MAX_IMAGE_SIDE
      if export_settings['height'].to_i.positive?
        return [longest, export_settings['height'].to_i]
      end
      aw, ah = Config.auto_aspect_ratio(aspect)
      if aw >= ah
        [longest, [(longest * ah.to_f / aw.to_f).round, Config::MIN_IMAGE_SIDE].max]
      else
        [[(longest * aw.to_f / ah.to_f).round, Config::MIN_IMAGE_SIDE].max, longest]
      end
    end

    def initialize(model, settings = nil)
      @model = model
      @settings = settings || FacadeExport.settings
      @planes = []
      @pages = []
      @planes_snapshot = nil
      @camera_snapshot = nil
    end

    attr_reader :planes, :pages

    # Возвращает {:facades, :outline, :scope, :bounds}.
    def detect
      faces = collect_faces
      if faces.empty?
        raise ExportError, 'Не найдено видимых граней. Выйдите из группы ' \
                           'или проверьте, что геометрия не скрыта.'
      end
      @bounds = faces.map { |f| f[:points] }.flatten(1)
      clusters = cluster_faces(faces)
      if clusters.empty?
        raise ExportError, 'Не найдено вертикальных поверхностей — фасады не обнаружены.'
      end
      facades = build_facades(clusters)
      if facades.empty?
        raise ExportError, 'Фасады не обнаружены. Проверьте ориентацию модели.'
      end
      {
        :facades => facades,
        :plan    => plan_map(faces),
        :scope   => @scope,
        :bounds  => @bounds
      }
    end

    # ------------------------------------------------------------- геометрия

    # Видимые грани в мировых координатах: [ {:points, :normal, :area}, ... ]
    #
    # Внутри открытой группы берём её определение: пользователь хочет
    # экспортировать то, что редактирует, а не всю сцену вокруг.
    def collect_faces
      path = begin
        @model.active_path
      rescue StandardError
        nil
      end
      if path.nil? || path.empty?
        entities = @model.entities
        transform = nil
        @scope = :model
      else
        transform = Geom::Transformation.new
        path.each { |instance| transform = transform * instance.transformation }
        entities = begin
          path.last.definition.entities
        rescue StandardError
          nil
        end
        raise ExportError, 'Не удалось прочитать открытую группу.' if entities.nil?
        @scope = :context
      end
      faces = []
      walk_faces(entities, transform, 0, faces)
      faces
    end

    def walk_faces(entities, transform, depth, out)
      return out if entities.nil? || depth > MAX_DEPTH
      entities.each do |entity|
        next unless Framing.entity_visible?(entity)
        if entity.is_a?(Sketchup::Face)
          record = face_record(entity, transform)
          out << record if record
          next
        end
        next unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
        local = begin
          entity.transformation
        rescue StandardError
          nil
        end
        next if local.nil?
        definition = begin
          entity.definition
        rescue StandardError
          nil
        end
        next if definition.nil?
        walk_faces(definition.entities, transform.nil? ? local : (transform * local), depth + 1, out)
      end
      out
    rescue StandardError => e
      FacadeExport.log("Авто-фасады: обход геометрии прерван (#{e.message})")
      out
    end

    def face_record(face, transform)
      points = face_points(face, transform)
      return nil if points.length < 3
      normal = face_normal(face, transform)
      return nil if normal.nil?
      area = polygon_area(points)
      return nil if area <= 0.0
      { :points => points, :normal => normal, :area => area }
    rescue StandardError
      nil
    end

    def face_points(face, transform)
      list = []
      face.vertices.each do |vertex|
        pt = vertex.position
        list << (transform.nil? ? pt : pt.transform(transform))
      end
      list
    rescue StandardError
      []
    end

    def face_normal(face, transform)
      n = face.normal
      return nil if n.nil?
      n = n.transform(transform) unless transform.nil?
      Geom::Vector3d.new(n.x, n.y, n.z)
    rescue StandardError
      nil
    end

    # Площадь многоугольника (веер треугольников).
    def polygon_area(points)
      sum = Geom::Vector3d.new(0, 0, 0)
      first = points.first
      (1...(points.length - 1)).each do |i|
        a = points[i] - first
        b = points[i + 1] - first
        cross = a.cross(b)
        sum = Geom::Vector3d.new(sum.x + cross.x, sum.y + cross.y, sum.z + cross.z)
      end
      sum.length / 2.0
    rescue StandardError
      0.0
    end

    # ------------------------------------------------------------- кластеры

    # Группирует вертикальные грани по азимуту нормали.
    def cluster_faces(faces)
      bins = (360.0 / BUCKET_DEG).round
      buckets = {}
      faces.each do |face|
        n = face[:normal]
        next if n.length < 1.0e-6
        next if n.z.abs > VERTICAL_TOL
        key = (azimuth(n) / BUCKET_DEG).round % bins
        bucket = (buckets[key] ||= { :area => 0.0, :faces => [], :vx => 0.0, :vy => 0.0 })
        bucket[:area] += face[:area]
        bucket[:faces] << face
        bucket[:vx] += n.x * face[:area]
        bucket[:vy] += n.y * face[:area]
      end
      return [] if buckets.empty?

      groups = merge_buckets(buckets, bins)
      max_area = groups.map { |g| g[:area] }.max
      return [] if max_area.nil? || max_area <= 0.0

      min_share = @settings.auto_val('min_area').to_f / 100.0
      keep = groups.select { |g| g[:area] >= max_area * min_share }
      keep = keep.sort_by { |g| -g[:area] }.first(@settings.auto_val('max_facades').to_i)
      keep.sort_by { |g| azimuth(g[:normal]) }
    end

    # Склеивает соседние по азимуту корзины: нормали дробятся на ±5°.
    def merge_buckets(buckets, bins)
      groups = []
      used = {}
      buckets.keys.sort.each do |key|
        next if used[key]
        group = { :area => 0.0, :faces => [], :vx => 0.0, :vy => 0.0 }
        [-1, 0, 1].each do |shift|
          k = (key + shift) % bins
          bucket = buckets[k]
          next if bucket.nil? || used[k]
          used[k] = true
          group[:area] += bucket[:area]
          group[:faces].concat(bucket[:faces])
          group[:vx] += bucket[:vx]
          group[:vy] += bucket[:vy]
        end
        next if group[:area] <= 0.0
        length = Math.sqrt(group[:vx]**2 + group[:vy]**2)
        next if length < 1.0e-9
        group[:normal] = Geom::Vector3d.new(group[:vx] / length, group[:vy] / length, 0.0)
        groups << group
      end
      groups
    end

    # Азимут горизонтального вектора в градусах 0..360 (0 — +X).
    def azimuth(vector)
      deg = Math.atan2(vector.y, vector.x) * 180.0 / Math::PI
      deg += 360.0 if deg < 0.0
      deg
    end

    # -------------------------------------------------------------- фасады

    def build_facades(clusters)
      prefix = @settings.auto_val('scene_prefix').to_s.strip
      prefix = 'Фасад' if prefix.empty?
      aspect = @settings.auto_val('aspect').to_s

      result = []
      clusters.each do |cluster|
        normal = cluster[:normal]
        facade = Facade.new
        facade.index = result.length + 1
        facade.normal = normal
        facade.direction = Geom::Vector3d.new(-normal.x, -normal.y, 0.0)
        facade.points = cluster[:faces].map { |f| f[:points] }.flatten(1)
        facade.area = cluster[:area]
        facade.aspect = aspect
        facade.selected = true
        facade.name = "#{prefix} #{facade.index}"
        facade.page_name = "#{prefix} #{facade.index} — #{compass(normal)}"
        facade.polygons = preview_polygons(cluster[:faces], facade)
        result << facade
      end
      result
    end

    # Название стороны света (грубо, по осям модели: +Y — север).
    def compass(normal)
      if normal.x.abs >= normal.y.abs
        normal.x >= 0.0 ? 'восток' : 'запад'
      else
        normal.y >= 0.0 ? 'север' : 'юг'
      end
    end

    # ---------------------------------------------------------------- кадры

    # Считает камеру и размер кадра для каждого выбранного фасада.
    # scale — общий для всех выбранных фасадов, чтобы картинки были
    # в одном масштабе: его задаёт самый большой фасад.
    def build_cameras!(facades)
      return facades if facades.nil? || facades.empty?
      plan = per_facade_plan(facades)
      scale = plan.map { |item| item[:scale] }.min
      plan.each do |item|
        facade = item[:facade]
        facade.image_width = item[:image_width]
        facade.image_height = item[:image_height]
        facade.camera = camera_for(item, scale)
      end
      facades
    end

    def per_facade_plan(facades)
      facades.map do |facade|
        width, height = self.class.image_size(facade.aspect, @settings.export)
        projection = Framing.projection(facade.points, facade.direction)
        gap = Framing.gap_pixels(@settings.export, width, height)
        avail_w = [width - 2.0 * gap, 1.0].max
        avail_h = [height - 2.0 * gap, 1.0].max
        scale = [
          avail_w / [projection[:width].to_f, 1.0e-6].max,
          avail_h / [projection[:height].to_f, 1.0e-6].max
        ].min
        scale = 1.0 if scale.nil? || scale <= 0.0 || scale.nan?
        {
          :facade => facade,
          :projection => projection,
          :image_width => width,
          :image_height => height,
          :gap => gap,
          :scale => scale
        }
      end
    end

    # Камера фасада: параллельная проекция, фасад прижат к низу кадра.
    def camera_for(item, scale)
      facade = item[:facade]
      projection = item[:projection]
      width = item[:image_width]
      height = item[:image_height]
      right = projection[:right]

      frame_height = height.to_f / scale
      target_z = projection[:v_min] + (height / 2.0 - item[:gap]) / scale
      center = facade_center(facade)
      center_u = center.x * right.x + center.y * right.y + center.z * right.z
      shift = projection[:u_center] - center_u
      target = Geom::Point3d.new(
        center.x + right.x * shift,
        center.y + right.y * shift,
        target_z
      )

      diagonal = context_diagonal
      depth = projection[:width].to_f + projection[:height].to_f
      distance = [diagonal * 2.0, frame_height * 2.0, depth + frame_height].max
      eye = Geom::Point3d.new(
        target.x - facade.direction.x * distance,
        target.y - facade.direction.y * distance,
        target.z
      )

      camera = Sketchup::Camera.new(eye, target, Z_AXIS)
      begin
        camera.perspective = false
      rescue StandardError
        nil
      end
      begin
        camera.height = frame_height
      rescue StandardError
        nil
      end
      camera
    rescue StandardError => e
      FacadeExport.log("Авто-фасады: камера не построена (#{e.message})")
      nil
    end

    def facade_center(facade)
      xs = facade.points.map { |p| p.x }
      ys = facade.points.map { |p| p.y }
      zs = facade.points.map { |p| p.z }
      Geom::Point3d.new((xs.min + xs.max) / 2.0, (ys.min + ys.max) / 2.0,
                        (zs.min + zs.max) / 2.0)
    rescue StandardError
      Geom::Point3d.new(0, 0, 0)
    end

    # Диагональ габаритов того, что анализировали: камера должна стоять
    # достаточно далеко, чтобы не обрезать дальнюю геометрию.
    def context_diagonal
      points = @bounds || []
      return 1000.0 if points.empty?
      xs = points.map { |p| p.x }
      ys = points.map { |p| p.y }
      zs = points.map { |p| p.z }
      dx = xs.max - xs.min
      dy = ys.max - ys.min
      dz = zs.max - zs.min
      diag = Math.sqrt(dx**2 + dy**2 + dz**2)
      diag > 0.0 ? diag : 1000.0
    rescue StandardError
      1000.0
    end

    # --------------------------------------------------------------- превью

    # Схема здания сверху: сетка занятых клеток (0..PLAN_GRID-1).
    #
    # Именно сетка, а не выпуклая оболочка: у здания с внутренним двором
    # оболочка «залила» бы двор, а по клеткам видно реальный контур.
    # Горизонтальные грани (крыша, перекрытия) заливаются, вертикальные
    # (стены) отмечаются линией — чтобы схема работала и без крыши.
    def plan_map(faces)
      points = faces.map { |f| f[:points] }.flatten(1)
      return { 'grid' => PLAN_GRID, 'cells' => [] } if points.empty?

      xs = points.map { |p| p.x }
      ys = points.map { |p| p.y }
      min_x = xs.min
      min_y = ys.min
      span = [xs.max - min_x, ys.max - min_y, 1.0e-6].max

      cells = {}
      filled = 0
      faces.sort_by { |f| -f[:area] }.each do |face|
        normal = face[:normal]
        if normal.z.abs > 0.5 && filled < PLAN_MAX_FILL
          filled += 1
          fill_plan_polygon(face[:points], min_x, min_y, span, cells)
        else
          mark_plan_edges(face[:points], min_x, min_y, span, cells)
        end
      end
      # Ось Y в SVG смотрит вниз: переворачиваем, чтобы север был сверху.
      {
        'grid' => PLAN_GRID,
        'cells' => cells.keys.map { |(ix, iy)| [ix, PLAN_GRID - 1 - iy] }
      }
    end

    def plan_cell_index(value, min, span)
      index = ((value - min) / span * PLAN_GRID).floor
      [[index, 0].max, PLAN_GRID - 1].min
    end

    def mark_plan_cell(point, min_x, min_y, span, cells)
      ix = plan_cell_index(point.x, min_x, span)
      iy = plan_cell_index(point.y, min_y, span)
      cells[[ix, iy]] = true
    end

    # Стена в плане — линия: отмечаем клетки с шагом в полклетки.
    def mark_plan_edges(points, min_x, min_y, span, cells)
      points.each_with_index do |a, index|
        b = points[(index + 1) % points.length]
        steps = [((a - b).length / span * PLAN_GRID * 2).ceil, 1].max
        steps = [steps, 96].min
        (0..steps).each do |step|
          t = step.to_f / steps
          mark_plan_cell(
            Geom::Point3d.new(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, 0),
            min_x, min_y, span, cells
          )
        end
      end
    end

    # Заливка горизонтальной грани в сетку (проверка центра клетки).
    def fill_plan_polygon(points, min_x, min_y, span, cells)
      xs = points.map { |p| p.x }
      ys = points.map { |p| p.y }
      ix0 = plan_cell_index(xs.min, min_x, span)
      ix1 = plan_cell_index(xs.max, min_x, span)
      iy0 = plan_cell_index(ys.min, min_y, span)
      iy1 = plan_cell_index(ys.max, min_y, span)
      step = span / PLAN_GRID
      (iy0..iy1).each do |iy|
        (ix0..ix1).each do |ix|
          cx = min_x + (ix + 0.5) * step
          cy = min_y + (iy + 0.5) * step
          cells[[ix, iy]] = true if point_in_polygon?(cx, cy, points)
        end
      end
    end

    def point_in_polygon?(x, y, points)
      inside = false
      j = points.length - 1
      points.each_with_index do |point, i|
        xi = point.x
        yi = point.y
        xj = points[j].x
        yj = points[j].y
        if ((yi > y) != (yj > y)) &&
           (x < (xj - xi) * (y - yi) / ((yj - yi).zero? ? 1.0e-12 : (yj - yi)) + xi)
          inside = !inside
        end
        j = i
      end
      inside
    end

    # Превью фасада: его грани, спроецированные на плоскость кадра.
    def preview_polygons(faces, facade)
      right = Framing.rotate_90(facade.direction)
      list = faces.sort_by { |f| -f[:area] }.first(MAX_POLYGONS)
      raw = []
      list.each do |face|
        poly = face[:points].map do |pt|
          [pt.x * right.x + pt.y * right.y + pt.z * right.z, pt.z]
        end
        poly = simplify(poly, MAX_POINTS)
        raw << poly if poly.length >= 3
      end
      return [] if raw.empty?
      us = raw.flatten(1).map { |p| p[0] }
      vs = raw.flatten(1).map { |p| p[1] }
      u_min = us.min
      v_max = vs.max
      span = [us.max - u_min, vs.max - vs.min, 1.0e-6].max
      raw.map do |poly|
        poly.map do |(u, v)|
          [
            ((u - u_min) / span * PREVIEW_SCALE).round,
            ((v_max - v) / span * PREVIEW_SCALE).round
          ]
        end
      end
    end

    # Прореживание контура до limit точек (превью — не чертёж).
    def simplify(points, limit)
      return points if points.length <= limit
      step = (points.length.to_f / limit).ceil
      result = []
      index = 0
      while index < points.length
        result << points[index]
        index += step
      end
      result << points.last unless result.last == points.last
      result
    end

    # --------------------------------------------------- плоскости и сцены

    # Точка и нормаль секущей плоскости: параллельно фасаду, чуть перед ним.
    # В SketchUp остаётся та часть модели, куда смотрит нормаль плоскости.
    # Нормаль направлена в здание (как смотрит камера), поэтому скрывается
    # всё между камерой и плоскостью — внутренний двор и соседние крылья, —
    # а сам фасад остаётся целым.
    def section_plane_data(facade)
      projection = Framing.projection(facade.points, facade.direction)
      center = facade_center(facade)
      # Точка на плоскости фасада, чуть сдвинутая к камере.
      span = [projection[:width].to_f, projection[:height].to_f, 1.0].max
      epsilon = span * 0.001
      point = Geom::Point3d.new(
        center.x - facade.direction.x * epsilon,
        center.y - facade.direction.y * epsilon,
        center.z
      )
      normal = Geom::Vector3d.new(facade.direction.x, facade.direction.y, 0.0)
      [point, normal]
    end

    # Создаёт по плоскости на каждый фасад. Возвращает список плоскостей.
    def create_planes!(facades)
      return [] unless @settings.auto_val('cut_sections')
      entities = export_entities
      snapshot_planes
      facades.each do |facade|
        point, normal = section_plane_data(facade)
        plane = begin
          entities.add_section_plane(point, normal)
        rescue StandardError => e
          FacadeExport.log("Секущая плоскость не создана: #{e.message}")
          nil
        end
        next if plane.nil?
        begin
          plane.name = "Разрез #{facade.index}"
        rescue StandardError
          nil
        end
        facade.section_plane = plane
        @planes << plane
      end
      @planes
    end

    # Показывает только плоскость этого фасада и активирует её.
    def activate(facade)
      @planes.each do |plane|
        next if plane.nil? || !plane_alive?(plane)
        hide_plane(plane, plane != facade.section_plane)
      end
      if facade.section_plane
        hide_plane(facade.section_plane, false)
        begin
          facade.section_plane.activate
        rescue StandardError => e
          FacadeExport.log("Плоскость не активирована: #{e.message}")
        end
      end
      view = begin
        @model.active_view
      rescue StandardError
        nil
      end
      if view && facade.camera
        begin
          view.camera = facade.camera
        rescue StandardError => e
          FacadeExport.log("Камера не установлена: #{e.message}")
        end
      end
      facade
    end

    # Создаёт сцены: в каждой своя камера и только своя секущая плоскость.
    def create_scenes!(facades)
      return [] unless @settings.auto_val('create_scenes')
      pages = model_pages
      return [] if pages.nil?
      view = begin
        @model.active_view
      rescue StandardError
        nil
      end
      snapshot_camera(view)
      facades.each do |facade|
        activate(facade)
        page = begin
          pages.add(facade.page_name)
        rescue StandardError => e
          FacadeExport.log("Сцена не создана: #{e.message}")
          nil
        end
        next if page.nil?
        facade.page = page
        @pages << page
        configure_page(page)
      end
      restore_camera(view)
      @pages
    end

    # Сцена должна запоминать камеру и видимость секущих плоскостей.
    def configure_page(page)
      begin
        page.use_section_planes = true if page.respond_to?(:use_section_planes=)
      rescue StandardError
        nil
      end
      flags = 0
      flags |= Sketchup.const_get(:PAGE_USE_CAMERA) if Sketchup.const_defined?(:PAGE_USE_CAMERA)
      if Sketchup.const_defined?(:PAGE_USE_SECTION_PLANES)
        flags |= Sketchup.const_get(:PAGE_USE_SECTION_PLANES)
      end
      return if flags.zero? || !page.respond_to?(:update)
      begin
        page.update(flags)
      rescue StandardError => e
        FacadeExport.log("Сцена не обновлена: #{e.message}")
      end
    end

    # Возвращает состояние разрезов и камеры, убирает временные объекты.
    #   keep_scenes — оставить сцены и плоскости в модели.
    def cleanup!(keep_scenes = false)
      if keep_scenes
        restore_camera(active_view)
        return true
      end
      pages = model_pages
      @pages.each do |page|
        begin
          pages.erase(page) if pages && page_alive?(page)
        rescue StandardError => e
          FacadeExport.log("Сцена не удалена: #{e.message}")
        end
      end
      @pages.clear
      @planes.each do |plane|
        begin
          plane.erase! if plane_alive?(plane)
        rescue StandardError => e
          FacadeExport.log("Плоскость не удалена: #{e.message}")
        end
      end
      @planes.clear
      restore_planes
      restore_camera(active_view)
      true
    end

    def export_entities
      path = begin
        @model.active_path
      rescue StandardError
        nil
      end
      return @model.entities if path.nil? || path.empty?
      begin
        path.last.definition.entities
      rescue StandardError
        @model.entities
      end
    end

    def model_pages
      @model.pages
    rescue StandardError => e
      FacadeExport.log("Сцены недоступны: #{e.message}")
      nil
    end

    def active_view
      @model.active_view
    rescue StandardError
      nil
    end

    # Запоминаем, какие плоскости были видны и какая активна.
    def snapshot_planes
      return if @planes_snapshot
      @planes_snapshot = existing_planes.map do |plane|
        [plane, safe_hidden(plane), plane_active?(plane)]
      end
    end

    def restore_planes
      return if @planes_snapshot.nil?
      @planes_snapshot.each do |plane, hidden, active|
        begin
          next unless plane_alive?(plane)
          hide_plane(plane, hidden)
          plane.activate if active
        rescue StandardError => e
          FacadeExport.log("Состояние разреза не возвращено: #{e.message}")
        end
      end
      @planes_snapshot = nil
    end

    def existing_planes(entities = nil, depth = 0, out = nil)
      out ||= []
      entities ||= export_entities
      return out if entities.nil? || depth > 4
      entities.each do |entity|
        if entity.is_a?(Sketchup::SectionPlane)
          out << entity
          next
        end
        next unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
        definition = begin
          entity.definition
        rescue StandardError
          nil
        end
        existing_planes(definition.entities, depth + 1, out) if definition
      end
      out
    rescue StandardError
      out
    end

    def snapshot_camera(view)
      return if view.nil? || @camera_snapshot
      @camera_snapshot = begin
        view.camera
      rescue StandardError
        nil
      end
    end

    def restore_camera(view)
      return if view.nil? || @camera_snapshot.nil?
      begin
        view.camera = @camera_snapshot
      rescue StandardError => e
        FacadeExport.log("Камера не возвращена: #{e.message}")
      end
      @camera_snapshot = nil
    end

    # Плоскость: hidden -> скрыта (не рисуется и не режет кадр в сцене).
    def hide_plane(plane, hidden)
      begin
        plane.hidden = hidden
      rescue StandardError
        nil
      end
      begin
        plane.visible = !hidden if plane.respond_to?(:visible=)
      rescue StandardError
        nil
      end
    end

    def safe_hidden(plane)
      plane.hidden? == true
    rescue StandardError
      false
    end

    def plane_active?(plane)
      plane.respond_to?(:active?) ? plane.active? == true : true
    rescue StandardError
      true
    end

    def plane_alive?(plane)
      !plane.respond_to?(:valid?) || plane.valid?
    rescue StandardError
      false
    end

    def page_alive?(page)
      !page.respond_to?(:valid?) || page.valid?
    rescue StandardError
      false
    end
  end
end
