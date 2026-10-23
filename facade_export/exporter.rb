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
require 'tmpdir'

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
      @bounds = nil
      @scope = nil
      @glass_entries = nil
      @glass_only_entries = nil
    end

    def run
      @bounds = nil
      @scope = nil
      @glass_entries = nil
      @glass_only_entries = nil
      validate!
      started = Time.now
      state = SceneState.new(@model, @view)
      style = OptionBag.new(@model.rendering_options, 'Стиль')
      shadow = OptionBag.new(@model.shadow_info, 'Тени')
      previous_status = safe_status_text
      selection = snapshot_selection
      isolated = []

      begin
        begin_export_operation
        clear_selection
        isolated = isolate_context
        apply_base_style(style)

        parallel = @settings.parallel_projection?
        visible = @settings.exp('visible_area') ? true : false
        # Если пользователь смотрит в перспективе, сначала переводим сам вид
        # в параллельную проекцию, и только потом считаем кадры и снимаем
        # фасады. Иначе зум/высота кадра считались бы по перспективе и
        # картинки разъезжались бы между фасадами.
        switch_to_parallel_view if parallel
        directions, cameras, plan, scope = build_cameras(parallel, visible)

        @result.scope = scope
        @result.image_width = plan[:image_width]
        @result.image_height = plan[:image_height]

        jobs = Exporter.output_jobs(@settings)
        total = jobs.length * @facade_count
        @result.expected = total
        done = 0

        # Сначала карта, потом фасады: стиль карты и работа с материалами
        # выполняются один раз на карту, а не на каждый фасад. Для карты окон
        # это главная экономия — перекраска стекла больше не повторяется
        # четыре раза подряд (и карта без окон не тратит на это время вовсе).
        jobs.each do |job|
          glass = nil
          begin
            apply_map_style(job.map, directions[0], style, shadow, job)
            glass = apply_glass(job.map, job)
            @facade_count.times do |facade_index|
              number = @first_number + facade_index
              done += 1
              report_progress(done, total, number, job)
              @view.camera = cameras[facade_index]
              # Помечаем вид как «требуется перерисовка», чтобы write_image
              # считал кадр уже с новой камерой.
              invalidate_view
              apply_shadows(job.map, directions[facade_index], shadow)
              write_job(job, number)
            end
          rescue StandardError => e
            @result.errors << "#{job.title}: #{e.message}"
            FacadeExport.log("Карта \"#{job.title}\" не выполнена: #{e.message}\n" \
                             "#{e.backtrace.first(5).join("\n")}")
          ensure
            glass.restore if glass
          end
        end
      ensure
        restore_safely(state)
        restore_isolation(isolated)
        restore_selection(selection)
        set_status_text(previous_status)
        invalidate_view
        end_export_operation
        cleanup_temp_dir
      end

      @result.elapsed = Time.now - started
      @result
    end

    # --------------------------------------------------------------- private

    private

    # Переводит текущий вид в параллельную проекцию (если он перспективный),
    # сохраняя точку взгляда, цель и примерную композицию.
    # Исходная камера пользователя всё равно вернётся в ensure (SceneState).
    def switch_to_parallel_view
      camera = @view.camera
      return false unless camera
      return false unless Framing.perspective?(camera)
      @view.camera = Framing.parallel_camera(camera)
      invalidate_view
      true
    rescue StandardError => e
      FacadeExport.log("Не удалось переключить вид в параллельную проекцию: #{e.message}")
      false
    end

    # Вся временная работа с моделью идёт внутри одной служебной операции,
    # которая в конце ОТМЕНЯЕТСЯ (abort_operation). Пользователь не увидит
    # в журнале «Отменить» ни одного шага экспорта: после экспорта история
    # остаётся такой же, как до нажатия кнопки, и её не нужно тратить на
    # откат служебных изменений.
    def begin_export_operation
      @operation_open = false
      result = @model.start_operation('Экспорт фасадов', true)
      @operation_open = result.nil? || result == true
      @operation_open
    rescue StandardError => e
      @operation_open = false
      FacadeExport.log("Не удалось открыть служебную операцию экспорта: #{e.message}")
      false
    end

    def end_export_operation
      return false unless @operation_open
      @operation_open = false
      @model.abort_operation
      true
    rescue StandardError => e
      FacadeExport.log("Не удалось отменить служебную операцию экспорта: #{e.message}")
      false
    end

    # Строит направления, камеры и размер кадра.
    #   * обычный режим — кадр по габаритам объекта (Framing.plan);
    #   * «только видимый участок» — кадр как на экране (Framing.visible_cameras).
    def build_cameras(parallel, visible)
      if visible
        directions = Framing.facade_directions(@view.camera, @facade_count)
        plan, cameras = Framing.visible_cameras(
          @view.camera, @view, @settings.export, @facade_count, parallel
        )
        return [directions, cameras, plan, :visible]
      end

      # При экспорте одного фасада можно всё равно проанализировать все
      # четыре направления и взять масштаб по самому большому фасаду —
      # тогда одиночный кадр совпадает по масштабу с полным экспортом.
      analysis_count = @facade_count
      if @facade_count < 4 && @settings.exp('fit_all_facades')
        analysis_count = 4
      end

      directions = Framing.facade_directions(@view.camera, analysis_count)
      # Габариты считаются один раз за экспорт: обход геометрии — самая
      # дорогая часть, повторять её на каждый фасад нельзя.
      bounds, scope = export_bounds
      plan = Framing.plan(bounds, directions, @settings.export)
      cameras = directions.each_with_index.map do |direction, index|
        Framing.build_camera(
          bounds, direction, plan[:projections][index], plan[:scale],
          plan[:image_width], plan[:image_height], plan[:gap], parallel
        )
      end
      [directions.first(@facade_count), cameras.first(@facade_count), plan, scope]
    end

    # Габариты того, что экспортируем (кэшируются на весь экспорт).
    def export_bounds
      return [@bounds, @scope] unless @bounds.nil?
      set_status_text('Экспорт фасадов: анализ модели…')
      Framing.reset_cache!
      @bounds, @scope = Framing.content_bounds(@model)
      [@bounds, @scope]
    end

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
      # Только дешёвые проверки: обход геометрии выполняется в export_bounds,
      # уже после окна сохранения (см. build_cameras).
      Framing.facade_directions(@view.camera, 1)
      true
    end

    # Шаг 1 задания: общий стиль для всего экспорта.
    def apply_base_style(style)
      e = @settings.export
      white = Util.to_color(e['background'] || '#FFFFFF')
      options = {
        # Вид: служебная графика (направляющие, оси, тексты, размеры,
        # скрытые объекты) не рисуется в кадре никогда.
        'HideConstructionGeometry' => true,
        'ShowViewName' => false,
        'DisplayWatermarks' => e['hide_watermarks'] ? false : true,
        'DisplayFog' => false,
        'DrawHidden' => false,
        'DisplaySketchAxes' => false,
        'DisplayInstanceAxes' => false,
        'DisplayText' => false,
        'DisplayDims' => false,

        # Правка > Фон: «Скрывать небо» и «Скрывать землю» включены по умолчанию.
        'DrawSky'   => e['hide_sky'] ? false : true,
        'DrawGround' => e['hide_ground'] ? false : true,
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
        'DisplaySectionPlanes' => false
      }
      options['DisplayLineStyles'] = false if style.supported?('DisplayLineStyles')
      style.apply(options)
    end

    # Шаг 3 задания: стиль конкретной карты.
    # Стиль карты: один раз на карту (не зависит от фасада).
    def apply_map_style(map, _direction, style, _shadow, job)
      mode = Config::RENDER_MODES[map['render_mode']] || 2
      style.apply(
        'RenderMode' => mode,
        'Texture' => MapOptions.textures?(map) ? true : false,
        'EdgeDisplayMode' => map['edges'] ? Config::EDGE_MODES['all'] : Config::EDGE_MODES['none'],
        'MaterialTransparency' => transparency_for(map, job) ? true : false
      )
    end

    # Тени зависят от фасада: солнце ставится заново для каждого направления.
    def apply_shadows(map, direction, shadow)
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

    # Запись одного кадра: файл в папку пользователя, статистика в отчёт.
    def write_job(job, number)
      path = file_path(number, job)
      started = Time.now
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
    end

    def apply_glass(map, job)
      whiten = windows_map?(map) && opaque_textures?
      return nil unless whiten || glass_needed?(job)
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
        :opaque_min => Config::GLASS_OPAQUE_MIN,
        :entries => glass_entries,
        :whiten_opaque => whiten
      )
      recolored.apply
      recolored
    end

    # Карта окон: на ней остаются только окна, все непрозрачные текстуры
    # становятся белыми.
    def windows_map?(map)
      map['kind'].to_s == 'windows'
    end

    # Список материалов считается один раз на весь экспорт.
    def glass_entries
      @glass_entries ||= GlassRecolor.scan(
        @model,
        :railing_max => Config::GLASS_RAILING_MAX,
        :tinted_min => Config::GLASS_TINTED_MIN,
        :opaque_min => Config::GLASS_OPAQUE_MIN,
        :include_opaque => true
      )
    end

    # Есть ли на карте окон что отбеливать (непрозрачные материалы с текстурой).
    def opaque_textures?
      glass_entries.any? { |entry| entry.type.to_s == 'opaque' }
    end

    # Только стеклянные материалы (без непрозрачных заготовок для отбеливания).
    def glass_only_entries
      @glass_only_entries ||= glass_entries.select { |e| Config::GLASS_TITLES.key?(e.type.to_s) }
    end

    # Нужно ли вообще что-то делать с материалами для этой карты.
    # Если стекла в модели нет, карта окон не тратит время на поиск окон.
    def glass_needed?(job)
      return false if glass_only_entries.empty?
      mode = job.glass_mode.to_s
      return true if mode == 'combined' || mode == 'hide_railings'
      glass_only_entries.any? { |entry| entry.type.to_s == mode }
    end

    # Экспорт PNG: ширина/высота кадра считаются по содержимому,
    # а не по размеру окна просмотра, поэтому файлы одинаковы на любом ПК.
    #
    # Файл пишется не сразу в папку пользователя, а во временную папку,
    # и только потом копируется на место:
    #   * SketchUp больше не держит открытым файл в папке результата
    #     (именно из-за этого Windows писала «файл открыт в COM Surrogate»
    #     и не давала удалить/перенести готовый PNG);
    #   * Проводник не видит недописанный .png и не запускает для него
    #     предпросмотр (dllhost.exe), который блокирует файл на минуты.
    def write_image(path)
      options = image_options
      temp = temp_file_path(path)
      if temp
        remove_existing(temp)
        ok = do_write(options.merge(:filename => temp))
        if ok && File.exist?(temp) && file_size(temp).positive?
          return publish(temp, path)
        end
        FacadeExport.log("Временный файл не создан, пишу напрямую: #{File.basename(path)}")
      end
      remove_existing(path)
      ok = do_write(options.merge(:filename => path))
      unless ok && File.exist?(path)
        # Одна повторная попытка на случай, если файл ещё занят антивирусом.
        sleep 0.15
        remove_existing(path)
        ok = do_write(options.merge(:filename => path))
      end
      ok && File.exist?(path)
    end

    def image_options
      options = {
        :width       => @result.image_width,
        :height      => @result.image_height,
        :antialias   => @settings.exp('antialias') ? true : false,
        :transparent => @settings.exp('transparent') ? true : false
      }
      options[:scale_factor] = @settings.exp('line_scale').to_f
      options
    end

    # Копируем готовый PNG на место. Копию создаём сами и сразу закрываем
    # дескриптор — файл в папке пользователя свободен.
    def publish(temp, path)
      remove_existing(path)
      copy_file(temp, path)
      ok = File.exist?(path) && file_size(path).positive?
      cleanup_temp(temp)
      ok
    rescue StandardError => e
      FacadeExport.log("Не удалось записать #{File.basename(path)}: #{e.message}")
      begin
        copy_file(temp, path)
        cleanup_temp(temp)
        true
      rescue StandardError => inner
        FacadeExport.log("Повторная запись не удалась: #{inner.message}")
        false
      end
    end

    def copy_file(from, to)
      File.open(from, 'rb') do |src|
        File.open(to, 'wb') do |dst|
          IO.copy_stream(src, dst)
          begin
            dst.flush
            dst.fsync
          rescue StandardError
            nil
          end
        end
      end
    end

    # Путь временного файла (вне папки результата).
    def temp_file_path(path)
      dir = temp_dir
      return nil if dir.nil?
      @temp_index = (@temp_index || 0) + 1
      File.join(dir, format('%04d_%s', @temp_index, File.basename(path)))
    end

    def temp_dir
      return @temp_dir if defined?(@temp_dir)
      @temp_dir = begin
        Dir.mktmpdir('facade_export')
      rescue StandardError => e
        FacadeExport.log("Системная временная папка недоступна (#{e.message})")
        nil
      end
      return @temp_dir if @temp_dir
      # Запасной вариант — служебная папка рядом с результатом.
      fallback = File.join(@directory.to_s, '.facade_export_tmp')
      begin
        FileUtils.mkdir_p(fallback)
        @temp_dir = fallback
      rescue StandardError => e
        FacadeExport.log("Временная папка недоступна (#{e.message})")
        @temp_dir = nil
      end
      @temp_dir
    end

    def cleanup_temp(path)
      return if path.nil?
      3.times do
        begin
          File.delete(path) if File.exist?(path)
        rescue SystemCallError, IOError
          sleep 0.05
          next
        end
        return true
      end
      false
    end

    def cleanup_temp_dir
      dir = defined?(@temp_dir) ? @temp_dir : nil
      return if dir.nil?
      Dir.glob(File.join(dir, '*')).each { |path| cleanup_temp(path) }
      Dir.rmdir(dir) if File.directory?(dir)
    rescue StandardError => e
      FacadeExport.log("Временная папка не удалена: #{e.message}")
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
      return true unless File.exist?(path)
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

      # Всё скрытие идёт внутри служебной операции экспорта, которую в конце
      # отменяем (см. begin_export_operation), поэтому в истории «Отменить»
      # не остаётся ни одного шага экспорта.
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
