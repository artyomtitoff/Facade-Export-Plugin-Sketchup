# encoding: utf-8
# Экспорт фасадов — основной движок экспорта.
# Автор: Артем Титов (motivate_rt)
#
# Принцип работы:
#   1. Один раз снимаем состояние сцены (стиль, тени, камера).
#   2. Переводим вид в параллельную проекцию и считаем единый масштаб,
#      при котором в кадр целиком влезают все четыре фасада.
#   3. Для каждого фасада: ставим камеру, затем для каждой карты меняем
#      только те параметры стиля, которые отличаются от предыдущей карты,
#      и пишем PNG через View#write_image (рендер идёт "за кадром",
#      окно просмотра не перерисовывается и не меняет размер).
#   4. Возвращаем стиль, тени и камеру пользователя как было.

require 'fileutils'

module FacadeExport
  class Exporter
    Result = Struct.new(:files, :errors, :warnings, :elapsed, :started_at, :per_image,
                        :expected, :directory)

    # Имя файла: Имя_Фасад_Номер_Карта.png
    def self.file_name(base_name, number, map_title)
      base = Util.sanitize_filename(base_name, 'Модель')
      title = Util.sanitize_filename(map_title, 'Карта')
      "#{base}_Фасад_#{number}_#{title}.png"
    end

    # Полный список файлов, которые появятся после экспорта.
    def self.planned_paths(settings, directory, base_name, facade_count)
      maps = settings.enabled_maps
      paths = []
      (1..facade_count).each do |number|
        maps.each do |map|
          paths << File.join(directory, file_name(base_name, number, map['title']))
        end
      end
      paths
    end

    def initialize(options = {})
      @model      = options[:model] || Sketchup.active_model
      @view       = options[:view] || @model.active_view
      @settings   = options[:settings] || FacadeExport.settings
      @directory  = options[:directory]
      @base_name  = options[:base_name]
      @facade_count = (options[:facade_count] || 4).to_i
      @first_number = (options[:first_number] || 1).to_i
      @on_progress = options[:on_progress]
      @result = Result.new([], [], [], 0.0, Time.now, [], 0, @directory)
    end

    def run
      validate!
      started = Time.now
      state = SceneState.new(@model, @view)
      style = OptionBag.new(@model.rendering_options, 'Стиль')
      shadow = OptionBag.new(@model.shadow_info, 'Тени')
      previous_status = safe_status_text
      selection = snapshot_selection

      begin
        clear_selection
        apply_base_style(style)
        directories = Framing.facade_directions(@view.camera, @facade_count)
        build_image_size
        aspect = @image_width.to_f / @image_height.to_f
        bounds = @model.bounds
        plan = Framing.plan_fit(bounds, directories, aspect, @settings.exp('margin'))

        cameras = directories.each_with_index.map do |direction, index|
          Framing.build_camera(
            bounds,
            direction,
            plan[:projections][index],
            plan[:height],
            @settings.exp('perspective')
          )
        end

        maps = @settings.enabled_maps
        total = maps.length * @facade_count
        @result.expected = total
        done = 0

        @facade_count.times do |facade_index|
          number = @first_number + facade_index
          @view.camera = cameras[facade_index]
          # Помечаем вид как «требуется перерисовка», чтобы кадр для
          # write_image считался уже с новой камерой. Сама перерисовка
          # произойдёт только когда SketchUp вернёт управление интерфейсу.
          begin
            @view.invalidate
          rescue StandardError
            nil
          end
          maps.each do |map|
            done += 1
            report_progress(done, total, number, map)
            render_map(map, directories[facade_index], number, style, shadow)
          end
        end
      ensure
        restore_safely(state)
        restore_selection(selection)
        set_status_text(previous_status)
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
      if @settings.enabled_maps.empty?
        raise ExportError, 'Все карты отключены в настройках плагина.'
      end
      begin
        FileUtils.mkdir_p(@directory)
      rescue StandardError => e
        raise ExportError, "Не удалось создать папку для сохранения: #{e.message}"
      end
      corners = Framing.bbox_corners(@model.bounds)
      raise ExportError, 'Габариты модели пусты.' if corners.empty?
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
        # Скрытая геометрия не должна попадать в кадр
        'DrawHidden' => false,

        # Правка > Фон
        'DrawSky'   => e['show_sky'] ? true : false,
        'DrawGround' => e['show_ground'] ? true : false,
        'DrawHorizon' => false,
        'BackgroundColor' => white,
        'SkyColor' => white,
        'GroundColor' => white,

        # Правка > Край: профили, показ глубин, расширение, конечные точки,
        # дрожание, пунктир, силуэты
        'DrawProfilesOnly' => false,
        'DrawDepthQue' => false,
        'ExtendLines' => false,
        'DrawLineEnds' => false,
        'JitterEdges' => false,
        'DrawSilhouettes' => false,
        'EdgeType' => 0,

        # Правка > Грань: задние рёбра и рентген
        'DrawBackEdges' => false,
        'ModelTransparency' => false
      }
      options['DisplayLineStyles'] = false if style.supported?('DisplayLineStyles')
      if e['hide_annotations']
        # Оси, размеры, тексты, оси компонентов — лишние линии на картах
        options['DisplaySketchAxes'] = false
        options['DisplayInstanceAxes'] = false
        options['DisplayText'] = false
        options['DisplayDims'] = false
      end
      if e['disable_section_cuts']
        options['DisplaySectionCuts'] = false
        options['DisplaySectionPlanes'] = false
      end
      style.apply(options)
    end

    # Шаг 3 задания: стиль конкретной карты.
    def apply_map_style(map, direction, style, shadow)
      mode = Config::RENDER_MODES[map['render_mode']] || 2
      style.apply(
        'RenderMode' => mode,
        'Texture' => map['textures'] ? true : false,
        'EdgeDisplayMode' => map['edges'] ? Config::EDGE_MODES['all'] : Config::EDGE_MODES['none'],
        'MaterialTransparency' => map['material_transparency'] ? true : false
      )

      if map['shadows']
        info = Sun.setup(
          shadow,
          direction,
          :azimuth => map['shadow_azimuth'],
          :elevation => map['shadow_elevation'],
          :light => map['shadow_light'],
          :dark => map['shadow_dark'],
          :use_sun_for_shading => map['sun_for_shading']
        )
        warn_about_sun(info)
      else
        Sun.disable(shadow, map['sun_for_shading'])
      end
    end

    # Если SketchUp не позволил выставить солнце точно под нужным углом —
    # сообщаем об этом один раз, чтобы это не стало сюрпризом на картинке.
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

    def render_map(map, direction, number, style, shadow)
      glass = nil
      path = file_path(number, map)
      started = Time.now
      begin
        apply_map_style(map, direction, style, shadow)

        if map['highlight_transparent']
          rgb = Util.hsl_to_rgb(map['glass_h'], map['glass_s'], map['glass_l'])
          glass = GlassRecolor.new(@model, rgb)
          glass.apply
        end

        ok = write_image(path)
        if ok && File.exist?(path)
          @result.files << path
          @result.per_image << [path, Time.now - started, File.size(path)]
        else
          @result.errors << "Не удалось сохранить файл: #{File.basename(path)}"
        end
      rescue StandardError => e
        @result.errors << "#{map['title']} (фасад #{number}): #{e.message}"
        FacadeExport.log("Ошибка экспорта #{File.basename(path)}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
      ensure
        glass.restore if glass
      end
    end

    # Экспорт PNG с параметрами по умолчанию:
    # PNG, ширина 9999, высота автоматически, множитель линий 0.3x,
    # без сглаживания, прозрачный фон.
    def write_image(path)
      options = {
        :filename    => path,
        :width       => @image_width,
        :height      => @image_height,
        :antialias   => @settings.exp('antialias') ? true : false,
        :transparent => @settings.exp('transparent') ? true : false
      }
      options[:scale_factor] = @settings.exp('line_scale').to_f

      # Удаляем старый файл заранее: иначе SketchUp может показать
      # диалог подтверждения перезаписи и остановить пакетный экспорт.
      begin
        File.delete(path) if File.exist?(path)
      rescue StandardError
        nil
      end

      begin
        @view.write_image(options)
      rescue ArgumentError, TypeError
        # SketchUp 2019.1 и старше не знают :scale_factor
        options.delete(:scale_factor)
        @view.write_image(options)
      end
    end

    def build_image_size
      e = @settings.export
      vw = begin
        @view.vpwidth.to_f
      rescue StandardError
        16.0
      end
      vh = begin
        @view.vpheight.to_f
      rescue StandardError
        9.0
      end
      vw = 16.0 if vw <= 0.0
      vh = 9.0 if vh <= 0.0

      if e['use_view_size']
        width = vw.round
        height = vh.round
      else
        width = e['width'].to_i
        height = e['height'].to_i
        if height <= 0
          # "Высота выставляется автоматически" — по пропорциям окна просмотра,
          # чтобы рассчитанная компоновка кадра точно совпала с картинкой.
          height = (width * vh / vw).round
        end
      end

      width = [[width, Config::MIN_IMAGE_SIDE].max, Config::MAX_IMAGE_SIDE].min
      height = [[height, Config::MIN_IMAGE_SIDE].max, Config::MAX_IMAGE_SIDE].min
      @image_width = width
      @image_height = height
    end

    def file_path(number, map)
      File.join(@directory, Exporter.file_name(@base_name, number, map['title']))
    end

    def report_progress(done, total, number, map)
      message = "Экспорт фасадов: #{done}/#{total} — фасад #{number}, карта \"#{map['title']}\""
      set_status_text(message)
      FacadeExport.log(message)
      @on_progress.call(done, total, message) if @on_progress.respond_to?(:call)
    end

    def set_status_text(text)
      begin
        Sketchup.status_text = text
      rescue StandardError
        nil
      end
    end

    def safe_status_text
      begin
        Sketchup.status_text
      rescue StandardError
        ''
      end
    end

    # Подсветка выделения попадает в write_image, поэтому на время экспорта
    # выделение снимается, а после — возвращается.
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
      @model.selection.add(entities.reject { |e| e.respond_to?(:valid?) && !e.valid? })
    rescue StandardError => e
      FacadeExport.log("Не удалось вернуть выделение: #{e.message}")
    end

    def restore_safely(state)
      begin
        state.restore!(@settings.exp('restore_view'))
      rescue StandardError => e
        FacadeExport.log("Не удалось полностью восстановить вид: #{e.message}")
      end
    end
  end
end
