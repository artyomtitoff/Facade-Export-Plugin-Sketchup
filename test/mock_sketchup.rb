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

    # Перенос на вектор не влияет — как в SketchUp для сдвига.
    def transform(_transformation)
      Geom::Vector3d.new(@x, @y, @z)
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

    def transform(transformation)
      Geom::Point3d.new(@x + transformation.x, @y + transformation.y, @z + transformation.z)
    end

    def inspect
      format('Point(%0.3f, %0.3f, %0.3f)', @x, @y, @z)
    end

    def ==(other)
      return false unless other.respond_to?(:x) && other.respond_to?(:y) && other.respond_to?(:z)
      (x - other.x).abs < 1e-9 && (y - other.y).abs < 1e-9 && (z - other.z).abs < 1e-9
    end
  end

  # Упрощённое преобразование: только перенос (для проверки контекста).
  class Transformation
    attr_reader :x, :y, :z

    def initialize(x = 0.0, y = 0.0, z = 0.0)
      @x = x.to_f
      @y = y.to_f
      @z = z.to_f
    end

    def *(other)
      Geom::Transformation.new(@x + other.x, @y + other.y, @z + other.z)
    end

    # Как в SketchUp: 16 чисел (матрица 4×4 по столбцам).
    def to_a
      [1.0, 0.0, 0.0, 0.0,
       0.0, 1.0, 0.0, 0.0,
       0.0, 0.0, 1.0, 0.0,
       @x.to_f, @y.to_f, @z.to_f, 1.0]
    end

    def inspect
      format('Transformation(%0.3f, %0.3f, %0.3f)', @x, @y, @z)
    end
  end

  class BoundingBox
    attr_reader :min, :max

    def initialize(points = nil)
      @min = nil
      @max = nil
      Array(points).each { |pt| add(pt) }
    end

    # Как в SketchUp: bbox.add(point)
    def add(point)
      if @min.nil?
        @min = Geom::Point3d.new(point.x, point.y, point.z)
        @max = Geom::Point3d.new(point.x, point.y, point.z)
      else
        @min = Geom::Point3d.new([@min.x, point.x].min, [@min.y, point.y].min, [@min.z, point.z].min)
        @max = Geom::Point3d.new([@max.x, point.x].max, [@max.y, point.y].max, [@max.z, point.z].max)
      end
      self
    end

    def empty?
      @min.nil?
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
  # Простейшие сущности модели (для проверки экспорта из открытой группы).
  class Entity
    attr_accessor :hidden, :bounds, :layer

    def initialize
      @hidden = false
      @layer = nil
    end

    def hidden?
      @hidden
    end

    def valid?
      true
    end
  end

  # Ребро: границы строятся по его концам.
  class Edge < Sketchup::Entity
    attr_reader :start, :end

    def initialize(start_point, end_point)
      super()
      @start = start_point
      @end = end_point
    end

    # Как в SketchUp: габариты ребра — его концы.
    def bounds
      Geom::BoundingBox.new([@start, @end])
    end
  end

  # Контур грани: список вершин.
  class Loop
    attr_reader :vertices

    def initialize(vertices)
      @vertices = vertices.map do |v|
        v.is_a?(Sketchup::Vertex) ? v : Sketchup::Vertex.new(v)
      end
    end
  end

  class Vertex
    attr_reader :position

    def initialize(position)
      @position = position
    end
  end

  # Грань. Как и в SketchUp, нормаль, площадь и габариты — «родные» и дешёвые:
  # считаются один раз при создании. Дорогой вызов — только #vertices
  # (создание обёрток Vertex), его и считаем в тестах на скорость.
  class Face < Sketchup::Entity
    attr_reader :loops, :vertex_calls

    def initialize(vertices)
      super()
      @loops = [Sketchup::Loop.new(vertices)]
      points = @loops.first.vertices.map(&:position)
      @bounds = Geom::BoundingBox.new(points)
      @normal = compute_normal(points)
      @area = compute_area(points)
      @vertex_calls = 0
    end

    def vertices
      @vertex_calls += 1
      @loops.first.vertices
    end

    def bounds
      @bounds
    end

    def normal
      @normal
    end

    def area
      @area
    end

    def reset_vertex_calls
      @vertex_calls = 0
    end

    private

    def compute_normal(points)
      return nil if points.length < 3
      origin = points[0]
      points[1..-1].each_with_index do |b, i|
        c = points[i + 2]
        next if c.nil?
        cross = (b - origin).cross(c - origin)
        next if cross.length < 1.0e-9
        return cross.normalize
      end
      nil
    end

    def compute_area(points)
      return 0.0 if points.length < 3
      sum = Geom::Vector3d.new(0, 0, 0)
      origin = points[0]
      (1...(points.length - 1)).each do |i|
        cross = (points[i] - origin).cross(points[i + 1] - origin)
        sum = Geom::Vector3d.new(sum.x + cross.x, sum.y + cross.y, sum.z + cross.z)
      end
      sum.length / 2.0
    end
  end

  # Изображение — видимый объект, но не ребро и не грань.
  class Image < Sketchup::Entity
    def initialize(bounds)
      super()
      @bounds = bounds
    end
  end

  # Метка (слой) и папка меток.
  class Layer
    attr_accessor :name, :folder

    def initialize(name = 'Layer0', visible = true)
      @name = name
      @visible = visible
      @folder = nil
    end

    def visible?
      @visible
    end

    def visible=(value)
      @visible = value
    end
  end

  class LayerFolder
    attr_accessor :name

    def initialize(name = 'Папка', visible = true)
      @name = name
      @visible = visible
    end

    def visible?
      @visible
    end
  end

  # Собирает «коробку» из 12 видимых рёбер — так тесты строят геометрию,
  # по которой плагин считает габариты.
  def self.test_box(entities, size_x, size_y, size_z, offset_x = 0.0, offset_y = 0.0, offset_z = 0.0)
    pts = {}
    [0.0, size_x].each do |x|
      [0.0, size_y].each do |y|
        [0.0, size_z].each do |z|
          pts[[x, y, z]] = Geom::Point3d.new(offset_x + x, offset_y + y, offset_z + z)
        end
      end
    end
    edges = []
    [0.0, size_x].each do |x|
      [0.0, size_y].each do |y|
        edges << [pts[[x, y, 0.0]], pts[[x, y, size_z]]]
      end
      [0.0, size_z].each do |z|
        edges << [pts[[x, 0.0, z]], pts[[x, size_y, z]]]
      end
    end
    [0.0, size_y].each do |y|
      [0.0, size_z].each do |z|
        edges << [pts[[0.0, y, z]], pts[[size_x, y, z]]]
      end
    end
    created = []
    edges.each do |a, b|
      edge = Sketchup::Edge.new(a, b)
      entities.add(edge)
      created << edge
    end
    created
  end

  class Entities
    include Enumerable

    def initialize(list = [])
      @list = list
    end

    def each(&block)
      @list.each(&block)
    end

    def to_a
      @list.dup
    end

    def add(entity)
      # Как в SketchUp: секущая плоскость помнит свой контекст.
      entity.owner = self if entity.is_a?(Sketchup::SectionPlane) && entity.respond_to?(:owner=)
      @list << entity
      self
    end

    def clear
      @list.clear
      self
    end

    def length
      @list.length
    end

    def delete(entity)
      @list.delete(entity)
      self
    end

    # Как в SketchUp: плоскость сечения добавляется в набор сущностей.
    def add_section_plane(point, normal)
      plane = Sketchup::SectionPlane.new(true, point, normal)
      plane.owner = self
      @list << plane
      plane
    end

    # В каждом контексте активна только одна плоскость сечения.
    def active_section_plane
      @list.find { |e| e.is_a?(Sketchup::SectionPlane) && e.active? }
    end

    def active_section_plane=(plane)
      @list.each do |e|
        next unless e.is_a?(Sketchup::SectionPlane)
        e.active = (e.equal?(plane))
      end
      plane
    end
  end

  class Definition
    attr_accessor :bounds, :entities

    def initialize(bounds, entities = nil)
      @bounds = bounds
      @entities = entities || Sketchup::Entities.new
    end
  end

  class ConstructionLine < Sketchup::Entity; end

  class ConstructionPoint < Sketchup::Entity; end

  class Text < Sketchup::Entity; end

  class Dimension < Sketchup::Entity; end

  class SectionPlane < Sketchup::Entity
    attr_accessor :name, :owner
    attr_reader :point, :plane_normal

    def initialize(active = true, point = nil, normal = nil)
      super()
      @active = active
      @point = point
      @plane_normal = normal
      @owner = nil
    end

    def active?
      @active
    end

    def active=(value)
      @active = value
    end

    def activate
      @owner.each { |e| e.active = false if e.is_a?(Sketchup::SectionPlane) } if @owner
      @active = true
      true
    end

    def visible=(value)
      @hidden = !value
    end

    def erase!
      @owner.delete(self) if @owner
      @erased = true
      true
    end

    def valid?
      !@erased
    end

    # Как в SketchUp: контекст, в котором лежит плоскость.
    def parent
      @owner
    end
  end

  # Группа/компонент: габариты считаются по содержимому определения.
  class Group < Sketchup::Entity
    attr_accessor :definition, :transformation

    def initialize(definition, transformation = Geom::Transformation.new)
      super()
      @definition = definition
      @transformation = transformation
    end
  end

  class GroupInstance < Sketchup::Group; end
  ComponentInstance = GroupInstance
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
        :materials => @model.materials.map do |m|
          [m.name, m.color.to_a, m.alpha, m.texture && m.texture.filename]
        end,
        :planes => @model.entities.select { |e| e.is_a?(Sketchup::SectionPlane) }
                          .map { |p| [p.name, p.hidden?, p.active?] },
        :selection => @model.selection.length,
        :hidden => @model.entities.map { |e| e.hidden? }
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

  # Сцена: имя, флаги обновления и состояние секущих плоскостей.
  class Page
    attr_accessor :name, :use_section_planes, :pages
    attr_reader :updates, :visible_planes

    def initialize(name)
      @name = name
      @use_section_planes = false
      @updates = []
      @visible_planes = []
      @valid = true
    end

    # Как в SketchUp: update запоминает текущее состояние модели —
    # в том числе какие плоскости сечения видны.
    def update(flags)
      @updates << flags
      @visible_planes = @pages ? @pages.visible_planes : []
      true
    end

    def valid?
      @valid
    end

    def erase!
      @valid = false
    end
  end

  class Pages
    include Enumerable

    def initialize(model = nil)
      @model = model
      @list = []
    end

    def add(name)
      page = Sketchup::Page.new(name)
      page.pages = self
      @list << page
      page
    end

    def visible_planes
      entities = @model ? @model.entities : nil
      return [] if entities.nil?
      entities.select do |e|
        e.is_a?(Sketchup::SectionPlane) && e.hidden? != true
      end
    end

    def erase(page)
      page.erase! if page.respond_to?(:erase!)
      @list.delete(page)
      true
    end

    def each(&block)
      @list.each(&block)
    end

    def to_a
      @list.dup
    end

    def length
      @list.length
    end

    def [](index)
      @list[index]
    end
  end

  PAGE_USE_CAMERA = 4
  PAGE_USE_SECTION_PLANES = 16

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
      @active_path = []
      @entities = Sketchup::Entities.new
      @started_operations = []
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
      Sketchup.test_box(@entities, 1200, 800, 600)
      @materials = Sketchup::Materials.new(
        [
          Sketchup::Material.new('Кирпич', Sketchup::Color.new(180, 90, 70)),
          Sketchup::Material.new('Стекло', Sketchup::Color.new(200, 230, 240), 0.35),
          Sketchup::Material.new('Рама', Sketchup::Color.new(60, 60, 60), 1.0),
          Sketchup::Material.new('Тонировка', Sketchup::Color.new(120, 140, 170), 0.95),
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

    attr_accessor :active_path, :entities

    attr_reader :operations, :aborts, :commits

    # Служебная операция: как в SketchUp, при отмене (abort_operation)
    # модель возвращается к состоянию на момент start_operation.
    def start_operation(name = nil, disable_ui = false)
      @started_operations << name
      @operations ||= []
      @operations << { :name => name, :disable_ui => disable_ui }
      @aborts ||= 0
      @commits ||= 0
      @operation_snapshot = operation_snapshot
      true
    end

    def commit_operation
      @commits = (@commits || 0) + 1
      @operation_snapshot = nil
      true
    end

    def abort_operation
      @aborts = (@aborts || 0) + 1
      restore_operation_snapshot(@operation_snapshot)
      @operation_snapshot = nil
      true
    end

    def operation_snapshot
      {
        :materials => @materials.map { |m| [m, m.color.to_a, m.alpha] },
        :rendering => @rendering_options.to_h,
        :shadow => @shadow_info.to_h,
        :hidden => visible_entities.map { |e| [e, e.hidden?] }
      }
    end

    def restore_operation_snapshot(snapshot)
      return if snapshot.nil?
      snapshot[:materials].each do |mat, color, alpha|
        mat.color = Sketchup::Color.new(color[0], color[1], color[2], color[3])
        mat.alpha = alpha
      end
      snapshot[:rendering].each { |k, v| @rendering_options[k.to_s] = v }
      snapshot[:shadow].each do |k, v|
        next if k == 'SunDirection'
        @shadow_info[k.to_s] = v
      end
      snapshot[:hidden].each { |entity, hidden| entity.hidden = hidden }
    end

    # Все сущности модели и вложенных определений (для снимка видимости).
    def visible_entities(list = nil, depth = 0)
      list ||= []
      return list if depth > 4
      @entities.each do |entity|
        list << entity
        if entity.respond_to?(:definition) && entity.definition
          visible_entities_definition(entity.definition, list, depth + 1)
        end
      end
      list
    end

    def visible_entities_definition(definition, list, depth)
      definition.entities.each do |entity|
        list << entity
        next unless entity.respond_to?(:definition) && entity.definition
        visible_entities_definition(entity.definition, list, depth + 1)
      end
    end

    def pages
      @pages ||= Sketchup::Pages.new(self)
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

    # Колбэки доступны тестам: так проверяется, что окно действительно
    # отдаёт данные в Ruby и что ошибки в колбэке не пропадают молча.
    attr_reader :callbacks
    # Скрипты, отправленные в окно: по ним видно, что Ruby обновил окно.
    attr_reader :scripts

    def initialize(_options = {})
      @callbacks = {}
      @scripts = []
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
    def execute_script(script)
      @scripts << script.to_s
      true
    end
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
