# encoding: utf-8
# Экспорт фасадов — сценарий «Автоматический вывод фасада».
# Автор: Артем Титов (motivate_rt)
#
# Кнопка находит фасады в открытой группе (или во всей модели), показывает
# окно с упрощёнными превью, ждёт выбора фасадов, соотношений сторон и имён,
# а затем прогоняет обычный экспорт — по одной камере и одной секущей
# плоскости на фасад.
#
# Временные сцены и плоскости удаляются после экспорта
# (настройка auto.delete_scenes); состояние разрезов пользователя
# возвращается как было.

module FacadeExport
  module AutoExport
    module_function

    # Нажатие кнопки: анализ модели и окно со списком фасадов.
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

      # Один анализ на всё окно: повторно геометрию не обходим.
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
      @settings = settings
      @payload = build_payload(result)
      Dialogs.show_auto_facades(@payload)
      @payload
    end

    # Данные для окна: превью фасадов, контур здания, соотношения сторон.
    def build_payload(result)
      settings = FacadeExport.settings
      longest = settings.exp('width').to_i
      {
        'scope' => result[:scope].to_s,
        'scopeText' => result[:scope] == :context ? 'открытая группа' : 'вся модель',
        'plan' => result[:plan] || { 'grid' => 32, 'cells' => [] },
        'aspects' => Config::AUTO_ASPECTS.keys.map do |key|
          label = key == Config::AUTO_DEFAULT_ASPECT ? "#{key} (по умолчанию)" : key
          [key, label]
        end,
        'defaultAspect' => settings.auto_val('aspect').to_s,
        'longestSide' => longest,
        'minSide' => Config::MIN_IMAGE_SIDE,
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
        'compass' => facade.page_name.to_s.split('—').last.to_s.strip,
        'aspect' => facade.aspect,
        'selected' => facade.selected ? true : false,
        'normal' => [facade.normal.x.round(4), facade.normal.y.round(4)],
        'polygons' => facade.polygons
      }
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
      detector.build_cameras!(selected)
      # Фасад без камеры не снимаем — и в именах файлов его тоже нет.
      selected = selected.select(&:camera)
      if selected.empty?
        UI.messagebox('Не удалось построить камеры фасадов.')
        return nil
      end

      destination = Dialogs.ask_destination(settings, @payload['baseName'])
      return nil if destination.nil?

      settings.set_export('last_directory', destination[:directory])
      settings.save

      labels = selected.map { |f| f.name }
      return nil unless confirm_overwrite(destination, labels)

      run(detector, selected, destination, labels)
    end

    # Собственно экспорт: плоскости -> сцены -> обычный движок -> уборка.
    def run(detector, facades, destination, labels)
      settings = FacadeExport.settings
      model = Sketchup.active_model

      # Плоскости и сцены создаются отдельной операцией, чтобы в журнале
      # «Отменить» это выглядело одним действием. Сам экспорт работает
      # в своей служебной операции, которую в конце отменяет.
      with_operation(model, 'Автоматический вывод фасада') do
        detector.create_planes!(facades)
        detector.create_scenes!(facades)
      end

      exporter = Exporter.new(
        :model     => model,
        :view      => model.active_view,
        :settings  => settings,
        :directory => destination[:directory],
        :base_name => destination[:base_name],
        :facades   => selected,
        :auto      => detector,
        :labels    => selected.map(&:name)
      )

      keep_scenes = false
      result = nil
      begin
        result = exporter.run
      rescue ExportError => e
        UI.messagebox(e.message)
      rescue StandardError => e
        FacadeExport.log("Авто-фасады: ошибка экспорта (#{e.message})")
        UI.messagebox("Ошибка экспорта: #{e.message}")
      ensure
        keep_scenes = !settings.auto_val('delete_scenes') &&
                      facades.any? { |f| !f.page.nil? }
        unless keep_scenes
          with_operation(model, 'Уборка сцен автоматического вывода') do
            detector.cleanup!(false)
          end
        end
        detector.cleanup!(keep_scenes) if keep_scenes
        close_dialog
      end

      Dialogs.show_report(result, facades.length) if result && settings.exp('show_report')
      result
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
        next unless item['selected'] || item['selected'] == 'true'
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
