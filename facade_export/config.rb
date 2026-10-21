# encoding: utf-8
# Экспорт фасадов — конфигурация и хранение настроек.
# Автор: Артем Титов (motivate_rt)

require 'json'

module FacadeExport
  # Все значения по умолчанию собраны в одном месте.
  # Ключи соответствуют параметрам окна экспорта SketchUp
  # (Файл > Экспорт > Двумерная графика) и настройкам стиля.
  module Config
    PREF_SECTION   = 'FacadeExport'.freeze
    PREF_KEY       = 'settings'.freeze
    SETTINGS_VERSION = 1

    # Значения "RenderMode" (SketchUp, "Правка > Грань"):
    # 0 — Каркас, 1 — Скрытые линии, 2 — Затенение, 5 — Монохромный.
    RENDER_MODES = {
      'wireframe'  => 0,
      'hidden'     => 1,
      'shaded'     => 2,
      'monochrome' => 5
    }.freeze

    RENDER_MODE_TITLES = {
      'wireframe'  => 'Каркас',
      'hidden'     => 'Скрытые линии',
      'shaded'     => 'Затенение',
      'monochrome' => 'Монохромный'
    }.freeze

    # Значения "EdgeDisplayMode" (SketchUp, "Правка > Край"):
    # 0 — края скрыты, 1 — показаны все края, 2 — только отдельные рёбра.
    EDGE_MODES = {
      'none'       => 0,
      'all'        => 1,
      'standalone' => 2
    }.freeze

    MAX_IMAGE_SIDE = 16_000
    MIN_IMAGE_SIDE = 100

    # Фон всегда полностью белый: RGB 255,255,255.
    WHITE_RGB = [255, 255, 255].freeze

    # ---------------------------------------------------------------- defaults

    def self.default_settings
      {
        'version' => SETTINGS_VERSION,
        'export'  => {
          # Параметры экспорта PNG (по умолчанию — как в задании).
          'use_view_size'  => false,   # "Не использовать размер вида"
          'width'          => 9999,    # Ширина, пикс.
          'height'         => 0,       # 0 = автоматически (по пропорциям вида)
          'antialias'      => false,   # "Автоматическое сглаживание" — выключено
          'transparent'    => true,    # "Прозрачный фон" — включён
          'line_scale'     => 0.3,     # "Множитель масштаба линии" — 0,3x

          # Компоновка кадра.
          'margin'         => 0.04,    # отступ вокруг фасада, доля кадра
          'perspective'    => false,   # "Параллельная проекция"

          # Стиль на время экспорта.
          'background'     => '#FFFFFF',
          'show_sky'       => false,
          'show_ground'    => false,
          'hide_guides'    => true,    # скрыть направляющие
          'hide_annotations' => true,  # скрыть оси, размеры, тексты
          'hide_watermarks'=> true,
          'disable_section_cuts' => true,

          # Тени (лоток "Тени" по умолчанию).
          'shadow_light'    => 100,    # "Светлее"
          'shadow_dark'     => 0,      # "Темнее"
          'sun_for_shading' => false,  # "Использовать солнце для затенения" — выкл.

          # Поведение плагина.
          'restore_view'   => true,    # вернуть вид и стиль после экспорта
          'show_report'    => true,    # показать итоговое окно со списком файлов
          'last_directory' => ''
        },
        'maps' => [
          {
            'key'                    => 'texture',
            'title'                  => 'Текстура',
            'enabled'                => true,
            'render_mode'            => 'shaded',   # Затенение с текстурами
            'textures'               => true,
            'edges'                  => false,      # края скрыты — только текстуры
            'shadows'                => false,
            'material_transparency'  => false,      # прозрачность материала убрана
            'sun_for_shading'        => false,
            'shadow_light'           => 100,
            'shadow_dark'            => 0,
            'shadow_azimuth'         => 45,
            'shadow_elevation'       => 45,
            'highlight_transparent'  => false,
            'glass_h'                => 125,
            'glass_s'                => 100,
            'glass_l'                => 50
          },
          {
            'key'                    => 'lines',
            'title'                  => 'Линии',
            'enabled'                => true,
            'render_mode'            => 'hidden',   # Скрытые линии
            'textures'               => false,
            'edges'                  => true,       # края показаны — только линии
            'shadows'                => false,
            'material_transparency'  => false,
            'sun_for_shading'        => false,
            'shadow_light'           => 100,
            'shadow_dark'            => 0,
            'shadow_azimuth'         => 45,
            'shadow_elevation'       => 45,
            'highlight_transparent'  => false,
            'glass_h'                => 125,
            'glass_s'                => 100,
            'glass_l'                => 50
          },
          {
            'key'                    => 'shadows',
            'title'                  => 'Тени',
            'enabled'                => true,
            'render_mode'            => 'hidden',   # белые грани — только тени
            'textures'               => false,
            'edges'                  => false,      # края скрыты
            'shadows'                => true,
            'material_transparency'  => false,
            'sun_for_shading'        => false,      # солнце для затенения — выкл.
            'shadow_light'           => 100,        # "Светлее"
            'shadow_dark'            => 0,          # "Темнее"
            'shadow_azimuth'         => 45,         # солнце слева сверху, 45°
            'shadow_elevation'       => 45,
            'highlight_transparent'  => false,
            'glass_h'                => 125,
            'glass_s'                => 100,
            'glass_l'                => 50
          },
          {
            'key'                    => 'windows',
            'title'                  => 'Окна',
            'enabled'                => true,
            'render_mode'            => 'shaded',   # "Отобразить в режиме теней"
            'textures'               => false,
            'edges'                  => false,
            'shadows'                => false,      # тени отключены
            'material_transparency'  => false,
            'sun_for_shading'        => false,
            'shadow_light'           => 100,
            'shadow_dark'            => 0,
            'shadow_azimuth'         => 45,
            'shadow_elevation'       => 45,
            # Перекраска материалов с непрозрачностью меньше 100 %
            'highlight_transparent'  => true,
            'glass_h'                => 125,
            'glass_s'                => 100,
            'glass_l'                => 50
          }
        ]
      }
    end

    # ------------------------------------------------------------------ helpers

    def self.deep_merge(base, extra)
      return base unless extra.is_a?(Hash)
      result = {}
      base.each { |k, v| result[k] = v }
      extra.each do |k, v|
        if result[k].is_a?(Hash) && v.is_a?(Hash)
          result[k] = deep_merge(result[k], v)
        elsif !v.nil?
          result[k] = v
        end
      end
      result
    end
  end

  # Обёртка над хэшем настроек: значения по умолчанию + пользовательские правки.
  class Settings
    attr_reader :data

    def initialize(hash = nil)
      defaults = Config.default_settings
      @data = Config.deep_merge(defaults, hash.is_a?(Hash) ? hash : {})
      normalize!
    end

    # ---- загрузка / сохранение -------------------------------------------

    def self.load
      raw = begin
        Sketchup.read_default(Config::PREF_SECTION, Config::PREF_KEY, '')
      rescue StandardError
        ''
      end
      hash = nil
      unless raw.nil? || raw.to_s.strip.empty?
        begin
          hash = JSON.parse(raw.to_s)
        rescue StandardError => e
          FacadeExport.log("Настройки повреждены, использую значения по умолчанию: #{e.message}")
          hash = nil
        end
      end
      new(hash)
    end

    def save
      begin
        Sketchup.write_default(Config::PREF_SECTION, Config::PREF_KEY, JSON.generate(@data))
        true
      rescue StandardError => e
        FacadeExport.log("Не удалось сохранить настройки: #{e.message}")
        false
      end
    end

    def to_json(*_args)
      JSON.generate(@data)
    end

    def replace!(hash)
      defaults = Config.default_settings
      @data = Config.deep_merge(defaults, hash.is_a?(Hash) ? hash : {})
      normalize!
      self
    end

    def reset!
      @data = Config.default_settings
      self
    end

    # ---- доступ ----------------------------------------------------------

    def export
      @data['export']
    end

    def exp(key)
      export[key.to_s]
    end

    def maps
      @data['maps']
    end

    def enabled_maps
      maps.select { |m| truthy(m['enabled']) }
    end

    def map(key)
      maps.find { |m| m['key'].to_s == key.to_s }
    end

    def set_export(key, value)
      export[key.to_s] = value
    end

    def truthy(value)
      value == true || value == 'true' || value == 1 || value == '1'
    end

    # Приводит числа к допустимым диапазонам и чинит битые значения.
    def normalize!
      e = export
      e['width']      = clamp_int(e['width'], Config::MIN_IMAGE_SIDE, Config::MAX_IMAGE_SIDE, 9999)
      e['height']     = clamp_int(e['height'], 0, Config::MAX_IMAGE_SIDE, 0)
      e['line_scale'] = clamp_float(e['line_scale'], 0.01, 10.0, 0.3)
      e['margin']     = clamp_float(e['margin'], 0.0, 0.30, 0.04)
      e['shadow_light'] = clamp_int(e['shadow_light'], 0, 100, 100)
      e['shadow_dark']  = clamp_int(e['shadow_dark'], 0, 100, 0)
      %w[use_view_size antialias transparent perspective show_sky show_ground
         hide_guides hide_annotations hide_watermarks disable_section_cuts
         sun_for_shading restore_view show_report].each do |key|
        e[key] = truthy(e[key])
      end
      e['background'] = '#FFFFFF' if e['background'].to_s.strip.empty?

      (maps || []).each do |m|
        m['key'] = m['key'].to_s
        m['title'] = m['key'] if m['title'].to_s.strip.empty?
        m['render_mode'] = 'shaded' unless Config::RENDER_MODES.key?(m['render_mode'])
        %w[enabled textures edges shadows material_transparency sun_for_shading
           highlight_transparent].each do |key|
          m[key] = truthy(m[key])
        end
        m['shadow_light']     = clamp_int(m['shadow_light'], 0, 100, 100)
        m['shadow_dark']      = clamp_int(m['shadow_dark'], 0, 100, 0)
        m['shadow_azimuth']   = clamp_float(m['shadow_azimuth'], 0.0, 90.0, 45.0)
        m['shadow_elevation'] = clamp_float(m['shadow_elevation'], 5.0, 89.0, 45.0)
        m['glass_h'] = clamp_int(m['glass_h'], 0, 360, 125)
        m['glass_s'] = clamp_int(m['glass_s'], 0, 100, 100)
        m['glass_l'] = clamp_int(m['glass_l'], 0, 100, 50)
      end
    end

    private

    def clamp_int(value, min, max, fallback)
      v = Integer(value)
      [[v, min].max, max].min
    rescue StandardError
      fallback
    end

    def clamp_float(value, min, max, fallback)
      v = Float(value)
      [[v, min].max, max].min
    rescue StandardError
      fallback
    end
  end
end
