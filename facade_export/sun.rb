# encoding: utf-8
# Экспорт фасадов — постановка солнца для "архитектурных" теней под 45°
# слева сверху (принцип плагина Elevation 45 Shadows, TIG).
# Автор: Артем Титов (motivate_rt)

module FacadeExport
  module Sun
    Z_AXIS = Geom::Vector3d.new(0, 0, 1)
    RAD2DEG = 180.0 / Math::PI
    DEG2RAD = Math::PI / 180.0

    # Дата/время подобраны так, чтобы солнце стояло в истинный полдень
    # (равноденствие 21 марта). Высота солнца при этом = 90° - широта,
    # поэтому широту можно точно "подогнать" под нужный угол.
    SOLAR_NOON = Time.gm(2000, 3, 21, 12, 6, 50).freeze

    module_function

    # Вектор "на солнце" (из модели к солнцу) для нужного фасада.
    # azimuth   — насколько солнце смещено влево от взгляда (0..90°)
    # elevation — высота солнца над горизонтом (5..89°)
    def desired_sun_vector(direction, azimuth_deg, elevation_deg)
      d = Geom::Vector3d.new(direction.x, direction.y, 0.0)
      d.normalize!
      right = d.cross(Z_AXIS)
      right = Geom::Vector3d.new(1, 0, 0) if right.length < 1.0e-6
      right.normalize!

      a = azimuth_deg.to_f * DEG2RAD
      e = elevation_deg.to_f * DEG2RAD

      # Солнце спереди (со стороны камеры) и слева от наблюдателя.
      hx = -d.x * Math.cos(a) - right.x * Math.sin(a)
      hy = -d.y * Math.cos(a) - right.y * Math.sin(a)
      hlen = Math.sqrt(hx * hx + hy * hy)
      return Geom::Vector3d.new(0, 0, 1) if hlen < 1.0e-9

      Geom::Vector3d.new(
        hx / hlen * Math.cos(e),
        hy / hlen * Math.cos(e),
        Math.sin(e)
      )
    end

    # Настройка теней для одного фасада.
    # bag — FacadeExport::OptionBag над model.shadow_info
    def setup(bag, direction, options = {})
      azimuth   = (options[:azimuth] || 45.0).to_f
      elevation = (options[:elevation] || 45.0).to_f
      use_sun   = options.key?(:use_sun_for_shading) ? options[:use_sun_for_shading] : false

      # Базовая "география" — как в Elevation 45 Shadows.
      bag.set('Country', 'Экспорт фасадов')
      bag.set('City', 'Экспорт фасадов')
      bag.set('TZOffset', 0)
      bag.set('DaylightSavings', false)
      bag.set('Longitude', 0.0)
      bag.set('ShadowTime', SOLAR_NOON)

      # Собственно тени.
      bag.set('DisplayShadows', true)
      bag.set('DisplayOnAllFaces', true)
      bag.set('DisplayOnGroundPlane', false)
      bag.set('EdgesCastShadows', true)
      bag.set('UseSunForAllShading', use_sun ? true : false)
      bag.set('Light', (options[:light] || 100).to_i)
      bag.set('Dark', (options[:dark] || 0).to_i)

      desired = desired_sun_vector(direction, azimuth, elevation)
      desired_azimuth = azimuth_of(desired)

      # 1. Высота солнца: подгоняем широту.
      latitude = [[90.0 - elevation, -89.0].max, 89.0].min
      bag.set('Latitude', latitude)
      bag.set('NorthAngle', 0.0)

      measured = sun_direction(bag)
      calibrated = false
      if measured
        3.times do
          elev = elevation_of(measured)
          err = elev - elevation
          break if err.abs < 0.2
          latitude = [[latitude + err, -89.0].max, 89.0].min
          bag.set('Latitude', latitude)
          measured = sun_direction(bag)
        end
        calibrated = true
      end

      # 2. Азимут солнца: подбираем NorthAngle по фактическому SunDirection.
      north_angle = nil
      if measured
        a0 = azimuth_of(measured)
        bag.set('NorthAngle', 30.0)
        probe = sun_direction(bag)
        if probe
          a1 = azimuth_of(probe)
          rate = Util.deg_delta(a0, a1) / 30.0
          if rate.abs > 0.05
            north_angle = 0.0
            4.times do
              bag.set('NorthAngle', Util.normalize_deg(north_angle))
              current = sun_direction(bag)
              break if current.nil?
              err = Util.deg_delta(azimuth_of(current), desired_azimuth)
              break if err.abs < 0.2
              north_angle += err / rate
            end
          end
        end
      end

      # 3. Резервный вариант — формула из Elevation 45 Shadows (TIG).
      if north_angle.nil?
        north_angle = legacy_north_angle(direction)
        bag.set('NorthAngle', Util.normalize_deg(north_angle))
        calibrated = false
      else
        bag.set('NorthAngle', Util.normalize_deg(north_angle))
      end

      final = sun_direction(bag)
      {
        :latitude      => bag.get('Latitude'),
        :north_angle   => bag.get('NorthAngle'),
        :azimuth       => final ? azimuth_of(final) : nil,
        :elevation     => final ? elevation_of(final) : nil,
        :target_azimuth => desired_azimuth,
        :target_elevation => elevation,
        :calibrated    => calibrated
      }
    end

    # Только выключить тени (для карт без теней).
    def disable(bag, use_sun_for_shading = false)
      bag.set('DisplayShadows', false)
      bag.set('UseSunForAllShading', use_sun_for_shading ? true : false)
    end

    def sun_direction(bag)
      v = bag.get('SunDirection')
      return nil unless v.respond_to?(:x) && v.respond_to?(:y) && v.respond_to?(:z)
      len = Math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
      return nil if len < 1.0e-9
      Geom::Vector3d.new(v.x / len, v.y / len, v.z / len)
    rescue StandardError
      nil
    end

    def azimuth_of(vector)
      Util.normalize_deg(Math.atan2(vector.y, vector.x) * RAD2DEG)
    end

    def elevation_of(vector)
      len = Math.sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z)
      return 0.0 if len < 1.0e-9
      Math.asin([[vector.z / len, -1.0].max, 1.0].min) * RAD2DEG
    end

    # Оригинальный расчёт из Elevation45shadows.rb (TIG, 2006-2014):
    # угол северного направления, при котором солнце светит под 45°
    # слева сверху относительно текущего вида.
    def legacy_north_angle(direction)
      x = direction.x
      y = direction.y
      z = direction.z
      a = Math.atan2(y, x).abs * RAD2DEG
      angle = 0.0

      if y == 0
        angle = 90 + 45 if x > 0
        angle = 270 + 45 if x < 0
      end
      if y > 0
        angle = 45 if x == 0
        angle = 90 - a + 45 if x > 0
        angle = 180 - a - 90 + 45 if x < 0
      end
      if y < 0
        angle = 180 + 45 if x == 0
        angle = a + 180 - 45 if x > 0
        angle = a + 90 + 45 if x < 0
      end
      angle = 90 + 45 if z != 0 && x == 0 && y == 0
      Util.normalize_deg(angle)
    end
  end
end
