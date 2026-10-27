# encoding: utf-8
# Экспорт фасадов — сценарий «Автоматический вывод фасада».
# Автор: Артем Титов (motivate_rt)
#
# Кнопка находит фасады в открытой группе (или во всей модели), показывает
# окно со схемой здания сверху, а затем прогоняет обычный экспорт — по одной
# камере и одной секущей плоскости на фасад.
#
# Порядок важен для скорости и для надёжности:
#   1. после кнопки — только быстрый анализ и окно (без превью фасадов);
#   2. пользователь отмечает фасады, жмёт «Экспортировать»;
#   3. ПЕРВЫМ делом — окно сохранения (оно не ждёт никаких расчётов);
#   4. камеры, плоскости и съёмка — уже после выбора папки;
#   5. окно с отчётом появляется всегда, даже если что-то упало.
#
# Сцены по умолчанию не создаются: пока они временные, они не нужны.
# Если в настройках включено «оставлять сцены», они создаются ПОСЛЕ того,
# как файлы записаны, — сбой со сценами уже не может испортить результат.

module FacadeExport
  module AutoExport
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
      @facades = result[:facades]
      @payload = build_payload(result, settings)
      FacadeExport.log("Авто-фасады: найдено #{@facades.length} фасадов " \
                       "(#{result[:scope] == :context ? 'открытая группа' : 'вся модель'})")
      Dialogs.show_auto_facades(@payload)
      @payload
    end

    # Данные для окна: схема сверху, список фасадов, соотношения сторон.
    # Никаких превью фасадов — только схема и подписи.
    def build_payload(result, settings)
      {
        'scope' => result[:scope].to_s,
        'plan' => result[:plan] || { 'grid' => AutoFacades::PLAN_GRID, 'cells' => [] },
        'aspects' => Config::AUTO_ASPECTS.keys.map do |key|
          label = key == Config::AUTO_DEFAULT_ASPECT ? "#{key} (по умолчанию)" : key
          [key, label]
        end,
        'defaultAspect' => settings.auto_val('aspect').to_s,
        'scenePrefix' => settings.auto_val('scene_prefix').to_s,
        # Чтобы окно могло вернуть координаты нарисованной линии в модель.
        'origin' => {
          'x' => (result[:plan] && result[:plan][:min_x]).to_f,
          'y' => (result[:plan] && result[:plan][:min_y]).to_f
        },
        'span' => (result[:plan] && result[:plan][:span]).to_f,
        'longestSide' => settings.exp('width').to_i,
        'deleteScenes' => settings.auto_val('delete_scenes') ? true : false,
        'cutSections' => settings.auto_val('cut_sections') ? true : false,
        'baseName' => FacadeExport.model_base_name(Sketchup.active_model),
        'facades' => result[:facades].map { |facade| facade_payload(facade) }
      }
    end

    def facade_payload(facade)
      {
        'index' => facade.index,
        'name' => facade.name,
        'pageName' => facade.page_name,
        'compass' => @detector && @detector.respond_to?(:compass) ?
                     @detector.compass(facade.normal) :
                     facade.page_name.to_s.split('—').last.to_s.strip,
        'aspect' => facade.aspect,
        'selected' => facade.selected ? true : false,
        'segment' => facade.segment
      }
    end

    # Окно прислало линию, нарисованную пользователем на схеме.
    # Возвращает описание нового фасада и передаёт его обратно в окно.
    def add_facade(data)
      detector = @detector
      facades = @facades || []
      if detector.nil?
        return respond_add('ok' => false, 'message' => 'Окно устарело: нажмите кнопку заново.')
      end
      point = parse_payload(data)
      if point.nil?
        return respond_add('ok' => false, 'message' => 'Линия не прочитана.')
      end
      facade = nil
      begin
        facade = detector.facade_from_line(point['x1'], point['y1'], point['x2'], point['y2'])
      rescue StandardError => e
        FacadeExport.log("Авто-фасады: линия не разобрана (#{e.message})")
      end
      if facade.nil?
        return respond_add('ok' => false,
                           'message' => 'Здесь стена не найдена — проведите линию вдоль фасада.')
      end
      prefix = (FacadeExport.settings.auto_val('scene_prefix') || 'Фасад').to_s.strip
      prefix = 'Фасад' if prefix.empty?
      index = (facades.map(&:index).max || 0).to_i + 1
      facade.index = index
      facade.selected = true
      facade.name = "#{prefix} #{index}"
      facade.page_name = "#{prefix} #{index} — #{detector.compass(facade.normal)}"
      facade.segment = detector.plan_segment(facade, detector.plan) if detector.plan
      facades << facade
      @facades = facades
      respond_add(facade_payload(facade).merge('ok' => true))
    end

    # Ответ окну на нарисованную линию: и успех, и отказ видны пользователю.
    def respond_add(payload)
      begin
        Dialogs.push_auto_add(payload)
      rescue StandardError => e
        FacadeExport.log("Авто-фасады: ответ в окно не отправлен (#{e.message})")
      end
      payload
    end

    # Вызывается из окна: пользователь нажал «Экспортировать».
    # payload — JSON-строка с выбором фасадов, именами и соотношениями.
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
        UI.messagebox('Не выбран ни один фасад.')
        return nil
      end

      settings = FacadeExport.settings

      # Окно сохранения — сразу: камеры и плоскости считаются потом.
      destination = Dialogs.ask_destination(settings, @payload['baseName'])
      return nil if destination.nil?

      settings.set_export('last_directory', destination[:directory])
      settings.save

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

    def apply_selection(facades, data)
      chosen = {}
      Array(data['facades']).each do |item|
        index = item['index'].to_i
        next unless item['selected'] == true || item['selected'] == 'true'
        chosen[index] = item
      end
      result = []
      facades.each do |facade|
        item = chosen[facade.index]
        next if item.nil?
        facade.selected = true
        aspect = item['aspect'].to_s
        facade.aspect = Config::AUTO_ASPECTS.key?(aspect) ? aspect : Config::AUTO_DEFAULT_ASPECT
        name = item['name'].to_s.strip
        facade.name = name.empty? ? facade.page_name : name
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
