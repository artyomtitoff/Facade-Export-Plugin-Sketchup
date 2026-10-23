# encoding: utf-8
# Экспорт фасадов — работа с прозрачными (стеклянными) материалами.
# Автор: Артем Титов (motivate_rt)
#
# Типы стекла определяются по непрозрачности материала:
#   0–10 %   — стеклянные ограждения (на картах текстур/линий/теней исчезают);
#   11–89 %  — основное стекло;
#   90–99 %  — тонированное стекло;
#   100 %    — обычный материал, не трогаем.

module FacadeExport
  class GlassRecolor
    # Режимы:
    #   'combined'     — карта "Окна": все типы стекла в свои цвета, непрозрачность 100 %;
    #   'main' / 'tinted' / 'railing' — отдельная карта одного типа:
    #                    нужный тип окрашен, остальные типы стекла исчезают;
    #   'hide_railings' — карты текстур/линий/теней: ограждения исчезают.
    MODES = %w[combined main tinted railing hide_railings].freeze
    TYPES = %w[main tinted railing].freeze

    attr_reader :recolored, :hidden

    def initialize(model, colors, options = {})
      @model = model
      @colors = colors || {}
      @mode = options[:mode].to_s
      @mode = 'combined' unless MODES.include?(@mode)
      @railing_max = (options[:railing_max] || Config::GLASS_RAILING_MAX).to_f
      @tinted_min  = (options[:tinted_min] || Config::GLASS_TINTED_MIN).to_f
      @opaque_min  = (options[:opaque_min] || Config::GLASS_OPAQUE_MIN).to_f
      @saved = []
      @applied = false
      @recolored = 0
      @hidden = 0
    end

    def applied?
      @applied
    end

    # Применяет режим к материалам модели. Возвращает число изменённых материалов.
    def apply
      return 0 if @applied
      @model.materials.each do |mat|
        begin
          alpha = material_alpha(mat)
          next if alpha.nil?
          type = classify(alpha * 100.0)
          next if type.nil?
          action = action_for(type)
          next if action.nil?
          change_material(mat, alpha, type, action)
        rescue StandardError => e
          FacadeExport.log("Материал \"#{safe_name(mat)}\" не изменён: #{e.message}")
        end
      end
      @applied = true
      @recolored + @hidden
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
          mat.color = Sketchup::Color.new(c[0], c[1], c[2], c[3])
          mat.alpha = state[:alpha]
        rescue StandardError => e
          FacadeExport.log("Материал \"#{safe_name(mat)}\" не восстановлен: #{e.message}")
        end
      end
      @saved.clear
      @applied = false
      @recolored = 0
      @hidden = 0
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

    # :color — перекрасить и сделать непрозрачным,
    # :hide  — сделать полностью прозрачным,
    # nil    — не трогать.
    def action_for(type)
      case @mode
      when 'combined'
        :color
      when 'main', 'tinted', 'railing'
        type == @mode ? :color : :hide
      when 'hide_railings'
        type == 'railing' ? :hide : nil
      end
    end

    def change_material(mat, alpha, type, action)
      state = save_state(mat, alpha)
      case action
      when :color
        color = @colors[type] || @colors['main'] || [0, 255, 21]
        mat.texture = nil if state[:texture]
        mat.color = Sketchup::Color.new(color[0], color[1], color[2])
        mat.alpha = 1.0
        @recolored += 1
      when :hide
        mat.alpha = 0.0
        @hidden += 1
      end
      @saved << state
    end

    def safe_name(mat)
      mat.respond_to?(:name) ? mat.name : mat.to_s
    end

    def material_alpha(mat)
      if mat.respond_to?(:use_alpha?) && mat.use_alpha? == false
        return 1.0
      end
      return mat.alpha.to_f if mat.respond_to?(:alpha)
      c = mat.color
      c ? c.alpha.to_f / 255.0 : 1.0
    rescue StandardError
      nil
    end

    def save_state(mat, alpha)
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
      {
        :material => mat,
        :color => [color.red, color.green, color.blue, color.alpha],
        :alpha => alpha,
        :texture => texture,
        :texture_width => tw,
        :texture_height => th
      }
    end
  end
end
