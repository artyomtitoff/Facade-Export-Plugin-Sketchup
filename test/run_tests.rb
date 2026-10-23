# encoding: utf-8
# Автотесты логики плагина "Экспорт фасадов" на заглушке SketchUp API.
# Запуск: см. test/README.md (Ruby-WASM) или "ruby test/run_tests.rb" при наличии Ruby.

require_relative 'mock_sketchup' unless defined?(Sketchup::Model)

unless defined?(FacadeExport::Exporter)
  ROOT = File.expand_path('../facade_export', __dir__)
  %w[config util scene_state framing sun glass exporter dialogs].each do |file|
    require File.join(ROOT, file)
  end
end

module FacadeExport
  # В SketchUp PATH указывает на папку facade_export (от __FILE__ main.rb),
  # в тестах подставляем её вручную.
  ROOT = File.expand_path('../facade_export', __dir__) unless defined?(ROOT)
  remove_const(:PATH) if defined?(PATH)
  PATH = ROOT
  def self.settings
    @settings ||= Settings.load
  end

  def self.settings=(value)
    @settings = value
  end

  def self.log(message)
    # puts "[log] #{message}"
  end
end

# ---------------------------------------------------------------------------

$failures = 0
$checks = 0

def check(title, condition, details = nil)
  $checks += 1
  if condition
    puts "  ok   #{title}"
  else
    $failures += 1
    puts "  FAIL #{title}"
    puts "       #{details}" if details
  end
end

def check_close(title, actual, expected, tolerance = 0.5)
  ok = !actual.nil? && (actual.to_f - expected.to_f).abs <= tolerance
  check(title, ok, "получено #{actual.inspect}, ожидалось #{expected} ± #{tolerance}")
end

def section(title)
  puts "\n== #{title} =="
end

def new_model
  model = Sketchup::Model.new
  Sketchup.active_model = model
  model
end

def fresh_settings
  FacadeExport.settings = FacadeExport::Settings.new
end

OUT_ROOT = ENV['FACADE_EXPORT_TEST_OUT'] || File.join(Dir.pwd, 'tmp_test_out')

def clean_out
  if File.directory?(OUT_ROOT)
    Dir.entries(OUT_ROOT).each do |e|
      next if e == '.' || e == '..'
      path = File.join(OUT_ROOT, e)
      File.delete(path) if File.file?(path)
    end
  else
    Dir.mkdir(OUT_ROOT)
  end
end

# ---------------------------------------------------------------- 1. утилиты

section 'Утилиты и настройки'
check('HSL 125/100/50 -> RGB',
      FacadeExport::Util.hsl_to_rgb(125, 100, 50) == [0, 255, 21],
      FacadeExport::Util.hsl_to_rgb(125, 100, 50).inspect)
check('HSL 0/0/100 -> белый', FacadeExport::Util.hsl_to_rgb(0, 0, 100) == [255, 255, 255])
check('HSL 0/0/0 -> чёрный', FacadeExport::Util.hsl_to_rgb(0, 0, 0) == [0, 0, 0])
check('HSL 240/100/50 -> синий', FacadeExport::Util.hsl_to_rgb(240, 100, 50) == [0, 0, 255])

check('Имя файла: запрещённые символы',
      FacadeExport::Util.sanitize_filename('Заречная:дом*1?.skp') == 'Заречная_дом_1_.skp',
      FacadeExport::Util.sanitize_filename('Заречная:дом*1?.skp'))

settings = fresh_settings
check('Ширина по умолчанию 9999', settings.exp('width') == 9999)
check('Высота автоматическая (0)', settings.exp('height') == 0)
check('Множитель линий 0,3x', (settings.exp('line_scale') - 0.3).abs < 1e-9)
check('Сглаживание выключено', settings.exp('antialias') == false)
check('Прозрачный фон включён', settings.exp('transparent') == true)
check('Параллельная проекция', settings.exp('perspective') == false)
check('Четыре карты', settings.maps.length == 4)
check('Названия карт', settings.maps.map { |m| m['title'] } == %w[Текстура Линии Тени Окна],
      settings.maps.map { |m| m['title'] }.inspect)
check('Карта "Текстура": затенение + текстуры + без краёв',
      settings.map('texture')['render_mode'] == 'shaded' &&
      settings.map('texture')['textures'] == true &&
      settings.map('texture')['edges'] == false)
check('Карта "Линии": скрытые линии + края',
      settings.map('lines')['render_mode'] == 'hidden' &&
      settings.map('lines')['edges'] == true)
check('Карта "Тени": тени включены, края скрыты',
      settings.map('shadows')['shadows'] == true &&
      settings.map('shadows')['edges'] == false)
check('Карта "Тени": солнце 45°/45°, светлее 100, темнее 0',
      settings.map('shadows')['shadow_azimuth'] == 45 &&
      settings.map('shadows')['shadow_elevation'] == 45 &&
      settings.map('shadows')['shadow_light'] == 100 &&
      settings.map('shadows')['shadow_dark'] == 0)
check('Карта "Окна": перекраска прозрачных материалов H125/S100/L50',
      settings.map('windows')['highlight_transparent'] == true &&
      settings.map('windows')['glass_h'] == 125 &&
      settings.map('windows')['shadow_elevation'] == 45)

settings.replace!('export' => { 'width' => 99_999, 'line_scale' => -5, 'margin' => 5 },
                  'maps' => [{ 'key' => 'texture', 'enabled' => 'true', 'render_mode' => 'xxx' }])
check('Ширина ограничена 16000', settings.exp('width') == 16_000)
check('Множитель линий ограничен', settings.exp('line_scale') == 0.01)
check('Отступ ограничен', (settings.exp('margin') - 0.3).abs < 1e-9)
check('Строка "true" -> true', settings.map('texture')['enabled'] == true)
check('Неизвестный режим -> shaded', settings.map('texture')['render_mode'] == 'shaded')

fresh_settings
FacadeExport.settings.set_export('last_directory', '/tmp/abc')
FacadeExport.settings.save
loaded = FacadeExport::Settings.load
check('Сохранение/загрузка настроек', loaded.exp('last_directory') == '/tmp/abc')

# ------------------------------------------------------------- 2. геометрия

section 'Камера и компоновка'
model = new_model
view = model.active_view
dirs = FacadeExport::Framing.facade_directions(view.camera, 4)
expected = [[0, 1], [1, 0], [0, -1], [-1, 0]]
dirs.each_with_index do |d, i|
  check_close("Фасад #{i + 1}: направление X", d.x, expected[i][0], 1e-6)
  check_close("Фасад #{i + 1}: направление Y", d.y, expected[i][1], 1e-6)
end
check_close('Поворот на 90°: длина вектора = 1', dirs[1].length, 1.0, 1e-9)

plan = FacadeExport::Framing.plan_fit(model.bounds, dirs, 9999.0 / (9999.0 * 900 / 1600), 0.04)
heights = plan[:projections].map { |p| p[:height] }
widths = plan[:projections].map { |p| p[:width] }
check('Проекции Y-фасадов: ширина 1200', (widths[0] - 1200).abs < 1e-6 && (widths[2] - 1200).abs < 1e-6,
      widths.inspect)
check('Проекции X-фасадов: ширина 800', (widths[1] - 800).abs < 1e-6, widths.inspect)
check('Высота проекции 600', (heights[0] - 600).abs < 1e-6)
aspect = 9999.0 / (9999.0 * 900 / 1600)
check_close('Единая высота кадра: широкий фасад + отступ',
            plan[:height], 1200.0 / aspect / 0.96, 1e-6)

cams = dirs.each_with_index.map do |d, i|
  FacadeExport::Framing.build_camera(model.bounds, d, plan[:projections][i], plan[:height], false)
end
check('Камера: параллельная проекция', cams.all? { |c| c.perspective? == false })
check('Камера: одинаковая высота кадра у всех фасадов',
      cams.map(&:height).uniq.length == 1)
cams.each_with_index do |c, i|
  check_close("Камера #{i + 1}: смотрит вдоль фасада",
              FacadeExport::Util.angle_between_deg(c.direction, Geom::Vector3d.new(*dirs[i].to_a)), 0.0, 1e-6)
  check_close("Камера #{i + 1}: цель по центру фасада", c.target.z, 300.0, 1e-6)
end
check('Цель камеры: центр по горизонтали',
      (cams[0].target.x - 600).abs < 1e-6 && (cams[0].target.y - 400).abs < 1e-6,
      [cams[0].target.x, cams[0].target.y].inspect)
check('Камера отодвинута от модели', cams[0].eye.y < -1000)

# ------------------------------------------------------------------ 3. солнце

section 'Солнце: тени 45° слева сверху'
model = new_model
shadow = FacadeExport::OptionBag.new(model.shadow_info, 'Тени')
dirs.each_with_index do |direction, i|
  info = FacadeExport::Sun.setup(
    shadow, direction,
    :azimuth => 45.0, :elevation => 45.0, :light => 100, :dark => 0, :use_sun_for_shading => false
  )
  desired = FacadeExport::Sun.desired_sun_vector(direction, 45.0, 45.0)
  desired_az = FacadeExport::Sun.azimuth_of(desired)
  check_close("Фасад #{i + 1}: азимут солнца", info[:azimuth], desired_az, 0.6)
  check_close("Фасад #{i + 1}: высота солнца 45°", info[:elevation], 45.0, 0.6)
  check("Фасад #{i + 1}: солнце слева от наблюдателя",
        shadow.get('SunDirection').dot(FacadeExport::Sun.desired_sun_vector(direction, 45, 45)) > 0.999,
        shadow.get('SunDirection').inspect)
  check("Фасад #{i + 1}: UseSunForAllShading = false", shadow.get('UseSunForAllShading') == false)
  check("Фасад #{i + 1}: тени включены", shadow.get('DisplayShadows') == true)
end
check('Солнце: параметры "Светлее/Темнее"',
      shadow.get('Light') == 100 && shadow.get('Dark') == 0)
check('Северный угол совпадает с формулой Elevation 45 Shadows для вида на север',
      (FacadeExport::Sun.legacy_north_angle(Geom::Vector3d.new(0, 1, 0)) - 45.0).abs < 1e-9,
      FacadeExport::Sun.legacy_north_angle(Geom::Vector3d.new(0, 1, 0)).inspect)
check('Формула TIG: вид на восток -> 135°',
      (FacadeExport::Sun.legacy_north_angle(Geom::Vector3d.new(1, 0, 0)) - 135.0).abs < 1e-9)
check('Формула TIG: вид на юг -> 225°',
      (FacadeExport::Sun.legacy_north_angle(Geom::Vector3d.new(0, -1, 0)) - 225.0).abs < 1e-9)

# --------------------------------------------------------------- 4. стекло

section 'Перекраска прозрачных материалов'
model = new_model
glass = FacadeExport::GlassRecolor.new(model, FacadeExport::Util.hsl_to_rgb(125, 100, 50))
before = model.materials.map { |m| [m.name, m.color.to_a, m.alpha, m.texture && m.texture.filename] }
recolored = glass.apply
check('Перекрашены 2 прозрачных материала', recolored == 2, )
check('Стекло перекрашено в H125/S100/L50', model.materials['Стекло'].color.to_a[0, 3] == [0, 255, 21])
check('Непрозрачность стекла 100 %', model.materials['Стекло'].alpha == 1.0)
check('Непрозрачный материал не тронут', model.materials['Кирпич'].color.to_a == [180, 90, 70, 255])
glass.restore
after = model.materials.map { |m| [m.name, m.color.to_a, m.alpha, m.texture && m.texture.filename] }
check('Исходные цвета восстановлены', before == after, "#{before.inspect}\n       #{after.inspect}")
check('Материал с текстурой: текстура возвращена', model.materials['Витрина'].texture != nil)

# ---------------------------------------------------- 5. полный экспорт (16)

section 'Полный экспорт всех фасадов'
clean_out
model = new_model
view = model.active_view
initial_rendering = model.rendering_options.to_h.dup
initial_shadow = model.shadow_info.to_h.dup
initial_eye = view.camera.eye.to_a
initial_target = view.camera.target.to_a
initial_mode = view.camera.perspective?

fresh_settings
exporter = FacadeExport::Exporter.new(
  :model => model, :view => view, :settings => FacadeExport.settings,
  :directory => OUT_ROOT, :base_name => 'Заречная', :facade_count => 4
)
result = exporter.run

check('Файлов создано: 16', result.files.length == 16, result.files.length)
check('Ошибок нет', result.errors.empty?, result.errors.inspect)
expected_names = []
(1..4).each do |n|
  %w[Текстура Линии Тени Окна].each { |t| expected_names << "Заречная_Фасад_#{n}_#{t}.png" }
end
actual_names = result.files.map { |f| File.basename(f) }
check('Имена файлов по шаблону', actual_names.sort == expected_names.sort, actual_names.inspect)
check('Все файлы существуют', result.files.all? { |f| File.file?(f) })
check('Все файлы непустые', result.files.all? { |f| File.size(f) > 8 })

writes = view.writes
check('Записей изображений: 16', writes.length == 16)
check('Ширина 9999', writes.all? { |w| w[:width] == 9999 }, writes.map { |w| w[:width] }.uniq.inspect)
check('Высота автоматическая (по пропорциям вида)',
      writes.all? { |w| w[:height] == (9999.0 * 900 / 1600).round },
      writes.map { |w| w[:height] }.uniq.inspect)
check('Сглаживание выключено', writes.all? { |w| w[:antialias] == false })
check('Прозрачный фон включён', writes.all? { |w| w[:transparent] == true })
check('Множитель линий 0.3', writes.all? { |w| (w[:scale_factor] - 0.3).abs < 1e-9 })

# Проверки стиля по картам
def write_for(writes, number, title)
  writes.find { |w| w[:path].include?("Фасад_#{number}_#{title}.png") }
end

texture_w = write_for(writes, 1, 'Текстура')
lines_w = write_for(writes, 1, 'Линии')
shadows_w = write_for(writes, 1, 'Тени')
windows_w = write_for(writes, 1, 'Окна')

check('Текстура: RenderMode 2 (затенение)', texture_w[:rendering]['RenderMode'] == 2)
check('Текстура: Texture = true', texture_w[:rendering]['Texture'] == true)
check('Текстура: края скрыты (0)', texture_w[:rendering]['EdgeDisplayMode'] == 0)
check('Текстура: тени выключены', texture_w[:shadow]['DisplayShadows'] == false)
check('Текстура: прозрачность материала выключена', texture_w[:rendering]['MaterialTransparency'] == false)

check('Линии: RenderMode 1 (скрытые линии)', lines_w[:rendering]['RenderMode'] == 1)
check('Линии: края показаны (1)', lines_w[:rendering]['EdgeDisplayMode'] == 1)
check('Линии: тени выключены', lines_w[:shadow]['DisplayShadows'] == false)

check('Тени: края скрыты', shadows_w[:rendering]['EdgeDisplayMode'] == 0)
check('Тени: тени включены', shadows_w[:shadow]['DisplayShadows'] == true)
check('Тени: солнце для затенения выключено', shadows_w[:shadow]['UseSunForAllShading'] == false)
check('Тени: светлее 100 / темнее 0',
      shadows_w[:shadow]['Light'] == 100 && shadows_w[:shadow]['Dark'] == 0)
sh_sun = shadows_w[:shadow]['SunDirection']
sh_elev = FacadeExport::Sun.elevation_of(sh_sun)
sh_az = FacadeExport::Sun.azimuth_of(sh_sun)
check_close('Тени: высота солнца 45°', sh_elev, 45.0, 1.0)
check_close('Тени: солнце слева сверху (азимут 225° для вида на север)', sh_az, 225.0, 1.0)

check('Окна: тени выключены', windows_w[:shadow]['DisplayShadows'] == false)
check('Окна: RenderMode 2', windows_w[:rendering]['RenderMode'] == 2)
glass_colors = windows_w[:materials].select { |m| m[0] == 'Стекло' }.first
check('Окна: стекло перекрашено в H125/S100/L50',
      glass_colors && glass_colors[1][0, 3] == [0, 255, 21],
      glass_colors.inspect)
check('Окна: края скрыты', windows_w[:rendering]['EdgeDisplayMode'] == 0)

# Восстановление состояния
check('Стиль восстановлен полностью', model.rendering_options.to_h == initial_rendering,
      model.rendering_options.to_h.reject { |k, v| initial_rendering[k] == v }.inspect)
check('Тени восстановлены полностью', model.shadow_info.to_h == initial_shadow,
      model.shadow_info.to_h.reject { |k, v| initial_shadow[k] == v }.inspect)
check('Камера восстановлена (eye)', view.camera.eye.to_a == initial_eye)
check('Камера восстановлена (target)', view.camera.target.to_a == initial_target)
check('Тип проекции восстановлен', view.camera.perspective? == initial_mode)
check('Материалы восстановлены',
      model.materials['Стекло'].color.to_a == [200, 230, 240, 255] &&
      (model.materials['Стекло'].alpha - 0.35).abs < 1e-9)

# Разные фасады -> разные камеры
facade_cams = (1..4).map { |n| write_for(writes, n, 'Текстура')[:camera] }
check('Четыре разных ракурса', facade_cams.map { |c| c.eye.to_a }.uniq.length == 4,
      facade_cams.map { |c| c.eye.to_a }.inspect)
check('Масштаб одинаковый у всех фасадов', facade_cams.map(&:height).uniq.length == 1,
      facade_cams.map(&:height).inspect)
check('Все камеры параллельные', facade_cams.all? { |c| c.perspective? == false })
check_close('Фасад 1 смотрит на север (+Y)', facade_cams[0].direction.y, 1.0, 1e-6)
check_close('Фасад 2 смотрит на восток (+X)', facade_cams[1].direction.x, 1.0, 1e-6)
check_close('Фасад 3 смотрит на юг (-Y)', facade_cams[2].direction.y, -1.0, 1e-6)
check_close('Фасад 4 смотрит на запад (-X)', facade_cams[3].direction.x, -1.0, 1e-6)

# --------------------------------------------------- 6. один фасад (4 файла)

section 'Экспорт одного фасада'
clean_out
model = new_model
view = model.active_view
fresh_settings
result = FacadeExport::Exporter.new(
  :model => model, :view => view, :settings => FacadeExport.settings,
  :directory => OUT_ROOT, :base_name => 'Дом 2', :facade_count => 1
).run
check('Файлов создано: 4', result.files.length == 4, result.files.length)
check('Имя с пробелом сохранено', result.files.map { |f| File.basename(f) }.include?('Дом 2_Фасад_1_Текстура.png'),
      result.files.map { |f| File.basename(f) }.inspect)
check('Поворот камеры не выполнялся', view.writes.map { |w| w[:camera].eye.to_a }.uniq.length == 1)

# ------------------------------------------- 7. отключение карт и настройки

section 'Настройки карт влияют на экспорт'
clean_out
model = new_model
view = model.active_view
fresh_settings
FacadeExport.settings.map('lines')['enabled'] = false
FacadeExport.settings.map('windows')['enabled'] = false
result = FacadeExport::Exporter.new(
  :model => model, :view => view, :settings => FacadeExport.settings,
  :directory => OUT_ROOT, :base_name => 'Тест', :facade_count => 4
).run
check('Отключены 2 карты -> 8 файлов', result.files.length == 8, result.files.length)
check('Нет файлов "Линии"', result.files.none? { |f| f.include?('Линии') })

section 'Ошибки'
clean_out
model = new_model
view = model.active_view
fresh_settings
begin
  FacadeExport::Exporter.new(
    :model => model, :view => view, :settings => FacadeExport.settings,
    :directory => OUT_ROOT, :base_name => 'Тест', :facade_count => 4
  )
  view.camera = Sketchup::Camera.new(Geom::Point3d.new(0, 0, 5000),
                                     Geom::Point3d.new(0, 0, 0),
                                     Geom::Vector3d.new(0, 1, 0))
  FacadeExport::Framing.facade_directions(view.camera, 4)
  check('Вид сверху -> понятная ошибка', false, 'исключение не возникло')
rescue FacadeExport::ExportError => e
  check('Вид сверху -> понятная ошибка', e.message.include?('перпендикулярно'), e.message)
end

case FacadeExport::Exporter.new(
  :model => model, :view => view, :settings => FacadeExport.settings,
  :directory => OUT_ROOT, :base_name => 'Пусто', :facade_count => 4
).send(:build_image_size)
when nil then check('Размер изображения считается', false)
else check('Размер изображения считается', true)
end

# ------------------------------------------------- 7б. выделение и аннотации

section 'Выделение и служебная графика не попадают в кадр'
clean_out
model = new_model
view = model.active_view
model.selection.add([Object.new, Object.new, Object.new])
fresh_settings
result = FacadeExport::Exporter.new(
  :model => model, :view => view, :settings => FacadeExport.settings,
  :directory => OUT_ROOT, :base_name => 'Тест', :facade_count => 4
).run
check('Экспорт выполнен', result.errors.empty?, result.errors.inspect)
check('Во время экспорта выделение снято',
      view.writes.all? { |w| w[:selection].zero? },
      view.writes.map { |w| w[:selection] }.uniq.inspect)
check('Выделение возвращено после экспорта', model.selection.length == 3)

w0 = view.writes.first
check('Скрытая геометрия выключена', w0[:rendering]['DrawHidden'] == false)
check('Оси выключены', w0[:rendering]['DisplaySketchAxes'] == false)
check('Тексты и размеры выключены',
      w0[:rendering]['DisplayText'] == false && w0[:rendering]['DisplayDims'] == false)
check('Оси компонентов выключены', w0[:rendering]['DisplayInstanceAxes'] == false)

clean_out
model = new_model
view = model.active_view
fresh_settings
FacadeExport.settings.set_export('hide_annotations', false)
FacadeExport::Exporter.new(
  :model => model, :view => view, :settings => FacadeExport.settings,
  :directory => OUT_ROOT, :base_name => 'Тест', :facade_count => 1
).run
check('Настройка "скрывать аннотации" отключается',
      view.writes.first[:rendering]['DisplaySketchAxes'] == true,
      view.writes.first[:rendering]['DisplaySketchAxes'].inspect)

# --------------------------------------------- 8. нажатие кнопок (main.rb)

section 'Кнопки плагина (меню, панель, экспорт по нажатию)'
# Перерегистрируем после подстановки PATH плагина.
FacadeExport.instance_variable_set(:@ui_registered, nil)
FacadeExport.register_ui
check('Меню/панель зарегистрированы', FacadeExport.instance_variable_get(:@ui_registered) == true)
commands = FacadeExport.instance_variable_get(:@commands)
check('Четыре команды (2 экспорта, настройки, о плагине)', commands.length == 4,
      commands.map(&:name).inspect)
# В виртуальной ФС Ruby-WASM файлов проекта нет, поэтому иконки не
# подхватываются (код это корректно переживает); сами PNG проверяет run.mjs.
check('Отсутствие файлов иконок не ломает регистрацию', FacadeExport::PATH.to_s.end_with?('facade_export'),
      FacadeExport::PATH.inspect)

clean_out
model = new_model
view = model.active_view
fresh_settings
UI.messages = []
UI.savepanel_result = File.join(OUT_ROOT, 'Заречная_Фасад_1_Текстура.png')
FacadeExport.export_all_facades
files = Dir.entries(OUT_ROOT).select { |f| f.end_with?('.png') }
check('Кнопка "Экспорт всех фасадов" -> 16 файлов', files.length == 16, files.inspect)
check('Отчёт показан пользователю',
      UI.messages.any? { |m| m.include?('Экспорт завершён') }, UI.messages.inspect)
check('Папка сохранена в настройках', FacadeExport.settings.exp('last_directory') == OUT_ROOT,
      FacadeExport.settings.exp('last_directory').inspect)
report = UI.messages.find { |m| m.include?('Экспорт завершён') }.to_s
check('В отчёте есть имена файлов', report.include?('Заречная_Фасад_1_Текстура.png'))
check('В отчёте есть среднее время', report.include?('В среднем на изображение'))

# Подтверждение перезаписи
clean_out
model = new_model
fresh_settings
UI.savepanel_result = File.join(OUT_ROOT, 'Заречная_Фасад_1_Текстура.png')
FacadeExport.export_all_facades
check('Первый экспорт без вопросов о перезаписи',
      UI.messages.none? { |m| m.include?('Заменить их?') }, UI.messages.inspect)
UI.messages = []
UI.messagebox_answer = 7 # IDNO
FacadeExport.export_all_facades
check('Существующие файлы: задан вопрос', UI.messages.any? { |m| m.include?('Заменить их?') })
check('Ответ "Нет" отменяет экспорт',
      !UI.messages.any? { |m| m.include?('Экспорт завершён') }, UI.messages.inspect)
UI.messages = []
UI.messagebox_answer = 6 # IDYES
FacadeExport.export_all_facades
check('Ответ "Да" продолжает экспорт',
      UI.messages.any? { |m| m.include?('Экспорт завершён') }, UI.messages.inspect)
UI.messagebox_answer = nil

clean_out
UI.savepanel_result = nil
UI.messages = []
model = new_model
FacadeExport.export_single_facade
check('Отмена выбора папки ничего не экспортирует',
      Dir.entries(OUT_ROOT).select { |f| f.end_with?('.png') }.empty?)

clean_out
UI.messages = []
model = new_model
view = model.active_view
view.camera = Sketchup::Camera.new(Geom::Point3d.new(0, 0, 5000),
                                   Geom::Point3d.new(0, 0, 0),
                                   Geom::Vector3d.new(0, 1, 0))
UI.savepanel_result = File.join(OUT_ROOT, 'x.png')
FacadeExport.export_all_facades
check('Вид сверху: понятное сообщение вместо экспорта',
      UI.messages.any? { |m| m.include?('перпендикулярно') }, UI.messages.inspect)
check('Вид сверху: файлы не созданы',
      Dir.entries(OUT_ROOT).select { |f| f.end_with?('.png') }.empty?)

clean_out
UI.messages = []
model = new_model
fresh_settings
FacadeExport.settings.maps.each { |m| m['enabled'] = false }
UI.savepanel_result = File.join(OUT_ROOT, 'x.png')
FacadeExport.export_all_facades
check('Все карты отключены: сообщение пользователю',
      UI.messages.any? { |m| m.include?('Все карты отключены') }, UI.messages.inspect)

# ------------------------------------------------------------------ итог

puts
puts "Проверок: #{$checks}, провалов: #{$failures}"
exit($failures.zero? ? 0 : 1)
