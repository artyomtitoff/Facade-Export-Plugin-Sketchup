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
    #
    # Габариты строятся только по видимым линиям и граням: скрытые объекты,
    # геометрия со скрытых меток (тегов), направляющие, сечения, размеры и
    # тексты в кадр не входят. Раньше в расчёт попадал `entity.bounds`, и
    # спрятанная геометрия растягивала кадр — фасад уходил в вертикальное
    # соотношение с огромным отступом.
    def content_bounds(model)
      reset_cache!
      path = begin
        model.active_path
      rescue StandardError
        nil
      end
      if path.nil? || path.empty?
        box = visible_bounds(model.entities)
        if box.empty?
          raise ExportError, 'В модели нет видимых линий и граней: всё скрыто или ' \
                             'лежит на скрытых метках. Включите нужную геометрию ' \
                             'и повторите экспорт.'
        end
        return [box, :model]
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

      # Внутри группы тоже кадрируем только видимое содержимое.
      box = visible_bounds(definition.entities, transform)
      if box.empty?
        raise ExportError, 'В открытой группе нет видимых линий и граней. ' \
                           'Выйдите из группы или включите её геометрию.'
      end
      [box, :context]
    end

    # Сброс кэшей габаритов. Нужен перед каждым экспортом: видимость
    # объектов внутри компонентов могла измениться.
    def reset_cache!
      @definition_cache = {}
      @layer_cache = {}
      @kind_cache = {}
      @support_cache = {}
    end

    # Максимальная глубина вложенности групп/компонентов при обходе.
    MAX_DEPTH = 32

    # Габариты только видимой геометрии: рёбра и грани, которые реально
    # рисуются, плюс видимое содержимое групп и компонентов.
    # transform — преобразование из координат контекста в координаты модели.
    def visible_bounds(entities, transform = nil)
      box = Geom::BoundingBox.new
      collect_visible(entities, transform, box, 0)
      box
    end

    # Обход сделан «дешёвым»: тип сущности определяется один раз на класс
    # (кэш @kind_cache), видимость метки — один раз на метку (@layer_cache),
    # а габариты видимого ребра/грани берутся готовыми (`entity.bounds`).
    # На больших моделях это в разы быстрее, чем is_a?/respond_to? на каждый
    # из сотен тысяч объектов.
    def collect_visible(entities, transform, box, depth)
      return box if entities.nil? || depth > MAX_DEPTH
      entities.each do |entity|
        klass = entity.class
        next if supports?(klass, :hidden?, nil) && entity.hidden?
        kind = entity_kind(entity)
        next if kind == :annotation || kind == :skip
        next unless layer_visible?(entity, klass)
        if kind == :instance
          add_instance_bounds(entity, transform, box, depth)
        else
          # Видимое ребро, грань или картинка: габариты объекта точные.
          add_entity_bounds(entity, transform, box)
        end
      end
      box
    rescue StandardError => e
      FacadeExport.log("Габариты: обход прерван (#{e.message})")
      box
    end

    # Тип сущности по её классу (результат кэшируется для класса).
    def entity_kind(entity)
      klass = entity.class
      cache = (@kind_cache ||= {})
      cached = cache[klass]
      return cached if cached
      cache[klass] = classify_entity(entity)
    end

    def classify_entity(entity)
      return :skip if annotation_class?(entity)
      return :instance if instance_entity?(entity)
      return :other if edge_entity?(entity) || face_entity?(entity)
      return :other if entity.respond_to?(:bounds)
      :skip
    rescue StandardError
      :skip
    end

    def add_entity_bounds(entity, transform, box)
      bounds = safe_bounds(entity)
      return if bounds.nil? || bounds.empty?
      add_local_box(box, bounds, transform)
    end

    # Группа/компонент: берём габариты содержимого определения (кэш) и
    # переносим их преобразованием экземпляра.
    def add_instance_bounds(instance, transform, box, depth)
      definition = begin
        instance.definition
      rescue StandardError
        nil
      end
      return if definition.nil?
      local = definition_visible_bounds(definition, depth)
      return if local.nil? || local.empty?
      own = begin
        instance.transformation
      rescue StandardError
        nil
      end
      world = own.nil? ? transform : (transform.nil? ? own : transform * own)
      add_local_box(box, local, world)
    end

    # Габариты видимого содержимого определения в его собственных координатах.
    def definition_visible_bounds(definition, depth = 0)
      @definition_cache ||= {}
      key = begin
        definition.respond_to?(:entityID) ? definition.entityID : definition.object_id
      rescue StandardError
        definition.object_id
      end
      cached = @definition_cache[key]
      return cached if cached
      box = Geom::BoundingBox.new
      collect_visible(definition.entities, nil, box, depth + 1)
      @definition_cache[key] = box
      box
    end

    def add_local_box(box, local, transform)
      if transform.nil?
        bbox_corners(local).each { |pt| box.add(pt) }
      else
        bbox_corners(local).each { |pt| box.add(pt.transform(transform)) }
      end
    end

    # Есть ли у класса сущности такой метод (проверяется один раз на класс:
    # respond_to? на каждый объект большой модели заметно замедляет обход).
    def supports?(klass, method, cache)
      cache = (@support_cache ||= {})[method] ||= {} if cache.nil?
      cached = cache[klass]
      return cached unless cached.nil?
      cache[klass] = begin
        klass.method_defined?(method) || klass.private_method_defined?(method)
      rescue StandardError
        true
      end
    end

    # Видима ли метка (тег) сущности и её папка. Результат кэшируется
    # по объекту метки: у модели обычно десятки меток, а сущностей — тысячи.
    def layer_visible?(entity, klass = entity.class)
      layer = begin
        supports?(klass, :layer, nil) ? entity.layer : nil
      rescue StandardError
        nil
      end
      return true if layer.nil?
      cache = (@layer_cache ||= {})
      key = layer.object_id
      cached = cache[key]
      return cached unless cached.nil?
      cache[key] = layer_visible_object?(layer)
    end

    def layer_visible_object?(layer)
      return false if layer.respond_to?(:visible?) && layer.visible? == false
      folder = begin
        layer.respond_to?(:folder) ? layer.folder : nil
      rescue StandardError
        nil
      end
      return false if folder && folder.respond_to?(:visible?) && folder.visible? == false
      true
    end

    def edge_entity?(entity)
      return true if defined?(Sketchup::Edge) && entity.is_a?(Sketchup::Edge)
      entity.respond_to?(:start) && entity.respond_to?(:end) &&
        !entity.respond_to?(:vertices)
    rescue StandardError
      false
    end

    def face_entity?(entity)
      defined?(Sketchup::Face) && entity.is_a?(Sketchup::Face)
    rescue StandardError
      false
    end

    def instance_entity?(entity)
      (defined?(Sketchup::Group) && entity.is_a?(Sketchup::Group)) ||
        (defined?(Sketchup::ComponentInstance) && entity.is_a?(Sketchup::ComponentInstance))
    rescue StandardError
      false
    end

    # Точки грани: внешний контур и отверстия.
    def face_points(face)
      points = []
      vertices = begin
        face.vertices
      rescue StandardError
        nil
      end
      if vertices
        vertices.each { |v| points << v.position }
        return points
      end
      loops = begin
        face.loops
      rescue StandardError
        nil
      end
      Array(loops).each do |loop|
        begin
          loop.vertices.each { |v| points << v.position }
        rescue StandardError
          nil
        end
      end
      points
    end

    def safe_bounds(entity)
      entity.bounds
    rescue StandardError
      nil
    end

    # Служебные объекты, которые не рисуются в кадре (или рисуются как
    # аннотации): направляющие, точки, сечения, тексты и размеры.
    ANNOTATION_CLASSES = %w[
      ConstructionLine ConstructionPoint SectionPlane Text Dimension
    ].freeze

    # Классы-аннотации ищутся один раз, а не на каждый объект модели:
    # габариты считаются по тысячам рёбер, и лишние const_get заметны.
    def annotation_classes
      @annotation_classes ||= ANNOTATION_CLASSES.map do |name|
        Sketchup.const_get(name) if Sketchup.const_defined?(name, false)
      end.compact
    rescue StandardError
      []
    end

    def annotation_class?(entity)
      annotation_classes.any? { |klass| entity.is_a?(klass) }
    end

    # Видима ли сущность: не аннотация, не скрыта, её метка (тег) включена.
    def entity_visible?(entity)
      return false if annotation_class?(entity)
      return false if entity.respond_to?(:hidden?) && entity.hidden?
      layer_visible?(entity)
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
    #
    # image_height — высота КАДРА в пикселях (то, что попадёт в PNG после
    # обрезки). canvas_height — высота снимка, который реально делает SketchUp;
    # если окно просмотра не в пропорциях кадра, снимок выше кадра и потом
    # обрезается по центру (см. render_canvas).
    def build_camera(bounds, direction, projection, scale, image_width, image_height,
                     gap_px, parallel = true, canvas_height = nil)
      canvas_height ||= image_height
      right = projection[:right]
      center = bounds.center
      center_u = center.x * right.x + center.y * right.y + center.z * right.z
      shift = projection[:u_center] - center_u

      # Высота снимка в единицах модели: ровно canvas_height пикселей.
      frame_height = canvas_height.to_f / scale
      target_z = projection[:v_min] + (image_height / 2.0 - gap_px) / scale
      target = Geom::Point3d.new(
        center.x + right.x * shift,
        center.y + right.y * shift,
        target_z
      )

      distance = if parallel
                   camera_distance(bounds, frame_height, projection, scale)
                 else
                   perspective_distance(frame_height)
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

    # Размер снимка и размер кадра после обрезки.
    #
    # SketchUp всегда снимает ВСЁ окно просмотра и растягивает снимок до
    # запрошенных пикселей. Окно SketchUp почти всегда шире кадра (16:9,
    # ultrawide 21:9 и т. п.), поэтому кадр занимает только часть картинки, а
    # по краям остаются пустые полосы. Раньше это и выглядело как «огромные
    # отступы у всех фасадов» — в модели их не было, их давало окно.
    #
    # Теперь снимок делается в пропорциях окна (без растяжения), а потом из
    # него вырезается центральная область кадра. Результат одинаковый на
    # любом мониторе.
    #
    # Возвращает [ширина снимка, высота снимка, ширина кадра, высота кадра].
    def render_canvas(image_width, image_height, viewport_ratio)
      width = image_width.to_i
      height = image_height.to_i
      return [width, height, width, height] if width <= 0 || height <= 0
      target = width.to_f / height.to_f
      ratio = viewport_ratio.to_f
      if !ratio.finite? || ratio <= 0.0 || (ratio - target).abs <= target * 0.01
        return [width, height, width, height]
      end

      if ratio > target
        canvas_h = height.to_f
        canvas_w = canvas_h * ratio
      else
        canvas_w = width.to_f
        canvas_h = canvas_w / ratio
      end

      # Ограничение SketchUp — 16000 px на сторону.
      scale = 1.0
      scale = [scale, Config::MAX_IMAGE_SIDE / canvas_w].min if canvas_w > Config::MAX_IMAGE_SIDE
      scale = [scale, Config::MAX_IMAGE_SIDE / canvas_h].min if canvas_h > Config::MAX_IMAGE_SIDE
      canvas_w = (canvas_w * scale).round
      canvas_h = (canvas_h * scale).round
      canvas_w = 1 if canvas_w < 1
      canvas_h = 1 if canvas_h < 1

      crop_h = [height, canvas_h].min
      crop_w = (crop_h * target).round
      if crop_w > canvas_w
        crop_w = [width, canvas_w].min
        crop_h = (crop_w / target).round
        crop_h = canvas_h if crop_h > canvas_h
      end
      crop_w = 1 if crop_w < 1
      crop_h = 1 if crop_h < 1
      [canvas_w, canvas_h, crop_w, crop_h]
    end

    # Расстояние для перспективной камеры.
    #
    # Кадр должен показывать ровно ту же область, что и параллельный:
    # по вертикали — frame_height единиц модели. Расстояние подбирается так,
    # чтобы на плоскости цели вертикальный угол обзора FOV накрывал ровно
    # frame_height: D = (frame_height / 2) / tan(FOV / 2).
    #
    # Раньше здесь вписывался описанный шар модели, и перспективный экспорт
    # «отъезжал»: фасад занимал лишь часть кадра, а по краям оставались поля.
    def perspective_distance(frame_height)
      height = frame_height.to_f
      height = 1000.0 unless height.finite? && height > 0.0
      tan_half = Math.tan(FOV * Math::PI / 360.0)
      return height * 2.0 if tan_half <= 0.0
      height / 2.0 / tan_half
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

    # Пропорции окна просмотра: по ним SketchUp строит снимок.
    # nil — если размер окна недоступен (тогда снимок делается как раньше).
    def viewport_ratio(view)
      width = view.vpwidth.to_f
      height = view.vpheight.to_f
      return nil if width <= 0.0 || height <= 0.0
      width / height
    rescue StandardError
      nil
    end

    # Точка взгляда камеры (Camera#eye в тестовой заглушке тоже есть).
    def eye_of(camera)
      camera.eye
    rescue StandardError
      camera.target
    end

    # Камеры для всех фасадов в режиме «что на экране».
    # Первая — ровно текущий вид, каждая следующая повёрнута на 90°.
    def visible_cameras(camera, view, export_settings, count = 4, parallel = true)
      width, height = visible_image_size(export_settings)
      ratio = height.to_f.zero? ? 1.0 : width.to_f / height.to_f
      frame_height = visible_frame_height(camera)
      canvas_w, canvas_h, crop_w, crop_h = render_canvas(width, height, viewport_ratio(view))
      # Снимок может быть выше кадра — тогда камера накрывает не height, а
      # canvas_h пикселей, и лишнее отрезается по центру.
      cam_height = frame_height * canvas_h.to_f / [crop_h, 1].max
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
            cam.height = cam_height
          else
            # Перспектива: тот же угол, но по вертикали должно быть видно
            # cam_height единиц (снимок может быть выше кадра).
            distance = (eye_of(cam) - cam.target).length
            cam.fov = if distance > MIN_SIZE
                        2.0 * Math.atan((cam_height / 2.0) / distance) * 180.0 / Math::PI
                      else
                        camera.fov
                      end
          end
        rescue StandardError
          nil
        end
        cameras << cam
        # поворот вектора «цель -> камера» на 90° вокруг вертикальной оси
        dx, dy = dy, -dx
      end

      [{
        :image_width => crop_w,
        :image_height => crop_h,
        :canvas_width => canvas_w,
        :canvas_height => canvas_h,
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
      span = begin
        d = bounds.max - bounds.min
        [d.x.to_f.abs, d.y.to_f.abs, d.z.to_f.abs]
      rescue StandardError
        [0.0, 0.0, 0.0]
      end
      {
        :projections => projections,
        :image_width => width,
        :image_height => height,
        :vertical => vertical,
        :gap => gap,
        :scale => scale,
        :biggest => biggest_index(projections),
        :span => span
      }
    end
  end
end
