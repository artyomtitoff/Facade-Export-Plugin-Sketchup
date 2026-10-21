# encoding: utf-8
# Минимальная заглушка SketchUp Ruby API для автотестов плагина.
# НЕ устанавливается вместе с плагином (лежит в папке test/).
# Позволяет прогнать всю логику экспорта без установленного SketchUp.

module Geom
  class Vector3d
    attr_reader :x, :y, :z

    def initialize(x = 0.0, y = 0.0, z = 0.0)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end

    def to_a
      [@x, @y, @z]
    end

    def length
      Math.sqrt(@x * @x + @y * @y + @z * @z)
    end
    alias_method :magnitude, :length

    def normalize!
      len = length
      return self if len.zero?
      @x /= len
      @y /= len
      @z /= len
      self
    end

    def normalize
      copy = Geom::Vector3d.new(@x, @y, @z)
      copy.normalize!
    end

    def cross(other)
      Geom::Vector3d.new(
        @y * other.z - @z * other.y,
        @z * other.x - @x * other.z,
        @x * other.y - @y * other.x
      )
    end

    def dot(other)
      @x * other.x + @y * other.y + @z * other.z
    end

    def -(other)
      Geom::Vector3d.new(@x - other.x, @y - other.y, @z - other.z)
    end

    def +(other)
      Geom::Vector3d.new(@x + other.x, @y + other.y, @z + other.z)
    end

    def inspect
      format('Vector(%0.3f, %0.3f, %0.3f)', @x, @y, @z)
    end

    def ==(other)
      return false unless other.respond_to?(:x) && other.respond_to?(:y) && other.respond_to?(:z)
      (x - other.x).abs < 1e-9 && (y - other.y).abs < 1e-9 && (z - other.z).abs < 1e-9
    end
  end

  class Point3d
    attr_reader :x, :y, :z

    def initialize(x = 0.0, y = 0.0, z = 0.0)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end

    def to_a
      [@x, @y, @z]
    end

    def -(other)
      if other.is_a?(Geom::Point3d)
        Geom::Vector3d.new(@x - other.x, @y - other.y, @z - other.z)
      else
        Geom::Point3d.new(@x - other.x, @y - other.y, @z - other.z)
      end
    end

    def +(vec)
      Geom::Point3d.new(@x + vec.x, @y + vec.y, @z + vec.z)
    end

    def inspect
      format('Point(%0.3f, %0.3f, %0.3f)', @x, @y, @z)
    end

    def ==(other)
      return false unless other.respond_to?(:x) && other.respond_to?(:y) && other.respond_to?(:z)
      (x - other.x).abs < 1e-9 && (y - other.y).abs < 1e-9 && (z - other.z).abs < 1e-9
    end
  end

  class BoundingBox
    attr_reader :min, :max

    def initialize(points)
      xs = points.map(&:x)
      ys = points.map(&:y)
      zs = points.map(&:z)
      @min = Geom::Point3d.new(xs.min, ys.min, zs.min)
      @max = Geom::Point3d.new(xs.max, ys.max, zs.max)
    end

    def empty?
      false
    end

    def center
      Geom::Point3d.new((@min.x + @max.x) / 2.0,
                        (@min.y + @max.y) / 2.0,
                        (@min.z + @max.z) / 2.0)
    end

    def diagonal
      @max - @min
    end

    def width
      @max.x - @min.x
    end

    def depth
      @max.y - @min.y
    end

    def height
      @max.z - @min.z
    end
  end
end

module Sketchup
  COLOR_NAMES = %w[red green blue alpha].freeze

  class Color
    def initialize(r, g, b, a = 255)
      @r = r.to_i
      @g = g.to_i
      @b = b.to_i
      @a = a.to_i
    end

    def red
      @r
    end

    def green
      @g
    end

    def blue
      @b
    end

    def alpha
      @a
    end

    def to_a
      [@r, @g, @b, @a]
    end

    def inspect
      format('Color(%d, %d, %d, %d)', @r, @g, @b, @a)
    end
  end

  class Camera
    attr_reader :eye, :target, :up

    def initialize(eye, target, up)
      @eye = eye
      @target = target
      @up = up
      @perspective = true
      @height = 100.0
      @fov = 35.0
    end

    def direction
      v = Geom::Vector3d.new(@target.x - @eye.x, @target.y - @eye.y, @target.z - @eye.z)
      v.normalize
    end

    def perspective?
      @perspective
    end

    attr_writer :perspective

    attr_accessor :height, :fov
  end

  class RenderingOptions
    include Enumerable

    def initialize(hash, strict = false)
      @hash = hash
      @strict = strict
    end

    def [](key)
      @hash[key.to_s]
    end

    def []=(key, value)
      k = key.to_s
      if @strict && !@hash.key?(k)
        raise ArgumentError, "Unknown rendering option: #{k}"
      end
      @hash[k] = value
    end

    def each(&block)
      @hash.each(&block)
    end

    def each_key(&block)
      @hash.each_key(&block)
    end

    def keys
      @hash.keys
    end

    def to_h
      @hash.dup
    end
  end

  # Тени + "физика солнца" (упрощённый алгоритм NOAA),
  # чтобы проверить калибровку угла солнца.
  class ShadowInfo
    include Enumerable

    DEG = Math::PI / 180.0
    RAD = 180.0 / Math::PI

    def initialize(hash)
      @hash = hash
    end

    def [](key)
      k = key.to_s
      return sun_direction if k == 'SunDirection'
      @hash[k]
    end

    def []=(key, value)
      @hash[key.to_s] = value
    end

    def each(&block)
      @hash.each(&block)
    end

    def each_key(&block)
      @hash.each_key(&block)
    end

    def keys
      @hash.keys
    end

    def to_h
      @hash.merge('SunDirection' => sun_direction)
    end

    private

    def sun_direction
      t = @hash['ShadowTime'] || Time.gm(2000, 3, 21, 12, 6, 50)
      t = t.utc
      yday = t.yday.to_f
      hour = t.hour + t.min / 60.0 + t.sec / 3600.0
      decl = 23.45 * Math.sin(2.0 * Math::PI / 365.0 * (284.0 + yday))
      b = 2.0 * Math::PI / 365.0 * (yday - 81.0)
      eot = 9.87 * Math.sin(2.0 * b) - 7.53 * Math.cos(b) - 1.5 * Math.sin(b)
      tz = (@hash['TZOffset'] || 0).to_f
      solar_time = hour - tz + @hash['Longitude'].to_f / 15.0 + eot / 60.0
      ha = 15.0 * (solar_time - 12.0) * DEG
      lat = @hash['Latitude'].to_f * DEG
      d = decl * DEG

      sin_alt = Math.sin(lat) * Math.sin(d) + Math.cos(lat) * Math.cos(d) * Math.cos(ha)
      sin_alt = [[sin_alt, -1.0].max, 1.0].min
      alt = Math.asin(sin_alt)
      az_geo = Math.atan2(-Math.sin(ha), Math.tan(d) * Math.cos(lat) - Math.sin(lat) * Math.cos(ha))

      e = Math.cos(alt) * Math.sin(az_geo)
      n = Math.cos(alt) * Math.cos(az_geo)
      u = Math.sin(alt)

      na = @hash['NorthAngle'].to_f * DEG
      north = [Math.sin(na), Math.cos(na)]
      east = [Math.cos(na), -Math.sin(na)]

      Geom::Vector3d.new(
        e * east[0] + n * north[0],
        e * east[1] + n * north[1],
        u
      )
    end
  end

  class Texture
    attr_accessor :filename, :width, :height
  end

  class Material
    attr_reader :name
    attr_accessor :color, :alpha

    def initialize(name, color, alpha = 1.0, texture = nil)
      @name = name
      @color = color
      @alpha = alpha
      @texture = texture
    end

    def texture
      @texture
    end

    # Как в SketchUp: material.texture = "путь/к/картинке.png"
    def texture=(value)
      if value.is_a?(String)
        tex = Sketchup::Texture.new
        tex.filename = value
        @texture = tex
      else
        @texture = value
      end
    end

    def use_alpha?
      @alpha < 1.0
    end
  end

  class Materials
    include Enumerable

    def initialize(list)
      @list = list
    end

    def each(&block)
      @list.each(&block)
    end

    def [](name)
      @list.find { |m| m.name == name }
    end

    def to_a
      @list.dup
    end
  end

  class View
    attr_reader :writes

    def initialize(model)
      @model = model
      @camera = Sketchup::Camera.new(
        Geom::Point3d.new(0, -3000, 300), Geom::Point3d.new(0, 0, 300), Geom::Vector3d.new(0, 0, 1)
      )
      @vpwidth = 1600.0
      @vpheight = 900.0
      @writes = []
    end

    def camera
      @camera
    end

    def camera=(value)
      @camera = value
    end

    attr_accessor :vpwidth, :vpheight

    # Имитация записи PNG: сохраняем снимок параметров на момент экспорта.
    def write_image(options)
      path = options[:filename] || options[0]
      dir = File.dirname(path)
      Dir.mkdir(dir) unless File.directory?(dir)
      payload = build_payload(options)
      File.write(path, payload)
      @writes << {
        :path => path,
        :width => options.is_a?(Hash) ? options[:width] : options[1],
        :height => options.is_a?(Hash) ? options[:height] : options[2],
        :antialias => options.is_a?(Hash) ? options[:antialias] : options[3],
        :transparent => options.is_a?(Hash) ? options[:transparent] : nil,
        :scale_factor => options.is_a?(Hash) ? options[:scale_factor] : nil,
        :rendering => @model.rendering_options.to_h,
        :shadow => @model.shadow_info.to_h,
        :camera => @camera,
        :materials => @model.materials.map { |m| [m.name, m.color.to_a, m.alpha] },
        :selection => @model.selection.length
      }
      true
    end

    private

    def build_payload(options)
      # Небольшой валидный PNG + текстовая сигнатура для тестов.
      signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A].pack('C*')
      body = "FAKE-PNG #{options.inspect}"
      body = body.encode('UTF-8').b if body.respond_to?(:b)
      signature + body
    end
  end

  class Selection
    include Enumerable

    def initialize
      @list = []
    end

    def to_a
      @list.dup
    end

    def clear
      @list.clear
      self
    end

    def add(entities)
      @list.concat(Array(entities))
      self
    end

    def each(&block)
      @list.each(&block)
    end

    def length
      @list.length
    end
  end

  class Model
    attr_accessor :title, :path, :rendering_options, :shadow_info, :materials, :bounds

    def initialize
      @title = 'Заречная'
      @path = '/models/Заречная.skp'
      @rendering_options = Sketchup::RenderingOptions.new(
        {
          'BackgroundColor' => Sketchup::Color.new(240, 240, 240),
          'SkyColor' => Sketchup::Color.new(120, 170, 255),
          'GroundColor' => Sketchup::Color.new(100, 90, 60),
          'HorizonColor' => Sketchup::Color.new(0, 0, 0, 0),
          'DrawSky' => true,
          'DrawGround' => true,
          'DrawHorizon' => true,
          'DrawBackEdges' => true,
          'ModelTransparency' => true,
          'MaterialTransparency' => true,
          'RenderMode' => 2,
          'Texture' => true,
          'EdgeDisplayMode' => 1,
          'DrawProfilesOnly' => true,
          'DrawDepthQue' => true,
          'ExtendLines' => true,
          'DrawLineEnds' => true,
          'JitterEdges' => true,
          'DrawSilhouettes' => true,
          'EdgeType' => 0,
          'DisplayFog' => true,
          'DisplayWatermarks' => true,
          'HideConstructionGeometry' => false,
          'DisplaySectionCuts' => true,
          'DisplaySectionPlanes' => true,
          'DisplayLineStyles' => true,
          'ShowViewName' => true,
          'DrawHidden' => true,
          'DisplaySketchAxes' => true,
          'DisplayInstanceAxes' => true,
          'DisplayText' => true,
          'DisplayDims' => true
        }
      )
      @shadow_info = Sketchup::ShadowInfo.new(
        {
          'City' => 'Amsterdam',
          'Country' => 'NL',
          'Latitude' => 52.37,
          'Longitude' => 4.9,
          'TZOffset' => 1,
          'NorthAngle' => 12.0,
          'DayOfYear' => 200,
          'DaylightSavings' => true,
          'DisplayShadows' => false,
          'DisplayNorth' => false,
          'DisplayOnAllFaces' => true,
          'DisplayOnGroundPlane' => true,
          'EdgesCastShadows' => true,
          'Light' => 80,
          'Dark' => 45,
          'UseSunForAllShading' => true,
          'ShadowTime' => Time.gm(2026, 7, 19, 9, 30, 0)
        }
      )
      house = [
        Geom::Point3d.new(0, 0, 0), Geom::Point3d.new(1200, 0, 0),
        Geom::Point3d.new(0, 800, 0), Geom::Point3d.new(1200, 800, 0),
        Geom::Point3d.new(0, 0, 600), Geom::Point3d.new(1200, 0, 600),
        Geom::Point3d.new(0, 800, 600), Geom::Point3d.new(1200, 800, 600)
      ]
      @bounds = Geom::BoundingBox.new(house)
      @materials = Sketchup::Materials.new(
        [
          Sketchup::Material.new('Кирпич', Sketchup::Color.new(180, 90, 70)),
          Sketchup::Material.new('Стекло', Sketchup::Color.new(200, 230, 240), 0.35),
          Sketchup::Material.new('Рама', Sketchup::Color.new(60, 60, 60), 1.0),
          Sketchup::Material.new(
            'Витрина', Sketchup::Color.new(150, 200, 220), 0.0,
            begin
              t = Sketchup::Texture.new
              t.filename = '/textures/glass.jpg'
              t.width = 1.0
              t.height = 1.0
              t
            end
          )
        ]
      )
      @selection = Sketchup::Selection.new
      @view = Sketchup::View.new(self)
    end

    def selection
      @selection
    end

    def active_view
      @view
    end
  end

  class << self
    attr_accessor :active_model

    def status_text
      @status_text ||= ''
    end

    def status_text=(value)
      @status_text = value
    end

    def read_default(section, key, default = '')
      (@defaults ||= {})["#{section}/#{key}"] || default
    end

    def write_default(section, key, value)
      (@defaults ||= {})["#{section}/#{key}"] = value
      true
    end

    def defaults
      @defaults ||= {}
    end
  end
end

module UI
  MB_OK = 0

  class Command
    attr_accessor :tooltip, :status_bar_text, :menu_text, :small_icon, :large_icon
    attr_reader :name

    def initialize(name, &block)
      @name = name
      @block = block
    end

    def call
      @block.call
    end
  end

  class Toolbar
    attr_reader :name, :items

    def initialize(name)
      @name = name
      @items = []
    end

    def add_item(command)
      @items << command
      self
    end

    def add_separator
      self
    end

    def restore
      self
    end

    def show
      self
    end
  end

  class Menu
    attr_reader :name, :items

    def initialize(name)
      @name = name
      @items = []
    end

    def add_item(command)
      @items << command
      self
    end

    def add_submenu(command)
      submenu = UI::Menu.new(command.is_a?(String) ? command : command.to_s)
      @items << submenu
      submenu
    end

    def add_separator
      self
    end
  end

  class HtmlDialog
    STYLE_DIALOG = 1

    def initialize(_options = {})
      @callbacks = {}
    end

    def add_action_callback(name, &block)
      @callbacks[name.to_s] = block
    end

    def set_file(_path); true; end
    def set_html(_html); true; end
    def show; true; end
    def close; true; end
    def visible?; false; end
    def bring_to_front; true; end
    def execute_script(_script); true; end
  end

  class << self
    attr_accessor :savepanel_result, :messages, :status_text, :messagebox_answer

    def messagebox(text, _flags = 0)
      (@messages ||= []) << text
      puts "  [messagebox] #{text.to_s.lines.first}"
      @messagebox_answer
    end

    def savepanel(_title, _dir, _name)
      @savepanel_result
    end

    def set_cursor(_cursor)
      true
    end

    def menu(_name)
      UI::Menu.new('Extensions')
    end
  end
end
