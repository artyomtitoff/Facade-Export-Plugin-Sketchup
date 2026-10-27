// Проверка окна автоматического вывода (facade_export/html/auto.html) без SketchUp:
// страница открывается в jsdom, эмулируется объект `sketchup` из UI::HtmlDialog.
//
// Окно новое: превью фасадов нет, вместо них — одна схема здания сверху
// («жучок») с переключаемыми стенами и компактный список фасадов.
//
//   node test/auto_ui.test.mjs

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

const GRID = 40;
const courtyardX = [16, 26];
const courtyardY = [18, 39];

// Данные, которые Ruby отдаёт в окно (AutoExport.build_payload).
const payload = {
  scope: "model",
  plan: {
    grid: GRID,
    cells: (() => {
      // П-образный план: внутренний двор (16..26 по X, 18..39 по Y) пустой.
      const cells = [];
      for (let y = 0; y < GRID; y++) {
        for (let x = 0; x < GRID; x++) {
          const courtyard = x >= courtyardX[0] && x <= courtyardX[1] &&
            y >= courtyardY[0] && y <= courtyardY[1];
          if (!courtyard) cells.push([x, y]);
        }
      }
      return cells;
    })(),
  },
  aspects: [
    ["3:4", "3:4 (по умолчанию)"],
    ["2:3", "2:3"],
    ["9:16", "9:16"],
    ["1:1", "1:1"],
    ["4:3", "4:3"],
    ["3:2", "3:2"],
    ["16:9", "16:9"],
  ],
  defaultAspect: "3:4",
  longestSide: 9999,
  deleteScenes: true,
  cutSections: true,
  baseName: "Заречная",
  facades: [
    {
      index: 1, name: "Фасад 1", pageName: "Фасад 1 — север", compass: "север",
      aspect: "3:4", selected: true,
      segment: { from: [90, 120], to: [910, 120], normal: [0, -1], area: 720 },
    },
    {
      index: 2, name: "Фасад 2", pageName: "Фасад 2 — восток", compass: "восток",
      aspect: "3:4", selected: true,
      segment: { from: [880, 150], to: [880, 880], normal: [1, 0], area: 610 },
    },
    {
      index: 3, name: "Фасад 3", pageName: "Фасад 3 — юг", compass: "юг",
      aspect: "3:4", selected: true,
      segment: { from: [90, 880], to: [910, 880], normal: [0, 1], area: 720 },
    },
    {
      index: 4, name: "Фасад 4", pageName: "Фасад 4 — запад", compass: "запад",
      aspect: "3:4", selected: true,
      segment: { from: [120, 150], to: [120, 880], normal: [-1, 0], area: 610 },
    },
  ],
};

const html = await fs.readFile(path.join(root, "facade_export/html/auto.html"), "utf8");
const dom = new JSDOM(html, { runScripts: "dangerously", pretendToBeVisual: true });
const { window } = dom;

const calls = { ready: 0, exported: null, canceled: 0 };

window.sketchup = {
  ready() {
    calls.ready += 1;
    window.FacadeExportAuto.setData(JSON.stringify(payload));
  },
  export(json) {
    calls.exported = json;
  },
  cancel() {
    calls.canceled += 1;
  },
};

window.document.dispatchEvent(new window.Event("DOMContentLoaded", { bubbles: true }));

const doc = window.document;
const fire = (el, type) => el.dispatchEvent(new window.Event(type, { bubbles: true }));
const rows = () => [...doc.querySelectorAll(".facade")];
// Сама стена — толстая линия; носик наружу рисуется отдельной тонкой линией.
const walls = (color, width) =>
  [...doc.querySelectorAll(`#canvas svg line[stroke="${color}"][stroke-width="${width}"]`)];
const badges = () => [...doc.querySelectorAll("#canvas svg text")];
const footnote = () => doc.getElementById("footnote").textContent;

console.log("Окно автоматического вывода (auto.html):");
check("Руби-мост вызвал ready", calls.ready === 1);
check("Одна схема на всё окно", doc.querySelectorAll("#canvas svg").length === 1,
  doc.querySelectorAll("#canvas svg").length);
check("Превью фасадов больше нет", doc.querySelectorAll(".preview").length === 0,
  doc.querySelectorAll(".preview").length);
check("Нет карточек со своей схемой", doc.querySelectorAll(".plan").length === 0);
check("В шапке — область анализа и число фасадов",
  doc.getElementById("subtitle").textContent.includes("вся модель") &&
  doc.getElementById("subtitle").textContent.includes("4"),
  doc.getElementById("subtitle").textContent);
check("В шапке нет пустого текста", !doc.getElementById("subtitle").textContent.includes("…"));

const rects = doc.querySelectorAll("#canvas svg rect");
check("Схема нарисована клетками контура", rects.length === payload.plan.cells.length + 1,
  [rects.length, payload.plan.cells.length].inspect ?? `${rects.length} / ${payload.plan.cells.length}`);
const courtyardFilled = [...rects].some((r) => {
  const x = Number(r.getAttribute("x"));
  const y = Number(r.getAttribute("y"));
  return x >= courtyardX[0] * 25 && x < courtyardX[1] * 25 + 25 &&
    y >= courtyardY[0] * 25;
});
check("Внутренний двор на схеме пустой", !courtyardFilled);
check("Стена нарисована на каждый фасад", walls("#e03131", 22).length === 4,
  walls("#e03131", 22).length);
check("Носик наружу у каждой стены",
  [...doc.querySelectorAll('#canvas svg line[stroke="#e03131"][stroke-width="11"]')].length === 4);
check("Номер фасада на схеме", badges().length === 4 &&
  badges().map((t) => t.textContent.trim()).join(",") === "1,2,3,4",
  badges().map((t) => t.textContent.trim()).join(","));
check("У стены есть кликабельная область", doc.querySelectorAll("#canvas svg .wall-hit").length === 4);
check("У номера есть кликабельная область", doc.querySelectorAll("#canvas svg .badge-g").length === 4);
check("Строка списка на каждый фасад", rows().length === 4, rows().length);

const first = rows()[0];
check("Имя фасада подставлено",
  first.querySelector('[data-role="name"]').value === "Фасад 1",
  first.querySelector('[data-role="name"]')?.value);
check("Соотношение по умолчанию 3:4",
  first.querySelector('[data-role="aspect"]').value === "3:4");
check("В списке соотношений есть вертикальные",
  ["3:4", "2:3", "9:16"].every((v) =>
    [...first.querySelectorAll('[data-role="aspect"] option')].some((o) => o.value === v)));
check("Размер PNG посчитан: 7499×9999",
  first.querySelector('[data-role="px"]').textContent === "7499×9999",
  first.querySelector('[data-role="px"]')?.textContent);
check("Фасад отмечен для экспорта", !first.classList.contains("off"));
check("Внизу — сколько выбрано и что сцены временные",
  footnote().includes("4 из 4") && footnote().includes("временные"), footnote());

// Клик по стене на схеме выключает фасад.
const wallThird = [...doc.querySelectorAll("#canvas svg .wall-hit")]
  .find((n) => n.getAttribute("data-index") === "2");
fire(wallThird, "click");
check("Клик по стене выключает фасад", rows()[2].classList.contains("off"));
check("Выключенная стена серая", walls("#b9c1cc", 14).length === 1 &&
  walls("#e03131", 22).length === 3,
  [walls("#b9c1cc", 14).length, walls("#e03131", 22).length]);
check("Внизу пересчитано количество", footnote().includes("3 из 4"), footnote());

// Клик по номеру возвращает фасад обратно.
const badgeFirst = [...doc.querySelectorAll("#canvas svg .badge-g")]
  .find((n) => n.getAttribute("data-index") === "0");
fire(badgeFirst, "click");
check("Клик по номеру выключает фасад", rows()[0].classList.contains("off"));
fire([...doc.querySelectorAll("#canvas svg .badge-g")]
  .find((n) => n.getAttribute("data-index") === "0"), "click");
check("Повторный клик по номеру включает фасад", !rows()[0].classList.contains("off"));

// Клик по номеру в списке тоже переключает фасад.
fire(rows()[3].querySelector('[data-role="toggle"]'), "click");
check("Номер в списке переключает фасад", rows()[3].classList.contains("off"));
fire(rows()[3].querySelector('[data-role="toggle"]'), "click");
check("Номер в списке включает фасад обратно", !rows()[3].classList.contains("off"));

// Имена и соотношения не переключают фасад.
const second = rows()[1];
const nameInput = second.querySelector('[data-role="name"]');
nameInput.value = "Восточное крыло";
fire(nameInput, "input");
check("Имя фасада меняется без переключения", !second.classList.contains("off"));

const aspectSelect = second.querySelector('[data-role="aspect"]');
aspectSelect.value = "1:1";
fire(aspectSelect, "change");
check("Размер PNG пересчитан под 1:1",
  second.querySelector('[data-role="px"]').textContent === "9999×9999",
  second.querySelector('[data-role="px"]')?.textContent);
check("Смена соотношения не выключает фасад", !second.classList.contains("off"));

check("Пока экспорт не нажат, в Ruby ничего не ушло", calls.exported === null);
fire(doc.getElementById("btn-export"), "click");
const sent = JSON.parse(calls.exported);
check("В Ruby ушёл JSON со всеми фасадами", sent.facades.length === 4, sent.facades?.length);
check("Выбор фасадов передан", sent.facades.filter((f) => f.selected).length === 3,
  sent.facades.map((f) => f.selected).join(","));
check("Имя фасада передано", sent.facades[1].name === "Восточное крыло", sent.facades[1].name);
check("Соотношение сторон передано", sent.facades[1].aspect === "1:1", sent.facades[1].aspect);
check("Индексы фасадов сохранены",
  sent.facades.map((f) => f.index).join(",") === "1,2,3,4",
  sent.facades.map((f) => f.index).join(","));

fire(doc.getElementById("btn-cancel"), "click");
check("По «Отмена» вызван Ruby-callback", calls.canceled === 1);

console.log(failures === 0
  ? "\nОкно автоматического вывода: всё в порядке"
  : `\nОкно автоматического вывода: провалов ${failures}`);
process.exit(failures === 0 ? 0 : 1);
