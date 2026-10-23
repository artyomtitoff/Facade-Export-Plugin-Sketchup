# encoding: utf-8
# Экспорт фасадов — диалоги: выбор папки, отчёт, окно настроек.
# Автор: Артем Титов (motivate_rt)

require 'json'

module FacadeExport
  module Dialogs
    module_function

    # ---------------------------------------------------------- выбор папки

    # Спрашивает у пользователя путь один раз (как штатный экспорт SketchUp).
    # Имя в поле "Имя файла" — это префикс будущих файлов: пользователь может
    # вписать своё название, и оно попадёт в имена всех PNG.
    # Возвращает {:directory => "...", :base_name => "..."} или nil.
    def ask_destination(settings, suggested_base)
      last = settings.exp('last_directory').to_s
      last = default_directory if last.empty? || !safe_directory?(last)

      suggestion = "#{Util.sanitize_filename(suggested_base, 'Модель')}.png"
      path = begin
        UI.savepanel('Экспорт фасадов — выберите папку для сохранения', last, suggestion)
      rescue StandardError => e
        UI.messagebox("Не удалось открыть окно сохранения: #{e.message}")
        return nil
      end
      return nil if path.nil? || path.to_s.strip.empty?

      directory = File.dirname(path.to_s)
      typed = File.basename(path.to_s, '.*').strip
      base = if typed.empty?
               Util.sanitize_filename(suggested_base, 'Модель')
             else
               Util.sanitize_filename(typed, 'Модель')
             end
      { :directory => directory, :base_name => base }
    end

    def default_directory
      home = begin
        Dir.home
      rescue StandardError
        nil
      end
      docs = begin
        File.join(home, 'Documents')
      rescue StandardError
        nil
      end
      if docs && File.directory?(docs)
        docs
      elsif home && File.directory?(home)
        home
      else
        ''
      end
    end

    def safe_directory?(path)
      File.directory?(path)
    rescue StandardError
      false
    end

    def file_size(path)
      File.size(path)
    rescue StandardError
      0
    end

    # ------------------------------------------------------------ сообщения

    def show_report(result, _facade_count = nil)
      return if result.nil?
      expected = result.expected.to_i
      expected = result.files.length + result.errors.length if expected <= 0
      lines = []
      lines << 'Экспорт завершён.'
      lines << "Файлов: #{result.files.length} из #{expected}."
      lines << "Папка: #{result.directory}" if result.directory
      lines << format('Время: %s', Util.format_duration(result.elapsed))
      if result.files.length > 0
        avg = result.elapsed / result.files.length
        lines << format('В среднем на изображение: %s', Util.format_duration(avg))
        total_bytes = result.files.inject(0) { |sum, f| sum + file_size(f) }
        lines << "Объём: #{Util.format_size(total_bytes)}"
        lines << ''
        lines << 'Файлы:'
        result.files.each { |f| lines << "  #{File.basename(f)}" }
      end
      unless result.errors.empty?
        lines << ''
        lines << 'Ошибки:'
        result.errors.each { |err| lines << "  #{err}" }
      end
      unless result.warnings.empty?
        lines << ''
        lines << 'Предупреждения:'
        result.warnings.each { |w| lines << "  #{w}" }
      end

      text = lines.join("\n")
      FacadeExport.log(text)
      # messagebox не любит очень длинный текст — режем до разумного размера.
      text = text[0, 3800] + "\n…" if text.length > 3900
      UI.messagebox(text)
    end

    # ------------------------------------------------------- окно настроек

    def show_settings
      if @settings_dialog && @settings_dialog.visible?
        @settings_dialog.bring_to_front
        return @settings_dialog
      end

      dialog = UI::HtmlDialog.new(
        :dialog_title     => 'Экспорт фасадов — настройки',
        :preferences_key  => 'FacadeExport.settings_dialog',
        :scrollable       => true,
        :resizable        => true,
        :width            => 820,
        :height           => 700,
        :min_width        => 700,
        :min_height       => 520,
        :style            => UI::HtmlDialog::STYLE_DIALOG
      )

      dialog.add_action_callback('ready') do |_context, _data|
        push_settings(dialog, FacadeExport.settings)
      end

      dialog.add_action_callback('save') do |_context, payload|
        begin
          hash = JSON.parse(payload.to_s)
          FacadeExport.settings.replace!(hash)
          FacadeExport.settings.save
          FacadeExport.log('Настройки сохранены.')
        rescue StandardError => e
          UI.messagebox("Не удалось сохранить настройки: #{e.message}")
        end
        dialog.close
      end

      dialog.add_action_callback('reset') do |_context, _data|
        push_settings(dialog, Settings.new)
      end

      dialog.add_action_callback('cancel') do |_context, _data|
        dialog.close
      end

      html = File.join(FacadeExport::PATH, 'html', 'settings.html')
      if File.exist?(html)
        dialog.set_file(html)
      else
        dialog.set_html('<p style="font-family:sans-serif">Не найден файл настроек settings.html</p>')
      end

      dialog.show
      @settings_dialog = dialog
    end

    def push_settings(dialog, settings)
      json = JSON.generate(settings.data)
      payload = JSON.generate(json) # строка, безопасная для вставки в JS
      dialog.execute_script("FacadeExport.setSettings(#{payload});")
    rescue StandardError => e
      FacadeExport.log("Не удалось передать настройки в окно: #{e.message}")
    end

    # ------------------------------------------------------------- прочее

    def about
      text = [
        "#{FacadeExport::PLUGIN_NAME} #{FacadeExport::VERSION}",
        '',
        'Автоматический экспорт 2D-геометрии фасадов в PNG:',
        '4 фасада × 4 карты (Текстура, Линии, Тени, Окна).',
        '',
        "Автор: #{FacadeExport::AUTHOR}",
        '',
        'Тени под 45° слева сверху — по принципу плагина',
        'Elevation 45 Shadows (TIG, 2006–2014).',
        '',
        'Стекло делится на три типа по непрозрачности материала:',
        '0–10 % — ограждения, 11–89 % — основное, 90–99 % — тонировка.',
        'В настройках карты «Окна» можно включить раздельные карты',
        'по типам стекла: «окно-стекло», «окно-тонировка», «окно-ограждения».',
        'Своя карта (кнопка «+») тоже умеет красить стекло по типам.',
        '',
        'Режим «Экспортировать только видимый участок» снимает ровно то,',
        'что видно в окне SketchUp, без подгонки кадра под объект.',
        '',
        'Кнопки: "Экспорт всех фасадов" и "Экспорт фасада".',
        'Перед нажатием выровняйте вид перпендикулярно фасаду.',
        '',
        'Настройки: Расширения > Экспорт фасадов > Настройки…'
      ].join("\n")
      UI.messagebox(text)
    end
  end
end
