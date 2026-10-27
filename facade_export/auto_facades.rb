# encoding: utf-8
# Экспорт фасадов — автоматический поиск фасадов («Автоматический вывод фасада»).
# Автор: Артем Титов (motivate_rt)
#
# Задача кнопки — здания сложной формы: больше четырёх фасадов, ломаный
# контур, внутренние дворы, объёмы под углом (не только 90°).
#
# Порядок работы:
#   1. быстрый проход по граням того контекста, где сейчас пользователь
#      (открытая группа/компонент) или по всей модели — камера не важна.
#      У грани читаются только родные (дешёвые) свойства: нормаль, площадь,
#      габариты. Вершины НЕ перебираются, превью фасадов не строятся —
#      именно на это раньше уходили секунды;
#   2. вертикальные грани группируются по направлению нормали И по глубине
#      плоскости: две параллельные стены на разной глубине (внешняя и
#      внутренняя стена двора) — это разные фасады;
#   3. для окна строится одна схема сверху («жучок») — сетка занятых клеток,
#      без деталей и балконов;
#   4. камеры, секущие плоскости и сцены считаются уже после того, как
#      пользователь выбрал фасады и папку.
#
# Сцены по умолчанию не создаются вовсе: пока они временные, они не нужны.
# Если в настройках включено «оставлять сцены», они создаются ПОСЛЕ экспорта,
# когда файлы уже записаны.

module FacadeExport
  class AutoFacades
    Z_AXIS = Geom::Vector3d.new(0, 0, 1)

    ANGLE_TOL   = 12.0    # градусов: грани одной плоскости
    COS_TOL     = Math.cos(ANGLE_TOL * Math::PI / 180.0)
    VERTICAL_TOL = 0.25   # насколько нормаль должна быть горизонтальной
    DEPTH_TOL   = 0.02    # допуск по глубине, доля диагонали модели
    MIN_DEPTH_TOL = 0.5
    MAX_DEPTH   = 24      # глубина обхода групп/компонентов
    PLAN_GRID   = 40      # сетка схемы сверху (40 × 40 клеток)
    PREVIEW_SCALE = 1000.0

    # Найденный фасад.
    #   normal    — наружу от фасада; direction — куда смотрит камера (= -normal);
    #   records   — грани с их трансформациями (вершины читаются только
    #               для выбранных фасадов, уже после окна);
    #   extents   — габариты фасада в плоскости кадра (u/v) и глубина (d).
    Facade = Struct.new(
      :index, :normal, :direction, :right, :records, :area, :depth, :aspect,
      :name, :page_name, :selected, :image_width, :image_height, :camera,
      :section_plane, :page, :extents, :segment
    )

    def initialize(model, settings = nil)
      @model = model
      @settings = settings || FacadeExport.settings
      @planes = []
      @pages = []
      @planes_snapshot = nil
      @camera_snapshot = nil
      @context_transform = nil
      @scope = :model
    end

    attr_reader :planes, :pages, :scope

    # ------------------------------------------------------------- анализ

    # Быстрый поиск фасадов. Возвращает {:facades, :plan, :scope}.
    def detect
      records = collect_faces
      if records.empty?
        raise ExportError, 'Не найдено видимых граней. Выйдите из группы ' \
                           'или проверьте, что геометрия не скрыта.'
      end
      clusters = cluster_faces(records)
      if clusters.empty?
        raise ExportError, 'Не найдено вертикальных поверхностей — фасады не обнаружены.'
      end
      facades = build_facades(clusters)
      if facades.empty?
        raise ExportError, 'Фасады не обнаружены. Проверьте ориентацию модели.'
      end
      plan = plan_map(records)
      facades.each { |facade| facade.segment = plan_segment(facade, plan) }
      { :facades => facades, :plan => plan, :scope => @scope }
    end

    # Видимые грани контекста: только родные свойства (нормаль, площадь,
    # габариты). Обходятся только грани и контейнеры — рёбра, размеры,
    # тексты и прочее даже не рассматриваются.
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
        @context_transform = nil
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
        @context_transform = transform
      end
      records = []
      walk(entities, transform, 0, records)
      records
    end

    def walk(entities, transform, depth, out)
      return out if entities.nil? || depth > MAX_DEPTH
      @layer_visible ||= {}
      entities.grep(Sketchup::Face).each do |face|
        next unless face_visible?(face)
        record = face_record(face, transform)
        out << record if record
      end
      containers = entities.grep(Sketchup::Group) + entities.grep(Sketchup::ComponentInstance)
      containers.uniq.each do |instance|
        next unless face_visible?(instance)
        local = begin
          instance.transformation
        rescue StandardError
          nil
        end
        next if local.nil?
        definition = begin
          instance.definition
        rescue StandardError
          nil
        end
        next if definition.nil?
        walk(definition.entities, transform.nil? ? local : (transform * local), depth + 1, out)
      end
      out
    rescue StandardError => e
      FacadeExport.log("Авто-фасады: обход геометрии прерван (#{e.message})")
      out
    end

    # Видимость без перебора классов аннотаций: у граней и контейнеров
    # достаточно скрытости и метки (тега).
    def face_visible?(entity)
      return false if entity.respond_to?(:hidden?) && entity.hidden?
      layer = begin
        entity.layer
      rescue StandardError
        nil
      end
      return true if layer.nil?
      key = layer.object_id
      return @layer_visible[key] if @layer_visible.key?(key)
      @layer_visible[key] = begin
        layer.visible? != false
      rescue StandardError
        true
      end
    end

    def face_record(face, transform)
      normal = face.normal
      return nil if normal.nil?
      return nil if normal.z.abs > VERTICAL_TOL
      horizontal = normal.x.abs + normal.y.abs
      return nil if horizontal < 1.0e-6
      area = begin
        face.area.to_f
      rescue StandardError
        0.0
      end
      return nil if area <= 0.0
      bounds = begin
        face.bounds
      rescue StandardError
        nil
      end
      return nil if bounds.nil?
      length = Math.sqrt(normal.x * normal.x + normal.y * normal.y)
      nx = normal.x / length
      ny = normal.y / length
      center = bounds.center
      center = center.transform(transform) unless transform.nil?
      {
        :face      => face,
        :normal    => [nx, ny],
        :area      => area,
        :depth     => center.x * nx + center.y * ny,
        :plan      => plan_bbox(bounds, transform),
        :transform => transform
      }
    rescue StandardError
      nil
    end

    # Габариты грани в плане (мировые координаты).
    def plan_bbox(bounds, transform)
      min = bounds.min
      max = bounds.max
      corners = [
        Geom::Point3d.new(min.x, min.y, min.z),
        Geom::Point3d.new(max.x, min.y, min.z),
        Geom::Point3d.new(min.x, max.y, min.z),
        Geom::Point3d.new(max.x, max.y, min.z)
      ]
      unless transform.nil?
        corners = corners.map { |point| point.transform(transform) }
      end
      xs = corners.map { |point| point.x }
      ys = corners.map { |point| point.y }
      [xs.min, ys.min, xs.max, ys.max]
    rescue StandardError
      nil
    end

    # ------------------------------------------------------------- кластеры

    # Группировка по нормали И по глубине плоскости.
    def cluster_faces(records)
      depth_tol = depth_tolerance(records)
      groups = []
      records.each do |record|
        target = nil
        groups.each do |group|
          if group_accepts?(group, record, depth_tol)
            target = group
            break
          end
        end
        if target
          add_to_group(target, record)
        else
          groups << new_group(record)
        end
      end
      groups.reject! { |group| group[:area] <= 0.0 }
      return [] if groups.empty?

      max_area = groups.map { |group| group[:area] }.max
      min_share = @settings.auto_val('min_area').to_f / 100.0
      keep = groups.select { |group| group[:area] >= max_area * min_share }
      keep = keep.sort_by { |group| -group[:area] }.first(@settings.auto_val('max_facades').to_i)
      keep.sort_by { |group| azimuth([group[:nx], group[:ny]]) }
    end

    def new_group(record)
      {
        :area    => record[:area],
        :vx      => record[:normal][0] * record[:area],
        :vy      => record[:normal][1] * record[:area],
        :depth   => record[:depth],
        :nx      => record[:normal][0],
        :ny      => record[:normal][1],
        :records => [record]
      }
    end

    def add_to_group(group, record)
      group[:area] += record[:area]
      group[:vx] += record[:normal][0] * record[:area]
      group[:vy] += record[:normal][1] * record[:area]
      length = Math.sqrt(group[:vx]**2 + group[:vy]**2)
      if length > 1.0e-9
        group[:nx] = group[:vx] / length
        group[:ny] = group[:vy] / length
      end
      group[:depth] = (group[:depth] * (group[:records].length) + record[:depth]) /
                      (group[:records].length + 1)
      group[:records] << record
    end

    def group_accepts?(group, record, depth_tol)
      dot = group[:nx] * record[:normal][0] + group[:ny] * record[:normal][1]
      return false if dot < COS_TOL
      (record[:depth] - group[:depth]).abs <= depth_tol
    end

    # Допуск по глубине: стены одной плоскости почти совпадают по смещению,
    # а внешняя и внутренняя стена двора — нет.
    def depth_tolerance(records)
      xs = []
      ys = []
      records.each do |record|
        box = record[:plan]
        next if box.nil?
        xs << box[0] << box[2]
        ys << box[1] << box[3]
      end
      return MIN_DEPTH_TOL if xs.empty?
      diagonal = Math.sqrt((xs.max - xs.min)**2 + (ys.max - ys.min)**2)
      tolerance = diagonal * DEPTH_TOL
      tolerance < MIN_DEPTH_TOL ? MIN_DEPTH_TOL : tolerance
    end

    # Азимут горизонтального вектора в градусах 0..360 (0 — +X).
    def azimuth(vector)
      x = vector.is_a?(Array) ? vector[0] : vector.x
      y = vector.is_a?(Array) ? vector[1] : vector.y
      deg = Math.atan2(y, x) * 180.0 / Math::PI
      deg += 360.0 if deg < 0.0
      deg
    end

    # -------------------------------------------------------------- фасады

    def build_facades(groups)
      prefix = @settings.auto_val('scene_prefix').to_s.strip
      prefix = 'Фасад' if prefix.empty?
      aspect = @settings.auto_val('aspect').to_s

      groups.each_with_index.map do |group, index|
        facade = Facade.new
        facade.index = index + 1
        facade.normal = Geom::Vector3d.new(group[:nx], group[:ny], 0.0)
        facade.direction = Geom::Vector3d.new(-group[:nx], -group[:ny], 0.0)
        facade.right = Geom::Vector3d.new(-group[:ny], group[:nx], 0.0)
        facade.records = group[:records]
        facade.area = group[:area]
        facade.depth = group[:depth]
        facade.aspect = aspect
        facade.selected = true
        facade.name = "#{prefix} #{facade.index}"
        facade.page_name = "#{prefix} #{facade.index} — #{compass(facade.normal)}"
        facade
      end
    end

    # Название стороны света (грубо, по осям модели: +Y — север).
    def compass(normal)
      if normal.x.abs >= normal.y.abs
        normal.x >= 0.0 ? 'восток' : 'запад'
      else
        normal.y >= 0.0 ? 'север' : 'юг'
      end
    end

    # --------------------------------------------------------- схема сверху

    # «Жучок»: сетка занятых клеток. Каждая грань закрашивает клетки своих
    # габаритов в плане — крыша даёт силуэт, стены — контур. Никаких деталей,
    # балконов и проработки: схема должна читаться с одного взгляда.
    def plan_map(records)
      xs = []
      ys = []
      records.each do |record|
        box = record[:plan]
        next if box.nil?
        xs << box[0] << box[2]
        ys << box[1] << box[3]
      end
      if xs.empty?
        return { 'grid' => PLAN_GRID, 'cells' => [], :min_x => 0.0, :min_y => 0.0,
                 :span => 1.0 }
      end
      min_x = xs.min
      min_y = ys.min
      span = [xs.max - min_x, ys.max - min_y, 1.0e-6].max
      cells = {}
      total = PLAN_GRID * PLAN_GRID
      records.each do |record|
        break if cells.length >= total
        box = record[:plan]
        next if box.nil?
        ix0, ix1 = cell_range(box[0], box[2], min_x, span)
        iy0, iy1 = cell_range(box[1], box[3], min_y, span)
        (iy0..iy1).each do |iy|
          (ix0..ix1).each { |ix| cells[[ix, iy]] = true }
        end
      end
      # Ось Y в SVG смотрит вниз: переворачиваем, чтобы север был сверху.
      list = cells.keys.map { |(ix, iy)| [ix, PLAN_GRID - 1 - iy] }
      { 'grid' => PLAN_GRID, 'cells' => list,
        :min_x => min_x, :min_y => min_y, :span => span }
    end

    def cell_range(min_value, max_value, origin, span)
      a = ((min_value - origin) / span * PLAN_GRID).floor
      b = ((max_value - origin) / span * PLAN_GRID).ceil - 1
      a = [[a, 0].max, PLAN_GRID - 1].min
      b = [[b, 0].max, PLAN_GRID - 1].min
      b = a if b < a
      [a, b]
    end

    # Линия фасада на схеме: отрезок вдоль стены + нормаль наружу.
    # Координаты — в тех же 0..1000, что и клетки.
    def plan_segment(facade, plan)
      min_x = plan[:min_x]
      min_y = plan[:min_y]
      span = plan[:span]
      u_min = nil
      u_max = nil
      facade.records.each do |record|
        box = record[:plan]
        next if box.nil?
        [[box[0], box[1]], [box[2], box[1]], [box[0], box[3]], [box[2], box[3]]].each do |(x, y)|
          u = x * facade.right.x + y * facade.right.y
          u_min = u if u_min.nil? || u < u_min
          u_max = u if u_max.nil? || u > u_max
        end
      end
      return nil if u_min.nil?
      normal = facade.normal
      depth = facade.depth
      point = lambda do |u|
        x = facade.right.x * u + normal.x * depth
        y = facade.right.y * u + normal.y * depth
        [
          ((x - min_x) / span * PREVIEW_SCALE).round(1),
          (PREVIEW_SCALE - (y - min_y) / span * PREVIEW_SCALE).round(1)
        ]
      end
      {
        'from'   => point.call(u_min),
        'to'     => point.call(u_max),
        'normal' => [normal.x.round(4), -normal.y.round(4)],
        'area'   => facade.area.round(1)
      }
    end

    # ---------------------------------------------------------------- кадры

    # Габариты фасада в плоскости кадра: только для выбранных фасадов,
    # уже после окна. Здесь единственный раз читаются вершины граней.
    def extents(facade)
      return facade.extents unless facade.extents.nil?
      u_min = u_max = v_min = v_max = d_min = d_max = nil
      facade.records.each do |record|
        transform = record[:transform]
        record[:face].vertices.each do |vertex|
          point = vertex.position
          point = point.transform(transform) unless transform.nil?
          u = point.x * facade.right.x + point.y * facade.right.y
          d = -(point.x * facade.direction.x + point.y * facade.direction.y)
          v = point.z
          u_min = u if u_min.nil? || u < u_min
          u_max = u if u_max.nil? || u > u_max
          v_min = v if v_min.nil? || v < v_min
          v_max = v if v_max.nil? || v > v_max
          d_max = d if d_max.nil? || d > d_max
          d_min = d if d_min.nil? || d < d_min
        end
      end
      facade.extents = {
        :u_min => u_min, :u_max => u_max, :v_min => v_min, :v_max => v_max,
        :d_min => d_min, :d_max => d_max
      }
    end

    # Камеры всех выбранных фасадов: общий масштаб (по самому большому),
    # фасад по центру по горизонтали и прижат к низу кадра.
    def build_cameras!(facades)
      return facades if facades.nil? || facades.empty?
      plans = facades.map { |facade| per_facade_plan(facade) }.compact
      return facades if plans.empty?
      scale = plans.map { |plan| plan[:scale] }.min
      plans.each { |plan| plan[:facade].camera = camera_for(plan, scale) }
      facades
    end

    def per_facade_plan(facade)
      extents = extents(facade)
      return nil if extents[:u_min].nil?
      width, height = self.class.image_size(facade.aspect, @settings.export)
      facade.image_width = width
      facade.image_height = height
      gap = Framing.gap_pixels(@settings.export, width, height)
      avail_w = [width - 2.0 * gap, 1.0].max
      avail_h = [height - 2.0 * gap, 1.0].max
      facade_width = [(extents[:u_max] - extents[:u_min]).abs, 1.0e-6].max
      facade_height = [(extents[:v_max] - extents[:v_min]).abs, 1.0e-6].max
      scale = [
        avail_w / facade_width,
        avail_h / facade_height
      ].min
      scale = 1.0 if scale.nil? || scale <= 0.0 || scale.nan?
      {
        :facade => facade,
        :extents => extents,
        :image_width => width,
        :image_height => height,
        :gap => gap,
        :scale => scale
      }
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

    def camera_for(plan, scale)
      facade = plan[:facade]
      extents = plan[:extents]
      height = plan[:image_height]
      frame_height = height.to_f / scale
      u_center = (extents[:u_min] + extents[:u_max]) / 2.0
      v_target = extents[:v_min] + (height / 2.0 - plan[:gap]) / scale
      normal = facade.normal
      depth = facade.depth
      target = Geom::Point3d.new(
        facade.right.x * u_center + normal.x * depth,
        facade.right.y * u_center + normal.y * depth,
        v_target
      )

      # Камера стоит ровно перед фасадом: чем ближе, тем меньше «прыжок»
      # вида, если что-то пойдёт не так, и тем точнее картинка. Запас нужен
      # только чтобы не обрезать геометрию за секущей плоскостью.
      depth_behind = [(extents[:d_max] - extents[:d_min]).abs, 0.0].max
      facade_diagonal = Math.sqrt(
        (extents[:u_max] - extents[:u_min])**2 + (extents[:v_max] - extents[:v_min])**2
      )
      distance = [frame_height * 1.5, facade_diagonal * 1.5, depth_behind + frame_height].max
      distance = 10.0 if distance < 10.0

      # direction — куда смотрит камера (внутрь здания), поэтому камера
      # стоит снаружи: eye = target - direction * distance.
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

    # --------------------------------------------------- плоскости и сцены

    # Точка и нормаль секущей плоскости в координатах контекста.
    # Плоскость параллельна фасаду и стоит чуть ГЛУБЖЕ стены; нормаль смотрит
    # в здание, поэтому отрезается всё за стеной (интерьер, внутренние стены,
    # крылья за двором), а фасад и его внешние детали (балконы, козырьки,
    # откосы) остаются целыми. Секущая плоскость скрывает ту сторону, куда
    # смотрит её нормаль.
    def section_plane_data(facade)
      extents = extents(facade)
      u_center = (extents[:u_min] + extents[:u_max]) / 2.0
      v_center = (extents[:v_min] + extents[:v_max]) / 2.0
      span = [(extents[:u_max] - extents[:u_min]).abs, (extents[:v_max] - extents[:v_min]).abs, 1.0].max
      epsilon = span * 0.001
      # d — смещение точки вдоль нормали наружу; «за стеной» = d меньше d_min.
      d = extents[:d_min] - epsilon
      normal = facade.normal
      point = Geom::Point3d.new(
        facade.right.x * u_center + normal.x * d,
        facade.right.y * u_center + normal.y * d,
        v_center
      )
      plane_normal = Geom::Vector3d.new(-normal.x, -normal.y, 0.0)
      to_context(point, plane_normal)
    end

    # Точка и вектор в координатах того контекста, где лежит плоскость.
    def to_context(point, vector)
      return [point, vector] if @context_transform.nil?
      inverse = begin
        @context_transform.inverse
      rescue StandardError
        nil
      end
      return [point, vector] if inverse.nil?
      local_point = begin
        point.transform(inverse)
      rescue StandardError
        point
      end
      local_vector = begin
        vector.transform(inverse)
      rescue StandardError
        vector
      end
      length = local_vector.length
      local_vector = Geom::Vector3d.new(local_vector.x / length, local_vector.y / length, 0.0) if length > 1.0e-9
      [local_point, local_vector]
    end

    # Создаёт по плоскости на каждый фасад. Возвращает список плоскостей.
    def create_planes!(facades)
      return [] unless @settings.auto_val('cut_sections')
      with_entities do |entities|
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
      end
      @planes
    end

    # Показывает только плоскость этого фасада, активирует её и ставит камеру.
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
      view = active_view
      return facade if view.nil? || facade.camera.nil?
      begin
        view.camera = facade.camera
      rescue StandardError => e
        FacadeExport.log("Камера не установлена: #{e.message}")
      end
      facade
    end

    # Сцены создаются ПОСЛЕ экспорта: файлы уже записаны, и сбой со сценами
    # не может испортить результат.
    def create_scenes!(facades)
      pages = model_pages
      return [] if pages.nil?
      view = active_view
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

    # Убирает временное: плоскости и (если не оставляем) сцены.
    # keep_scenes — оставить сцены и плоскости в модели.
    def cleanup!(keep_scenes = false)
      unless keep_scenes
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
      end
      restore_camera(active_view)
      true
    end

    # ------------------------------------------------------------- служебное

    def with_entities
      path = begin
        @model.active_path
      rescue StandardError
        nil
      end
      entities = if path.nil? || path.empty?
                   @model.entities
                 else
                   begin
                     path.last.definition.entities
                   rescue StandardError
                     @model.entities
                   end
                 end
      yield entities
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
      if entities.nil?
        path = begin
          @model.active_path
        rescue StandardError
          nil
        end
        entities = if path.nil? || path.empty?
                     @model.entities
                   else
                     begin
                       path.last.definition.entities
                     rescue StandardError
                       @model.entities
                     end
                   end
      end
      return out if depth > 4
      entities.grep(Sketchup::SectionPlane).each { |plane| out << plane }
      (entities.grep(Sketchup::Group) + entities.grep(Sketchup::ComponentInstance)).uniq.each do |instance|
        definition = begin
          instance.definition
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

    def restore_camera(view = nil)
      view ||= active_view
      return if view.nil? || @camera_snapshot.nil?
      begin
        view.camera = @camera_snapshot
      rescue StandardError => e
        FacadeExport.log("Камера не возвращена: #{e.message}")
      end
      @camera_snapshot = nil
    end

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
