# encoding: utf-8
# Экспорт фасадов — снимок и восстановление состояния сцены
# (параметры стиля, настройки теней, камера).
# Автор: Артем Титов (motivate_rt)

module FacadeExport
  # Универсальная "сумка" параметров над RenderingOptions / ShadowInfo.
  # Умеет безопасно писать только те ключи, которые реально существуют
  # в текущей версии SketchUp (в 2024+ запись неизвестного ключа бросает
  # ArgumentError, а в старых версиях ключа может просто не быть).
  class OptionBag
    # Вычисляемые SketchUp значения: их нельзя (и не нужно) записывать.
    READ_ONLY_KEYS = %w[SunDirection SunRise SunSet].freeze

    attr_reader :object, :label, :unsupported

    def initialize(object, label)
      @object = object
      @label = label
      @keys = nil
      @unsupported = {}
    end

    def keys
      @keys ||= begin
        list = []
        begin
          @object.each_key { |k| list << k.to_s }
        rescue StandardError
          begin
            @object.each { |k, _v| list << k.to_s }
          rescue StandardError
            list = []
          end
        end
        list
      end
    end

    def supported?(key)
      k = key.to_s
      return false if READ_ONLY_KEYS.include?(k)
      keys.empty? || keys.include?(k)
    end

    def get(key)
      @object[key.to_s]
    rescue StandardError
      nil
    end

    def same?(a, b)
      if a.is_a?(Sketchup::Color) || b.is_a?(Sketchup::Color)
        ca = a.is_a?(Sketchup::Color) ? a.to_a : a
        cb = b.is_a?(Sketchup::Color) ? b.to_a : b
        ca == cb
      elsif a.is_a?(Numeric) && b.is_a?(Numeric)
        (a.to_f - b.to_f).abs < 1.0e-9
      else
        a == b
      end
    end

    # Возвращает true, если значение записано.
    def set(key, value)
      key = key.to_s
      unless supported?(key)
        @unsupported[key] = true
        return false
      end
      begin
        @object[key] = value
        true
      rescue StandardError => e
        @unsupported[key] = true
        FacadeExport.log("#{@label}: не удалось задать \"#{key}\" = #{value.inspect} (#{e.message})")
        false
      end
    end

    # Пишет только отличающиеся значения. Возвращает список изменённых ключей.
    def apply(hash)
      changed = []
      hash.each do |key, value|
        k = key.to_s
        next unless supported?(k)
        next if same?(get(k), value)
        changed << k if set(k, value)
      end
      changed
    end

    def snapshot
      hash = {}
      begin
        @object.each { |k, v| hash[k.to_s] = v }
      rescue StandardError => e
        FacadeExport.log("#{@label}: не удалось прочитать состояние: #{e.message}")
      end
      hash
    end

    def restore(hash)
      return if hash.nil? || hash.empty?
      hash.each do |key, value|
        next unless supported?(key)
        next if same?(get(key), value)
        set(key, value)
      end
    end
  end

  # Снимок всего, что плагин меняет во время экспорта.
  class SceneState
    attr_reader :rendering, :shadow, :camera_info, :view

    def initialize(model, view)
      @model = model
      @view  = view
      @rendering = OptionBag.new(model.rendering_options, 'Стиль')
      @shadow    = OptionBag.new(model.shadow_info, 'Тени')
      @rendering_snapshot = @rendering.snapshot
      @shadow_snapshot    = @shadow.snapshot
      @camera_info = capture_camera(view.camera)
    end

    def restore!(restore_camera = true)
      restore_camera! if restore_camera && @camera_info
      @rendering.restore(@rendering_snapshot)
      @shadow.restore(@shadow_snapshot)
      true
    end

    def restore_camera!
      info = @camera_info
      return false if info.nil?
      cam = begin
        Sketchup::Camera.new(info[:eye], info[:target], info[:up])
      rescue StandardError
        nil
      end
      return false if cam.nil?
      begin
        cam.perspective = info[:perspective]
      rescue StandardError
        nil
      end
      if info[:perspective]
        begin
          cam.fov = info[:fov] if info[:fov]
        rescue StandardError
          nil
        end
      else
        begin
          cam.height = info[:height] if info[:height]
        rescue StandardError
          nil
        end
      end
      @view.camera = cam
      true
    end

    private

    def capture_camera(cam)
      info = {}
      begin
        info[:eye]    = Geom::Point3d.new(cam.eye.x, cam.eye.y, cam.eye.z)
        info[:target] = Geom::Point3d.new(cam.target.x, cam.target.y, cam.target.z)
        info[:up]     = Geom::Vector3d.new(cam.up.x, cam.up.y, cam.up.z)
      rescue StandardError
        return nil
      end
      info[:perspective] = begin
        cam.perspective?
      rescue StandardError
        true
      end
      info[:fov] = begin
        cam.fov
      rescue StandardError
        nil
      end
      info[:height] = begin
        cam.height
      rescue StandardError
        nil
      end
      info
    end
  end
end
