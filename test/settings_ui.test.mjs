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

const glassDefaults = {
  main_h: 125, main_s: 100, main_l: 50,
  tinted_h: 180, tinted_s: 100, tinted_l: 50,
  railing_h: 300, railing_s: 100, railing_l: 50,
};

// Настройки «по умолчанию» — как их отдаёт Ruby (Config.default_settings).
const defaults = {
  version: 2,
  export: {
    width: 9999, height: 0, line_scale: 0.3, margin: 0.02,
    restore_view: true, show_report: true,
    aspect: "4:3", projection: "parallel", sun_for_shading: false,
    use_view_size: false, antialias: false, transparent: true, background: "#FFFFFF",
    show_sky: false, show_ground: false, hide_guides: true, hide_annotations: true,
    hide_watermarks: true, show_section_planes: false, last_directory: "",
  },
  maps: [
    {
      key: "texture", kind: "standard", title: "Текстура", enabled: true, render_mode: "shaded",
      textures: true, edges: false, shadows: false, material_transparency: false, split_windows: false,
      shadow_light: 100, shadow_dark: 0, shadow_azimuth: 45, shadow_elevation: 45, ...glassDefaults,
    },
    {
      key: "lines", kind: "standard", title: "Линии", enabled: true, render_mode: "hidden",
      textures: false, edges: true, shadows: false, material_transparency: false, split_windows: false,
      shadow_light: 100, shadow_dark: 0, shadow_azimuth: 45, shadow_elevation: 45, ...glassDefaults,
    },
    {
      key: "shadows", kind: "standard", title: "Тени", enabled: true, render_mode: "hidden",
      textures: false, edges: false, shadows: true, material_transparency: false, split_windows: false,
      shadow_light: 100, shadow_dark: 0, shadow_azimuth: 45, shadow_elevation: 45, ...glassDefaults,
    },
    {
      key: "windows", kind: "windows", title: "Окна", enabled: true, render_mode: "shaded",
      textures: false, edges: false, shadows: false, material_transparency: false, split_windows: false,
      shadow_light: 100, shadow_dark: 0, shadow_azimuth: 45, shadow_elevation: 45, ...glassDefaults,
    },
  ],
};

const html = await fs.readFile(path.join(root, "facade_export/html/settings.html"), "utf8");
const dom = new JSDOM(html, { runScripts: "dangerously", pretendToBeVisual: true });

const { window } = dom;
const calls = { ready: 0, save: null, reset: 0, cancel: 0 };

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
check("Вкладки построены: Экспорт + 4 карты", doc.querySelectorAll("nav button[data-tab]").length === 5,
  doc.querySelectorAll("nav button[data-tab]").length);
check("Названия вкладок", [...doc.querySelectorAll("nav button[data-tab]")].map((b) => b.textContent).join("|")
  === "Экспорт|Текстура|Линии|Тени|Окна",
  [...doc.querySelectorAll("nav button[data-tab]")].map((b) => b.textContent).join("|"));
check("Есть кнопка «+» для своей карты", !!q("nav button[data-add-map]"));

// --- вкладка «Экспорт»: только основные поля видны сразу
const exportTab = q("#tab-export");
const visibleExport = [...exportTab.querySelectorAll("input, select")]
  .filter((el) => !el.closest("details.adv"));
const visiblePaths = visibleExport.map((el) => el.getAttribute("data-path"));
check("Экспорт: видимых полей 6", visibleExport.length === 6, visiblePaths.join(", "));
check("Экспорт: видны ширина/высота/линии/отступ",
  ["export.width", "export.height", "export.line_scale", "export.margin"].every((p) => visiblePaths.includes(p)),
  visiblePaths.join(", "));
check("Экспорт: видны возврат вида и отчёт",
  visiblePaths.includes("export.restore_view") && visiblePaths.includes("export.show_report"));
check("Ширина 9999 из настроек", byPath("export.width")?.value === "9999", byPath("export.width")?.value);
check("Ширина: максимум 9999 в подсказке", byPath("export.width")?.getAttribute("max") === "9999");
check("Высота 0 (авто)", byPath("export.height")?.value === "0");
check("Множитель линий 0.3", byPath("export.line_scale")?.value === "0.3");
check("Отступ 0.02", byPath("export.margin")?.value === "0.02");
check("Параллельная проекция включена", byPath("export.projection")?.checked === true);
check("Солнце для затенения только на вкладке «Экспорт»",
  !!byPath("export.sun_for_shading") && !doc.querySelector('[data-path^="maps."][data-path$="sun_for_shading"]'));
check("Светлее/темнее больше нет на вкладке «Экспорт»",
  !byPath("export.shadow_light") && !byPath("export.shadow_dark"));
check("Параметры кадра спрятаны в «Расширенные настройки»",
  !!exportTab.querySelector("details.adv") && byPath("export.aspect")?.closest("details.adv") !== null);
check("Соотношение сторон по умолчанию 4:3", byPath("export.aspect")?.value === "4:3");
check("Нет формулировки «по заданию»", !doc.body.textContent.includes("по заданию"));

// --- вкладка карты: только имя, режим, экспорт, края, тени
const mapTab = q("#tab-map-2");
const visibleMap = [...mapTab.querySelectorAll("input, select")]
  .filter((el) => !el.closest("details.adv"));
const visibleMapPaths = visibleMap.map((el) => el.getAttribute("data-path"));
check("Карта: видимых полей 5", visibleMap.length === 5, visibleMapPaths.join(", "));
check("Карта «Тени»: тени включены", byPath("maps.2.shadows")?.checked === true);
check("Карта «Тени»: режим = скрытые линии", byPath("maps.2.render_mode")?.value === "hidden");
check("Карта «Тени»: текстуры спрятаны в расширенные",
  byPath("maps.2.textures")?.closest("details.adv") !== null);
check("Карта «Тени»: светлее/темнее в расширенных настройках",
  byPath("maps.2.shadow_light")?.value === "100" && byPath("maps.2.shadow_dark")?.value === "0");
check("Карта «Текстура»: текстуры включены", byPath("maps.0.textures")?.checked === true);
check("Карта «Линии»: края включены", byPath("maps.1.edges")?.checked === true);

// --- стекло
check("Карта «Окна»: разделение по типам стекла есть и выключено",
  byPath("maps.3.split_windows")?.checked === false);
check("Стекло: основное H=125", byPath("maps.3.main_h")?.value === "125");
check("Стекло: тонировка H=180", byPath("maps.3.tinted_h")?.value === "180");
check("Стекло: ограждения H=300", byPath("maps.3.railing_h")?.value === "300");
check("Палитра основного стекла отрисована",
  /rgb\(/.test(q("#swatch-3-main")?.style.background || ""), q("#swatch-3-main")?.style.background);
check("Палитра ограждений отрисована",
  /rgb\(/.test(q("#swatch-3-railing")?.style.background || ""), q("#swatch-3-railing")?.style.background);
check("У стандартных карт нет кнопки удаления", !q("button[data-remove-map]"));

// Переключение вкладок
const tabButtons = doc.querySelectorAll("nav button[data-tab]");
check("Первая вкладка активна", tabButtons[0].classList.contains("active"));
tabButtons[2].dispatchEvent(new window.Event("click", { bubbles: true }));
check("По клику открывается вкладка карты",
  doc.getElementById("tab-map-1")?.classList.contains("active"));
check("Активная вкладка подсвечена", tabButtons[2].classList.contains("active"));

// --- изменение и сохранение
byPath("export.width").value = "12000";
byPath("export.projection").checked = false;
byPath("maps.1.edges").checked = false;
byPath("maps.3.main_h").value = "200";
doc.getElementById("btn-save").dispatchEvent(new window.Event("click", { bubbles: true }));

check("По «Сохранить» вызван Ruby-callback", typeof calls.save === "string");
let saved = null;
try { saved = JSON.parse(calls.save); } catch (e) { saved = null; }
check("JSON сохраняется корректно", saved !== null);
check("Изменённая ширина попала в JSON", saved?.export?.width === 12000, saved?.export?.width);
check("Снятая галочка проекции -> perspective", saved?.export?.projection === "perspective",
  saved?.export?.projection);
check("Соотношение сторон сохранено", saved?.export?.aspect === "4:3");
check("Все поля карт сохранены", saved?.maps?.length === 4, saved?.maps?.length);
check("Изменённая карта сохранена", saved?.maps?.[1]?.edges === false);
check("Цвет стекла сохранён", saved?.maps?.[3]?.main_h === 200);
check("Остальные значения не потеряны",
  saved?.maps?.[2]?.shadows === true && saved?.export?.line_scale === 0.3 &&
  saved?.maps?.[3]?.split_windows === false);

// --- своя карта (п. 13)
q("nav button[data-add-map]").dispatchEvent(new window.Event("click", { bubbles: true }));
check("Кнопка «+» добавляет вкладку", doc.querySelectorAll("nav button[data-tab]").length === 6,
  doc.querySelectorAll("nav button[data-tab]").length);
const customTab = doc.querySelector("nav button[data-tab='map-4']");
check("Новая вкладка называется «Своя карта 1»", customTab?.textContent === "Своя карта 1",
  customTab?.textContent);
check("Новая вкладка активна", customTab?.classList.contains("active"));
check("Своя карта: все поля редактируемы",
  !!byPath("maps.4.title") && !!byPath("maps.4.render_mode") &&
  !!byPath("maps.4.textures") && !!byPath("maps.4.shadows") &&
  !!byPath("maps.4.shadow_light"));
check("Своя карта: есть кнопка удаления", !!q("button[data-remove-map='4']"));
byPath("maps.4.title").value = "Фасад в цвете";
byPath("maps.4.title").dispatchEvent(new window.Event("input", { bubbles: true }));
check("Название вкладки обновляется на лету",
  doc.querySelector("nav button[data-tab='map-4']")?.textContent === "Фасад в цвете",
  doc.querySelector("nav button[data-tab='map-4']")?.textContent);
byPath("maps.4.render_mode").value = "wireframe";

doc.getElementById("btn-save").dispatchEvent(new window.Event("click", { bubbles: true }));
saved = JSON.parse(calls.save);
check("Своя карта сохраняется", saved?.maps?.length === 5, saved?.maps?.length);
check("Своя карта: вид custom", saved?.maps?.[4]?.kind === "custom", saved?.maps?.[4]?.kind);
check("Своя карта: название и режим сохранены",
  saved?.maps?.[4]?.title === "Фасад в цвете" && saved?.maps?.[4]?.render_mode === "wireframe",
  `${saved?.maps?.[4]?.title} / ${saved?.maps?.[4]?.render_mode}`);
check("Своя карта: готова к экспорту", saved?.maps?.[4]?.enabled === true);

q("button[data-remove-map='4']").dispatchEvent(new window.Event("click", { bubbles: true }));
check("Кнопка удаления убирает карту", doc.querySelectorAll("nav button[data-tab]").length === 5,
  doc.querySelectorAll("nav button[data-tab]").length);
doc.getElementById("btn-save").dispatchEvent(new window.Event("click", { bubbles: true }));
saved = JSON.parse(calls.save);
check("После удаления карта не сохраняется", saved?.maps?.length === 4, saved?.maps?.length);

doc.getElementById("btn-reset").dispatchEvent(new window.Event("click", { bubbles: true }));
check("По «Вернуть значения по умолчанию» вызван Ruby-callback", calls.reset === 1);

doc.getElementById("btn-cancel").dispatchEvent(new window.Event("click", { bubbles: true }));
check("По «Отмена» вызван Ruby-callback", calls.cancel === 1);

console.log(failures === 0 ? "\nОкно настроек: всё в порядке" : `\nОкно настроек: провалов ${failures}`);
process.exit(failures === 0 ? 0 : 1);
