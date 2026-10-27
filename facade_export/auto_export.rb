# encoding: utf-8
# Экспорт фасадов — сценарий «Автоматический вывод фасада».
# Автор: Артем Титов (motivate_rt)
#
# Кнопка открывает окно со схемой здания сверху. Готовых фасадов плагин
# больше не предлагает: пользователь сам рисует линии на схеме мышью.
# Нарисованные фасады (со всеми настройками — имя, ориентация, пропорции,
# направление) сохраняются в атрибутах модели и привязываются к контексту
# (группе), поэтому:
#   * повторное нажатие кнопки показывает уже нарисованные фасады;
#   * другой пользователь с этим плагином увидит их же, открыв файл;
#   * файл модели вырастает на считанные килобайты (одна строка JSON),
#     время сохранения не меняется.
#
# Порядок важен для скорости и для надёжности:
#   1. после кнопки — только быстрый анализ и окно (без превью фасадов);
#   2. пользователь рисует/двигает фасады, жмёт «Экспортировать»;
#   3. ПЕРВЫМ делом — окно сохранения (оно не ждёт никаких расчётов);
#   4. камеры, плоскости и съёмка — уже после выбора папки;
#   5. окно с отчётом появляется всегда, даже если что-то упало.

module FacadeExport
  module AutoExport
    DICT_NAME = 'FacadeExport'.freeze
    DICT_KEY  = 'auto_facades'.freeze

    module_function

    # Нажатие кнопки: быстрый анализ модели и окно со схемой.
    def start
      model = Sketchup.active_model
      if model.nil?
        UI.messagebox('Нет активной модели.')
        return nil
      end
      settings = FacadeExport.settings
      if settings.enabled_maps.empty?
        UI.messagebox('Все карты отключены. Включите хотя бы одну в настройках плагина.')
        return nil
      end

      detector = AutoFacades.new(model, settings)
      result = begin
        detector.detect
      rescue ExportError => e
        UI.messagebox(e.message)
        return nil
      rescue StandardError => e
        FacadeExport.log("Авто-фасады: анализ не выполнен (#{e.message})")
        UI.messagebox("Не удалось найти фасады: #{e.message}")
        return nil
      end

      @detector = detector
      @result = result
      @facades = detector.restore(load_drawn)
      @payload = build_payload(result, settings, @facades)
      FacadeExport.log("Авто-фасады: нарисовано фасадов — #{@facades.length} " \
                       "(#{result[:scope] == :context ? 'открытая группа' : 'вся модель'})")
      Dialogs.show_auto_facades(@payload)
      @payload
    end

    # Данные для окна: схема сверху, нарисованные фасады, направления
    # основных плоскостей (для «магнита») и варианты кадра.
    def build_payload(result, settings, facades)
      {
        'scope' => result[:scope].to_s,
        'plan' => plan_payload(result[:plan]),
        'magnets' => result[:magnets] || [],
        'orients' => Config::AUTO_ORIENTS.map { |key, title| [key, title] },
        'ratios' => Config::AUTO_RATIOS.keys.map { |key| [key, key] } +
                    [[Config::AUTO_RATIO_AUTO, 'авто — по фасаду']],
        'defaultOrient' => Config.auto_orient(settings.auto_val('orient')),
        'defaultRatio' => Config.auto_ratio_name(settings.auto_val('ratio')),
        'maxFacades' => Config::MAX_AUTO_FACADES,
        'origin' => {
          'x' => (result[:plan] && result[:plan][:min_x]).to_f,
          'y' => (result[:plan] && result[:plan][:min_y]).to_f
        },
        'span' => (result[:plan] && result[:plan][:span]).to_f,
        'longestSide' => settings.exp('width').to_i,
        'deleteScenes' => settings.auto_val('delete_scenes') ? true : false,
        'cutSections' => settings.auto_val('cut_sections') ? true : false,
        'baseName' => FacadeExport.model_base_name(Sketchup.active_model),
        'facades' => facades.map { |facade| facade_payload(facade) }
      }
    end

    # Схема для окна: только то, что нужно рисовать (без мировых координат).
    def plan_payload(plan)
      plan = {} if plan.nil?
      {
        'grid' => plan['grid'] || plan[:grid] || AutoFacades::PLAN_GRID,
        'cells' => plan['cells'] || plan[:cells] || [],
        'polygons' => plan['polygons'] || plan[:polygons] || []
      }
    end

    # Полный набор данных окна (после удаления фасада и перенумерации).
    def refresh_payload
      return nil if @detector.nil?
      result = @result || {}
      payload = build_payload(
        { :plan => @detector.plan, :scope => result[:scope] || :model,
          :magnets => result[:magnets] || [] },
        FacadeExport.settings, @facades || []
      )
      @payload = payload
      payload
    end

    def facade_payload(facade)
      {
        'id' => facade.id,
        'index' => facade.index,
        'name' => facade.name,
        'pageName' => facade.page_name,
        'compass' => @detector && @detector.respond_to?(:compass) ?
                     @detector.compass(facade.normal) :
                     facade.page_name.to_s.split('—').last.to_s.strip,
        'orient' => facade.orient,
        'ratio' => facade.ratio,
        'selected' => facade.selected ? true : false,
        'segment' => facade.segment
      }
    end

    # ------------------------------------------------- нарисованные фасады

    # Окно прислало линию — добавляем фасад.
    def add_facade(data)
      detector = @detector
      facades = @facades || []
      return respond_add('ok' => false, 'message' => 'Окно устарело: нажмите кнопку заново.') if detector.nil?
      return respond_add('ok' => false, 'message' => "Больше #{Config::MAX_AUTO_FACADES} фасадов нельзя.") if
        facades.length >= Config::MAX_AUTO_FACADES
      line = line_from_payload(data)
      return respond_add('ok' => false, 'message' => 'Линия не прочитана.') if line.nil?
      facade = nil
      begin
        facade = detector.facade_from_line(line[0], line[1], line[2], line[3])
      rescue StandardError => e
        FacadeExport.log("Авто-фасады: линия не разобрана (#{e.message})")
      end
      return respond_add('ok' => false, 'message' => 'Не удалось создать фасад по этой линии.') if facade.nil?
      facade.id = next_id(facades)
      facades << facade
      detector.renumber!(facades)
      @facades = facades
      save_drawn(facades)
      respond_add(facade_payload(facade).merge('ok' => true))
    end

    # Окно передвинуло нарисованную линию (поворачивать нельзя).
    def move_facade(data)
      facade, position, error = find_facade(data)
      return respond_update('ok' => false, 'message' => error) if facade.nil?
      line = line_from_payload(data)
      return respond_update('ok' => false, 'message' => 'Линия не прочитана.') if line.nil?
      fresh = begin
        @detector.move(facade, line[0], line[1], line[2], line[3])
      rescue StandardError => e
        FacadeExport.log("Авто-фасады: линия не передвинута (#{e.message})")
        nil
      end
      return respond_update('ok' => false, 'message' => 'Не удалось передвинуть фасад.') if fresh.nil?
      @facades[position] = fresh
      save_drawn(@facades)
      respond_update(facade_payload(fresh).merge('ok' => true))
    end

    # Окно просит развернуть фасад в другую сторону (оставаясь на месте).
    def invert_facade(data)
      facade, position, error = find_facade(data)
      return respond_update('ok' => false, 'message' => error) if facade.nil?
      fresh = begin
        @detector.invert(facade)
      rescue StandardError => e
        FacadeExport.log("Авто-фасады: фасад не развёрнут (#{e.message})")
        nil
      end
      return respond_update('ok' => false, 'message' => 'Не удалось развернуть фасад.') if fresh.nil?
      @facades[position] = fresh
      save_drawn(@facades)
      respond_update(facade_payload(fresh).merge('ok' => true))
    end

    # Окно убрало фасад.
    def remove_facade(data)
      facade, position, error = find_facade(data)
      return { 'ok' => false, 'message' => error } if facade.nil?
      @facades.delete_at(position)
      @detector.renumber!(@facades)
      save_drawn(@facades)
      # Номера считает Ruby — окно получает готовый список 1..N.
      begin
        Dialogs.push_auto_data_public
      rescue StandardError => e
        FacadeExport.log("Авто-фасады: окно не перерисовано (#{e.message})")
      end
      { 'ok' => true }
    end

    def find_facade(data)
      payload = parse_payload(data)
      return [nil, nil, 'Окно устарело: нажмите кнопку заново.'] if payload.nil? || @detector.nil?
      list = @facades || []
      id = payload['id']
      position = list.index { |facade| facade.id.to_i == id.to_i } if id
      position ||= list.index { |facade| facade.index.to_i == payload['index'].to_i }
      return [nil, nil, 'Фасад не найден.'] if position.nil?
      [list[position], position, nil]
    end

    def next_id(facades)
      (Array(facades).map { |facade| facade.id.to_i }.max || 0) + 1
    end

    def line_from_payload(data)
      payload = parse_payload(data)
      return nil unless payload.is_a?(Hash)
      values = %w[x1 y1 x2 y2].map { |key| payload[key] }
      return nil if values.any? { |value| value.nil? }
      line = values.map { |value| value.to_f }
      length = Math.sqrt((line[2] - line[0])**2 + (line[3] - line[1])**2)
      return nil if length < 1.0e-6
      line
    end

    # ------------------------------------------------------- хранение в файле

    # Ключ контекста: открытая группа (по persistent_id) или вся модель.
    def storage_key(model = nil)
      model ||= Sketchup.active_model
      path = begin
        model.active_path
      rescue StandardError
        nil
      end
      return 'model' if path.nil? || path.empty?
      ids = path.map do |instance|
        begin
          instance.persistent_id
        rescue StandardError
          begin
            instance.entityID
          rescue StandardError
            instance.object_id
          end
        end
      end
      "path:#{ids.join('/')}"
    end

    def read_store(model = nil)
      model ||= Sketchup.active_model
      raw = begin
        model.get_attribute(DICT_NAME, DICT_KEY, '')
      rescue StandardError
        ''
      end
      return {} if raw.nil? || raw.to_s.empty?
      data = JSON.parse(raw.to_s)
      data.is_a?(Hash) ? data : {}
    rescue StandardError => e
      FacadeExport.log("Авто-фасады: сохранённые фасады не прочитаны (#{e.message})")
      {}
    end

    # Сохранённые фасады текущего контекста.
    def load_drawn(model = nil)
      Array(read_store(model)[storage_key(model)])
    rescue StandardError
      []
    end

    # Записать фасады контекста. Одна строка JSON в атрибутах модели —
    # это считанные килобайты, время сохранения файла не меняется.
    def save_drawn(facades, model = nil)
      model ||= Sketchup.active_model
      return false if model.nil?
      store = read_store(model)
      key = storage_key(model)
      list = Array(facades).map { |facade| stored_facade(facade) }
      if list.empty?
        store.delete(key)
      else
        store[key] = list
      end
      begin
        if store.empty?
          model.set_attribute(DICT_NAME, DICT_KEY, '')
        else
          model.set_attribute(DICT_NAME, DICT_KEY, JSON.generate(store))
        end
      rescue StandardError => e
        FacadeExport.log("Авто-фасады: фасады не сохранены в модели (#{e.message})")
        return false
      end
      true
    end

    def stored_facade(facade)
      line = facade.line_world || [0.0, 0.0, 0.0, 0.0]
      {
        'id' => facade.id,
        'x1' => line[0].round(2), 'y1' => line[1].round(2),
        'x2' => line[2].round(2), 'y2' => line[3].round(2),
        'nx' => facade.normal.x.round(4), 'ny' => facade.normal.y.round(4),
        'name' => facade.name.to_s,
        'orient' => facade.orient.to_s,
        'ratio' => facade.ratio.to_s
      }
    end

    # ------------------------------------------------------------- экспорт

    # Вызывается из окна: пользователь нажал «Экспортировать».
    def export(payload)
      data = parse_payload(payload)
      return nil if data.nil?
      detector = @detector
      if detector.nil? || @payload.nil?
        UI.messagebox('Окно устарело: нажмите кнопку «Автоматический вывод фасада» заново.')
        return nil
      end

      selected = apply_selection(@facades || [], data)
      if selected.empty?
        UI.messagebox('Не нарисовано ни одного фасада.')
        return nil
      end

      settings = FacadeExport.settings

      # Окно сохранения — сразу: камеры и плоскости считаются потом.
      destination = Dialogs.ask_destination(settings, @payload['baseName'])
      return nil if destination.nil?

      settings.set_export('last_directory', destination[:directory])
      settings.save

      detector.renumber!(selected)
      @facades = selected
      save_drawn(selected)

      detector.build_cameras!(selected)
      selected = selected.select(&:camera)
      if selected.empty?
        UI.messagebox('Не удалось построить камеры фасадов.')
        return nil
      end

      return nil unless confirm_overwrite(destination, selected.map(&:name))

      run(detector, selected, destination)
    end

    # Собственно экспорт: плоскости -> съёмка -> (при желании) сцены -> уборка.
    def run(detector, facades, destination)
      settings = FacadeExport.settings
      model = Sketchup.active_model
      view = model.active_view
      # Сцены нужны только если их оставляют в модели: пока они временные,
      # создавать их бессмысленно — это лишнее время.
      keep_scenes = settings.auto_val('create_scenes') && !settings.auto_val('delete_scenes')

      # Камера пользователя запоминается до всего остального и возвращается
      # в любом случае — даже если экспорт упал.
      detector.snapshot_camera(view)

      result = nil
      error = nil
      begin
        # Чужие разрезы (пользователя и старых сцен) на время съёмки выключаем:
        # иначе они режут модель вместе с нашим сечением.
        detector.suspend_foreign_planes
        with_operation(model, 'Автоматический вывод фасада') do
          detector.create_planes!(facades)
        end

        result = Exporter.new(
          :model     => model,
          :view      => view,
          :settings  => settings,
          :directory => destination[:directory],
          :base_name => destination[:base_name],
          :facades   => facades,
          :auto      => detector,
          :labels    => facades.map(&:name)
        ).run

        # Сцены — только если их оставляют, и только после записи файлов.
        if keep_scenes && !result.files.empty?
          with_operation(model, 'Сцены автоматического вывода') do
            detector.create_scenes!(facades)
          end
        end
      rescue ExportError => e
        error = e.message
      rescue StandardError => e
        error = "Ошибка экспорта: #{e.message}"
        FacadeExport.log("Авто-фасады: #{e.message}\n#{e.backtrace.first(10).join("\n")}")
      ensure
        with_operation(model, 'Уборка автоматического вывода') do
          detector.cleanup!(keep_scenes && result && !result.files.empty?)
        end
        detector.resume_foreign_planes
        detector.restore_camera(view)
        view.invalidate if view.respond_to?(:invalidate)
        close_dialog
      end

      report(result, facades.length, error)
      result
    end

    # Отчёт показывается всегда: пользователь должен видеть, что произошло.
    def report(result, count, error)
      if error
        UI.messagebox(error)
        return
      end
      return if result.nil?
      settings = FacadeExport.settings
      if settings.exp('show_report') || !result.errors.empty? || result.files.empty?
        Dialogs.show_report(result, count)
      end
    rescue StandardError => e
      FacadeExport.log("Авто-фасады: отчёт не показан (#{e.message})")
    end

    # ------------------------------------------------------------- служебное

    # Одна операция в журнале «Отменить» на действие.
    def with_operation(model, name)
      started = begin
        model.start_operation(name, true)
      rescue StandardError
        false
      end
      yield
    ensure
      begin
        model.commit_operation if started
      rescue StandardError
        nil
      end
    end

    # Фасады, которые окно оставило: порядок окна = порядок нумерации.
    def apply_selection(facades, data)
      wanted = []
      Array(data['facades']).each do |item|
        next unless item['selected'] == true || item['selected'] == 'true'
        wanted << item
      end
      result = []
      wanted.each do |item|
        id = item['id']
        facade = facades.find { |f| !id.nil? && f.id.to_i == id.to_i }
        facade ||= facades.find { |f| f.index.to_i == item['index'].to_i }
        next if facade.nil?
        facade.selected = true
        facade.orient = Config.auto_orient(item['orient'] || facade.orient)
        facade.ratio = Config.auto_ratio_name(item['ratio'] || facade.ratio)
        name = item['name'].to_s.strip
        facade.name = name.empty? ? facade.name : name
        result << facade
      end
      result
    end

    def parse_payload(payload)
      return payload if payload.is_a?(Hash)
      JSON.parse(payload.to_s)
    rescue StandardError => e
      FacadeExport.log("Авто-фасады: данные окна не прочитаны (#{e.message})")
      nil
    end

    def respond_add(payload)
      begin
        Dialogs.push_auto_add(payload)
      rescue StandardError => e
        FacadeExport.log("Авто-фасады: ответ в окно не отправлен (#{e.message})")
      end
      payload
    end

    def respond_update(payload)
      begin
        Dialogs.push_auto_update(payload)
      rescue StandardError => e
        FacadeExport.log("Авто-фасады: обновление в окно не отправлено (#{e.message})")
      end
      payload
    end

    def confirm_overwrite(destination, labels)
      planned = Exporter.planned_paths(
        FacadeExport.settings, destination[:directory],
        destination[:base_name], labels.length, labels
      )
      existing = planned.select { |path| File.exist?(path) }
      return true if existing.empty?

      yes = defined?(IDYES) ? IDYES : 6
      buttons = defined?(MB_YESNO) ? MB_YESNO : 4
      text = "В папке уже есть #{existing.length} файл(ов) с такими именами:\n" \
             "#{destination[:directory]}\n\nЗаменить их?"
      answer = begin
        UI.messagebox(text, buttons)
      rescue StandardError
        yes
      end
      answer == yes || answer == true
    end

    def close_dialog
      Dialogs.close_auto_facades
    rescue StandardError
      nil
    end
  end
end
