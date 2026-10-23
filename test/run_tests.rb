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

def box_points(size_x, size_y, size_z, offset_x = 0.0, offset_y = 0.0, offset_z = 0.0)
  points = []
  [0.0, size_x].each do |x|
    [0.0, size_y].each do |y|
      [0.0, size_z].each do |z|
        points << Geom::Point3d.new(offset_x + x, offset_y + y, offset_z + z)
      end
    end
  end
  Geom::BoundingBox.new(points)
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
check('HSL 180/100/50 -> тонировка (голубой)', FacadeExport::Util.hsl_to_rgb(180, 100, 50) == [0, 255, 255],
      FacadeExport::Util.hsl_to_rgb(180, 100, 50).inspect)
check('HSL 300/100/50 -> ограждения (пурпурный)', FacadeExport::Util.hsl_to_rgb(300, 100, 50) == [255, 0, 255],
      FacadeExport::Util.hsl_to_rgb(300, 100, 50).inspect)
check('HSL 0/0/100 -> белый', FacadeExport::Util.hsl_to_rgb(0, 0, 100) == [255, 255, 255])
check('HSL 0/0/0 -> чёрный', FacadeExport::Util.hsl_to_rgb(0, 0, 0) == [0, 0, 0])

check('Имя файла: запрещённые символы',
      FacadeExport::Util.sanitize_filename('Заречная:дом*1?.skp') == 'Заречная_дом_1_.skp',
      FacadeExport::Util.sanitize_filename('Заречная:дом*1?.skp'))
check('Имя файла плагина: шаблон',
      FacadeExport::Exporter.file_name('Заречная', 2, 'Окна') == 'Заречная_Фасад_2_Окна.png',
      FacadeExport::Exporter.file_name('Заречная', 2, 'Окна'))
check('Имя файла: префикс из окна сохранения сохраняется',
      FacadeExport::Exporter.file_name('Дом_Иванова', 1, 'Текстура') == 'Дом_Иванова_Фасад_1_Текстура.png')

settings = fresh_settings
check('Версия настроек 4', settings.data['version'] == 4, settings.data['version'])
check('Ширина по умолчанию 9999', settings.exp('width') == 9999)
check('Высота автоматическая (0)', settings.exp('height') == 0)
check('Соотношение сторон 4:3', settings.exp('aspect') == '4:3', settings.exp('aspect').inspect)
check('Множитель линий 0,3x', (settings.exp('line_scale') - 0.3).abs < 1e-9)
check('Отступ вокруг фасада 0,02', (settings.exp('margin') - 0.02).abs < 1e-9, settings.exp('margin'))
check('Сглаживание выключено', settings.exp('antialias') == false)
check('Прозрачный фон включён', settings.exp('transparent') == true)
check('Параллельная проекция включена по умолчанию',
      settings.parallel_projection? == true && settings.exp('projection') == 'parallel')
check('Солнце для затенения выключено', settings.exp('sun_for_shading') == false)
check('Небо и земля скрыты по умолчанию',
      settings.exp('hide_sky') == true && settings.exp('hide_ground') == true,
      [settings.exp('hide_sky'), settings.exp('hide_ground')].inspect)
check('Настроек «оставлять небо/землю» больше нет',
      !settings.export.key?('show_sky') && !settings.export.key?('show_ground'))
check('Служебные настройки графики убраны',
      !settings.export.key?('hide_guides') && !settings.export.key?('hide_annotations') &&
      !settings.export.key?('show_section_planes'))
check('Подгонка одиночного фасада по всем включена по умолчанию? — нет',
      settings.exp('fit_all_facades') == false, settings.exp('fit_all_facades').inspect)

# Перенос старых настроек: «Оставлять небо» -> «Скрывать небо» = false
old_settings = FacadeExport::Settings.new(
  'version' => 3,
  'export' => { 'show_sky' => true, 'show_ground' => false }
)
check('Старые настройки: включённое небо сохраняется',
      old_settings.exp('hide_sky') == false && old_settings.exp('hide_ground') == true,
      [old_settings.exp('hide_sky'), old_settings.exp('hide_ground')].inspect)
check('Старые настройки: версия обновлена', old_settings.data['version'] == 4)
check('Возврат вида включён', settings.exp('restore_view') == true)
check('Отчёт включён', settings.exp('show_report') == true)
check('Четыре стандартные карты', settings.maps.length == 4)
check('Названия карт', settings.maps.map { |m| m['title'] } == %w[Текстура Линии Тени Окна],
      settings.maps.map { |m| m['title'] }.inspect)
check('Карта "Текстура": затенение + текстуры + без краёв',
      settings.map('texture')['render_mode'] == 'shaded' &&
      settings.map('texture')['textures'] == true &&
      settings.map('texture')['edges'] == false)
check('Текстуры не настраиваются вручную: только режим затенения',
      FacadeExport::Config.textures_for('shaded') == true &&
      FacadeExport::Config.textures_for('hidden') == false &&
      FacadeExport::Config.textures_for('wireframe') == false &&
      FacadeExport::Config.textures_for('monochrome') == false)
check('Карта "Линии": текстуры выключены сами (скрытые линии)',
      settings.map('lines')['textures'] == false)
check('Режим сменили -> текстуры пересчитались',
      begin
        fresh_settings
        m = FacadeExport.settings.map('texture')
        m['render_mode'] = 'hidden'
        FacadeExport.settings.normalize!
        m['textures'] == false
      end)
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
win = settings.map('windows')
check('Карта "Окна": режим затенения с текстурами (из режима)',
      win['render_mode'] == 'shaded' && win['textures'] == true, win['textures'].inspect)
check('Карта "Окна": красит стекло всегда', FacadeExport::MapOptions.glass_highlight?(win) == true)
check('Карта "Окна": разделение по типам стекла выключено', win['split_windows'] == false)
check('Стекло: основное H125/S100/L50', win['main_h'] == 125 && win['main_s'] == 100 && win['main_l'] == 50)
check('Стекло: тонировка H180/S100/L50', win['tinted_h'] == 180 && win['tinted_s'] == 100 && win['tinted_l'] == 50)
check('Стекло: ограждения H300/S100/L50', win['railing_h'] == 300 && win['railing_s'] == 100 && win['railing_l'] == 50)

custom = FacadeExport::Config.new_custom_map(1)
check('Своя карта: вид custom', custom['kind'] == 'custom')
check('Своя карта: название по умолчанию', custom['title'] == 'Своя карта 1', custom['title'])
check('Своя карта: экспортируется', custom['enabled'] == true)
check('Своя карта: редактируемые параметры на месте',
      custom.key?('render_mode') && custom.key?('edges') && custom.key?('shadows') &&
      custom.key?('shadow_light') && custom.key?('material_transparency'))
check('Своя карта: настройки стекла на месте',
      custom.key?('glass_highlight') && custom.key?('split_windows') &&
      custom.key?('main_h') && custom.key?('tinted_h') && custom.key?('railing_h'))
check('Своя карта: стекло по умолчанию не красит',
      FacadeExport::MapOptions.glass_highlight?(custom) == false)

settings.replace!('export' => { 'width' => 99_999, 'line_scale' => -5, 'margin' => 5 },
                  'maps' => [{ 'key' => 'texture', 'enabled' => 'true', 'render_mode' => 'xxx' }])
check('Ширина ограничена 16000', settings.exp('width') == 16_000, settings.exp('width'))
check('Множитель линий ограничен', settings.exp('line_scale') == 0.01)
check('Отступ ограничен', (settings.exp('margin') - 0.25).abs < 1e-9, settings.exp('margin'))
check('Строка "true" -> true', settings.map('texture')['enabled'] == true)
check('Неизвестный режим -> shaded', settings.map('texture')['render_mode'] == 'shaded')

settings.replace!('export' => { 'aspect' => 'нет такого', 'projection' => 'странная' })
check('Неизвестное соотношение -> 4:3', settings.exp('aspect') == '4:3')
check('Есть широкие соотношения 2:1 и 3:1',
      FacadeExport::Config::ASPECTS.key?('2:1') && FacadeExport::Config::ASPECTS.key?('3:1'),
      FacadeExport::Config::ASPECTS.keys.inspect)
check('Вертикальных дублей нет (3:4, 2:3, 9:16)',
      !FacadeExport::Config::ASPECTS.key?('3:4') &&
      !FacadeExport::Config::ASPECTS.key?('2:3') &&
      !FacadeExport::Config::ASPECTS.key?('9:16'),
      FacadeExport::Config::ASPECTS.keys.inspect)
check('Все соотношения записаны широкой стороной',
      FacadeExport::Config::ASPECTS.values.all? { |w, h| w >= h },
      FacadeExport::Config::ASPECTS.values.inspect)
check('Неизвестная проекция -> параллельная', settings.exp('projection') == 'parallel')

settings.replace!('maps' => [])
check('Пустой список карт -> стандартные четыре', settings.maps.length == 4)

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

fresh_settings
plan = FacadeExport::Framing.plan(model.bounds, dirs, FacadeExport.settings.export)
projections = plan[:projections]
check('Кадр 4:3 -> 9999×7499', plan[:image_width] == 9999 && plan[:image_height] == 7499,
      [plan[:image_width], plan[:image_height]].inspect)
check('Зазор 2 % от 9999 = 200 px', plan[:gap] == 200, plan[:gap])
check('Проекции Y-фасадов: ширина 1200',
      (projections[0][:width] - 1200).abs < 1e-6 && (projections[2][:width] - 1200).abs < 1e-6,
      projections.map { |p| p[:width] }.inspect)
check('Проекции X-фасадов: ширина 800', (projections[1][:width] - 800).abs < 1e-6,
      projections.map { |p| p[:width] }.inspect)
check('Высота проекции 600', (projections[0][:height] - 600).abs < 1e-6)
check('Самый большой фасад — первый', plan[:biggest] == 0, plan[:biggest])
check_close('Общий масштаб: 1200 px-единиц в 9599 px', plan[:scale], 9599.0 / 1200.0, 1e-6)

cams = dirs.each_with_index.map do |d, i|
  FacadeExport::Framing.build_camera(model.bounds, d, projections[i], plan[:scale],
                                     plan[:image_width], plan[:image_height], plan[:gap], true)
end
check('Камеры: параллельная проекция', cams.all? { |c| c.perspective? == false })
check('Камеры: одинаковая высота кадра у всех фасадов', cams.map(&:height).uniq.length == 1,
      cams.map(&:height).inspect)
cams.each_with_index do |c, i|
  check_close("Камера #{i + 1}: смотрит вдоль фасада",
              FacadeExport::Util.angle_between_deg(c.direction, Geom::Vector3d.new(*dirs[i].to_a)), 0.0, 1e-6)
end
check('Цель камеры: центр фасада по горизонтали',
      cams.all? { |c| (c.target.x - 600).abs < 1e-6 && (c.target.y - 400).abs < 1e-6 },
      cams.map { |c| [c.target.x, c.target.y] }.inspect)
gap_units = 0.0 - (cams[0].target.z - cams[0].height / 2.0)
check_close('Фасад прижат к низу кадра: зазор 200 px', gap_units * plan[:scale], 200.0, 1.0)
check('Камера отодвинута от модели', cams[0].eye.y < -1000, cams[0].eye.y)

# Скрытая геометрия не должна растягивать кадр
model_hidden = new_model
far_away = Sketchup.test_box(model_hidden.entities, 100, 100, 100, 50_000, 0, 0)
far_away.each { |edge| edge.hidden = true }
bounds_visible, scope_visible = FacadeExport::Framing.content_bounds(model_hidden)
check('Скрытая геометрия не растягивает кадр', scope_visible == :model &&
      (bounds_visible.max.x - 1200).abs < 1e-6 && (bounds_visible.min.x).abs < 1e-6,
      [bounds_visible.min.to_a, bounds_visible.max.to_a].inspect)

# Направляющие, сечения, размеры и тексты не растягивают кадр
guide = Sketchup::ConstructionLine.new
guide.bounds = box_points(1, 1, 1, -20_000, -20_000, 0)
text = Sketchup::Text.new
text.bounds = box_points(1, 1, 1, 30_000, 30_000, 0)
section = Sketchup::SectionPlane.new
section.bounds = box_points(1, 1, 1, 0, 0, 40_000)
dimension = Sketchup::Dimension.new
dimension.bounds = box_points(1, 1, 1, -30_000, 0, 0)
[guide, text, section, dimension].each { |e| model_hidden.entities.add(e) }
bounds_no_guides, _scope = FacadeExport::Framing.content_bounds(model_hidden)
check('Направляющие, сечения, размеры и тексты не растягивают кадр',
      (bounds_no_guides.max.x - 1200).abs < 1e-6 && (bounds_no_guides.min.x).abs < 1e-6,
      [bounds_no_guides.min.to_a, bounds_no_guides.max.to_a].inspect)

# Геометрия со скрытой метки (тега) в кадр не входит
hidden_layer = Sketchup::Layer.new('Скрытая метка', false)
far_layer_edges = Sketchup.test_box(model_hidden.entities, 200, 200, 200, 0, 30_000, 0)
far_layer_edges.each { |edge| edge.layer = hidden_layer }
bounds_layer, _scope = FacadeExport::Framing.content_bounds(model_hidden)
check('Геометрия со скрытой метки игнорируется',
      (bounds_layer.max.y - 800).abs < 1e-6,
      [bounds_layer.min.to_a, bounds_layer.max.to_a].inspect)

# Метка в скрытой папке меток тоже не учитывается
folder = Sketchup::LayerFolder.new('Скрытая папка', false)
folder_layer = Sketchup::Layer.new('В папке')
folder_layer.folder = folder
folder_edges = Sketchup.test_box(model_hidden.entities, 300, 300, 300, 0, 0, 20_000)
folder_edges.each { |edge| edge.layer = folder_layer }
bounds_folder, _scope = FacadeExport::Framing.content_bounds(model_hidden)
check('Метки в скрытой папке игнорируются',
      (bounds_folder.max.z - 600).abs < 1e-6,
      [bounds_folder.min.to_a, bounds_folder.max.to_a].inspect)

# Только грани без рёбер тоже дают габариты
model_faces = Sketchup::Model.new
model_faces.entities.clear
model_faces.entities.add(Sketchup::Face.new([
  Geom::Point3d.new(0, 0, 0), Geom::Point3d.new(900, 0, 0),
  Geom::Point3d.new(900, 0, 400), Geom::Point3d.new(0, 0, 400)
]))
bounds_faces, _scope = FacadeExport::Framing.content_bounds(model_faces)
check('Габариты по видимым граням (900×400)',
      (bounds_faces.max.x - 900).abs < 1e-6 && (bounds_faces.max.z - 400).abs < 1e-6,
      [bounds_faces.min.to_a, bounds_faces.max.to_a].inspect)

# Скрытые грани и рёбра не в счёт
model_faces.entities.to_a.each { |e| e.hidden = true }
hidden_only = begin
  FacadeExport::Framing.content_bounds(model_faces)
  nil
rescue FacadeExport::ExportError => e
  e.message
end
check('Всё скрыто — понятная ошибка', hidden_only.to_s.include?('нет видимых линий и граней'),
      hidden_only.inspect)

# Внутри компонента скрытая геометрия тоже не растягивает кадр
model_comp = new_model
model_comp.entities.clear
inner = Sketchup::Definition.new(box_points(500, 500, 300))
Sketchup.test_box(inner.entities, 500, 500, 300)
far_inner = Sketchup.test_box(inner.entities, 50, 50, 50, 0, 10_000, 0)
far_inner.each { |edge| edge.hidden = true }
instance = Sketchup::ComponentInstance.new(inner, Geom::Transformation.new(0, 0, 0))
model_comp.entities.add(instance)
bounds_comp, _scope = FacadeExport::Framing.content_bounds(model_comp)
check('Скрытое внутри компонента не растягивает кадр',
      (bounds_comp.max.y - 500).abs < 1e-6,
      [bounds_comp.min.to_a, bounds_comp.max.to_a].inspect)

far_away.each { |edge| edge.hidden = false }
bounds_all, _scope = FacadeExport::Framing.content_bounds(model_hidden)
check('Видимая геометрия учитывается целиком', (bounds_all.max.x - 50_100).abs < 1e-6,
      bounds_all.max.to_a.inspect)

# Высокий объект (башня)
tower = box_points(400, 400, 2000)
plan_v = FacadeExport::Framing.plan(tower, dirs, FacadeExport.settings.export)
check('Высокий объект: 9999 по вертикали (7499×9999)',
      plan_v[:image_width] == 7499 && plan_v[:image_height] == 9999,
      [plan_v[:image_width], plan_v[:image_height]].inspect)
check('Высокий объект: кадр вертикальный', plan_v[:vertical] == true)
cam_v = FacadeExport::Framing.build_camera(tower, dirs[0], plan_v[:projections][0], plan_v[:scale],
                                           plan_v[:image_width], plan_v[:image_height], plan_v[:gap], true)
check_close('Высокий объект: высота кадра 9999 px', cam_v.height * plan_v[:scale], 9999.0, 1.5)

settings_h = FacadeExport::Settings.new
settings_h.set_export('height', 5000)
check('Явная высота используется как есть',
      FacadeExport::Framing.image_size(settings_h.export, projections)[0, 2] == [9999, 5000],
      FacadeExport::Framing.image_size(settings_h.export, projections).inspect)

settings_31 = FacadeExport::Settings.new
settings_31.set_export('aspect', '3:1')
plan_31 = FacadeExport::Framing.plan(model.bounds, dirs, settings_31.export)
check('Соотношение 3:1 -> 9999×3333',
      plan_31[:image_width] == 9999 && plan_31[:image_height] == 3333,
      [plan_31[:image_width], plan_31[:image_height]].inspect)
settings_31.set_export('aspect', '2:1')
plan_21 = FacadeExport::Framing.plan(box_points(400, 400, 2000), dirs, settings_31.export)
check('2:1 для башни разворачивается: 5000×9999',
      plan_21[:image_width] == 5000 && plan_21[:image_height] == 9999,
      [plan_21[:image_width], plan_21[:image_height]].inspect)

bounds_all, scope_all = FacadeExport::Framing.content_bounds(model)
check('Без открытой группы кадрируется вся модель', scope_all == :model &&
      (bounds_all.max.x - 1200).abs < 1e-6)

group_bounds = box_points(400, 300, 200)
definition = Sketchup::Definition.new(group_bounds)
Sketchup.test_box(definition.entities, 400, 300, 200)
instance = Sketchup::GroupInstance.new(definition, Geom::Transformation.new(1000, 1000, 0))
model.active_path = [instance]
bounds_ctx, scope_ctx = FacadeExport::Framing.content_bounds(model)
check('Внутри группы кадрируется только группа', scope_ctx == :context, scope_ctx)
check('Габариты группы: 400×300×200', (bounds_ctx.max.x - bounds_ctx.min.x - 400).abs < 1e-6 &&
      (bounds_ctx.max.y - bounds_ctx.min.y - 300).abs < 1e-6 &&
      (bounds_ctx.max.z - bounds_ctx.min.z - 200).abs < 1e-6,
      [bounds_ctx.min.to_a, bounds_ctx.max.to_a].inspect)
check('Группа смещена преобразованием экземпляра',
      (bounds_ctx.min.x - 1000).abs < 1e-6 && (bounds_ctx.min.y - 1000).abs < 1e-6,
      bounds_ctx.min.to_a.inspect)
model.active_path = []

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

section 'Типы стекла и перекраска'
model = new_model
fresh_settings
win = FacadeExport.settings.map('windows')
colors = {
  'main'    => FacadeExport::Util.hsl_to_rgb(win['main_h'], win['main_s'], win['main_l']),
  'tinted'  => FacadeExport::Util.hsl_to_rgb(win['tinted_h'], win['tinted_s'], win['tinted_l']),
  'railing' => FacadeExport::Util.hsl_to_rgb(win['railing_h'], win['railing_s'], win['railing_l'])
}
probe = FacadeExport::GlassRecolor.new(model, colors, :mode => 'combined')
check('Непрозрачность 0 % -> ограждения', probe.classify(0) == 'railing')
check('Непрозрачность 10 % -> ограждения', probe.classify(10) == 'railing')
check('Непрозрачность 11 % -> основное стекло', probe.classify(11) == 'main')
check('Непрозрачность 89 % -> основное стекло', probe.classify(89) == 'main')
check('Непрозрачность 90 % -> тонировка', probe.classify(90) == 'tinted')
check('Непрозрачность 99 % -> тонировка', probe.classify(99) == 'tinted')
check('Непрозрачность 100 % -> обычный материал', probe.classify(100).nil?)
check('Непрозрачность 99,5 % -> обычный материал', probe.classify(99.5).nil?)

before = model.materials.map { |m| [m.name, m.color.to_a, m.alpha, m.texture && m.texture.filename] }
glass = FacadeExport::GlassRecolor.new(model, colors, :mode => 'combined')
recolored = glass.apply
check('Карта окон: перекрашены 3 материала стекла', recolored == 3, recolored)
check('Основное стекло: H125/S100/L50',
      model.materials['Стекло'].color.to_a[0, 3] == [0, 255, 21], model.materials['Стекло'].color.to_a.inspect)
check('Тонировка: H180/S100/L50',
      model.materials['Тонировка'].color.to_a[0, 3] == [0, 255, 255])
check('Ограждения: H300/S100/L50',
      model.materials['Витрина'].color.to_a[0, 3] == [255, 0, 255])
check('Все стеклянные материалы на карте окон непрозрачны',
      [model.materials['Стекло'].alpha, model.materials['Тонировка'].alpha,
       model.materials['Витрина'].alpha] == [1.0, 1.0, 1.0])
check('Непрозрачный материал не тронут', model.materials['Кирпич'].color.to_a == [180, 90, 70, 255])
glass.restore
after = model.materials.map { |m| [m.name, m.color.to_a, m.alpha, m.texture && m.texture.filename] }
check('Исходные цвета и текстуры восстановлены', before == after, "#{before.inspect}\n       #{after.inspect}")
check('Материал с текстурой: текстура возвращена',
      model.materials['Витрина'].texture && model.materials['Витрина'].texture.filename == '/textures/glass.jpg')

hidden = FacadeExport::GlassRecolor.new(model, colors, :mode => 'hide_railings')
hidden.apply
check('Карты текстур/линий/теней: ограждения исчезают (0 %)', model.materials['Витрина'].alpha == 0.0)
check('Карты текстур/линий/теней: основное стекло становится непрозрачным',
      model.materials['Стекло'].alpha == 1.0, model.materials['Стекло'].alpha)
check('Карты текстур/линий/теней: цвет основного стекла сохранён',
      model.materials['Стекло'].color.to_a[0, 3] == [200, 230, 240],
      model.materials['Стекло'].color.to_a.inspect)
check('Карты текстур/линий/теней: тонировка тоже непрозрачна',
      model.materials['Тонировка'].alpha == 1.0)
check('Карты текстур/линий/теней: текстура ограждения не потеряна',
      !model.materials['Витрина'].texture.nil?)
hidden.restore
check('После карты с ограждениями всё восстановлено',
      (model.materials['Витрина'].alpha - 0.0).abs < 1e-9 &&
      model.materials['Витрина'].texture != nil)

split = FacadeExport::GlassRecolor.new(model, colors, :mode => 'tinted')
split.apply
check('Отдельная карта тонировки: тонировка окрашена',
      model.materials['Тонировка'].color.to_a[0, 3] == [0, 255, 255] && model.materials['Тонировка'].alpha == 1.0)
check('Отдельная карта тонировки: основное стекло скрыто', model.materials['Стекло'].alpha == 0.0)
check('Отдельная карта тонировки: ограждения скрыты', model.materials['Витрина'].alpha == 0.0)
split.restore

split_main = FacadeExport::GlassRecolor.new(model, colors, :mode => 'main')
split_main.apply
check('Отдельная карта стекла: основное стекло окрашено',
      model.materials['Стекло'].color.to_a[0, 3] == [0, 255, 21] && model.materials['Стекло'].alpha == 1.0)
check('Отдельная карта стекла: тонировки нет', model.materials['Тонировка'].alpha == 0.0)
split_main.restore
after_split = model.materials.map { |m| [m.name, m.color.to_a, m.alpha] }
check('Раздельные карты стекла не портят материалы',
      after_split == before.map { |b| [b[0], b[1], b[2]] }, "#{after_split.inspect}\n       #{before.map { |b| [b[0], b[1], b[2]] }.inspect}")

# -------------------------------------- 4б. режим «только видимый участок»

section 'Экспорт только видимого участка'
clean_out
model = new_model
view = model.active_view
view.vpwidth = 1920.0
view.vpheight = 1080.0
fresh_settings
FacadeExport.settings.set_export('visible_area', true)
check('Режим по умолчанию выключен', FacadeExport::Settings.new.exp('visible_area') == false)
check('Режим включается', FacadeExport.settings.exp('visible_area') == true)

user_camera = view.camera
plan_vis, cams_vis = FacadeExport::Framing.visible_cameras(
  user_camera, view, FacadeExport.settings.export, 4, true
)
check('Кадр по соотношению ИЗ НАСТРОЕК, а не окна: 9999×7499 (4:3)',
      plan_vis[:image_width] == 9999 && plan_vis[:image_height] == 7499,
      [plan_vis[:image_width], plan_vis[:image_height]].inspect)
# Пользователь смотрел в перспективе — переводим в параллельную проекцию
# с эквивалентной высотой кадра на расстоянии до цели.
expected_height = 2.0 * (user_camera.eye - user_camera.target).length *
                  Math.tan(user_camera.fov / 2.0 * Math::PI / 180.0)
check_close('Перспектива -> эквивалентная высота ортокадра',
            cams_vis[0].height, expected_height, 1e-6)
check('Первая камера совпадает с видом пользователя',
      cams_vis[0].eye.to_a == user_camera.eye.to_a &&
      cams_vis[0].target.to_a == user_camera.target.to_a,
      [cams_vis[0].eye.to_a, user_camera.eye.to_a].inspect)
check('Камеры параллельные (как в настройках)', cams_vis.all? { |c| c.perspective? == false })
check('Все камеры на одном расстоянии',
      cams_vis.map { |c| (c.eye - c.target).length.round(6) }.uniq.length == 1,
      cams_vis.map { |c| (c.eye - c.target).length }.inspect)
check('Четыре разных ракурса', cams_vis.map { |c| c.eye.to_a }.uniq.length == 4)
check('Цель у всех камер одна', cams_vis.map { |c| c.target.to_a }.uniq.length == 1)
expected_dirs = [[0, 1], [1, 0], [0, -1], [-1, 0]]
cams_vis.each_with_index do |c, i|
  check_close("Видимый режим, камера #{i + 1}: поворот на 90°",
              FacadeExport::Util.angle_between_deg(c.direction, Geom::Vector3d.new(*expected_dirs[i])), 0.0, 1e-6)
end
check('Масштаб (пикселей на единицу) посчитан', plan_vis[:scale].to_f > 0.0, plan_vis[:scale])

parallel_cam = Sketchup::Camera.new(Geom::Point3d.new(0, -5000, 300),
                                   Geom::Point3d.new(0, 0, 300), Geom::Vector3d.new(0, 0, 1))
parallel_cam.perspective = false
parallel_cam.height = 2500.0
plan_par, cams_par = FacadeExport::Framing.visible_cameras(
  parallel_cam, view, FacadeExport.settings.export, 1, true
)
check_close('Параллельная камера пользователя: высота кадра без изменений',
            cams_par[0].height, 2500.0, 1e-6)

# Форма окна просмотра на размер кадра не влияет
view.vpwidth = 1080.0
view.vpheight = 1920.0
plan_portrait, = FacadeExport::Framing.visible_cameras(
  view.camera, view, FacadeExport.settings.export, 1, true
)
check('Вертикальное окно просмотра: размер всё равно 9999×7499',
      plan_portrait[:image_width] == 9999 && plan_portrait[:image_height] == 7499,
      [plan_portrait[:image_width], plan_portrait[:image_height]].inspect)
view.vpwidth = 1920.0
view.vpheight = 1080.0

# Соотношение из настроек действует и в режиме «что на экране»
settings_vis_aspect = FacadeExport::Settings.new
settings_vis_aspect.set_export('visible_area', true)
settings_vis_aspect.set_export('aspect', '3:1')
plan_vis_31, = FacadeExport::Framing.visible_cameras(
  view.camera, view, settings_vis_aspect.export, 1, true
)
check('Видимый режим: 3:1 из настроек -> 9999×3333',
      plan_vis_31[:image_width] == 9999 && plan_vis_31[:image_height] == 3333,
      [plan_vis_31[:image_width], plan_vis_31[:image_height]].inspect)
settings_vis_aspect.set_export('aspect', '1:1')
plan_vis_11, = FacadeExport::Framing.visible_cameras(
  view.camera, view, settings_vis_aspect.export, 1, true
)
check('Видимый режим: 1:1 из настроек -> 9999×9999',
      plan_vis_11[:image_width] == 9999 && plan_vis_11[:image_height] == 9999,
      [plan_vis_11[:image_width], plan_vis_11[:image_height]].inspect)

# Полный экспорт в этом режиме
clean_out
model = new_model
view = model.active_view
view.vpwidth = 1920.0
view.vpheight = 1080.0
fresh_settings
FacadeExport.settings.set_export('visible_area', true)
before_eye = view.camera.eye.to_a
result = FacadeExport::Exporter.new(
  :model => model, :view => view, :settings => FacadeExport.settings,
  :directory => OUT_ROOT, :base_name => 'Экран', :facade_count => 4
).run
check('Видимый режим: 16 файлов', result.files.length == 16, result.files.length)
check('Видимый режим: ошибок нет', result.errors.empty?, result.errors.inspect)
check('Видимый режим: пометка в результате', result.scope == :visible, result.scope)
check('Видимый режим: размеры из настроек (9999×7499)',
      view.writes.all? { |w| w[:width] == 9999 && w[:height] == 7499 },
      view.writes.map { |w| [w[:width], w[:height]] }.uniq.inspect)
check('Видимый режим: камера пользователя не сдвинута',
      view.writes.first[:camera].eye.to_a == before_eye,
      [view.writes.first[:camera].eye.to_a, before_eye].inspect)
check('Видимый режим: камера восстановлена', view.camera.eye.to_a == before_eye)
check('Видимый режим: стиль всё равно настроен',
      view.writes.all? { |w| w[:rendering]['DrawSky'] == false })

# Перспективный вид пользователя: сначала переключение в параллельную проекцию
clean_out
model = new_model
view = model.active_view
persp = Sketchup::Camera.new(Geom::Point3d.new(1000, -8000, 2500),
                             Geom::Point3d.new(600, 400, 300),
                             Geom::Vector3d.new(0, 0, 1))
persp.perspective = true
persp.fov = 40.0
view.camera = persp
check('Пользователь смотрит в перспективе', view.camera.perspective? == true)
expected_persp_height = 2.0 * (persp.eye - persp.target).length *
                        Math.tan(persp.fov / 2.0 * Math::PI / 180.0)
exporter_probe = FacadeExport::Exporter.new(
  :model => model, :view => view, :settings => FacadeExport.settings,
  :directory => OUT_ROOT, :base_name => 'Проба', :facade_count => 1
)
check('До экспорта вид перспективный', view.camera.perspective? == true)
exporter_probe.send(:switch_to_parallel_view)
check('switch_to_parallel_view переключает сам вид', view.camera.perspective? == false)
check('switch_to_parallel_view сохраняет ракурс',
      view.camera.eye.to_a == persp.eye.to_a && view.camera.target.to_a == persp.target.to_a)
view.camera = persp

converted = FacadeExport::Framing.parallel_camera(persp)
check('Функция переводит камеру в параллельную проекцию', converted.perspective? == false)
check('Точка взгляда и цель сохраняются',
      converted.eye.to_a == persp.eye.to_a && converted.target.to_a == persp.target.to_a,
      [converted.eye.to_a, converted.target.to_a].inspect)
check_close('Высота кадра эквивалентна перспективе',
            converted.height, expected_persp_height, 1e-6)
check('Исходная камера не изменена', persp.perspective? == true)

fresh_settings
before_eye = persp.eye.to_a
before_target = persp.target.to_a
result = FacadeExport::Exporter.new(
  :model => model, :view => view, :settings => FacadeExport.settings,
  :directory => OUT_ROOT, :base_name => 'Перспектива', :facade_count => 4
).run
check('Перспектива: экспорт выполнен', result.errors.empty?, result.errors.inspect)
check('Перспектива: 16 файлов', result.files.length == 16, result.files.length)
check('Перспектива: все кадры параллельные',
      view.writes.all? { |w| w[:camera].perspective? == false })
check('Перспектива: вид переключён ДО первого кадра (высота у всех одинаковая)',
      view.writes.map { |w| w[:camera].height.round(6) }.uniq.length == 1,
      view.writes.map { |w| w[:camera].height }.uniq.inspect)
check('Перспектива: камера пользователя восстановлена',
      view.camera.perspective? == true &&
      view.camera.eye.to_a == before_eye && view.camera.target.to_a == before_target,
      [view.camera.perspective?, view.camera.eye.to_a].inspect)

# То же в режиме «только видимый участок»
clean_out
model = new_model
view = model.active_view
persp2 = Sketchup::Camera.new(Geom::Point3d.new(0, -6000, 1500),
                              Geom::Point3d.new(0, 0, 500), Geom::Vector3d.new(0, 0, 1))
persp2.perspective = true
persp2.fov = 45.0
view.camera = persp2
fresh_settings
FacadeExport.settings.set_export('visible_area', true)
before_eye2 = view.camera.eye.to_a
result = FacadeExport::Exporter.new(
  :model => model, :view => view, :settings => FacadeExport.settings,
  :directory => OUT_ROOT, :base_name => 'Экран2', :facade_count => 2
).run
check('Видимый режим из перспективы: экспорт выполнен', result.errors.empty?, result.errors.inspect)
check('Видимый режим из перспективы: кадры параллельные',
      view.writes.all? { |w| w[:camera].perspective? == false })
check('Видимый режим из перспективы: ракурс и цель пользователя сохранены',
      view.writes.first[:camera].eye.to_a == before_eye2 &&
      view.writes.first[:camera].target.to_a == persp2.target.to_a,
      [view.writes.first[:camera].eye.to_a, before_eye2].inspect)
expected_vis_height = 2.0 * (persp2.eye - persp2.target).length *
                      Math.tan(persp2.fov / 2.0 * Math::PI / 180.0)
check('Видимый режим из перспективы: высота кадра равна перспективной',
      view.writes.all? { |w| (w[:camera].height - expected_vis_height).abs < 1e-6 },
      view.writes.map { |w| w[:camera].height }.uniq.inspect)
check('Видимый режим из перспективы: камера пользователя восстановлена',
      view.camera.perspective? == true && view.camera.eye.to_a == before_eye2)

# Явная высота перекрывает соотношение окна
clean_out
model = new_model
view = model.active_view
view.vpwidth = 1920.0
view.vpheight = 1080.0
fresh_settings
FacadeExport.settings.set_export('visible_area', true)
FacadeExport.settings.set_export('height', 4000)
FacadeExport::Exporter.new(
  :model => model, :view => view, :settings => FacadeExport.settings,
  :directory => OUT_ROOT, :base_name => 'Своя', :facade_count => 1
).run
check('Видимый режим: явная высота уважается',
      view.writes.all? { |w| w[:width] == 9999 && w[:height] == 4000 },
      view.writes.map { |w| [w[:width], w[:height]] }.uniq.inspect)

# ---------------------------------------------------- 5. полный экспорт (16)

section 'Полный экспорт всех фасадов'
clean_out
model = new_model
view = model.active_view
# Пользователь выключил сечения в стиле — плагин обязан включить их на экспорте.
model.rendering_options['DisplaySectionCuts'] = false
model.rendering_options['DisplaySectionPlanes'] = true
initial_rendering = model.rendering_options.to_h.dup
initial_shadow = model.shadow_info.to_h.dup
initial_eye = view.camera.eye.to_a
initial_target = view.camera.target.to_a
initial_mode = view.camera.perspective?
# Размер окна просмотра не должен влиять на размер PNG.
view.vpwidth = 640.0
view.vpheight = 480.0

fresh_settings
result = FacadeExport::Exporter.new(
  :model => model, :view => view, :settings => FacadeExport.settings,
  :directory => OUT_ROOT, :base_name => 'Заречная', :facade_count => 4
).run

check('Файлов создано: 16', result.files.length == 16, result.files.length)
check('Ошибок нет', result.errors.empty?, result.errors.inspect)
check('Режим кадрирования: вся модель', result.scope == :model, result.scope)
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
check('Размер не зависит от окна просмотра: ширина 9999',
      writes.all? { |w| w[:width] == 9999 }, writes.map { |w| w[:width] }.uniq.inspect)
check('Кадр 4:3: высота 7499',
      writes.all? { |w| w[:height] == 7499 }, writes.map { |w| w[:height] }.uniq.inspect)
check('Сглаживание выключено', writes.all? { |w| w[:antialias] == false })
check('Прозрачный фон включён', writes.all? { |w| w[:transparent] == true })
check('Множитель линий 0.3', writes.all? { |w| (w[:scale_factor] - 0.3).abs < 1e-9 })
check('Сечения продолжают резать геометрию (DisplaySectionCuts = true)',
      writes.all? { |w| w[:rendering]['DisplaySectionCuts'] == true })
check('Рамки плоскостей сечений скрыты (DisplaySectionPlanes = false)',
      writes.all? { |w| w[:rendering]['DisplaySectionPlanes'] == false })

def write_for(writes, number, title)
  writes.find { |w| w[:path].include?("Фасад_#{number}_#{title}.png") }
end

def shot(writes, number, title, material = nil)
  w = write_for(writes, number, title)
  return nil if w.nil?
  return w if material.nil?
  w[:materials].find { |m| m[0] == material }
end

texture_w = write_for(writes, 1, 'Текстура')
lines_w = write_for(writes, 1, 'Линии')
shadows_w = write_for(writes, 1, 'Тени')
windows_w = write_for(writes, 1, 'Окна')

check('Текстура: RenderMode 2 (затенение)', texture_w[:rendering]['RenderMode'] == 2)
check('Текстура: Texture = true', texture_w[:rendering]['Texture'] == true)
check('Текстура: края скрыты (0)', texture_w[:rendering]['EdgeDisplayMode'] == 0)
check('Текстура: тени выключены', texture_w[:shadow]['DisplayShadows'] == false)

check('Линии: RenderMode 1 (скрытые линии)', lines_w[:rendering]['RenderMode'] == 1)
check('Линии: края показаны (1)', lines_w[:rendering]['EdgeDisplayMode'] == 1)
check('Линии: тени выключены', lines_w[:shadow]['DisplayShadows'] == false)

check('Тени: края скрыты', shadows_w[:rendering]['EdgeDisplayMode'] == 0)
check('Тени: тени включены', shadows_w[:shadow]['DisplayShadows'] == true)
check('Тени: солнце для затенения выключено', shadows_w[:shadow]['UseSunForAllShading'] == false)
check('Тени: светлее 100 / темнее 0',
      shadows_w[:shadow]['Light'] == 100 && shadows_w[:shadow]['Dark'] == 0)
sh_sun = shadows_w[:shadow]['SunDirection']
check_close('Тени: высота солнца 45°', FacadeExport::Sun.elevation_of(sh_sun), 45.0, 1.0)
check_close('Тени: солнце слева сверху (азимут 225° для вида на север)',
            FacadeExport::Sun.azimuth_of(sh_sun), 225.0, 1.0)

check('Линии: текстуры выключены режимом (Texture = false)', lines_w[:rendering]['Texture'] == false)
check('Тени: текстуры выключены режимом (Texture = false)', shadows_w[:rendering]['Texture'] == false)
check('Окна: тени выключены', windows_w[:shadow]['DisplayShadows'] == false)
check('Окна: RenderMode 2', windows_w[:rendering]['RenderMode'] == 2)
glass_main = shot(writes, 1, 'Окна', 'Стекло')
check('Окна: основное стекло H125/S100/L50',
      glass_main && glass_main[1][0, 3] == [0, 255, 21] && glass_main[2] == 1.0, glass_main.inspect)
glass_rail = shot(writes, 1, 'Окна', 'Витрина')
check('Окна: ограждения H300/S100/L50 и непрозрачны',
      glass_rail && glass_rail[1][0, 3] == [255, 0, 255] && glass_rail[2] == 1.0, glass_rail.inspect)
glass_tint = shot(writes, 1, 'Окна', 'Тонировка')
check('Окна: тонировка H180/S100/L50',
      glass_tint && glass_tint[1][0, 3] == [0, 255, 255], glass_tint.inspect)

[['Текстура', texture_w], ['Линии', lines_w], ['Тени', shadows_w]].each do |title, w|
  rail = w[:materials].find { |m| m[0] == 'Витрина' }
  main_glass = w[:materials].find { |m| m[0] == 'Стекло' }
  tint = w[:materials].find { |m| m[0] == 'Тонировка' }
  check("#{title}: стеклянные ограждения исчезают", rail && rail[2] == 0.0, rail.inspect)
  check("#{title}: основное стекло непрозрачно (не просвечивает)",
        main_glass && main_glass[2] == 1.0, main_glass.inspect)
  check("#{title}: тонировка непрозрачна", tint && tint[2] == 1.0, tint.inspect)
end

check('Стиль восстановлен полностью', model.rendering_options.to_h == initial_rendering,
      model.rendering_options.to_h.reject { |k, v| initial_rendering[k] == v }.inspect)
check('Тени восстановлены полностью', model.shadow_info.to_h == initial_shadow,
      model.shadow_info.to_h.reject { |k, v| initial_shadow[k] == v }.inspect)
check('Камера восстановлена (eye)', view.camera.eye.to_a == initial_eye, view.camera.eye.to_a.inspect)
check('Камера восстановлена (target)', view.camera.target.to_a == initial_target)
check('Тип проекции восстановлен', view.camera.perspective? == initial_mode)
check('Материалы восстановлены',
      model.materials['Стекло'].color.to_a == [200, 230, 240, 255] &&
      (model.materials['Стекло'].alpha - 0.35).abs < 1e-9 &&
      model.materials['Витрина'].texture != nil)

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
facade_cams.each_with_index do |c, i|
  bottom = c.target.z - c.height / 2.0
  check_close("Фасад #{i + 1}: прижат к низу кадра (зазор 200 px)",
              (0.0 - bottom) * (c.height.zero? ? 1.0 : 7499.0 / c.height), 200.0, 1.5)
end

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
check('Имя с пробелом сохранено',
      result.files.map { |f| File.basename(f) }.include?('Дом 2_Фасад_1_Текстура.png'),
      result.files.map { |f| File.basename(f) }.inspect)
check('Поворот камеры не выполнялся', view.writes.map { |w| w[:camera].eye.to_a }.uniq.length == 1)

# --------------------------------------- 7. раздельные карты окон (п. 11)

section 'Раздельные карты окон по типам стекла'
clean_out
model = new_model
view = model.active_view
fresh_settings
FacadeExport.settings.map('windows')['split_windows'] = true
jobs = FacadeExport::Exporter.output_jobs(FacadeExport.settings)
check('Задач на фасад: 6 (3 обычные + 3 стекла)', jobs.length == 6, jobs.map(&:title).inspect)
check('Названия карт стекла',
      jobs.map(&:title).include?('окно-стекло') && jobs.map(&:title).include?('окно-тонировка') &&
      jobs.map(&:title).include?('окно-ограждения'), jobs.map(&:title).inspect)
result = FacadeExport::Exporter.new(
  :model => model, :view => view, :settings => FacadeExport.settings,
  :directory => OUT_ROOT, :base_name => 'Стекло', :facade_count => 4
).run
check('Файлов создано: 24', result.files.length == 24, result.files.length)
check('Ошибок нет', result.errors.empty?, result.errors.inspect)
names = result.files.map { |f| File.basename(f) }
check('Есть файл "окно-стекло"', names.include?('Стекло_Фасад_1_окно-стекло.png'), names.inspect)
check('Есть файл "окно-тонировка"', names.include?('Стекло_Фасад_1_окно-тонировка.png'))
check('Есть файл "окно-ограждения"', names.include?('Стекло_Фасад_1_окно-ограждения.png'))
check('Общей карты "Окна" больше нет', names.none? { |n| n.include?('_Окна.png') })

rail_shot = shot(view.writes, 1, 'окно-ограждения', 'Витрина')
check('Карта ограждений: ограждения окрашены и видны',
      rail_shot && rail_shot[1][0, 3] == [255, 0, 255] && rail_shot[2] == 1.0, rail_shot.inspect)
rail_hidden = shot(view.writes, 1, 'окно-ограждения', 'Стекло')
check('Карта ограждений: основное стекло скрыто', rail_hidden && rail_hidden[2] == 0.0)
main_shot = shot(view.writes, 1, 'окно-стекло', 'Стекло')
check('Карта стекла: основное стекло окрашено',
      main_shot && main_shot[1][0, 3] == [0, 255, 21] && main_shot[2] == 1.0, main_shot.inspect)
main_rail = shot(view.writes, 1, 'окно-стекло', 'Витрина')
check('Карта стекла: ограждения скрыты', main_rail && main_rail[2] == 0.0)

# ------------------------------------------------ 8. своя карта (п. 13)

section 'Своя карта из кнопки "+"'
clean_out
model = new_model
view = model.active_view
fresh_settings
custom = FacadeExport::Config.new_custom_map(1)
custom['title'] = 'Цветной фасад'
custom['render_mode'] = 'monochrome'
FacadeExport.settings.maps << custom
check('Планируемых файлов на фасад: 5',
      FacadeExport::Exporter.planned_paths(FacadeExport.settings, OUT_ROOT, 'Своя', 1).length == 5)
result = FacadeExport::Exporter.new(
  :model => model, :view => view, :settings => FacadeExport.settings,
  :directory => OUT_ROOT, :base_name => 'Своя', :facade_count => 1
).run
check('Своя карта экспортируется', result.files.length == 5, result.files.length)
check('Имя файла со своей картой',
      result.files.map { |f| File.basename(f) }.include?('Своя_Фасад_1_Цветной фасад.png'),
      result.files.map { |f| File.basename(f) }.inspect)
custom_shot = write_for(view.writes, 1, 'Цветной фасад')
check('Своя карта: выбранный режим отображения применён', custom_shot[:rendering]['RenderMode'] == 5,
      custom_shot[:rendering]['RenderMode'].inspect)

# --- своя карта со стеклом
clean_out
model = new_model
view = model.active_view
fresh_settings
custom_glass = FacadeExport::Config.new_custom_map(1)
custom_glass['title'] = 'Витражи'
custom_glass['glass_highlight'] = true
FacadeExport.settings.maps << custom_glass
FacadeExport.settings.normalize!
jobs = FacadeExport::Exporter.output_jobs(FacadeExport.settings)
check('Своя карта со стеклом: одна общая карта', jobs.map(&:title).include?('Витражи'),
      jobs.map(&:title).inspect)
custom_glass['split_windows'] = true
jobs = FacadeExport::Exporter.output_jobs(FacadeExport.settings)
check('Своя карта: разделение по типам стекла даёт 3 карты',
      jobs.map(&:title).include?('Витражи — окно-стекло') &&
      jobs.map(&:title).include?('Витражи — окно-тонировка') &&
      jobs.map(&:title).include?('Витражи — окно-ограждения'), jobs.map(&:title).inspect)
check('Задач у своей карты со стеклом: 3 из 7', jobs.count { |j| j.map['title'] == 'Витражи' } == 3,
      jobs.map(&:title).inspect)
result = FacadeExport::Exporter.new(
  :model => model, :view => view, :settings => FacadeExport.settings,
  :directory => OUT_ROOT, :base_name => 'Витражи', :facade_count => 1
).run
check('Файлы своей карты со стеклом созданы',
      result.files.map { |f| File.basename(f) }.include?('Витражи_Фасад_1_Витражи — окно-стекло.png'),
      result.files.map { |f| File.basename(f) }.inspect)
custom_rail = shot(view.writes, 1, 'Витражи — окно-ограждения', 'Витрина')
check('Своя карта: ограждения окрашены', custom_rail && custom_rail[2] == 1.0, custom_rail.inspect)

# своя карта без стекла -> ограждения просто скрываются
clean_out
model = new_model
view = model.active_view
fresh_settings
plain = FacadeExport::Config.new_custom_map(2)
plain['title'] = 'Схема'
FacadeExport.settings.maps << plain
FacadeExport.settings.normalize!
result = FacadeExport::Exporter.new(
  :model => model, :view => view, :settings => FacadeExport.settings,
  :directory => OUT_ROOT, :base_name => 'Схема', :facade_count => 1
).run
plain_w = write_for(view.writes, 1, 'Схема')
check('Своя карта без стекла: одна карта',
      result.files.map { |f| File.basename(f) }.count { |n| n.end_with?('_Схема.png') } == 1,
      result.files.map { |f| File.basename(f) }.inspect)
check('Своя карта без стекла: ограждения скрыты',
      plain_w[:materials].find { |m| m[0] == 'Витрина' }[2] == 0.0)

# ------------------------------------- 9. экспорт из открытой группы (п. 4)

section 'Экспорт содержимого открытой группы'
clean_out
model = new_model
view = model.active_view
fresh_settings
sibling_a = Sketchup::Entity.new
sibling_b = Sketchup::Entity.new
definition = Sketchup::Definition.new(box_points(400, 300, 200))
Sketchup.test_box(definition.entities, 400, 300, 200)
instance = Sketchup::GroupInstance.new(definition, Geom::Transformation.new(1000, 1000, 0))
model.entities.add(sibling_a)
model.entities.add(sibling_b)
model.entities.add(instance)
model.active_path = [instance]
result = FacadeExport::Exporter.new(
  :model => model, :view => view, :settings => FacadeExport.settings,
  :directory => OUT_ROOT, :base_name => 'Группа', :facade_count => 4
).run
check('Ошибок нет', result.errors.empty?, result.errors.inspect)
check('Кадрируется только открытая группа', result.scope == :context, result.scope)
check('Файлов 16', result.files.length == 16, result.files.length)
check('Окружение скрыто на время экспорта',
      view.writes.all? { |w| w[:hidden].count(false) == 1 },
      view.writes.map { |w| w[:hidden] }.uniq.inspect)
check('Окружение возвращено после экспорта',
      model.entities.none? { |e| e.hidden? },
      model.entities.map { |e| e.hidden? }.inspect)
check('Кадр по группе: 4:3 (9999×7499)',
      view.writes.all? { |w| w[:width] == 9999 && w[:height] == 7499 })
cam_ctx = view.writes.first[:camera]
check_close('Камера смотрит в группу (цель по её центру X)', cam_ctx.target.x, 1200.0, 1.0)
check('Камера ближе, чем для всей модели', cam_ctx.height < 2000.0, cam_ctx.height)

# ------------------------------------------- 10. отключение карт и ошибки

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
model = new_model
view = model.active_view
fresh_settings
begin
  FacadeExport::Framing.facade_directions(
    Sketchup::Camera.new(Geom::Point3d.new(0, 0, 5000), Geom::Point3d.new(0, 0, 0),
                         Geom::Vector3d.new(0, 1, 0)), 4
  )
  check('Вид сверху -> понятная ошибка', false, 'исключение не возникло')
rescue FacadeExport::ExportError => e
  check('Вид сверху -> понятная ошибка', e.message.include?('перпендикулярно'), e.message)
end

begin
  FacadeExport::Exporter.new(
    :model => model, :view => view, :settings => FacadeExport.settings,
    :directory => nil, :base_name => 'Тест', :facade_count => 4
  ).run
  check('Без папки -> понятная ошибка', false, 'исключение не возникло')
rescue FacadeExport::ExportError => e
  check('Без папки -> понятная ошибка', e.message.include?('папка'), e.message)
end

fresh_settings
FacadeExport.settings.maps.each { |m| m['enabled'] = false }
begin
  FacadeExport::Exporter.new(
    :model => model, :view => view, :settings => FacadeExport.settings,
    :directory => OUT_ROOT, :base_name => 'Тест', :facade_count => 4
  ).run
  check('Все карты отключены -> понятная ошибка', false, 'исключение не возникло')
rescue FacadeExport::ExportError => e
  check('Все карты отключены -> понятная ошибка', e.message.include?('отключены'), e.message)
end

# --------------------------------------------- 11. выделение и аннотации

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

check('Плоскости сечений не рисуются', w0[:rendering]['DisplaySectionPlanes'] == false)
check('Направляющие скрыты всегда', w0[:rendering]['HideConstructionGeometry'] == true)
check('Небо и земля скрыты по умолчанию',
      w0[:rendering]['DrawSky'] == false && w0[:rendering]['DrawGround'] == false,
      [w0[:rendering]['DrawSky'], w0[:rendering]['DrawGround']].inspect)

clean_out
model = new_model
view = model.active_view
fresh_settings
FacadeExport.settings.set_export('hide_sky', false)
FacadeExport.settings.set_export('hide_ground', false)
FacadeExport::Exporter.new(
  :model => model, :view => view, :settings => FacadeExport.settings,
  :directory => OUT_ROOT, :base_name => 'Тест', :facade_count => 1
).run
check('Небо и землю можно вернуть',
      view.writes.first[:rendering]['DrawSky'] == true &&
      view.writes.first[:rendering]['DrawGround'] == true,
      [view.writes.first[:rendering]['DrawSky'], view.writes.first[:rendering]['DrawGround']].inspect)

# --------------------------------------------- 12. нажатие кнопок (main.rb)

section 'Кнопки плагина (меню, панель, экспорт по нажатию)'
FacadeExport.instance_variable_set(:@ui_registered, nil)
FacadeExport.register_ui
check('Меню/панель зарегистрированы', FacadeExport.instance_variable_get(:@ui_registered) == true)
commands = FacadeExport.instance_variable_get(:@commands)
check('Четыре команды (2 экспорта, настройки, о плагине)', commands.length == 4,
      commands.map(&:name).inspect)
check('Отсутствие файлов иконок не ломает регистрацию', FacadeExport::PATH.to_s.end_with?('facade_export'),
      FacadeExport::PATH.inspect)

clean_out
model = new_model
view = model.active_view
fresh_settings
UI.messages = []
# Имя, вписанное пользователем в окне сохранения, — префикс всех файлов (п. 10).
UI.savepanel_result = File.join(OUT_ROOT, 'Дом_Иванова.png')
FacadeExport.export_all_facades
files = Dir.entries(OUT_ROOT).select { |f| f.end_with?('.png') }
check('Кнопка "Экспорт всех фасадов" -> 16 файлов', files.length == 16, files.inspect)
check('Префикс из окна сохранения в именах файлов',
      files.include?('Дом_Иванова_Фасад_1_Текстура.png'), files.sort.inspect)
check('Отчёт показан пользователю',
      UI.messages.any? { |m| m.include?('Экспорт завершён') }, UI.messages.inspect)
check('Папка сохранена в настройках', FacadeExport.settings.exp('last_directory') == OUT_ROOT,
      FacadeExport.settings.exp('last_directory').inspect)
report = UI.messages.find { |m| m.include?('Экспорт завершён') }.to_s
check('В отчёте есть имена файлов', report.include?('Дом_Иванова_Фасад_1_Текстура.png'))
check('В отчёте есть среднее время', report.include?('В среднем на изображение'))

# Подтверждение перезаписи
clean_out
model = new_model
fresh_settings
UI.savepanel_result = File.join(OUT_ROOT, 'Заречная.png')
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

# --------------------------------------- 13. журнал «Отменить» после экспорта

section 'Экспорт не оставляет следов в журнале «Отменить»'
clean_out
model = new_model
view = model.active_view
fresh_settings
materials_before = model.materials.map { |m| [m.name, m.color.to_a, m.alpha] }
FacadeExport::Exporter.new(
  :model => model, :view => view, :settings => FacadeExport.settings,
  :directory => OUT_ROOT, :base_name => 'Отмена', :facade_count => 4
).run
check('Служебная операция открыта и отменена',
      model.operations.length == 1 && model.aborts == 1 && model.commits.zero?,
      [model.operations.length, model.aborts, model.commits].inspect)
check('Операция открыта без обновления интерфейса',
      model.operations.first[:disable_ui] == true, model.operations.first.inspect)
check('Материалы после экспорта такие же, как до него',
      model.materials.map { |m| [m.name, m.color.to_a, m.alpha] } == materials_before,
      model.materials.map { |m| [m.name, m.alpha] }.inspect)
check('Стиль после экспорта восстановлен',
      model.rendering_options['DrawSky'] == true && model.rendering_options['RenderMode'] == 2,
      model.rendering_options.to_h.inspect)

# ------------------------------- 14. одиночный фасад с подгонкой по всем фасадам

section 'Одиночный фасад: подгонка по самому большому фасаду'
clean_out
model = new_model
model.entities.clear
Sketchup.test_box(model.entities, 600, 3000, 500)
view = model.active_view
fresh_settings
FacadeExport.settings.set_export('fit_all_facades', false)
FacadeExport::Exporter.new(
  :model => model, :view => view, :settings => FacadeExport.settings,
  :directory => OUT_ROOT, :base_name => 'Один', :facade_count => 1
).run
height_off = view.writes.first[:camera].height
check('Без подгонки масштаб по текущему фасаду', view.writes.length == 4,
      view.writes.length)

clean_out
view.writes.clear
FacadeExport.settings.set_export('fit_all_facades', true)
result_one = FacadeExport::Exporter.new(
  :model => model, :view => view, :settings => FacadeExport.settings,
  :directory => OUT_ROOT, :base_name => 'Один', :facade_count => 1
).run
height_on = view.writes.first[:camera].height
check('С подгонкой кадр больше по самому большому фасаду',
      height_on > height_off * 4.0,
      [height_off, height_on].inspect)
check('С подгонкой всё равно один фасад', result_one.files.length == 4,
      result_one.files.length)
height_all = nil
clean_out
view.writes.clear
result_all = FacadeExport::Exporter.new(
  :model => model, :view => view, :settings => FacadeExport.settings,
  :directory => OUT_ROOT, :base_name => 'Все', :facade_count => 4
).run
height_all = view.writes.first[:camera].height
check('Масштаб одиночного кадра совпадает с полным экспортом',
      (height_on - height_all).abs < 1e-6, [height_on, height_all].inspect)
check('Полный экспорт не изменился (16 файлов)', result_all.files.length == 16,
      result_all.files.length)

# ------------------------------------- 15. файлы готовы к удалению (Windows)

section 'Файлы результата свободны (COM Surrogate)'
paths = result_all.files
check('Файлы лежат в папке результата',
      paths.all? { |f| File.dirname(f) == OUT_ROOT }, paths.first)
check('Файлы не пустые', paths.all? { |f| File.size(f).positive? }, paths.first)
check('PNG-подпись на месте',
      File.binread(paths.first, 8) == "\x89PNG\r\n\x1a\n".b,
      File.binread(paths.first, 8).inspect)
check('Временных файлов в папке не осталось',
      Dir.entries(OUT_ROOT).none? { |f| f.include?('.part') || f == '.facade_export_tmp' },
      Dir.entries(OUT_ROOT).inspect)
check('Пишем во временный файл, а не сразу в папку результата',
      view.writes.first[:path] != paths.first,
      [view.writes.first[:path], paths.first].inspect)

# ------------------------------ 16. карта окон не ищет окна, которых нет

section 'Карта окон: стекло ищется один раз'
model_plain = new_model
model_plain.materials = Sketchup::Materials.new(
  [Sketchup::Material.new('Кирпич', Sketchup::Color.new(180, 90, 70))]
)
view_plain = model_plain.active_view
fresh_settings
plain_exporter = FacadeExport::Exporter.new(
  :model => model_plain, :view => view_plain, :settings => FacadeExport.settings,
  :directory => OUT_ROOT, :base_name => 'Без стекла', :facade_count => 1
)
check('Стекла в модели нет — список пуст', plain_exporter.send(:glass_entries).empty?,
      plain_exporter.send(:glass_entries).inspect)
windows_job = FacadeExport::Exporter.output_jobs(FacadeExport.settings)
                             .find { |j| j.map['kind'] == 'windows' }
check('Карта окон без стекла ничего не перекрашивает',
      plain_exporter.send(:glass_needed?, windows_job) == false)
clean_out
plain_result = plain_exporter.run
check('Экспорт без стекла проходит', plain_result.errors.empty?, plain_result.errors.inspect)

model_glass = new_model
view_glass = model_glass.active_view
glass_exporter = FacadeExport::Exporter.new(
  :model => model_glass, :view => view_glass, :settings => FacadeExport.settings,
  :directory => OUT_ROOT, :base_name => 'Стекло', :facade_count => 1
)
entries = glass_exporter.send(:glass_entries)
check('Стеклянные материалы найдены', entries.length == 3,
      entries.map { |e| [e.material.name, e.type] }.inspect)
check('Типы стекла определены верно',
      entries.map(&:type).sort == %w[main railing tinted],
      entries.map(&:type).inspect)
check('Список стекла кэшируется',
      glass_exporter.send(:glass_entries).equal?(entries))
check('Раздельная карта: нет своего типа — ничего не делает',
      glass_exporter.send(:glass_needed?,
                          FacadeExport::Exporter::Job.new(FacadeExport.settings.map('windows'), 'tinted', 'x')) == true)
check('Скрытие ограждений при наличии стекла включается',
      glass_exporter.send(:glass_needed?,
                          FacadeExport::Exporter::Job.new(FacadeExport.settings.map('texture'), 'hide_railings', 'x')) == true)
check('Ограждения без стекла не трогаются',
      plain_exporter.send(:glass_needed?,
                          FacadeExport::Exporter::Job.new(FacadeExport.settings.map('texture'), 'hide_railings', 'x')) == false)

# ------------------------- 17. порядок работы: карта → фасады (скорость)

section 'Порядок работы: стиль и стекло — один раз на карту'
module CountGlassApplies
  def apply
    $glass_applies = ($glass_applies || 0) + 1
    super
  end
end
FacadeExport::GlassRecolor.prepend(CountGlassApplies)

clean_out
model = new_model
view = model.active_view
fresh_settings
$glass_applies = 0
FacadeExport::Exporter.new(
  :model => model, :view => view, :settings => FacadeExport.settings,
  :directory => OUT_ROOT, :base_name => 'Порядок', :facade_count => 4
).run
check('Стекло перекрашивается один раз на карту, а не на фасад',
      $glass_applies == 4, $glass_applies)
check('Сначала снимаются все фасады одной карты',
      view.writes.first(4).all? { |w| w[:path].end_with?('_Текстура.png') },
      view.writes.first(4).map { |w| File.basename(w[:path]) }.inspect)
check('Номер фасада идёт по порядку внутри карты',
      view.writes.first(4).map { |w| w[:path][/Фасад_(\d)/, 1].to_i } == [1, 2, 3, 4],
      view.writes.first(4).map { |w| w[:path][/Фасад_(\d)/, 1] }.inspect)
check('Тени ставятся для каждого фасада отдельно',
      view.writes.select { |w| w[:path].end_with?('_Тени.png') }
                 .map { |w| w[:shadow]['SunDirection'].to_a.map { |v| v.round(3) } }.uniq.length == 4,
      view.writes.select { |w| w[:path].end_with?('_Тени.png') }
                 .map { |w| w[:shadow]['SunDirection'].to_a.map { |v| v.round(3) } }.inspect)

clean_out
model = new_model
model.materials = Sketchup::Materials.new(
  [Sketchup::Material.new('Кирпич', Sketchup::Color.new(180, 90, 70))]
)
view = model.active_view
fresh_settings
$glass_applies = 0
FacadeExport::Exporter.new(
  :model => model, :view => view, :settings => FacadeExport.settings,
  :directory => OUT_ROOT, :base_name => 'Пусто', :facade_count => 4
).run
check('Без стекла перекраска не запускается ни разу', $glass_applies.zero?, $glass_applies)

# ------------------------------------------------------------------ итог

puts
puts "Проверок: #{$checks}, провалов: #{$failures}"
exit($failures.zero? ? 0 : 1)
