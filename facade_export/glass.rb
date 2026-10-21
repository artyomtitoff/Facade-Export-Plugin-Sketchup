# encoding: utf-8
# Экспорт фасадов — временная перекраска прозрачных (стеклянных) материалов
# в контрастный цвет и возврат исходных цветов.
# Автор: Артем Титов (motivate_rt)

module FacadeExport
  class GlassRecolor
    # min_alpha / max_alpha — какие материалы считаем "непрозрачность ≠ 100 %".
    def initialize(model, rgb, options = {})
      @model = model
      @rgb = rgb
      @min_alpha = options.key?(:min_alpha) ? options[:min_alpha].to_f : 0.0
      @max_alpha = options.key?(:max_alpha) ? options[:max_alpha].to_f : 0.999
      @saved = []
      @applied = false
      @recolored = 0
    end

    attr_reader :recolored

    def apply
      return 0 if @applied
      color = Sketchup::Color.new(@rgb[0], @rgb[1], @rgb[2])
      @model.materials.each do |mat|
        begin
          alpha = material_alpha(mat)
          next if alpha.nil?
          next if alpha >= @max_alpha || alpha < @min_alpha

          state = save_state(mat, alpha)
          mat.texture = nil if state[:texture]
          mat.color = color
          mat.alpha = 1.0
          @saved << state
          @recolored += 1
        rescue StandardError => e
          FacadeExport.log("Материал \"#{safe_name(mat)}\" не перекрашен: #{e.message}")
        end
      end
      @applied = true
      @recolored
    end

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
          mat.color = Sketchup::Color.new(state[:color][0], state[:color][1], state[:color][2], state[:color][3])
          mat.alpha = state[:alpha]
        rescue StandardError => e
          FacadeExport.log("Материал \"#{safe_name(mat)}\" не восстановлен: #{e.message}")
        end
      end
      @saved.clear
      @applied = false
      true
    end

    def applied?
      @applied
    end

    private

    def safe_name(mat)
      mat.respond_to?(:name) ? mat.name : mat.to_s
    end

    def material_alpha(mat)
      if mat.respond_to?(:use_alpha?) && mat.use_alpha? == false
        return 1.0
      end
      if mat.respond_to?(:alpha)
        return mat.alpha.to_f
      end
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
