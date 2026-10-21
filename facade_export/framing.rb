# encoding: utf-8
# Экспорт фасадов — расчёт камеры: единый масштаб и полный кадр для всех фасадов.
# Автор: Артем Титов (motivate_rt)

module FacadeExport
  # Класс ошибок плагина (понятные сообщения пользователю).
  class ExportError < StandardError; end

  module Framing
    Z_AXIS = Geom::Vector3d.new(0, 0, 1)

    module_function

    # Горизонтальное направление взгляда камеры (куда смотрит камера).
    # Возвращает [вектор, ошибка].
    def horizontal_direction(camera)
      d = camera.direction
      v = Geom::Vector3d.new(d.x, d.y, 0.0)
      if v.length < 1.0e-6
        return [nil, 'Вид направлен вертикально (сверху/снизу). Выровняйте вид перпендикулярно фасаду.']
      end
      if d.z.abs > 0.75
        return [nil, 'Вид слишком сильно наклонён. Выровняйте вид перпендикулярно плоскости фасада (Камера > Стандартные виды или "Выровнять вид").']
      end
      [v.normalize, nil]
    end

    # Поворот горизонтального вектора на 90° (по часовой стрелке относительно оси Z).
    def rotate_90(vector)
      Geom::Vector3d.new(vector.y, -vector.x, 0.0)
    end

    # Направления взгляда для всех фасадов, начиная с текущего вида.
    def facade_directions(camera, count = 4)
      base, error = horizontal_direction(camera)
      raise ExportError, error if base.nil?
      dirs = []
      v = base
      count.times do
        dirs << Geom::Vector3d.new(v.x, v.y, 0.0)
        v = rotate_90(v)
      end
      dirs
    end

    # Восемь углов габаритного ящика модели.
    def bbox_corners(bounds)
      if bounds.nil? || bounds.empty?
        raise ExportError, 'В модели нет геометрии: экспортировать нечего.'
      end
      xs = [bounds.min.x, bounds.max.x]
      ys = [bounds.min.y, bounds.max.y]
      zs = [bounds.min.z, bounds.max.z]
      corners = []
      xs.each do |x|
        ys.each do |y|
          zs.each do |z|
            corners << Geom::Point3d.new(x, y, z)
          end
        end
      end
      corners
    end

    # Для направления взгляда считает габариты проекции и точку цели.
    def projection(corners, direction)
      right = direction.cross(Z_AXIS)
      right = Geom::Vector3d.new(1, 0, 0) if right.length < 1.0e-6
      right.normalize!

      us = []
      vs = []
      corners.each do |c|
        us << (c.x * right.x + c.y * right.y + c.z * right.z)
        vs << c.z
      end

      {
        :right => right,
        :u_min => us.min,
        :u_max => us.max,
        :v_min => vs.min,
        :v_max => vs.max,
        :width => (us.max - us.min).abs,
        :height => (vs.max - vs.min).abs,
        :u_center => (us.min + us.max) / 2.0,
        :v_center => (vs.min + vs.max) / 2.0
      }
    end

    # Единый масштаб для всех фасадов: считаем высоту ортокадра так,
    # чтобы самый "широкий" фасад целиком влез в кадр с заданным отступом.
    #
    # aspect — отношение ширины кадра к высоте.
    def plan_fit(bounds, directions, aspect, margin)
      corners = bbox_corners(bounds)
      aspect = 1.0 if aspect.nil? || aspect <= 0.0
      margin = 0.0 if margin.nil? || margin.negative?
      scale = 1.0 - margin
      scale = 0.98 if scale <= 0.0

      projections = directions.map { |d| projection(corners, d) }
      needed = projections.map do |p|
        [p[:height], p[:width] / aspect].max / scale
      end
      height = needed.max
      height = 1.0 if height.nil? || height.to_f <= 0.0

      {
        :height => height,
        :aspect => aspect,
        :projections => projections,
        :corners => corners
      }
    end

    # Точка цели камеры для конкретного фасада: центр проекции.
    def camera_target(bounds, projection)
      c = bounds.center
      right = projection[:right]
      c_u = c.x * right.x + c.y * right.y + c.z * right.z
      du = projection[:u_center] - c_u
      Geom::Point3d.new(
        c.x + right.x * du,
        c.y + right.y * du,
        projection[:v_center]
      )
    end

    # Готовая камера для фасада.
    def build_camera(bounds, direction, projection, ortho_height, perspective = false)
      target = camera_target(bounds, projection)
      distance = camera_distance(bounds, ortho_height)
      eye = Geom::Point3d.new(
        target.x - direction.x * distance,
        target.y - direction.y * distance,
        target.z - direction.z * distance
      )
      camera = Sketchup::Camera.new(eye, target, Z_AXIS)
      begin
        camera.perspective = perspective ? true : false
      rescue StandardError
        nil
      end
      begin
        if perspective
          camera.fov = 35.0
        else
          camera.height = ortho_height
        end
      rescue StandardError
        nil
      end
      camera
    end

    # Отодвигаем камеру достаточно далеко, чтобы ближняя плоскость отсечения
    # не срезала геометрию, но и не слишком далеко (точность координат).
    def camera_distance(bounds, ortho_height)
      diag = 1.0
      begin
        diag = bounds.diagonal.length
      rescue StandardError
        begin
          d = bounds.max - bounds.min
          diag = Math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
        rescue StandardError
          diag = 1000.0
        end
      end
      diag = 1000.0 if diag.nil? || diag.to_f <= 0.0 || diag.to_f.nan?
      [diag * 2.0, ortho_height.to_f * 2.0, diag * 0.75].max
    end
  end
end
