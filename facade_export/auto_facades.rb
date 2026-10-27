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
    MAX_FACADES  = 30     # больше 30 фасадов в одном контексте не рисуем
    SNAP_TOL     = 10.0   # градусов: насколько линия «магнитится» к стене
    PREVIEW_SCALE = 1000.0
    PLAN_FACE_Z  = 0.7    # грань считается «вид сверху», если её нормаль вверх
    MAX_PLAN_FACES = 400  # больше граней в контур не берём

    # Найденный фасад.
    #   normal    — наружу от фасада; direction — куда смотрит камера (= -normal);
    #   records   — грани с их трансформациями (вершины читаются только
    #               для выбранных фасадов, уже после окна);
    #   extents   — габариты фасада в плоскости кадра (u/v) и глубина (d).
    Facade = Struct.new(
      :id, :index, :normal, :direction, :right, :records, :area, :depth,
      :orient, :ratio,
      :name, :page_name, :selected, :image_width, :image_height, :camera,
      :section_plane, :page, :extents, :segment,
      # Линия, которую пользователь провёл на схеме (мировые координаты).
      # Именно по ней ставится камера и секущая плоскость.
      :line_world
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

    # Быстрый анализ контекста. Заготовленных фасадов больше нет: в окно
    # уходят только те, что пользователь нарисовал сам (и которые уже
    # сохранены в модели). Возвращает {:facades, :plan, :scope, :magnets}.
    def detect
      @plan_faces = []
      records = collect_faces
      # Даже если вертикальных стен нет, контур сверху уже собран — схему
      # показать можно, а фасады пользователь нарисует мышью.
      if records.empty? && (@plan_faces || []).empty?
        raise ExportError, 'Не найдено видимых граней. Выйдите из группы ' \
                           'или проверьте, что геометрия не скрыта.'
      end
      @records = records
      @depth_tol = depth_tolerance(records)
      @runs = records.empty? ? [] : cluster_faces(records)
      @plan = plan_map(records)
      { :facades => [], :plan => @plan, :scope => @scope, :magnets => magnet_angles }
    end

    attr_reader :plan, :records, :runs

    # Направления основных плоскостей модели (0..180°): по ним «магнитится»
    # линия, которую пользователь ведёт мышью. Это направления стен.
    def magnet_angles
      angles = (@runs || []).map { |run| normalize_angle(azimuth([run[:nx], run[:ny]]) + 90.0) }
      angles += [0.0, 90.0]
      angles = angles.map { |angle| (angle * 10.0).round / 10.0 }.uniq.sort
      angles
    end

    def normalize_angle(deg)
      value = deg.to_f % 180.0
      value += 180.0 if value.negative?
      value
    end

    # Притянуть линию к ближайшей основной плоскости: угол округляется до
    # магнита, середина и длина линии сохраняются. Если рядом нет ничего
    # подходящего — линия остаётся как провели.
    def snap_line(x1, y1, x2, y2, tolerance = SNAP_TOL)
      x1 = x1.to_f
      y1 = y1.to_f
      x2 = x2.to_f
      y2 = y2.to_f
      dx = x2 - x1
      dy = y2 - y1
      length = Math.sqrt(dx * dx + dy * dy)
      return [x1, y1, x2, y2] if length < 1.0e-6
      angle = normalize_angle(Math.atan2(dy, dx) * 180.0 / Math::PI)
      best = nil
      magnet_angles.each do |candidate|
        diff = (angle - candidate).abs
        diff = 180.0 - diff if diff > 90.0
        best = [candidate, diff] if best.nil? || diff < best[1]
      end
      return [x1, y1, x2, y2] if best.nil? || best[1] > tolerance
      radians = best[0] * Math::PI / 180.0
      ux = Math.cos(radians)
      uy = Math.sin(radians)
      mx = (x1 + x2) / 2.0
      my = (y1 + y2) / 2.0
      [mx - ux * length / 2.0, my - uy * length / 2.0,
       mx + ux * length / 2.0, my + uy * length / 2.0]
    end

    # Фасад по нарисованной линии. Линия НЕ ищет «ближайшую стену» и не
    # укорачивается: как провели — по ней и режется, и снимается фасад.
    def facade_from_line(x1, y1, x2, y2, invert = false, orient = nil, ratio = nil)
      line = snap_line(x1, y1, x2, y2)
      build_drawn_facade(line[0], line[1], line[2], line[3], invert, orient, ratio)
    end

    # Нормаль фасада: перпендикуляр к нарисованной линии, направленный
    # ОТ здания (наружу). Сторону подсказывает ближайшая стена, параллельная
    # линии: её нормаль уже смотрит наружу. Если параллельных стен рядом
    # нет — по массе геометрии: наружу туда, где здания меньше.
    # Пользователь всегда может развернуть фасад стрелкой.
    def outward_normal(mx, my, ux, uy)
      px = -uy
      py = ux
      best = nil
      (@records || []).each do |record|
        box = record[:plan]
        next if box.nil?
        normal = record[:normal]
        next if normal.nil? || normal[0].nil? || normal[1].nil?
        next if (normal[0] * ux + normal[1] * uy).abs > COS_TOL
        cx = (box[0] + box[2]) / 2.0
        cy = (box[1] + box[3]) / 2.0
        distance = ((cx - mx) * px + (cy - my) * py).abs
        best = [normal[0], normal[1], distance] if best.nil? || distance < best[2]
      end
      unless best.nil?
        sign = best[0] * px + best[1] * py
        return sign >= 0.0 ? [px, py] : [-px, -py]
      end

      first = 0.0
      second = 0.0
      (@records || []).each do |record|
        box = record[:plan]
        next if box.nil?
        cx = (box[0] + box[2]) / 2.0
        cy = (box[1] + box[3]) / 2.0
        if (cx - mx) * px + (cy - my) * py >= 0.0
          first += record[:area].to_f
        else
          second += record[:area].to_f
        end
      end
      first > second ? [-px, -py] : [px, py]
    end

    def plan_span
      @plan && @plan[:span] ? @plan[:span] : 1.0
    end

    def build_drawn_facade(x1, y1, x2, y2, invert = false, orient = nil, ratio = nil)
      dx = x2.to_f - x1.to_f
      dy = y2.to_f - y1.to_f
      length = Math.sqrt(dx * dx + dy * dy)
      return nil if length < 1.0e-6
      ux = dx / length
      uy = dy / length
      mx = (x1.to_f + x2.to_f) / 2.0
      my = (y1.to_f + y2.to_f) / 2.0
      nx, ny = outward_normal(mx, my, ux, uy)
      nx, ny = -nx, -ny if invert
      right = [-ny, nx]
      u1 = x1.to_f * right[0] + y1.to_f * right[1]
      u2 = x2.to_f * right[0] + y2.to_f * right[1]
      u_min, u_max = [u1, u2].min, [u1, u2].max
      depth = mx * nx + my * ny
      facade = Facade.new
      facade.normal = Geom::Vector3d.new(nx, ny, 0.0)
      facade.direction = Geom::Vector3d.new(-nx, -ny, 0.0)
      facade.right = Geom::Vector3d.new(right[0], right[1], 0.0)
      facade.depth = depth
      facade.line_world = [x1.to_f, y1.to_f, x2.to_f, y2.to_f]
      facade.records = drawn_records(right, u_min, u_max)
      facade.extents = drawn_extents(facade, u_min, u_max)
      height = (facade.extents[:v_max] - facade.extents[:v_min]).abs
      facade.area = (u_max - u_min).abs * [height, 0.0].max
      facade.orient = Config.auto_orient(orient || @settings.auto_val('orient'))
      facade.ratio = Config.auto_ratio_name(ratio || @settings.auto_val('ratio'))
      facade.selected = true
      facade.segment = drawn_segment(x1.to_f, y1.to_f, x2.to_f, y2.to_f, nx, ny)
      facade
    end

    # Грани рядом с линией (по её длине) — из них берётся высота фасада.
    def drawn_records(right, u_min, u_max)
      margin = (u_max - u_min).abs * 0.02 + 1.0
      chosen = (@records || []).select do |record|
        record_overlaps_u?(record, right, u_min - margin, u_max + margin)
      end
      chosen.empty? ? (@records || []) : chosen
    end

    def record_overlaps_u?(record, right, from, to)
      box = record[:plan]
      return true if box.nil?
      range = record_u_range(record, right)
      return true if range.nil?
      range[1] >= from && range[0] <= to
    end

    # Габариты нарисованного фасада: ширина — ровно по линии, высота — по
    # геометрии рядом, глубина — по самой линии (по ней и режем).
    def drawn_extents(facade, u_min = nil, u_max = nil)
      if u_min.nil? || u_max.nil?
        line = facade.line_world
        return facade.extents if line.nil?
        right = facade.right
        u1 = line[0] * right.x + line[1] * right.y
        u2 = line[2] * right.x + line[3] * right.y
        u_min, u_max = [u1, u2].min, [u1, u2].max
      end
      source = facade.records.nil? || facade.records.empty? ? (@records || []) : facade.records
      v_min = v_max = nil
      source.each do |record|
        transform = record[:transform]
        record[:face].vertices.each do |vertex|
          point = vertex.position
          point = point.transform(transform) unless transform.nil?
          v = point.z
          v_min = v if v_min.nil? || v < v_min
          v_max = v if v_max.nil? || v > v_max
        end
      end
      v_min = 0.0 if v_min.nil?
      v_max = 1.0 if v_max.nil? || v_max <= v_min
      depth = facade.depth.to_f
      { :u_min => u_min, :u_max => u_max, :v_min => v_min, :v_max => v_max,
        :d_min => depth, :d_max => depth }
    end

    # Отрезок на схеме — ровно та линия, которую провёл пользователь.
    def drawn_segment(x1, y1, x2, y2, nx, ny)
      min_x = @plan[:min_x]
      min_y = @plan[:min_y]
      span = @plan[:span]
      to_plan = lambda do |x, y|
        [((x - min_x) / span * PREVIEW_SCALE).round(1),
         (PREVIEW_SCALE - (y - min_y) / span * PREVIEW_SCALE).round(1)]
      end
      {
        'from'   => to_plan.call(x1, y1),
        'to'     => to_plan.call(x2, y2),
        'normal' => [nx.round(4), (-ny).round(4)],
        'area'   => 0.0
      }
    end

    # Развернуть фасад в другую сторону, оставив ту же линию и то же место.
    def invert(facade)
      return nil if facade.nil?
      line = facade.line_world
      return nil if line.nil?
      fresh = build_drawn_facade(line[0], line[1], line[2], line[3], true,
                                 facade.orient, facade.ratio)
      return nil if fresh.nil?
      fresh.id = facade.id
      fresh.index = facade.index
      fresh.name = facade.name
      fresh.page_name = renamed_page(facade.page_name, fresh.normal)
      fresh.selected = facade.selected
      fresh
    end

    # Сдвинуть фасад: линия переносится, направление и пропорции остаются.
    def move(facade, x1, y1, x2, y2)
      return nil if facade.nil?
      # Перенос — только сдвиг: сторону и пропорции сохраняем как были.
      fresh = build_drawn_facade(x1, y1, x2, y2, false, facade.orient, facade.ratio)
      return nil if fresh.nil?
      if (fresh.normal.x - facade.normal.x).abs + (fresh.normal.y - facade.normal.y).abs > 0.5
        fresh = build_drawn_facade(x1, y1, x2, y2, true, facade.orient, facade.ratio)
        return nil if fresh.nil?
      end
      fresh.id = facade.id
      fresh.index = facade.index
      fresh.name = facade.name
      fresh.page_name = facade.page_name
      fresh.selected = facade.selected
      fresh
    end

    # Восстановить сохранённые в модели фасады этого контекста.
    def restore(definitions)
      list = []
      Array(definitions).each do |item|
        next unless item.is_a?(Hash)
        line = %w[x1 y1 x2 y2].map { |key| item[key].to_f }
        length = Math.sqrt((line[2] - line[0])**2 + (line[3] - line[1])**2)
        next if length < 1.0e-6
        facade = build_drawn_facade(line[0], line[1], line[2], line[3], false,
                                    item['orient'], item['ratio'])
        next if facade.nil?
        # Сторону берём из файла: если авто-выбор дал другую, разворачиваем.
        if item['nx'] && item['ny']
          dot = facade.normal.x * item['nx'].to_f + facade.normal.y * item['ny'].to_f
          if dot < 0.0
            facade = build_drawn_facade(line[0], line[1], line[2], line[3], true,
                                        item['orient'], item['ratio'])
            next if facade.nil?
          end
        end
        facade.id = item['id'].to_i
        name = item['name'].to_s.strip
        facade.name = name unless name.empty?
        list << facade
      end
      renumber!(list)
      list
    end

    # Нумерация по факту: 1..N в том порядке, в каком фасады лежат в списке.
    # Удалили восемь, нарисовали новый — он первый, а не девятый.
    def renumber!(facades)
      prefix = @settings.auto_val('scene_prefix').to_s.strip
      prefix = 'Фасад' if prefix.empty?
      pattern = /\A#{Regexp.escape(prefix)} \d+\z/
      Array(facades).each_with_index do |facade, position|
        facade.index = position + 1
        name = facade.name.to_s.strip
        if name.empty? || name =~ pattern
          facade.name = "#{prefix} #{facade.index}"
        end
        facade.page_name = renamed_page(facade.name, facade.normal)
      end
      facades
    end

    # Имя сцены после разворота: «Фасад 3 — юг» → «Фасад 3 — север».
    def renamed_page(name, normal)
      text = name.to_s
      head = text.include?('—') ? text.split('—').first.to_s.rstrip : text
      "#{head} — #{compass(normal)}"
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
        # Контур сверху — это ровно то, что видно в виде сверху: грани,
        # смотрящие вверх (крыша, перекрытия). Из них и складывается схема.
        collect_plan_face(face, transform)
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
      split_runs(groups)
    end

    # Одна плоскость — ещё не один фасад: две параллельные стены в разных
    # концах здания лежат в одной плоскости, но фасадов два. Поэтому группы
    # режутся на сплошные участки вдоль стены.
    def split_runs(groups)
      gap = run_gap
      runs = []
      groups.each do |group|
        right = [-group[:ny], group[:nx]]
        entries = group[:records].map do |record|
          [record_u_range(record, right), record]
        end
        entries.sort_by! { |(range, _record)| range ? range[0] : 0.0 }
        current = nil
        entries.each do |(range, record)|
          if !current.nil? && !range.nil? && (range[0] - current[:u_max]) <= gap
            current[:records] << record
            current[:area] += record[:area]
            current[:u_max] = range[1] if range[1] > current[:u_max]
            current[:u_min] = range[0] if range[0] < current[:u_min]
          else
            current = {
              :area    => record[:area],
              :nx      => group[:nx],
              :ny      => group[:ny],
              :depth   => group[:depth],
              :right   => right,
              :records => [record],
              :u_min   => range ? range[0] : 0.0,
              :u_max   => range ? range[1] : 0.0
            }
            runs << current
          end
        end
      end
      runs.reject { |run| run[:area] <= 0.0 }
    end

    # Разрыв, после которого стена считается другой: примерно две клетки схемы.
    def run_gap
      xs = []
      ys = []
      (@records || []).each do |record|
        box = record[:plan]
        next if box.nil?
        xs << box[0] << box[2]
        ys << box[1] << box[3]
      end
      return MIN_DEPTH_TOL if xs.empty?
      span = [xs.max - xs.min, ys.max - ys.min, 1.0].max
      [span / PLAN_GRID * 2.0, 1.0].max
    end

    # Интервал вдоль стены, который занимает грань.
    def record_u_range(record, right)
      box = record[:plan]
      return nil if box.nil?
      us = [[box[0], box[1]], [box[2], box[1]], [box[0], box[3]], [box[2], box[3]]].map do |(x, y)|
        x * right[0] + y * right[1]
      end
      [us.min, us.max]
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

    # Название стороны света по нормали: восемь румбов (+Y — север).
    # Нужно для имён сцен: у здания под 45° фасад не «восток», а «северо-восток».
    def compass(normal)
      angle = azimuth([normal.x, normal.y])
      names = %w[восток северо-восток север северо-запад запад юго-запад юг юго-восток]
      names[((angle / 45.0).round % 8)]
    end

    # --------------------------------------------------------- схема сверху

    # «Жучок»: контур здания сверху. Берутся грани, смотрящие вверх
    # (крыша, перекрытия) — ровно то, что видно в виде сверху внутри открытой
    # группы. Окно заливает их одним цветом без обводки, поэтому получается
    # реальный силуэт здания, включая косые крылья и внутренний двор.
    def plan_map(records)
      boxes = records.map { |record| record[:plan] }.compact
      xs = boxes.map { |box| [box[0], box[2]] }.flatten
      ys = boxes.map { |box| [box[1], box[3]] }.flatten
      # Если вертикальных стен не нашлось, габариты берём по самому контуру.
      (@plan_faces || []).each do |face|
        face[:points].each do |(x, y)|
          xs << x
          ys << y
        end
      end
      min_x, min_y, span = plan_bounds_from(xs, ys)
      if min_x.nil?
        return { 'grid' => PLAN_GRID, 'cells' => [], 'polygons' => [],
                 :polygons_world => [], :min_x => 0.0, :min_y => 0.0, :span => 1.0 }
      end
      faces = plan_faces(min_x, min_y, span)
      faces = boxes.map { |box| rectangle_points(box) } if faces.empty?
      faces = faces.first(MAX_PLAN_FACES).map { |points| simplify_polygon(points, span) }
      polygons = faces.map do |points|
        points.map do |(x, y)|
          [((x - min_x) / span * PREVIEW_SCALE).round(1),
           (PREVIEW_SCALE - (y - min_y) / span * PREVIEW_SCALE).round(1)]
        end
      end
      {
        'grid' => PLAN_GRID,
        'cells' => raster_cells(faces, min_x, min_y, span),
        'polygons' => polygons,
        :polygons_world => faces,
        :min_x => min_x,
        :min_y => min_y,
        :span => span
      }
    end

    def plan_bounds_from(xs, ys)
      return [nil, nil, nil] if xs.empty? || ys.empty?
      min_x = xs.min
      min_y = ys.min
      span = [xs.max - min_x, ys.max - min_y, 1.0e-6].max
      [min_x, min_y, span]
    end

    # Контуры граней «сверху» в мировых координатах, без мелочи.
    def plan_faces(min_x, min_y, span)
      faces = @plan_faces || []
      return [] if faces.empty?
      max_area = faces.map { |face| face[:area] }.max
      limit = max_area * 0.002
      faces.select { |face| face[:area] >= limit }.map { |face| face[:points] }
    end

    # Убираем точки на одной прямой: контур остаётся тем же, а в окно
    # уходит в разы меньше данных (окно должно открываться мгновенно).
    def simplify_polygon(points, span)
      return points if points.length <= 3
      tolerance = span * 1.0e-4
      result = []
      points.each_with_index do |point, i|
        prev = result.last || points[(i - 1) % points.length]
        nxt = points[(i + 1) % points.length]
        area = ((point[0] - prev[0]) * (nxt[1] - prev[1]) -
                (point[1] - prev[1]) * (nxt[0] - prev[0])).abs
        result << point if area > tolerance
      end
      result.length >= 3 ? result : points
    end

    def rectangle_points(box)
      [[box[0], box[1]], [box[2], box[1]], [box[2], box[3]], [box[0], box[3]]]
    end

    # Клетки схемы: центр клетки внутри контура. Нужны как запасной вариант
    # для окна и для «попала ли линия в здание».
    def raster_cells(faces, min_x, min_y, span)
      step = span / PLAN_GRID
      cells = []
      PLAN_GRID.times do |iy|
        cy = min_y + (iy + 0.5) * step
        PLAN_GRID.times do |ix|
          cx = min_x + (ix + 0.5) * step
          inside = faces.any? { |points| point_in_polygon?(cx, cy, points) }
          cells << [ix, PLAN_GRID - 1 - iy] if inside
        end
      end
      cells
    end

    # Грань «сверху»: горизонтальная и смотрит вверх.
    def collect_plan_face(face, transform)
      normal = face.normal
      return if normal.nil?
      normal = normal.transform(transform) unless transform.nil?
      return if normal.z < PLAN_FACE_Z
      area = face.area.to_f
      return if area <= 0.0
      points = plan_loop(face, transform)
      return if points.nil? || points.length < 3
      @plan_faces << { :points => points, :area => area }
    rescue StandardError => e
      FacadeExport.log("Авто-фасады: грань плана пропущена (#{e.message})")
      nil
    end

    # Контур грани в плане (X, Y), без повторов соседних точек.
    def plan_loop(face, transform)
      points = []
      face.vertices.each do |vertex|
        point = vertex.position
        point = point.transform(transform) unless transform.nil?
        x = point.x
        y = point.y
        last = points.last
        next if last && (last[0] - x).abs < 1.0e-6 && (last[1] - y).abs < 1.0e-6
        points << [x, y]
      end
      points.pop if points.length > 2 &&
                    (points.first[0] - points.last[0]).abs < 1.0e-6 &&
                    (points.first[1] - points.last[1]).abs < 1.0e-6
      points
    end

    # Точка внутри многоугольника (алгоритм луча).
    def point_in_polygon?(x, y, points)
      inside = false
      j = points.length - 1
      points.each_with_index do |(xi, yi), i|
        xj, yj = points[j]
        if ((yi > y) != (yj > y)) &&
           (x < (xj - xi) * (y - yi) / ((yj - yi).to_f) + xi)
          inside = !inside
        end
        j = i
      end
      inside
    end

    # ---------------------------------------------------------------- кадры

    # Габариты фасада в плоскости кадра: только для выбранных фасадов,
    # уже после окна. Здесь единственный раз читаются вершины граней.
    # Габариты фасада в плоскости кадра (u/v) и глубина (d).
    def extents(facade)
      return facade.extents unless facade.extents.nil?
      drawn_extents(facade)
    end

    # Камеры всех фасадов: общий масштаб (по самому крупному), фасад
    # по центру по горизонтали и прижат к низу кадра.
    def build_cameras!(facades)
      return facades if facades.nil? || facades.empty?
      plans = facades.map { |facade| facade_plan(facade) }.compact
      return facades if plans.empty?
      scale = plans.map { |plan| plan[:scale] }.min
      plans.each { |plan| plan[:facade].camera = camera_for(plan, scale) }
      facades
    end

    def facade_plan(facade)
      extents = extents(facade)
      return nil if extents.nil? || extents[:u_min].nil?
      facade_width = [(extents[:u_max] - extents[:u_min]).abs, 1.0e-6].max
      facade_height = [(extents[:v_max] - extents[:v_min]).abs, 1.0e-6].max
      width, height = self.class.image_size(
        facade.orient, facade.ratio, @settings.export, facade_width, facade_height
      )
      facade.image_width = width
      facade.image_height = height
      gap = Framing.gap_pixels(@settings.export, width, height)
      avail_w = [width - 2.0 * gap, 1.0].max
      avail_h = [height - 2.0 * gap, 1.0].max
      scale = [avail_w / facade_width, avail_h / facade_height].min
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
    # вторая — по пропорциям. Ориентация («горизонтальное», «вертикальное»,
    # «квадрат») выбирается отдельно от пропорций (3:4, 16:9, 3:1 …).
    def self.image_size(orient, ratio, export_settings, facade_width = nil, facade_height = nil)
      longest = export_settings['width'].to_i
      longest = Config::MIN_IMAGE_SIDE if longest < Config::MIN_IMAGE_SIDE
      longest = Config::MAX_IMAGE_SIDE if longest > Config::MAX_IMAGE_SIDE
      if export_settings['height'].to_i.positive?
        return [longest, export_settings['height'].to_i]
      end
      pair = Config.auto_ratio(ratio)
      if pair.nil?
        # «авто» — кадр по пропорциям самой геометрии фасада.
        w = facade_width.to_f
        h = facade_height.to_f
        pair = (w.positive? && h.positive?) ? [w, h] : [4.0, 3.0]
      end
      long = [pair[0].to_f, pair[1].to_f].max
      short = [pair[0].to_f, pair[1].to_f].min
      long = 1.0 if long <= 0.0
      side = [[(longest * short / long).round, Config::MIN_IMAGE_SIDE].max, longest].min
      key = Config.auto_orient(orient)
      case key
      when 'v'  then [side, longest]
      when 'sq' then [longest, longest]
      else [longest, side]
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
    # Плоскость стоит РОВНО на нарисованной линии (чуть со стороны камеры,
    # чтобы грань стены не оказалась в самой плоскости и не исчезла) и
    # отсекает всё, что находится ДО линии, то есть между камерой и стеной.
    # В кадр попадает стена и всё, что за ней.
    def section_plane_data(facade)
      ext = facade.extents || drawn_extents(facade)
      span = [(ext[:u_max] - ext[:u_min]).abs, (ext[:v_max] - ext[:v_min]).abs, 1.0].max
      epsilon = [span * 0.002, 0.1].max
      u_center = (ext[:u_min] + ext[:u_max]) / 2.0
      v_center = (ext[:v_min] + ext[:v_max]) / 2.0
      normal = facade.normal
      depth = facade.depth.to_f + epsilon
      point = Geom::Point3d.new(
        facade.right.x * u_center + normal.x * depth,
        facade.right.y * u_center + normal.y * depth,
        v_center
      )
      plane_normal = Geom::Vector3d.new(normal.x, normal.y, 0.0)
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
          next if point.nil? || normal.nil?
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
      if facade.section_plane && plane_alive?(facade.section_plane)
        plane = facade.section_plane
        hide_plane(plane, false)
        # Разрез должен работать ТОЛЬКО на своём фасаде: в каждом контексте
        # активной делаем ровно эту плоскость.
        begin
          entities = begin
            plane.parent
          rescue StandardError
            nil
          end
          if entities.respond_to?(:active_section_plane=)
            entities.active_section_plane = plane
          else
            plane.activate
          end
        rescue StandardError => e
          FacadeExport.log("Плоскость не активирована: #{e.message}")
          begin
            plane.activate
          rescue StandardError
            nil
          end
        end
      else
        clear_active_planes
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
      else
        resume_foreign_planes
      end
      resume_foreign_planes
      restore_camera(active_view)
      true
    end

    # ------------------------------------------------------------- служебное

    def with_entities
      yield context_entities
    end

    def context_entities
      path = begin
        @model.active_path
      rescue StandardError
        nil
      end
      if path.nil? || path.empty?
        @model.entities
      else
        begin
          path.last.definition.entities
        rescue StandardError
          @model.entities
        end
      end
    end

    # Чужие секущие плоскости (пользователя, из старых сцен) на время
    # авто-вывода выключаются. Иначе они продолжают резать модель вместе
    # с нашей плоскостью — и кадр получается обрезанным «сам по себе».
    def suspend_foreign_planes
      @foreign_planes = []
      existing_planes.each do |plane|
        next if @planes.include?(plane)
        next unless plane_active?(plane)
        @foreign_planes << plane
        entities = begin
          plane.parent
        rescue StandardError
          nil
        end
        begin
          entities.active_section_plane = nil if entities.respond_to?(:active_section_plane=)
        rescue StandardError => e
          FacadeExport.log("Чужое сечение не выключено: #{e.message}")
        end
      end
      @foreign_planes.length
    end

    # Возвращает чужие плоскости в то состояние, в котором они были.
    def resume_foreign_planes
      Array(@foreign_planes).each do |plane|
        begin
          plane.activate if plane_alive?(plane)
        rescue StandardError => e
          FacadeExport.log("Чужое сечение не возвращено: #{e.message}")
        end
      end
      @foreign_planes = []
      true
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

    # Снять активность со всех наших разрезов (в каждом контексте — свой).
    def clear_active_planes
      owners = []
      @planes.each do |plane|
        next if plane.nil? || !plane_alive?(plane)
        owners << begin
          plane.parent
        rescue StandardError
          nil
        end
      end
      owners.compact.uniq.each do |entities|
        next unless entities.respond_to?(:active_section_plane=)
        begin
          entities.active_section_plane = nil
        rescue StandardError => e
          FacadeExport.log("Разрез не выключен: #{e.message}")
        end
      end
      true
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
