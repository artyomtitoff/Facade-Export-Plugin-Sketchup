# encoding: utf-8
# Экспорт фасадов — конфигурация и хранение настроек.
# Автор: Артем Титов (motivate_rt)

require 'json'

module FacadeExport
  # Все значения по умолчанию собраны в одном месте.
  module Config
    PREF_SECTION = 'FacadeExport'.freeze
    PREF_KEY     = 'settings'.freeze
    SETTINGS_VERSION = 7

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

    # Соотношения сторон кадра. Всегда записываются «широкой» стороной:
    # для вертикальных объектов (башен, небоскрёбов) плагин сам разворачивает
    # кадр, поэтому отдельные вертикальные варианты (3:4, 2:3, 9:16) не нужны.
    #
    # Пропорции жёсткие: кадр один и тот же у всех четырёх фасадов, поэтому
    # все PNG получаются одного размера. Фасад прижат к низу и к боковым
    # краям (минимальный зазор), а сверху остаётся запас — он и нужен, чтобы
    # при небольшом изменении высоты здания кадр не пришлось пересчитывать.
    #
    # Самый вытянутый вариант — 1:2. Более вытянутых (2:1, 3:1 и т. п.) в
    # списке нет: кадр разворачивается по самой длинной стороне фасада, и
    # «1:2» для широкого фасада и есть прежнее 2:1.
    ASPECTS = {
      '4:3'  => [4, 3],
      '3:2'  => [3, 2],
      '16:9' => [16, 9],
      '1:2'  => [1, 2],
      '1:1'  => [1, 1]
    }.freeze

    DEFAULT_ASPECT = '4:3'.freeze

    # Пункты выпадающего списка пропорций (значение, подпись).
    def self.aspect_options
      ASPECTS.keys.map { |key| [key, key] }
    end

    def self.aspect_valid?(name)
      ASPECTS.key?(name.to_s)
    end

    # Пределы стороны изображения (ограничение SketchUp — 16000).
    MAX_IMAGE_SIDE = 16_000
    MIN_IMAGE_SIDE = 100

    # Фон всегда полностью белый: RGB 255,255,255.
    WHITE_RGB = [255, 255, 255].freeze

    # Названия отдельных карт для типов стекла (п. 11).
    GLASS_TITLES = {
      'main'    => 'окно-стекло',
      'tinted'  => 'окно-тонировка',
      'railing' => 'окно-ограждения'
    }.freeze

    # Пороги непрозрачности материала, % (п. 11).
    GLASS_RAILING_MAX = 10    # 0–10 %   — стеклянные ограждения
    GLASS_TINTED_MIN  = 90    # 90–99 %  — тонированное стекло
    GLASS_OPAQUE_MIN  = 99.5  # ≥ 99.5 % — не стекло, обычные материалы

    # Текстуры есть только в режиме «Затенение»: в остальных режимах
    # SketchUp их не рисует, поэтому отдельной галочки в настройках нет.
    def self.textures_for(render_mode)
      render_mode.to_s == 'shaded'
    end

    def self.aspect_ratio(name)
      ASPECTS[name.to_s] || ASPECTS[DEFAULT_ASPECT]
    end

    # ---------------------------------------------------------------- defaults

    def self.default_export
      {
        # Основные (видны сразу)
        'width'           => 9999,      # длина большей стороны кадра
        'height'          => 0,         # 0 = автоматически по соотношению
        'line_scale'      => 0.3,       # множитель масштаба линии 0,3x
        'margin'          => 0.02,      # зазор от края, доля большей стороны
        'restore_view'    => true,      # возвращать вид и стиль после экспорта
        'show_report'     => true,      # показывать отчёт
        # Анализировать все 4 фасада и при экспорте одного фасада подгонять
        # кадр по самому большому из них (по умолчанию выключено).
        'fit_all_facades' => false,
        # Показать ровно то, что видно в окне SketchUp: кадр не подгоняется
        # под габариты объекта, масштаб и композиция берутся с экрана.
        'visible_area'    => false,

        # Расширенные
        'aspect'          => DEFAULT_ASPECT,
        # Карта окон: обычные (не стеклянные) материалы с текстурой
        # становятся белыми, чтобы на карте остались только окна.
        'whiten_textures' => true,
        'projection'      => 'parallel', # параллельная проекция
        'sun_for_shading' => false,      # "использовать солнце для затенения"
        'use_view_size'   => false,
        'antialias'       => false,
        'transparent'     => true,
        'background'      => '#FFFFFF',
        # Небо и землю на фасадах скрываем: в кадре только объект.
        'hide_sky'        => true,
        'hide_ground'     => true,
        'hide_watermarks' => true,
        'last_directory'  => ''
      }
    end

    def self.default_glass
      {
        'main_h'    => 125, 'main_s'    => 100, 'main_l'    => 50,
        'tinted_h'  => 180, 'tinted_s'  => 100, 'tinted_l'  => 50,
        'railing_h' => 300, 'railing_s' => 100, 'railing_l' => 50
      }
    end

    def self.default_maps
      [
        {
          'key'        => 'texture',
          'kind'       => 'standard',
          'title'      => 'Текстура',
          'enabled'    => true,
          'render_mode'=> 'shaded',   # Затенение с текстурами
          'edges'      => false,      # только текстуры, без линий
          'shadows'    => false,
          'material_transparency' => false,
          'shadow_azimuth'   => 45,
          'shadow_elevation' => 45,
          'shadow_light'     => 100,
          'shadow_dark'      => 0
        },
        {
          'key'        => 'lines',
          'kind'       => 'standard',
          'title'      => 'Линии',
          'enabled'    => true,
          'render_mode'=> 'hidden',   # Скрытые линии
          'edges'      => true,       # только линии
          'shadows'    => false,
          'material_transparency' => false,
          'shadow_azimuth'   => 45,
          'shadow_elevation' => 45,
          'shadow_light'     => 100,
          'shadow_dark'      => 0
        },
        {
          'key'        => 'shadows',
          'kind'       => 'standard',
          'title'      => 'Тени',
          'enabled'    => true,
          'render_mode'=> 'hidden',   # белые грани — остаются только тени
          'edges'      => false,
          'shadows'    => true,
          'material_transparency' => false,
          'shadow_azimuth'   => 45,   # солнце слева сверху под 45°
          'shadow_elevation' => 45,
          'shadow_light'     => 100,  # "Светлее"
          'shadow_dark'      => 0     # "Темнее"
        },
        {
          'key'        => 'windows',
          'kind'       => 'windows',
          'title'      => 'Окна',
          'enabled'    => true,
          'render_mode'=> 'shaded',   # "Отобразить в режиме теней" — без теней
          'edges'      => false,
          'shadows'    => false,
          'material_transparency' => false,
          'glass_highlight' => true,  # перекрашивать стекло на этой карте
          'split_windows' => false,   # разделять по типам стекла
          'shadow_azimuth'   => 45,
          'shadow_elevation' => 45,
          'shadow_light'     => 100,
          'shadow_dark'      => 0
        }.merge(default_glass)
      ]
    end

    def self.default_settings
      {
        'version' => SETTINGS_VERSION,
        'export'  => default_export,
        'maps'    => default_maps
      }
    end

    # Карта, создаваемая кнопкой "+" (п. 13).
    def self.new_custom_map(index)
      default_maps[0].merge(
        'key'        => "custom_#{index}",
        'kind'       => 'custom',
        'title'      => "Своя карта #{index}",
        'enabled'    => true,
        'render_mode'=> 'shaded',
        'edges'      => false,
        'shadows'    => false,
        'material_transparency' => false,
        'glass_highlight' => false, # по умолчанию свою карту стекло не красит
        'split_windows'   => false
      ).merge(default_glass)
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
      @data = Config.deep_merge(Config.default_settings, hash.is_a?(Hash) ? hash : {})
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
      @data = Config.deep_merge(Config.default_settings, hash.is_a?(Hash) ? hash : {})
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

    def parallel_projection?
      exp('projection').to_s != 'perspective'
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
      e['margin']     = clamp_float(e['margin'], 0.0, 0.25, 0.02)
      # Значение «auto» из 1.5.3 больше не существует — такие настройки
      # автоматически возвращаются к 4:3.
      e['aspect'] = Config::DEFAULT_ASPECT if e['aspect'].to_s == 'auto'
      # Пропорции 2:1 и 3:1 из 1.5.5 убраны как «слишком вытянутые»:
      # самой вытянутой осталась 1:2 (для широкого фасада это и есть 2:1).
      e['aspect'] = '1:2' if %w[2:1 3:1].include?(e['aspect'].to_s)
      e['aspect']     = Config::DEFAULT_ASPECT unless Config::aspect_valid?(e['aspect'])
      e['projection'] = 'parallel' unless %w[parallel perspective].include?(e['projection'].to_s)

      migrate_old_keys!(e)
      %w[restore_view show_report fit_all_facades sun_for_shading use_view_size
         antialias transparent hide_sky hide_ground hide_watermarks
         visible_area whiten_textures].each do |key|
        e[key] = truthy(e[key])
      end
      # Служебная графика (направляющие, оси, тексты, размеры, плоскости
      # сечений) не рисуется всегда — отдельных настроек больше нет.
      %w[hide_guides hide_annotations show_section_planes show_sky show_ground].each do |key|
        e.delete(key)
      end
      e['background'] = '#FFFFFF' if e['background'].to_s.strip.empty?

      list = maps
      unless list.is_a?(Array) && !list.empty?
        @data['maps'] = Config.default_maps
        list = @data['maps']
      end

      seen = {}
      list.each_with_index do |m, index|
        m['kind'] = 'standard' unless %w[standard windows custom].include?(m['kind'].to_s)
        m['key']  = m['key'].to_s.strip
        m['key']  = "map_#{index}" if m['key'].empty? || seen[m['key']]
        seen[m['key']] = true
        m['title'] = m['key'] if m['title'].to_s.strip.empty?
        m['render_mode'] = 'shaded' unless Config::RENDER_MODES.key?(m['render_mode'])
        %w[enabled edges shadows material_transparency split_windows glass_highlight].each do |key|
          m[key] = truthy(m[key])
        end
        # Текстуры не настраиваются: они есть только в режиме «Затенение».
        m['textures'] = Config.textures_for(m['render_mode'])
        # Карта «Окна» всегда красит стекло, у своих карт это галочка.
        m['glass_highlight'] = true if m['kind'] == 'windows'
        m['shadow_light']     = clamp_int(m['shadow_light'], 0, 100, 100)
        m['shadow_dark']      = clamp_int(m['shadow_dark'], 0, 100, 0)
        m['shadow_azimuth']   = clamp_float(m['shadow_azimuth'], 0.0, 90.0, 45.0)
        m['shadow_elevation'] = clamp_float(m['shadow_elevation'], 5.0, 89.0, 45.0)
        Config.default_glass.each do |key, value|
          m[key] = clamp_int(m[key], 0, key.end_with?('_h') ? 360 : 100, value)
        end
      end
    end

    private

    # Настройки старых версий (до 1.5.0, т.е. и 1.5.1): «Оставлять небо/землю» превратились
    # в «Скрывать небо/землю». Старые ключи удаляются ниже.
    def migrate_old_keys!(e)
      e['hide_sky'] = false if e.key?('show_sky') && truthy(e['show_sky'])
      e['hide_ground'] = false if e.key?('show_ground') && truthy(e['show_ground'])
      @data['version'] = Config::SETTINGS_VERSION
    end

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
