# encoding: utf-8
# Экспорт фасадов — точка входа: меню, панель инструментов, запуск экспорта.
# Автор: Артем Титов (motivate_rt)

require 'sketchup.rb'
require 'json'

require_relative 'config'
require_relative 'util'
require_relative 'scene_state'
require_relative 'framing'
require_relative 'sun'
require_relative 'glass'
require_relative 'exporter'
require_relative 'dialogs'

module FacadeExport
  PLUGIN_NAME = 'Экспорт фасадов'
  VERSION     = '1.5.1'
  AUTHOR      = 'Артем Титов motivate_rt'
  PATH = File.expand_path(File.dirname(__FILE__)) unless defined?(PATH) && PATH

  class << self
    def settings
      @settings ||= Settings.load
    end

    def settings=(value)
      @settings = value
    end

    def log(message)
      puts "[#{PLUGIN_NAME}] #{message}"
    rescue StandardError
      nil
    end

    # --------------------------------------------------------------- экспорт

    def export_all_facades
      export_facades(4)
    end

    def export_single_facade
      export_facades(1)
    end

    def export_facades(count)
      model = Sketchup.active_model
      if model.nil?
        UI.messagebox('Нет активной модели.')
        return
      end
      view = model.active_view

      # До окна сохранения проверяем только камеру: это мгновенно.
      # Габариты модели (обход всей геометрии) считаются уже после выбора
      # папки, иначе на большой модели SketchUp «думает» минуту, прежде чем
      # показать окно сохранения.
      begin
        Framing.facade_directions(view.camera, 1)
      rescue ExportError => e
        UI.messagebox(e.message)
        return
      end

      maps = settings.enabled_maps
      if maps.empty?
        UI.messagebox('Все карты отключены. Включите хотя бы одну в настройках плагина.')
        return
      end

      # Имя в окне сохранения — префикс имён файлов (п. 10 задания).
      base_name = model_base_name(model)
      destination = Dialogs.ask_destination(settings, base_name)
      return if destination.nil?

      settings.set_export('last_directory', destination[:directory])
      settings.save

      return unless confirm_overwrite(destination[:directory], destination[:base_name], count)

      exporter = Exporter.new(
        :model        => model,
        :view         => view,
        :settings     => settings,
        :directory    => destination[:directory],
        :base_name    => destination[:base_name],
        :facade_count => count,
        :first_number => 1
      )

      result = nil
      begin
        result = exporter.run
      rescue ExportError => e
        UI.messagebox(e.message)
        return
      rescue StandardError => e
        log("Критическая ошибка экспорта: #{e.message}\n#{e.backtrace.first(10).join("\n")}")
        UI.messagebox("Ошибка экспорта: #{e.message}")
        return
      end

      Dialogs.show_report(result, count) if settings.exp('show_report')
      result
    end

    # Если в папке уже есть файлы с такими именами — спрашиваем подтверждение,
    # чтобы случайно не перезаписать прошлый экспорт.
    def confirm_overwrite(directory, base_name, count)
      planned = Exporter.planned_paths(settings, directory, base_name, count)
      existing = planned.select { |path| File.exist?(path) }
      return true if existing.empty?

      yes = defined?(IDYES) ? IDYES : 6
      buttons = defined?(MB_YESNO) ? MB_YESNO : 4
      text = "В папке уже есть #{existing.length} файл(ов) с такими именами:\n" \
             "#{directory}\n\nЗаменить их?"
      answer = begin
        UI.messagebox(text, buttons)
      rescue StandardError
        yes
      end
      answer == yes || answer == true
    end

    # ---------------------------------------------------------------- утилиты

    def model_base_name(model)
      path = begin
        model.path.to_s
      rescue StandardError
        ''
      end
      base = if path.empty?
               begin
                 model.title.to_s
               rescue StandardError
                 ''
               end
             else
               File.basename(path)
             end
      base = File.basename(base, '.*') unless base.to_s.empty?
      Util.sanitize_filename(base, 'Модель')
    end

    def open_settings
      Dialogs.show_settings
    end

    def about
      Dialogs.about
    end

    # --------------------------------------------------------- команды и меню

    def register_ui
      return if @ui_registered

      command_all = UI::Command.new('Экспорт всех фасадов') { export_all_facades }
      command_all.tooltip = 'Экспорт всех фасадов: 4 фасада × 4 карты = 16 PNG'
      command_all.status_bar_text = 'Выровняйте вид по фасаду и нажмите — плагин экспортирует 16 изображений'
      command_all.menu_text = 'Экспорт всех фасадов'
      set_icons(command_all, 'export_all')

      command_one = UI::Command.new('Экспорт фасада') { export_single_facade }
      command_one.tooltip = 'Экспорт текущего фасада: 4 карты = 4 PNG'
      command_one.status_bar_text = 'Экспортирует 4 карты текущего (выровненного) вида'
      command_one.menu_text = 'Экспорт фасада'
      set_icons(command_one, 'export_one')

      command_settings = UI::Command.new('Настройки…') { open_settings }
      command_settings.tooltip = 'Настройки карт и параметров экспорта'
      command_settings.status_bar_text = 'Настройки плагина "Экспорт фасадов"'
      set_icons(command_settings, 'settings')

      command_about = UI::Command.new('О плагине…') { about }
      command_about.status_bar_text = 'Автор: ' + AUTHOR

      toolbar = UI::Toolbar.new(PLUGIN_NAME)
      toolbar.add_item(command_all)
      toolbar.add_item(command_one)
      toolbar.add_separator
      toolbar.add_item(command_settings)
      show_toolbar(toolbar)

      menu = UI.menu('Extensions').add_submenu(PLUGIN_NAME)
      menu.add_item(command_all)
      menu.add_item(command_one)
      menu.add_separator
      menu.add_item(command_settings)
      menu.add_item(command_about)

      @toolbar = toolbar
      @commands = [command_all, command_one, command_settings, command_about]
      @ui_registered = true
      true
    end

    # При первой установке панель нужно показать, иначе restore её не выведет.
    def show_toolbar(toolbar)
      state = begin
        toolbar.get_last_state
      rescue StandardError
        nil
      end
      never_shown = defined?(TB_NEVER_SHOWN) ? TB_NEVER_SHOWN : 4
      if state.nil? || state == never_shown
        toolbar.show
      else
        toolbar.restore
      end
    rescue StandardError => e
      FacadeExport.log("Не удалось показать панель инструментов: #{e.message}")
    end

    def set_icons(command, base)
      small = File.join(PATH, 'icons', "#{base}_24.png")
      large = File.join(PATH, 'icons', "#{base}_32.png")
      command.small_icon = small if File.exist?(small)
      command.large_icon = large if File.exist?(large)
    end
  end
end

FacadeExport.register_ui
