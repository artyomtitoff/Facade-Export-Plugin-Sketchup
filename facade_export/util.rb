# encoding: utf-8
# Экспорт фасадов — вспомогательные функции.
# Автор: Артем Титов (motivate_rt)

module FacadeExport
  module Util
    INVALID_FILENAME_CHARS = /[\\\/:\*\?"<>\|\x00-\x1F]/.freeze

    module_function

    # Имя файла без запрещённых символов.
    def sanitize_filename(name, fallback = 'Фасад')
      s = name.to_s.dup
      s = s.encode('UTF-8', invalid: :replace, undef: :replace) if s.respond_to?(:encode)
      s = s.gsub(INVALID_FILENAME_CHARS, '_').strip
      s = s.gsub(/\s+/, ' ')
      s = s.sub(/[\. ]+\z/, '')
      s.empty? ? fallback : s
    end

    # HEX-строка или массив -> Sketchup::Color
    def to_color(value, fallback = Config::WHITE_RGB)
      rgb =
        case value
        when Sketchup::Color then [value.red, value.green, value.blue]
        when Array then value.first(3)
        when String
          hex = value.strip.sub(/\A#/, '')
          if hex =~ /\A[0-9a-fA-F]{6}\z/
            [hex[0, 2].to_i(16), hex[2, 2].to_i(16), hex[4, 2].to_i(16)]
          else
            fallback
          end
        else
          fallback
        end
      rgb = fallback if rgb.nil? || rgb.length < 3
      Sketchup::Color.new(rgb[0].to_i, rgb[1].to_i, rgb[2].to_i)
    rescue StandardError
      Sketchup::Color.new(fallback[0], fallback[1], fallback[2])
    end

    def to_hex(value, fallback = '#FFFFFF')
      c = to_color(value)
      format('#%02X%02X%02X', c.red, c.green, c.blue)
    rescue StandardError
      fallback
    end

    # HSL (как в окне "Правка" материала SketchUp) -> [r, g, b]
    # h: 0..360, s: 0..100, l: 0..100
    def hsl_to_rgb(h, s, l)
      hh = (h.to_f % 360.0) / 360.0
      ss = [[s.to_f, 0.0].max, 100.0].min / 100.0
      ll = [[l.to_f, 0.0].max, 100.0].min / 100.0

      if ss.zero?
        v = (ll * 255.0).round
        return [v, v, v]
      end

      q = ll < 0.5 ? ll * (1.0 + ss) : ll + ss - ll * ss
      p = 2.0 * ll - q

      [
        (hue_to_rgb(p, q, hh + 1.0 / 3.0) * 255.0).round,
        (hue_to_rgb(p, q, hh) * 255.0).round,
        (hue_to_rgb(p, q, hh - 1.0 / 3.0) * 255.0).round
      ].map { |v| [[v, 0].max, 255].min }
    end

    def hue_to_rgb(p, q, t)
      t += 1.0 if t < 0.0
      t -= 1.0 if t > 1.0
      return p + (q - p) * 6.0 * t if t < 1.0 / 6.0
      return q if t < 0.5
      return p + (q - p) * (2.0 / 3.0 - t) * 6.0 if t < 2.0 / 3.0
      p
    end

    # Угол между векторами в градусах.
    def angle_between_deg(v1, v2)
      a = Math.atan2(v1.y, v1.x)
      b = Math.atan2(v2.y, v2.x)
      diff = (b - a) * 180.0 / Math::PI
      normalize_deg(diff)
    end

    # Приводит угол к диапазону [0, 360)
    def normalize_deg(deg)
      d = deg.to_f % 360.0
      d += 360.0 if d < 0.0
      d
    end

    # Кратчайшая разница углов, результат в (-180, 180]
    def deg_delta(from, to)
      d = (to.to_f - from.to_f) % 360.0
      d -= 360.0 if d > 180.0
      d
    end

    def format_duration(seconds)
      s = seconds.to_f
      return format('%.1f с', s) if s < 60.0
      minutes = (s / 60.0).floor
      rest = (s - minutes * 60).round
      format('%d мин %02d с', minutes, rest)
    end

    def format_size(bytes)
      b = bytes.to_f
      return format('%.0f Б', b) if b < 1024.0
      kb = b / 1024.0
      return format('%.0f КБ', kb) if kb < 1024.0
      format('%.1f МБ', kb / 1024.0)
    end

    # Безопасный лог в консоль Ruby.
    def log(message)
      FacadeExport.log(message)
    end
  end
end
