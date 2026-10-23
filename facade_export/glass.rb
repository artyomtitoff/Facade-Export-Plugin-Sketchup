# encoding: utf-8
# Экспорт фасадов — работа с прозрачными (стеклянными) материалами.
# Автор: Артем Титов (motivate_rt)
#
# Типы стекла определяются по непрозрачности материала:
#   0–10 %   — стеклянные ограждения (на картах текстур/линий/теней исчезают);
#   11–89 %  — основное стекло;
#   90–99 %  — тонированное стекло;
#   100 %    — обычный материал, не трогаем.
#
# На картах текстур, линий и теней основное и тонированное стекло становится
# непрозрачным (цвет и текстура сохраняются): иначе фасад просвечивает, за ним
# видно лишние объекты и на стекло не падают тени. Исчезают только ограждения.

module FacadeExport
  class GlassRecolor
    # Режимы:
    #   'combined'     — карта "Окна": все типы стекла в свои цвета, непрозрачность 100 %;
    #   'main' / 'tinted' / 'railing' — отдельная карта одного типа:
    #                    нужный тип окрашен, остальные типы стекла исчезают;
    #   'hide_railings' — карты текстур/линий/теней: ограждения исчезают.
    MODES = %w[combined main tinted railing hide_railings].freeze
    TYPES = %w[main tinted railing].freeze

    # Один найденный материал: материал, его непрозрачность, тип и текстура.
    # Тип 'opaque' — непрозрачный материал с текстурой (на карте окон он
    # отбеливается, чтобы на карте остались только окна).
    Entry = Struct.new(:material, :alpha, :type, :texture)

    attr_reader :recolored, :hidden, :whitened, :entries

    # Один раз просматривает материалы модели и возвращает список стекла.
    # Дальше этот список переиспользуется для всех карт и фасадов — плагин
    # не ищет окна заново на каждое изображение (раньше «пустая» карта окон
    # тратила на это больше времени, чем сам рендер).
    def self.scan(model, options = {})
      railing_max = (options[:railing_max] || Config::GLASS_RAILING_MAX).to_f
      tinted_min  = (options[:tinted_min] || Config::GLASS_TINTED_MIN).to_f
      opaque_min  = (options[:opaque_min] || Config::GLASS_OPAQUE_MIN).to_f
      include_opaque = options[:include_opaque] ? true : false
      list = []
      materials = begin
        model.materials
      rescue StandardError
        nil
      end
      return list if materials.nil?
      materials.each do |mat|
        begin
          alpha = alpha_of(mat)
          next if alpha.nil?
          type = type_for(alpha * 100.0, railing_max, tinted_min, opaque_min)
          if type.nil?
            next unless include_opaque
            # Обычный непрозрачный материал: на карте окон важно отбелить
            # только текстуры, поэтому материалы без текстуры не трогаем.
            texture = texture_filename(mat)
            next if texture.nil?
            list << Entry.new(mat, alpha, 'opaque', texture)
            next
          end
          list << Entry.new(mat, alpha, type, nil)
        rescue StandardError => e
          FacadeExport.log("Материал пропущен: #{e.message}")
        end
      end
      list
    end

    # Путь к текстуре материала (nil, если текстуры нет).
    def self.texture_filename(mat)
      texture = mat.texture
      return nil if texture.nil?
      name = texture.filename.to_s
      name.empty? ? nil : name
    rescue StandardError
      nil
    end

    def self.alpha_of(mat)
      if mat.respond_to?(:use_alpha?) && mat.use_alpha? == false
        return 1.0
      end
      return mat.alpha.to_f if mat.respond_to?(:alpha)
      c = mat.color
      c ? c.alpha.to_f / 255.0 : 1.0
    rescue StandardError
      nil
    end

    def self.type_for(opacity_percent, railing_max, tinted_min, opaque_min)
      return 'railing' if opacity_percent <= railing_max
      return 'tinted' if opacity_percent >= tinted_min && opacity_percent < opaque_min
      return 'main' if opacity_percent < tinted_min
      nil
    end

    def initialize(model, colors, options = {})
      @model = model
      @colors = colors || {}
      @mode = options[:mode].to_s
      @mode = 'combined' unless MODES.include?(@mode)
      @railing_max = (options[:railing_max] || Config::GLASS_RAILING_MAX).to_f
      @tinted_min  = (options[:tinted_min] || Config::GLASS_TINTED_MIN).to_f
      @opaque_min  = (options[:opaque_min] || Config::GLASS_OPAQUE_MIN).to_f
      @entries = options[:entries]
      @whiten_opaque = options[:whiten_opaque] ? true : false
      @saved = []
      @applied = false
      @recolored = 0
      @hidden = 0
      @whitened = 0
    end

    def applied?
      @applied
    end

    # Применяет режим к материалам модели. Возвращает число изменённых материалов.
    def apply
      return 0 if @applied
      entries.each do |entry|
        begin
          action = action_for(entry.type)
          next if action.nil?
          change_material(entry, action)
        rescue StandardError => e
          FacadeExport.log("Материал \"#{safe_name(entry.material)}\" не изменён: #{e.message}")
        end
      end
      @applied = true
      @recolored + @hidden + @whitened
    end

    # Список материалов: заранее посчитанный (options[:entries]) или свой.
    def entries
      @entries ||= self.class.scan(@model,
                                   :railing_max => @railing_max,
                                   :tinted_min => @tinted_min,
                                   :opaque_min => @opaque_min,
                                   :include_opaque => @whiten_opaque)
    end

    # Возвращает исходные цвета, непрозрачность и текстуры.
    def restore
      return false unless @applied
      @saved.each do |state|
        mat = state[:material]
        next if mat.nil?
        begin
          if state[:texture]
            mat.texture = state[:texture]
            begin
              mat.texture.width = state[:texture_width] if state[:texture_width]
              mat.texture.height = state[:texture_height] if state[:texture_height]
            rescue StandardError
              nil
            end
          end
          c = state[:color]
          mat.color = Sketchup::Color.new(c[0], c[1], c[2], c[3]) if c
          mat.alpha = state[:alpha]
        rescue StandardError => e
          FacadeExport.log("Материал \"#{safe_name(mat)}\" не восстановлен: #{e.message}")
        end
      end
      @saved.clear
      @applied = false
      @recolored = 0
      @hidden = 0
      @whitened = 0
      true
    end

    # Тип стекла по непрозрачности в процентах (или nil для обычных материалов).
    def classify(opacity_percent)
      return 'railing' if opacity_percent <= @railing_max
      return 'tinted' if opacity_percent >= @tinted_min && opacity_percent < @opaque_min
      return 'main' if opacity_percent < @tinted_min
      nil
    end

    private

    # :color  — перекрасить и сделать непрозрачным (карта окон),
    # :opaque — оставить исходный цвет и текстуру, но сделать непрозрачным
    #           (карты текстур/линий/теней: стекло там не должно просвечивать
    #           и пропускать свет — иначе видны предметы за фасадом и нет тени),
    # :hide   — сделать полностью прозрачным (ограждения на «не оконных» картах),
    # :white  — убрать текстуру и покрасить в белый (непрозрачные материалы на
    #           карте окон: на карте должны остаться только окна),
    # nil     — не трогать.
    def action_for(type)
      return(@whiten_opaque ? :white : nil) if type == 'opaque'
      case @mode
      when 'combined'
        :color
      when 'main', 'tinted', 'railing'
        type == @mode ? :color : :hide
      when 'hide_railings'
        type == 'railing' ? :hide : :opaque
      end
    end

    def change_material(entry, action)
      mat = entry.material
      # Полное состояние (с текстурой) нужно только при перекраске:
      # для «сделать непрозрачным» и «скрыть» меняется одна непрозрачность.
      state = save_state(mat, entry.alpha, action == :color || action == :white)
      case action
      when :color
        color = @colors[entry.type] || @colors['main'] || [0, 255, 21]
        mat.texture = nil if state[:texture]
        mat.color = Sketchup::Color.new(color[0], color[1], color[2])
        mat.alpha = 1.0
        @recolored += 1
      when :opaque
        mat.alpha = 1.0
        @recolored += 1
      when :hide
        mat.alpha = 0.0
        @hidden += 1
      when :white
        mat.texture = nil
        mat.color = Sketchup::Color.new(255, 255, 255)
        @whitened += 1
      end
      @saved << state
    end

    def safe_name(mat)
      mat.respond_to?(:name) ? mat.name : mat.to_s
    end

    def save_state(mat, alpha, with_texture)
      state = { :material => mat, :alpha => alpha }
      return state unless with_texture
      color = mat.color
      texture = nil
      tw = nil
      th = nil
      begin
        if mat.texture
          texture = mat.texture.filename
          tw = mat.texture.width
          th = mat.texture.height
        end
      rescue StandardError
        texture = nil
      end
      state[:color] = [color.red, color.green, color.blue, color.alpha] if color
      state[:texture] = texture
      state[:texture_width] = tw
      state[:texture_height] = th
      state
    end
  end
end
