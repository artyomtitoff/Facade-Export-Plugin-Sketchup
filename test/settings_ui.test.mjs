// Проверка окна настроек (facade_export/html/settings.html) без SketchUp:
// страница открывается в jsdom, эмулируется объект `sketchup` из UI::HtmlDialog.
//
//   node test/settings_ui.test.mjs

import fs from "node:fs/promises";
import path from "node:path";
import { JSDOM } from "jsdom";

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");

let failures = 0;
function check(title, condition, details) {
  if (condition) {
    console.log(`  ok   ${title}`);
  } else {
    failures += 1;
    console.log(`  FAIL ${title}`);
    if (details !== undefined) console.log(`       ${details}`);
  }
}

// Настройки «по умолчанию» — как их отдаёт Ruby (Config.default_settings).
const defaults = {
  version: 1,
  export: {
    use_view_size: false, width: 9999, height: 0, antialias: false, transparent: true,
    line_scale: 0.3, margin: 0.04, perspective: false, background: "#FFFFFF",
    show_sky: false, show_ground: false, hide_guides: true, hide_annotations: true,
    hide_watermarks: true, disable_section_cuts: true, shadow_light: 100, shadow_dark: 0,
    sun_for_shading: false, restore_view: true, show_report: true, last_directory: "",
  },
  maps: [
    {
      key: "texture", title: "Текстура", enabled: true, render_mode: "shaded", textures: true,
      edges: false, shadows: false, material_transparency: false, sun_for_shading: false,
      shadow_light: 100, shadow_dark: 0, shadow_azimuth: 45, shadow_elevation: 45,
      highlight_transparent: false, glass_h: 125, glass_s: 100, glass_l: 50,
    },
    {
      key: "lines", title: "Линии", enabled: true, render_mode: "hidden", textures: false,
      edges: true, shadows: false, material_transparency: false, sun_for_shading: false,
      shadow_light: 100, shadow_dark: 0, shadow_azimuth: 45, shadow_elevation: 45,
      highlight_transparent: false, glass_h: 125, glass_s: 100, glass_l: 50,
    },
    {
      key: "shadows", title: "Тени", enabled: true, render_mode: "hidden", textures: false,
      edges: false, shadows: true, material_transparency: false, sun_for_shading: false,
      shadow_light: 100, shadow_dark: 0, shadow_azimuth: 45, shadow_elevation: 45,
      highlight_transparent: false, glass_h: 125, glass_s: 100, glass_l: 50,
    },
    {
      key: "windows", title: "Окна", enabled: true, render_mode: "shaded", textures: false,
      edges: false, shadows: false, material_transparency: false, sun_for_shading: false,
      shadow_light: 100, shadow_dark: 0, shadow_azimuth: 45, shadow_elevation: 45,
      highlight_transparent: true, glass_h: 125, glass_s: 100, glass_l: 50,
    },
  ],
};

const html = await fs.readFile(path.join(root, "facade_export/html/settings.html"), "utf8");
const dom = new JSDOM(html, { runScripts: "dangerously", pretendToBeVisual: true });

const { window } = dom;
const calls = { ready: 0, save: null, reset: 0, cancel: 0 };

// Эмуляция моста UI::HtmlDialog: sketchup.<callback>(arg).
window.sketchup = {
  ready() {
    calls.ready += 1;
    window.FacadeExport.setSettings(JSON.stringify(defaults));
  },
  save(json) { calls.save = json; },
  reset() { calls.reset += 1; },
  cancel() { calls.cancel += 1; },
};

window.document.dispatchEvent(new window.Event("DOMContentLoaded", { bubbles: true }));

const doc = window.document;
const q = (sel) => doc.querySelector(sel);
const byPath = (p) => doc.querySelector(`[data-path="${p}"]`);

console.log("Окно настроек (settings.html):");
check("Руби-мост вызвал ready", calls.ready === 1);
check("Вкладки построены", doc.querySelectorAll("nav button").length === 5,
  doc.querySelectorAll("nav button").length);
check("Названия вкладок", [...doc.querySelectorAll("nav button")].map((b) => b.textContent).join("|")
  === "Экспорт|Текстура|Линии|Тени|Окна");
check("Ширина 9999 из настроек", byPath("export.width")?.value === "9999", byPath("export.width")?.value);
check("Высота 0 (авто)", byPath("export.height")?.value === "0");
check("Множитель линий 0.3", byPath("export.line_scale")?.value === "0.3");
check("Прозрачный фон включён", byPath("export.transparent")?.checked === true);
check("Сглаживание выключено", byPath("export.antialias")?.checked === false);
check("Размер вида не используется (ширина из поля)", byPath("export.use_view_size")?.checked === false);
check("Карта «Тени»: тени включены", byPath("maps.2.shadows")?.checked === true);
check("Карта «Тени»: режим = скрытые линии", byPath("maps.2.render_mode")?.value === "hidden");
check("Карта «Окна»: перекраска включена", byPath("maps.3.highlight_transparent")?.checked === true);
check("Карта «Текстура»: текстуры включены", byPath("maps.0.textures")?.checked === true);
check("Карта «Линии»: края включены", byPath("maps.1.edges")?.checked === true);
check("Цвет стекла H=125", byPath("maps.3.glass_h")?.value === "125");
check("Палитра цвета отрисована",
  /rgb\(/.test(q("#swatch-3")?.style.background || ""), q("#swatch-3")?.style.background);

// Переключение вкладок
const tabButtons = doc.querySelectorAll("nav button");
check("Первая вкладка активна", tabButtons[0].classList.contains("active"));
tabButtons[2].dispatchEvent(new window.Event("click", { bubbles: true }));
check("По клику открывается вкладка карты",
  doc.getElementById("tab-map-1")?.classList.contains("active"));
check("Активная вкладка подсвечена", tabButtons[2].classList.contains("active"));

// Изменение и сохранение
byPath("export.width").value = "12000";
byPath("maps.1.edges").checked = false;
byPath("maps.3.glass_h").value = "200";
doc.getElementById("btn-save").dispatchEvent(new window.Event("click", { bubbles: true }));

check("По «Сохранить» вызван Ruby-callback", typeof calls.save === "string");
let saved = null;
try { saved = JSON.parse(calls.save); } catch (e) { saved = null; }
check("JSON сохраняется корректно", saved !== null);
check("Изменённая ширина попала в JSON", saved?.export?.width === 12000, saved?.export?.width);
check("Все поля карт сохранены", saved?.maps?.length === 4, saved?.maps?.length);
check("Изменённая карта сохранена", saved?.maps?.[1]?.edges === false);
check("Цвет стекла сохранён", saved?.maps?.[3]?.glass_h === 200);
check("Остальные значения не потеряны", saved?.maps?.[2]?.shadows === true && saved?.export?.line_scale === 0.3);

doc.getElementById("btn-reset").dispatchEvent(new window.Event("click", { bubbles: true }));
check("По «Вернуть значения по умолчанию» вызван Ruby-callback", calls.reset === 1);

doc.getElementById("btn-cancel").dispatchEvent(new window.Event("click", { bubbles: true }));
check("По «Отмена» вызван Ruby-callback", calls.cancel === 1);

console.log(failures === 0 ? "\nОкно настроек: всё в порядке" : `\nОкно настроек: провалов ${failures}`);
process.exit(failures === 0 ? 0 : 1);
