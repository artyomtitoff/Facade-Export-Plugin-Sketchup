# encoding: utf-8
# Экспорт фасадов — расчёт камеры и кадра.
# Автор: Артем Титов (motivate_rt)
#
# Правила кадра:
#   * кадрируется только то, что экспортируется: вся модель или,
#     если пользователь вошёл в группу/компонент, — содержимое этой группы;
#   * соотношение сторон кадра задано настройкой (по умолчанию 4:3),
#     большая сторона = ширина из настроек (9999), вторая — по соотношению;
#   * для высоких объектов (башни, небоскрёбы) кадр разворачивается:
#     9999 уходит по вертикали, вторая сторона — по соотношению;
#   * масштаб общий для всех четырёх фасадов и не зависит от размера
#     окна просмотра SketchUp;
#   * фасад прижат к низу кадра на расстоянии зазора, по центру по горизонтали.
#
# Отдельный режим «Экспортировать только видимый участок»
# (export.visible_area = true) ничего не масштабирует: в PNG попадает то,
# что пользователь видит в окне SketchUp (см. visible_cameras).

module FacadeExport
  # Класс ошибок плагина (понятные сообщения пользователю).
  class ExportError < StandardError; end

  module Framing
    Z_AXIS = Geom::Vector3d.new(0, 0, 1)
    MIN_SIZE = 1.0e-6
    # Угол обзора перспективной камеры (используется только в расширенных
    # настройках; по умолчанию проекция параллельная).
    FOV = 35.0

    module_function

    # Горизонтальное направление взгляда камеры (куда смотрит камера).
    def horizontal_direction(camera)
      d = camera.direction
      v = Geom::Vector3d.new(d.x, d.y, 0.0)
      if v.length < 1.0e-6
        return [nil, 'Вид направлен вертикально (сверху/снизу). ' \
                     'Выровняйте вид перпендикулярно фасаду.']
      end
      if d.z.abs > 0.75
        return [nil, 'Вид слишком сильно наклонён. Выровняйте вид перпендикулярно ' \
                     'плоскости фасада (Камера > Стандартные виды или "Выровнять вид").']
      end
      [v.normalize, nil]
    end

    # Поворот горизонтального вектора на 90° (по часовой стрелке относительно Z).
    def rotate_90(vector)
      Geom::Vector3d.new(vector.y, -vector.x, 0.0)
    end

    # Направления взгляда для всех фасадов, начиная с текущего вида.
    def facade_directions(camera, count = 4)
      base, error = horizontal_direction(camera)
      raise ExportError, error if base.nil?
      dirs = []
      v = base
      count.times do
        dirs << Geom::Vector3d.new(v.x, v.y, 0.0)
        v = rotate_90(v)
      end
      dirs
    end

    # Восемь углов габаритного ящика.
    def bbox_corners(bounds)
      if bounds.nil? || bounds.empty?
        raise ExportError, 'В модели нет геометрии: экспортировать нечего.'
      end
      xs = [bounds.min.x, bounds.max.x]
      ys = [bounds.min.y, bounds.max.y]
      zs = [bounds.min.z, bounds.max.z]
      corners = []
      xs.each do |x|
        ys.each do |y|
          zs.each do |z|
            corners << Geom::Point3d.new(x, y, z)
          end
        end
      end
      corners
    end

    def bounds_from_points(points)
      box = Geom::BoundingBox.new
      points.each { |pt| box.add(pt) }
      box
    end

    # Что именно экспортируем:
    #   :model   — вся модель;
    #   :context — содержимое группы/компонента, внутри которого сейчас пользователь.
    # Возвращает [габариты, режим].
    def content_bounds(model)
      path = begin
        model.active_path
      rescue StandardError
        nil
      end
      if path.nil? || path.empty?
        visible = visible_bounds(model.entities)
        return [visible, :model] unless visible.empty?
        return [model.bounds, :model]
      end

      transform = Geom::Transformation.new
      path.each do |instance|
        transform = transform * instance.transformation
      end
      definition = begin
        path.last.definition
      rescue StandardError
        nil
      end
      raise ExportError, 'Не удалось определить габариты открытой группы.' if definition.nil?

      # Внутри группы тоже кадрируем только видимое содержимое, чтобы
      # скрытая геометрия не превращала фасад в маленькое пятно на листе.
      visible = visible_bounds(definition.entities, transform)
      return [visible, :context] unless visible.empty?

      corners = bbox_corners(definition.bounds).map { |pt| pt.transform(transform) }
      [bounds_from_points(corners), :context]
    end

    # Габариты только видимых сущностей (скрытые и выключенные теги не в счёт).
    # transform — преобразование из координат контекста в координаты модели.
    def visible_bounds(entities, transform = nil)
      box = Geom::BoundingBox.new
      entities.each do |entity|
        next unless entity_visible?(entity)
        bounds = begin
          entity.bounds
        rescue StandardError
          nil
        end
        next if bounds.nil? || bounds.empty?
        if transform.nil?
          box.add(bounds.min)
          box.add(bounds.max)
        else
          bbox_corners(bounds).each { |pt| box.add(pt.transform(transform)) }
        end
      end
      box
    end

    # Служебные объекты, которые не рисуются в кадре (или рисуются как
    # аннотации): направляющие, точки, сечения, тексты и размеры.
    ANNOTATION_CLASSES = %w[
      ConstructionLine ConstructionPoint SectionPlane Text Dimension
    ].freeze

    def entity_visible?(entity)
      ANNOTATION_CLASSES.each do |name|
        klass = Sketchup.const_get(name) if Sketchup.const_defined?(name, false)
        return false if klass && entity.is_a?(klass)
      end
      return false if entity.respond_to?(:hidden?) && entity.hidden?
      if entity.respond_to?(:layer)
        layer = begin
          entity.layer
        rescue StandardError
          nil
        end
        if layer && layer.respond_to?(:visible?) && layer.visible? == false
          return false
        end
      end
      true
    end

    # Проекция габаритов на плоскость кадра для одного направления взгляда.
    def projection(corners, direction)
      right = direction.cross(Z_AXIS)
      right = Geom::Vector3d.new(1, 0, 0) if right.length < 1.0e-6
      right.normalize!

      us = []
      vs = []
      corners.each do |c|
        us << (c.x * right.x + c.y * right.y + c.z * right.z)
        vs << c.z
      end

      {
        :right => right,
        :u_min => us.min,
        :u_max => us.max,
        :v_min => vs.min,
        :v_max => vs.max,
        :width => (us.max - us.min).abs,
        :height => (vs.max - vs.min).abs,
        :u_center => (us.min + us.max) / 2.0,
        :v_center => (vs.min + vs.max) / 2.0
      }
    end

    def projections(bounds, directions)
      corners = bbox_corners(bounds)
      directions.map { |d| projection(corners, d) }
    end

    # Индекс самого большого фасада: у него самая длинная сторона.
    def biggest_index(projections)
      best = 0
      best_value = -1.0
      projections.each_with_index do |p, i|
        value = [p[:width], p[:height]].max
        if value > best_value
          best_value = value
          best = i
        end
      end
      best
    end

    # Размер кадра в пикселях.
    #   width  — длина большей стороны,
    #   height — 0 => по соотношению сторон.
    # Возвращает [ширина, высота, вертикальный?].
    def image_size(export_settings, projections)
      longest = export_settings['width'].to_i
      longest = Config::MIN_IMAGE_SIDE if longest < Config::MIN_IMAGE_SIDE
      height = export_settings['height'].to_i
      return [longest, height, height > longest] if height > 0

      vertical = content_vertical?(projections)
      aw, ah = Config.aspect_ratio(export_settings['aspect'])
      ratio = aw.to_f / ah.to_f
      ratio = 1.0 / ratio if vertical && ratio > 1.0
      ratio = 1.0 / ratio if !vertical && ratio < 1.0

      if ratio >= 1.0
        [longest, [(longest / ratio).round, Config::MIN_IMAGE_SIDE].max, false]
      else
        [(longest * ratio).round, longest, true]
      end
    end

    # Вертикальный ли самый большой фасад (башня/небоскрёб).
    def content_vertical?(projections)
      p = projections[biggest_index(projections)]
      p[:height] > p[:width]
    end

    # Пикселей на единицу модели: общий масштаб для всех фасадов,
    # при котором самый большой фасад занимает кадр целиком (минус зазоры).
    def pixels_per_unit(projections, image_width, image_height, gap_px)
      avail_w = [image_width - 2.0 * gap_px, Config::MIN_IMAGE_SIDE].max
      avail_h = [image_height - 2.0 * gap_px, Config::MIN_IMAGE_SIDE].max
      scale = nil
      projections.each do |p|
        w = [p[:width].to_f, MIN_SIZE].max
        h = [p[:height].to_f, MIN_SIZE].max
        candidate = [avail_w / w, avail_h / h].min
        scale = candidate if scale.nil? || candidate < scale
      end
      scale = 1.0 if scale.nil? || scale <= 0.0 || scale.nan?
      scale
    end

    # Зазор в пикселях кадра.
    def gap_pixels(export_settings, image_width, image_height)
      fraction = export_settings['margin'].to_f
      base = [image_width, image_height].max
      [(base * fraction).round, 0].max
    end

    # Камера для одного фасада: прижата к низу кадра, по центру по горизонтали.
    def build_camera(bounds, direction, projection, scale, image_width, image_height,
                     gap_px, parallel = true)
      right = projection[:right]
      center = bounds.center
      center_u = center.x * right.x + center.y * right.y + center.z * right.z
      shift = projection[:u_center] - center_u

      frame_height = image_height.to_f / scale      # высота кадра в единицах модели
      target_z = projection[:v_min] + (image_height / 2.0 - gap_px) / scale
      target = Geom::Point3d.new(
        center.x + right.x * shift,
        center.y + right.y * shift,
        target_z
      )

      distance = if parallel
                   camera_distance(bounds, frame_height, projection, scale)
                 else
                   perspective_distance(bounds)
                 end
      eye = Geom::Point3d.new(
        target.x - direction.x * distance,
        target.y - direction.y * distance,
        target.z - direction.z * distance
      )

      camera = Sketchup::Camera.new(eye, target, Z_AXIS)
      begin
        camera.perspective = parallel ? false : true
      rescue StandardError
        nil
      end
      begin
        if parallel
          camera.height = frame_height
        else
          camera.fov = FOV
        end
      rescue StandardError
        nil
      end
      camera
    end

    # Расстояние для перспективной камеры: габаритный шар целиком в кадре.
    def perspective_distance(bounds)
      diag = 1.0
      begin
        d = bounds.max - bounds.min
        diag = Math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
      rescue StandardError
        diag = 1000.0
      end
      diag = 1000.0 if diag.nil? || diag.to_f <= 0.0 || diag.to_f.nan?
      half_fov = (FOV / 2.0) * Math::PI / 180.0
      sin_half = Math.sin(half_fov)
      return diag * 2.0 if sin_half <= 0.0
      diag / 2.0 / sin_half * 1.05
    end

    # Камера стоит достаточно далеко, чтобы отсечение не срезало геометрию.
    def camera_distance(bounds, frame_height, projection, scale)
      diag = 1.0
      begin
        d = bounds.max - bounds.min
        diag = Math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
      rescue StandardError
        diag = 1000.0
      end
      diag = 1000.0 if diag.nil? || diag.to_f <= 0.0 || diag.to_f.nan?
      depth = 0.0
      begin
        depth = projection[:depth].to_f
      rescue StandardError
        depth = 0.0
      end
      [diag * 2.0, frame_height * 2.0, depth * 1.5 + frame_height].max
    end

    # Проекция с учётом глубины по направлению взгляда (для дистанции камеры).
    def projection_with_depth(corners, direction)
      data = projection(corners, direction)
      us = corners.map { |c| c.x * direction.x + c.y * direction.y + c.z * direction.z }
      data[:depth] = (us.max - us.min).abs
      data
    end

    # ------------------------------------------------- режим «что на экране»
    #
    # «Экспортировать только видимый участок»: кадр не подгоняется под
    # габариты объекта. Берётся текущий вид пользователя — тот же ракурс,
    # тот же зум, та же композиция. Ограничения остаются прежними:
    #   * параллельная проекция (если включена в настройках);
    #   * соотношение сторон и размеры — из настроек (4:3, большая сторона
    #     9999 px), а не из окна просмотра;
    #   * остальные фасады — та же камера, повёрнутая на 90° вокруг цели.

    # Камера переводится в параллельную проекцию до начала экспорта:
    # сохраняются точка взгляда, цель и направление, а высота кадра
    # подбирается так, чтобы вместить то же, что вмещала перспектива.
    def parallel_camera(camera)
      target = Geom::Point3d.new(camera.target.x, camera.target.y, camera.target.z)
      eye = Geom::Point3d.new(camera.eye.x, camera.eye.y, camera.eye.z)
      cam = Sketchup::Camera.new(eye, target, Z_AXIS)
      begin
        cam.up = camera.up
      rescue StandardError
        nil
      end
      begin
        cam.perspective = false
      rescue StandardError
        nil
      end
      begin
        cam.height = visible_frame_height(camera)
      rescue StandardError
        nil
      end
      cam
    end

    # Перспективная ли камера (для решения о переключении вида).
    def perspective?(camera)
      camera.perspective? == true
    rescue StandardError
      false
    end

    # Отношение сторон окна просмотра (ширина / высота).
    # Используется только как справочное: размер кадра задают настройки.
    def viewport_ratio(view)
      w = begin
        view.vpwidth.to_f
      rescue StandardError
        0.0
      end
      h = begin
        view.vpheight.to_f
      rescue StandardError
        0.0
      end
      return nil if w <= 0.0 || h <= 0.0
      w / h
    end

    # Высота кадра в единицах модели для текущей камеры.
    def visible_frame_height(camera)
      perspective = begin
        camera.perspective?
      rescue StandardError
        true
      end
      unless perspective
        h = begin
          camera.height.to_f
        rescue StandardError
          0.0
        end
        return h if h > 0.0
      end
      distance = begin
        (camera.eye - camera.target).length
      rescue StandardError
        0.0
      end
      fov = begin
        camera.fov.to_f
      rescue StandardError
        FOV
      end
      fov = FOV if fov <= 0.0 || fov >= 170.0
      height = 2.0 * distance * Math.tan(fov / 2.0 * Math::PI / 180.0)
      height > 0.0 ? height : 1000.0
    end

    # Размер картинки в режиме «что на экране».
    # Соотношение сторон берётся ИЗ НАСТРОЕК (export.aspect), а не из окна
    # просмотра: размер PNG должен быть одинаковым на любом компьютере.
    # Длинная сторона — «ширина» из настроек, вторая — по соотношению.
    def visible_image_size(export_settings)
      longest = export_settings['width'].to_i
      longest = Config::MIN_IMAGE_SIDE if longest < Config::MIN_IMAGE_SIDE
      height = export_settings['height'].to_i
      return [longest, height] if height > 0

      aw, ah = Config.aspect_ratio(export_settings['aspect'])
      ratio = aw.to_f / ah.to_f
      ratio = 1.0 if ratio <= 0.0
      side = [(longest * [ratio, 1.0 / ratio].min).round, Config::MIN_IMAGE_SIDE].max
      ratio >= 1.0 ? [longest, side] : [side, longest]
    end

    # Камеры для всех фасадов в режиме «что на экране».
    # Первая — ровно текущий вид, каждая следующая повёрнута на 90°.
    def visible_cameras(camera, view, export_settings, count = 4, parallel = true)
      width, height = visible_image_size(export_settings)
      ratio = height.to_f.zero? ? 1.0 : width.to_f / height.to_f
      frame_height = visible_frame_height(camera)
      camera = parallel_camera(camera) if parallel && perspective?(camera)

      target = Geom::Point3d.new(camera.target.x, camera.target.y, camera.target.z)
      eye = camera.eye
      dx = eye.x - target.x
      dy = eye.y - target.y
      dz = eye.z - target.z

      cameras = []
      count.times do
        cam = Sketchup::Camera.new(
          Geom::Point3d.new(target.x + dx, target.y + dy, target.z + dz),
          Geom::Point3d.new(target.x, target.y, target.z),
          Z_AXIS
        )
        begin
          cam.perspective = parallel ? false : true
        rescue StandardError
          nil
        end
        begin
          if parallel
            cam.height = frame_height
          else
            cam.fov = camera.fov
          end
        rescue StandardError
          nil
        end
        cameras << cam
        # поворот вектора «цель -> камера» на 90° вокруг вертикальной оси
        dx, dy = dy, -dx
      end

      [{
        :image_width => width,
        :image_height => height,
        :frame_height => frame_height,
        :ratio => ratio,
        :visible => true,
        :gap => 0,
        :scale => height.to_f / [frame_height, MIN_SIZE].max
      }, cameras]
    end

    def plan(bounds, directions, export_settings)
      corners = bbox_corners(bounds)
      projections = directions.map { |d| projection_with_depth(corners, d) }
      width, height, vertical = image_size(export_settings, projections)
      gap = gap_pixels(export_settings, width, height)
      scale = pixels_per_unit(projections, width, height, gap)
      {
        :projections => projections,
        :image_width => width,
        :image_height => height,
        :vertical => vertical,
        :gap => gap,
        :scale => scale,
        :biggest => biggest_index(projections)
      }
    end
  end
end
