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
  version: 3,
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
      glass_highlight: false,
      shadow_light: 100, shadow_dark: 0, shadow_azimuth: 45, shadow_elevation: 45, ...glassDefaults,
    },
    {
      key: "lines", kind: "standard", title: "Линии", enabled: true, render_mode: "hidden",
      textures: false, edges: true, shadows: false, material_transparency: false, split_windows: false,
      glass_highlight: false,
      shadow_light: 100, shadow_dark: 0, shadow_azimuth: 45, shadow_elevation: 45, ...glassDefaults,
    },
    {
      key: "shadows", kind: "standard", title: "Тени", enabled: true, render_mode: "hidden",
      textures: false, edges: false, shadows: true, material_transparency: false, split_windows: false,
      glass_highlight: false,
      shadow_light: 100, shadow_dark: 0, shadow_azimuth: 45, shadow_elevation: 45, ...glassDefaults,
    },
    {
      key: "windows", kind: "windows", title: "Окна", enabled: true, render_mode: "shaded",
      textures: true, edges: false, shadows: false, material_transparency: false, split_windows: false,
      glass_highlight: true,
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
const fire = (el, type) => el.dispatchEvent(new window.Event(type, { bubbles: true }));
const isHidden = (el) => !!el.closest(".is-hidden");

console.log("Окно настроек (settings.html):");
check("Руби-мост вызвал ready", calls.ready === 1);
check("Вкладки построены: Экспорт + 4 карты", doc.querySelectorAll("nav button[data-tab]").length === 5,
  doc.querySelectorAll("nav button[data-tab]").length);
check("Названия вкладок", [...doc.querySelectorAll("nav button[data-tab]")].map((b) => b.textContent).join("|")
  === "Экспорт|Текстура|Линии|Тени|Окна",
  [...doc.querySelectorAll("nav button[data-tab]")].map((b) => b.textContent).join("|"));
check("Есть кнопка «+» для своей карты", !!q("nav button[data-add-map]"));

/* ------------------------------------------- вкладка «Экспорт» */

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
check("Ширина: максимум 9999", byPath("export.width")?.getAttribute("max") === "9999");
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

/* ------------------------------------------------ вкладка карты */

const mapTab = q("#tab-map-2");
check("Карта: нет блока «Расширенные настройки»", !mapTab.querySelector("details.adv"));
const visibleMap = [...mapTab.querySelectorAll("input, select")].filter((el) => !el.closest(".dep"));
const visibleMapPaths = visibleMap.map((el) => el.getAttribute("data-path"));
check("Карта: основных полей 6 (имя, режим, экспорт, края, тени, прозрачность)",
  visibleMap.length === 6, visibleMapPaths.join(", "));
check("Карта: «Прозрачность материала» среди основных полей",
  visibleMapPaths.includes("maps.2.material_transparency"), visibleMapPaths.join(", "));
check("Карта «Тени»: тени включены", byPath("maps.2.shadows")?.checked === true);
check("Карта «Тени»: режим = скрытые линии", byPath("maps.2.render_mode")?.value === "hidden");
check("Карта «Тени»: «Прозрачность материала» в основных настройках",
  byPath("maps.2.material_transparency")?.closest(".dep") === null);
check("Карта «Тени»: светлее/темнее показаны при включённых тенях",
  byPath("maps.2.shadow_light")?.value === "100" && !isHidden(byPath("maps.2.shadow_light")));

/* --------------------------- п. 2: настройки теней только при флажке */

check("Карта «Текстура»: тени выключены — настройки теней скрыты",
  byPath("maps.0.shadows")?.checked === false && isHidden(byPath("maps.0.shadow_light")),
  isHidden(byPath("maps.0.shadow_light")));
byPath("maps.0.shadows").checked = true;
fire(byPath("maps.0.shadows"), "change");
check("Включили «Тени» — настройки теней появились", !isHidden(byPath("maps.0.shadow_light")));
byPath("maps.0.shadows").checked = false;
fire(byPath("maps.0.shadows"), "change");
check("Сняли «Тени» — настройки теней снова скрыты", isHidden(byPath("maps.0.shadow_light")));

/* ------------------------------- п. 3: нет настройки «Текстуры» */

check("Ни на одной вкладке карты нет поля «Текстуры»",
  doc.querySelectorAll('[data-path$=".textures"]').length === 0,
  doc.querySelectorAll('[data-path$=".textures"]').length);
check("Карта «Текстура»: режим затенения (текстуры сами)",
  byPath("maps.0.render_mode")?.value === "shaded");
byPath("maps.0.render_mode").value = "hidden";

/* ------------------------------------- окна: настройки отображения */

const windowsTab = q("#tab-map-3");
check("Карта «Окна»: блок «Настройки отображения окон»",
  windowsTab.textContent.includes("Настройки отображения окон"));
check("Карта «Окна»: нет слова «Расширенные настройки»",
  !windowsTab.textContent.includes("Расширенные настройки"));
check("Карта «Окна»: разделение по типам стекла есть и выключено",
  byPath("maps.3.split_windows")?.checked === false);
check("Стекло: основное H=125", byPath("maps.3.main_h")?.value === "125");
check("Стекло: тонировка H=180", byPath("maps.3.tinted_h")?.value === "180");
check("Стекло: ограждения H=300", byPath("maps.3.railing_h")?.value === "300");
check("Палитра основного стекла отрисована",
  /rgb\(/.test(q("#swatch-3-main")?.style.background || ""), q("#swatch-3-main")?.style.background);
check("Палитра ограждений отрисована",
  /rgb\(/.test(q("#swatch-3-railing")?.style.background || ""), q("#swatch-3-railing")?.style.background);

/* ------------------------------------ п. 8: расклеенные колонки */

const css = html.slice(html.indexOf("<style>"), html.indexOf("</style>"));
const gapMatch = /column-gap:\s*(\d+)px/.exec(css);
check("Двухколоночная сетка: зазор между столбцами ≥ 32 px",
  gapMatch !== null && Number(gapMatch[1]) >= 32, gapMatch && gapMatch[0]);
check("Подвал не сжимается: footer с flex 0 0 auto",
  /footer\s*\{[^}]*flex:\s*0 0 auto/.test(css.replace(/\n/g, " ")));
check("Прокручивается только содержимое (main с min-height 0)",
  /main\s*\{[^}]*min-height:\s*0/.test(css.replace(/\n/g, " ")));

/* --------------------------------------------- переключение вкладок */

const tabButtons = doc.querySelectorAll("nav button[data-tab]");
check("Первая вкладка активна", tabButtons[0].classList.contains("active"));
fire(tabButtons[2], "click");
check("По клику открывается вкладка карты", doc.getElementById("tab-map-1")?.classList.contains("active"));
check("Активная вкладка подсвечена", tabButtons[2].classList.contains("active"));

/* --------------------------------------------- изменение и сохранение */

byPath("export.width").value = "12000";
byPath("export.projection").checked = false;
byPath("maps.1.edges").checked = false;
byPath("maps.3.main_h").value = "200";
fire(doc.getElementById("btn-save"), "click");

check("По «Сохранить» вызван Ruby-callback", typeof calls.save === "string");
let saved = null;
try { saved = JSON.parse(calls.save); } catch (e) { saved = null; }
check("JSON сохраняется корректно", saved !== null);
check("Изменённая ширина попала в JSON", saved?.export?.width === 12000, saved?.export?.width);
check("Снятая галочка проекции -> perspective", saved?.export?.projection === "perspective",
  saved?.export?.projection);
check("Все поля карт сохранены", saved?.maps?.length === 4, saved?.maps?.length);
check("Изменённая карта сохранена", saved?.maps?.[1]?.edges === false);
check("Цвет стекла сохранён", saved?.maps?.[3]?.main_h === 200);
check("Текстуры выводятся из режима: «Скрытые линии» -> false",
  saved?.maps?.[0]?.textures === false, saved?.maps?.[0]?.textures);
check("Текстуры выводятся из режима: «Затенение» -> true",
  saved?.maps?.[2]?.textures === false && saved?.maps?.[3]?.textures === true,
  `${saved?.maps?.[2]?.textures} / ${saved?.maps?.[3]?.textures}`);
check("Остальные значения не потеряны",
  saved?.maps?.[2]?.shadows === true && saved?.export?.line_scale === 0.3 &&
  saved?.maps?.[3]?.split_windows === false);

/* ---------------------------------------------- своя карта (п. 4, 13) */

fire(q("nav button[data-add-map]"), "click");
check("Кнопка «+» добавляет вкладку", doc.querySelectorAll("nav button[data-tab]").length === 6,
  doc.querySelectorAll("nav button[data-tab]").length);
const customTab = doc.querySelector("nav button[data-tab='map-4']");
check("Новая вкладка называется «Своя карта 1»", customTab?.textContent === "Своя карта 1",
  customTab?.textContent);
check("Новая вкладка активна", customTab?.classList.contains("active"));
check("Своя карта: есть основные настройки",
  !!byPath("maps.4.title") && !!byPath("maps.4.render_mode") &&
  !!byPath("maps.4.edges") && !!byPath("maps.4.shadows") &&
  !!byPath("maps.4.material_transparency"));
check("Своя карта: блок «Окна и стекло»",
  doc.getElementById("tab-map-4").textContent.includes("Окна и стекло"));
check("Своя карта: перекраска стекла выключена по умолчанию",
  byPath("maps.4.glass_highlight")?.checked === false);
check("Своя карта: цвета стекла скрыты, пока нет перекраски",
  isHidden(byPath("maps.4.main_h")));
byPath("maps.4.glass_highlight").checked = true;
fire(byPath("maps.4.glass_highlight"), "change");
check("Включили перекраску — появились типы стекла и цвета",
  !isHidden(byPath("maps.4.main_h")) && !isHidden(byPath("maps.4.split_windows")));
check("Своя карта: есть кнопка удаления", !!q("button[data-remove-map='4']"));
check("Своя карта: настройки теней скрыты при выключенных тенях",
  isHidden(byPath("maps.4.shadow_light")));

byPath("maps.4.title").value = "Фасад в цвете";
fire(byPath("maps.4.title"), "input");
check("Название вкладки обновляется на лету",
  doc.querySelector("nav button[data-tab='map-4']")?.textContent === "Фасад в цвете",
  doc.querySelector("nav button[data-tab='map-4']")?.textContent);
byPath("maps.4.render_mode").value = "wireframe";
byPath("maps.4.shadows").checked = true;
fire(byPath("maps.4.shadows"), "change");
byPath("maps.4.shadow_light").value = "80";
byPath("maps.4.tinted_h").value = "210";

fire(doc.getElementById("btn-save"), "click");
saved = JSON.parse(calls.save);
check("Своя карта сохраняется", saved?.maps?.length === 5, saved?.maps?.length);
check("Своя карта: вид custom", saved?.maps?.[4]?.kind === "custom", saved?.maps?.[4]?.kind);
check("Своя карта: название и режим сохранены",
  saved?.maps?.[4]?.title === "Фасад в цвете" && saved?.maps?.[4]?.render_mode === "wireframe",
  `${saved?.maps?.[4]?.title} / ${saved?.maps?.[4]?.render_mode}`);
check("Своя карта: готова к экспорту", saved?.maps?.[4]?.enabled === true);
check("Своя карта: тени и их настройки сохранены",
  saved?.maps?.[4]?.shadows === true && saved?.maps?.[4]?.shadow_light === 80,
  `${saved?.maps?.[4]?.shadows} / ${saved?.maps?.[4]?.shadow_light}`);
check("Своя карта: перекраска стекла и цвет сохранены",
  saved?.maps?.[4]?.glass_highlight === true && saved?.maps?.[4]?.tinted_h === 210,
  `${saved?.maps?.[4]?.glass_highlight} / ${saved?.maps?.[4]?.tinted_h}`);
check("Своя карта: текстуры выключены для каркаса", saved?.maps?.[4]?.textures === false);

fire(q("button[data-remove-map='4']"), "click");
check("Кнопка удаления убирает карту", doc.querySelectorAll("nav button[data-tab]").length === 5,
  doc.querySelectorAll("nav button[data-tab]").length);
fire(doc.getElementById("btn-save"), "click");
saved = JSON.parse(calls.save);
check("После удаления карта не сохраняется", saved?.maps?.length === 4, saved?.maps?.length);

fire(doc.getElementById("btn-reset"), "click");
check("По «Вернуть значения по умолчанию» вызван Ruby-callback", calls.reset === 1);

fire(doc.getElementById("btn-cancel"), "click");
check("По «Отмена» вызван Ruby-callback", calls.cancel === 1);

console.log(failures === 0 ? "\nОкно настроек: всё в порядке" : `\nОкно настроек: провалов ${failures}`);
process.exit(failures === 0 ? 0 : 1);
