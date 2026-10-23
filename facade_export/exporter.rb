# encoding: utf-8
# Экспорт фасадов — основной движок экспорта.
# Автор: Артем Титов (motivate_rt)
#
# Принцип работы:
#   1. Один раз снимаем состояние сцены (стиль, тени, камера, выделение).
#   2. Определяем, что экспортируем: всю модель или открытую группу/компонент,
#      и временно скрываем всё окружение (если пользователь внутри группы).
#   3. Считаем кадр: соотношение 4:3, большая сторона 9999, самый большой
#      фасад задаёт масштаб; ориентация кадра подстраивается под высотные дома.
#   4. Для каждого фасада ставим камеру и для каждой карты меняем только те
#      параметры стиля, которые отличаются, и пишем PNG через View#write_image
#      (рендер идёт "за кадром", окно просмотра не перерисовывается).
#   5. Возвращаем стиль, тени, камеру, выделение и видимость объектов.

require 'fileutils'

module FacadeExport
  # Производные признаки карты, которые не хранятся в настройках напрямую.
  module MapOptions
    module_function

    # Текстуры есть только в режиме «Затенение» (отдельной галочки нет).
    def textures?(map)
      Config.textures_for(map['render_mode'])
    end

    # Красит ли карта стекло (карта «Окна» — всегда).
    def glass_highlight?(map)
      return true if map['kind'].to_s == 'windows'
      truthy?(map['glass_highlight'])
    end

    def split_windows?(map)
      glass_highlight?(map) && truthy?(map['split_windows'])
    end

    # Название отдельной карты стекла: у карты «Окна» — просто тип стекла,
    # у своей карты — «Своя карта N — окно-стекло».
    def glass_title(map, glass_title)
      return glass_title if map['kind'].to_s == 'windows'
      "#{map['title']} — #{glass_title}"
    end

    def truthy?(value)
      value == true || value == 'true' || value == 1 || value == '1'
    end
  end

  class Exporter
    Result = Struct.new(:files, :errors, :warnings, :elapsed, :started_at, :per_image,
                        :expected, :directory, :image_width, :image_height, :scope)

    # Одна задача экспорта: карта + режим обработки стекла + имя в файле.
    Job = Struct.new(:map, :glass_mode, :title)

    # Имя файла: Имя_Фасад_Номер_Карта.png
    def self.file_name(base_name, number, map_title)
      base = Util.sanitize_filename(base_name, 'Модель')
      title = Util.sanitize_filename(map_title, 'Карта')
      "#{base}_Фасад_#{number}_#{title}.png"
    end

    # Список задач экспорта.
    #   * карта, которая красит стекло, даёт одну карту «combined»
    #     (или три раздельные, если включено разделение по типам стекла);
    #   * остальные карты (Текстура, Линии, Тени и свои без стекла)
    #     скрывают стеклянные ограждения.
    def self.output_jobs(settings)
      jobs = []
      settings.enabled_maps.each do |map|
        if MapOptions.glass_highlight?(map)
          if MapOptions.split_windows?(map)
            Config::GLASS_TITLES.each do |mode, glass_title|
              jobs << Job.new(map, mode, MapOptions.glass_title(map, glass_title))
            end
          else
            jobs << Job.new(map, 'combined', map['title'])
          end
        else
          jobs << Job.new(map, 'hide_railings', map['title'])
        end
      end
      jobs
    end

    # Полный список файлов, которые появятся после экспорта.
    def self.planned_paths(settings, directory, base_name, facade_count)
      jobs = output_jobs(settings)
      paths = []
      (1..facade_count).each do |number|
        jobs.each do |job|
          paths << File.join(directory, file_name(base_name, number, job.title))
        end
      end
      paths
    end

    def initialize(options = {})
      @model        = options[:model] || Sketchup.active_model
      @view         = options[:view] || @model.active_view
      @settings     = options[:settings] || FacadeExport.settings
      @directory    = options[:directory]
      @base_name    = options[:base_name]
      @facade_count = (options[:facade_count] || 4).to_i
      @first_number = (options[:first_number] || 1).to_i
      @on_progress  = options[:on_progress]
      @result = Result.new([], [], [], 0.0, Time.now, [], 0, @directory, 0, 0, :model)
      @transparent_materials = nil
    end

    def run
      validate!
      started = Time.now
      state = SceneState.new(@model, @view)
      style = OptionBag.new(@model.rendering_options, 'Стиль')
      shadow = OptionBag.new(@model.shadow_info, 'Тени')
      previous_status = safe_status_text
      selection = snapshot_selection
      isolated = []

      begin
        clear_selection
        isolated = isolate_context
        apply_base_style(style)

        directions = Framing.facade_directions(@view.camera, @facade_count)
        bounds, scope = Framing.content_bounds(@model)
        plan = Framing.plan(bounds, directions, @settings.export)
        @result.scope = scope
        @result.image_width = plan[:image_width]
        @result.image_height = plan[:image_height]

        parallel = @settings.parallel_projection?
        cameras = directions.each_with_index.map do |direction, index|
          Framing.build_camera(
            bounds, direction, plan[:projections][index], plan[:scale],
            plan[:image_width], plan[:image_height], plan[:gap], parallel
          )
        end

        jobs = Exporter.output_jobs(@settings)
        total = jobs.length * @facade_count
        @result.expected = total
        done = 0

        @facade_count.times do |facade_index|
          number = @first_number + facade_index
          @view.camera = cameras[facade_index]
          # Помечаем вид как «требуется перерисовка», чтобы write_image
          # считал кадр уже с новой камерой.
          invalidate_view
          jobs.each do |job|
            done += 1
            report_progress(done, total, number, job)
            render_job(job, directions[facade_index], number, style, shadow)
          end
        end
      ensure
        restore_safely(state)
        restore_isolation(isolated)
        restore_selection(selection)
        set_status_text(previous_status)
        invalidate_view
      end

      @result.elapsed = Time.now - started
      @result
    end

    # --------------------------------------------------------------- private

    private

    def validate!
      raise ExportError, 'Нет активной модели SketchUp.' if @model.nil?
      raise ExportError, 'Нет активного вида.' if @view.nil?
      raise ExportError, 'Не выбрана папка для сохранения.' if @directory.nil? || @directory.to_s.empty?
      if Exporter.output_jobs(@settings).empty?
        raise ExportError, 'Все карты отключены в настройках плагина.'
      end
      begin
        FileUtils.mkdir_p(@directory)
      rescue StandardError => e
        raise ExportError, "Не удалось создать папку для сохранения: #{e.message}"
      end
      Framing.facade_directions(@view.camera, 1)
      bounds, _scope = Framing.content_bounds(@model)
      Framing.bbox_corners(bounds)
      true
    end

    # Шаг 1 задания: общий стиль для всего экспорта.
    def apply_base_style(style)
      e = @settings.export
      white = Util.to_color(e['background'] || '#FFFFFF')
      options = {
        # Вид
        'HideConstructionGeometry' => e['hide_guides'] ? true : false,
        'ShowViewName' => false,
        'DisplayWatermarks' => e['hide_watermarks'] ? false : true,
        'DisplayFog' => false,
        'DrawHidden' => false,

        # Правка > Фон
        'DrawSky'   => e['show_sky'] ? true : false,
        'DrawGround' => e['show_ground'] ? true : false,
        'DrawHorizon' => false,
        'BackgroundColor' => white,
        'SkyColor' => white,
        'GroundColor' => white,

        # Правка > Край
        'DrawProfilesOnly' => false,
        'DrawDepthQue' => false,
        'ExtendLines' => false,
        'DrawLineEnds' => false,
        'JitterEdges' => false,
        'DrawSilhouettes' => false,
        'EdgeType' => 0,

        # Правка > Грань: задние рёбра и рентген
        'DrawBackEdges' => false,
        'ModelTransparency' => false,

        # Активные сечения продолжают резать геометрию: в SketchUp выключение
        # "Section Cuts" делает модель снова целой, поэтому этот параметр всегда
        # включён. Плоскости сечений (их рамки) по умолчанию не рисуем.
        'DisplaySectionCuts'   => true,
        'DisplaySectionPlanes' => e['show_section_planes'] ? true : false
      }
      options['DisplayLineStyles'] = false if style.supported?('DisplayLineStyles')
      if e['hide_annotations']
        options['DisplaySketchAxes'] = false
        options['DisplayInstanceAxes'] = false
        options['DisplayText'] = false
        options['DisplayDims'] = false
      end
      style.apply(options)
    end

    # Шаг 3 задания: стиль конкретной карты.
    def apply_map_style(map, direction, style, shadow, job)
      mode = Config::RENDER_MODES[map['render_mode']] || 2
      style.apply(
        'RenderMode' => mode,
        'Texture' => MapOptions.textures?(map) ? true : false,
        'EdgeDisplayMode' => map['edges'] ? Config::EDGE_MODES['all'] : Config::EDGE_MODES['none'],
        'MaterialTransparency' => transparency_for(map, job) ? true : false
      )

      use_sun = @settings.exp('sun_for_shading') ? true : false
      if map['shadows']
        info = Sun.setup(
          shadow,
          direction,
          :azimuth => map['shadow_azimuth'],
          :elevation => map['shadow_elevation'],
          :light => map['shadow_light'],
          :dark => map['shadow_dark'],
          :use_sun_for_shading => use_sun
        )
        warn_about_sun(info)
      else
        Sun.disable(shadow, use_sun)
      end
    end

    # Прозрачность нужна, если карта её просит или если обработка стекла
    # делает материалы частично/полностью прозрачными.
    def transparency_for(map, job)
      return true if map['material_transparency']
      return true unless job.glass_mode == 'combined'
      transparent_materials?
    end

    def transparent_materials?
      return @transparent_materials unless @transparent_materials.nil?
      @transparent_materials = false
      begin
        @model.materials.each do |mat|
          alpha = begin
            mat.alpha.to_f
          rescue StandardError
            1.0
          end
          if alpha < 0.999
            @transparent_materials = true
            break
          end
        end
      rescue StandardError
        @transparent_materials = false
      end
      @transparent_materials
    end

    # Если SketchUp не позволил выставить солнце точно под нужным углом.
    def warn_about_sun(info)
      return if info.nil? || info[:azimuth].nil? || info[:elevation].nil?
      az_error = Util.deg_delta(info[:azimuth], info[:target_azimuth]).abs
      el_error = (info[:elevation] - info[:target_elevation]).abs
      return if az_error < 1.0 && el_error < 1.0
      message = format('Тени: солнце выставлено приблизительно (азимут %0.1f°, высота %0.1f°). ' \
                       'Возможно, модель имеет ограничения по геолокации.',
                       info[:azimuth], info[:elevation])
      return if @result.warnings.include?(message)
      @result.warnings << message
      FacadeExport.log(message)
    end

    def render_job(job, direction, number, style, shadow)
      map = job.map
      glass = nil
      path = file_path(number, job)
      started = Time.now
      begin
        apply_map_style(map, direction, style, shadow, job)
        glass = apply_glass(map, job)
        ok = write_image(path)
        if ok && File.exist?(path)
          @result.files << path
          @result.per_image << [path, Time.now - started, file_size(path)]
        else
          @result.errors << "Не удалось сохранить файл: #{File.basename(path)}"
        end
      rescue StandardError => e
        @result.errors << "#{job.title} (фасад #{number}): #{e.message}"
        FacadeExport.log("Ошибка экспорта #{File.basename(path)}: #{e.message}\n" \
                         "#{e.backtrace.first(5).join("\n")}")
      ensure
        glass.restore if glass
      end
    end

    def apply_glass(map, job)
      return nil unless transparent_materials? || job.glass_mode != 'hide_railings'
      colors = {
        'main'    => Util.hsl_to_rgb(map['main_h'], map['main_s'], map['main_l']),
        'tinted'  => Util.hsl_to_rgb(map['tinted_h'], map['tinted_s'], map['tinted_l']),
        'railing' => Util.hsl_to_rgb(map['railing_h'], map['railing_s'], map['railing_l'])
      }
      recolored = GlassRecolor.new(
        @model, colors,
        :mode => job.glass_mode,
        :railing_max => Config::GLASS_RAILING_MAX,
        :tinted_min => Config::GLASS_TINTED_MIN,
        :opaque_min => Config::GLASS_OPAQUE_MIN
      )
      recolored.apply
      recolored
    end

    # Экспорт PNG: ширина/высота кадра считаются по содержимому,
    # а не по размеру окна просмотра, поэтому файлы одинаковы на любом ПК.
    def write_image(path)
      options = {
        :filename    => path,
        :width       => @result.image_width,
        :height      => @result.image_height,
        :antialias   => @settings.exp('antialias') ? true : false,
        :transparent => @settings.exp('transparent') ? true : false
      }
      options[:scale_factor] = @settings.exp('line_scale').to_f

      remove_existing(path)
      ok = do_write(options)
      unless ok && File.exist?(path)
        # Файл мог остаться занятым (COM Surrogate/антивирус) — одна повторная
        # попытка после короткой паузы.
        sleep 0.15
        remove_existing(path)
        ok = do_write(options)
      end
      # Ждём, пока SketchUp/Windows полностью отпустят файл,
      # иначе следующий файл (и Проводник) может получить "COM Surrogate".
      wait_until_released(path) if ok
      ok
    end

    def do_write(options)
      @view.write_image(options)
    rescue ArgumentError, TypeError
      # Старые версии SketchUp не знают :scale_factor
      options.delete(:scale_factor)
      begin
        @view.write_image(options)
      rescue StandardError => e
        FacadeExport.log("write_image: #{e.message}")
        false
      end
    rescue StandardError => e
      FacadeExport.log("write_image: #{e.message}")
      false
    end

    def remove_existing(path)
      return unless File.exist?(path)
      5.times do
        begin
          File.delete(path)
          return true
        rescue SystemCallError, IOError
          sleep 0.05
        end
      end
      false
    end

    # Ждём, пока Windows/SketchUp полностью отпустят файл: иначе следующий
    # кадр (или Проводник с COM Surrogate) может получить "файл занят".
    def wait_until_released(path, timeout = 2.0)
      deadline = Time.now + timeout
      loop do
        begin
          size = File.size(path)
          return true if size.positive? && readable_and_unlocked?(path)
        rescue SystemCallError, IOError
          nil
        end
        return false if Time.now > deadline
        sleep 0.02
      end
    end

    # Пробуем открыть файл на запись: на Windows это сразу покажет,
    # что дескриптор ещё держит другой процесс.
    def readable_and_unlocked?(path)
      File.open(path, 'r+b') { |io| io.read(0) }
      true
    rescue SystemCallError, IOError
      false
    end

    def file_size(path)
      File.size(path)
    rescue StandardError
      0
    end

    def file_path(number, job)
      File.join(@directory, Exporter.file_name(@base_name, number, job.title))
    end

    def report_progress(done, total, number, job)
      message = "Экспорт фасадов: #{done}/#{total} — фасад #{number}, карта \"#{job.title}\""
      set_status_text(message)
      FacadeExport.log(message)
      @on_progress.call(done, total, message) if @on_progress.respond_to?(:call)
    end

    def invalidate_view
      @view.invalidate
    rescue StandardError
      nil
    end

    def set_status_text(text)
      Sketchup.status_text = text
    rescue StandardError
      nil
    end

    def safe_status_text
      Sketchup.status_text
    rescue StandardError
      ''
    end

    # ------------------------------------------------------- выделение и группы

    def snapshot_selection
      @model.selection.to_a
    rescue StandardError
      []
    end

    def clear_selection
      @model.selection.clear
    rescue StandardError
      nil
    end

    def restore_selection(entities)
      return if entities.nil? || entities.empty?
      alive = entities.reject { |e| e.respond_to?(:valid?) && !e.valid? }
      @model.selection.add(alive) unless alive.empty?
    rescue StandardError => e
      FacadeExport.log("Не удалось вернуть выделение: #{e.message}")
    end

    # Если пользователь вошёл в группу/компонент — временно прячем всё
    # окружение, чтобы в кадр попало только содержимое этой группы.
    def isolate_context
      path = begin
        @model.active_path
      rescue StandardError
        nil
      end
      return [] if path.nil? || path.empty?

      # Скрытие не оборачиваем в операцию: так в истории «Отменить» не
      # появляется лишний шаг, а видимость всё равно возвращается в ensure.
      saved = []
      path.each_with_index do |instance, index|
        collection = if index.zero?
                       @model.entities
                     else
                       path[index - 1].definition.entities
                     end
        collection.each do |entity|
          next if entity == instance
          next if entity.respond_to?(:hidden?) && entity.hidden?
          begin
            entity.hidden = true
            saved << entity
          rescue StandardError
            nil
          end
        end
      end
      saved
    end

    def restore_isolation(entities)
      return if entities.nil? || entities.empty?
      entities.each do |entity|
        begin
          next if entity.respond_to?(:valid?) && !entity.valid?
          entity.hidden = false
        rescue StandardError
          nil
        end
      end
    end

    def restore_safely(state)
      state.restore!(@settings.exp('restore_view'))
    rescue StandardError => e
      FacadeExport.log("Не удалось полностью восстановить вид: #{e.message}")
    end
  end
end
