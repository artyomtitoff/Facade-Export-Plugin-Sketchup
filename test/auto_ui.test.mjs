// Проверка окна автоматического вывода (facade_export/html/auto.html) без SketchUp:
// страница открывается в jsdom, эмулируется объект `sketchup` из UI::HtmlDialog.
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

// Данные, которые Ruby отдаёт в окно (AutoExport.build_payload).
const payload = {
  scope: "model",
  scopeText: "вся модель",
  plan: {
    grid: 32,
    cells: (() => {
      // П-образный план: внутренний двор (10..21 по X, 12..31 по Y) пустой.
      const cells = [];
      for (let y = 0; y < 32; y++) {
        for (let x = 0; x < 32; x++) {
          const courtyard = x >= 10 && x <= 21 && y >= 12;
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
  minSide: 100,
  deleteScenes: true,
  cutSections: true,
  baseName: "Заречная",
  facades: [
    {
      index: 1, name: "Фасад 1", pageName: "Фасад 1 — север", compass: "север",
      aspect: "3:4", selected: true, normal: [0, 1],
      polygons: [[[0, 0], [1000, 0], [1000, 600], [0, 600]]],
    },
    {
      index: 2, name: "Фасад 2", pageName: "Фасад 2 — восток", compass: "восток",
      aspect: "3:4", selected: true, normal: [1, 0],
      polygons: [[[0, 0], [800, 0], [800, 1000], [0, 1000]]],
    },
    {
      index: 3, name: "Фасад 3", pageName: "Фасад 3 — юг", compass: "юг",
      aspect: "3:4", selected: true, normal: [0, -1],
      polygons: [[[0, 0], [1000, 0], [1000, 400], [0, 400]]],
    },
    {
      index: 4, name: "Фасад 4", pageName: "Фасад 4 — запад", compass: "запад",
      aspect: "3:4", selected: true, normal: [-1, 0],
      polygons: [[[0, 0], [800, 0], [800, 1000], [0, 1000]]],
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
const cards = () => [...doc.querySelectorAll(".facade")];

console.log("Окно автоматического вывода (auto.html):");
check("Руби-мост вызвал ready", calls.ready === 1);
check("Карточка на каждый фасад", cards().length === 4, cards().length);
check("В шапке — область анализа и число фасадов",
  doc.getElementById("subtitle").textContent.includes("вся модель"),
  doc.getElementById("subtitle").textContent);
check("В шапке нет пустого текста", !doc.getElementById("subtitle").textContent.includes("…"));

const first = cards()[0];
check("Есть упрощённое превью фасада", !!first.querySelector(".preview svg polygon"));
check("Есть схема сверху", !!first.querySelector(".plan svg rect"));
check("На схеме — красная линия фасада",
  !!first.querySelector('.plan svg line[stroke="#e03131"]'));
check("На схеме — стрелка на фасад",
  first.querySelector(".plan svg").innerHTML.includes("marker-end"));
check("Своя метка стрелки на каждую схему",
  new Set(cards().map((c) => c.querySelector(".plan svg defs marker")?.id)).size === 4);
check("Схема рисует план клетками", first.querySelectorAll(".plan svg rect").length > 200,
  first.querySelectorAll(".plan svg rect").length);
check("Имя фасада подставлено",
  first.querySelector('[data-role="name"]').value === "Фасад 1",
  first.querySelector('[data-role="name"]')?.value);
check("Сторона света подписана",
  first.textContent.includes("север"));
check("Соотношение по умолчанию 3:4",
  first.querySelector('[data-role="aspect"]').value === "3:4");
check("В списке соотношений есть вертикальные",
  ["3:4", "2:3", "9:16"].every((v) =>
    [...first.querySelectorAll('[data-role="aspect"] option')].some((o) => o.value === v)));
check("Размер PNG посчитан: 7499 × 9999",
  first.querySelector('[data-role="px"]').textContent === "7499 × 9999 px",
  first.querySelector('[data-role="px"]')?.textContent);
check("Фасад отмечен для экспорта",
  first.querySelector('[data-role="selected"]').checked === true);
check("Внизу — сколько выбрано и что сцены временные",
  doc.getElementById("footnote").textContent.includes("4 из 4") &&
  doc.getElementById("footnote").textContent.includes("удаляются"),
  doc.getElementById("footnote").textContent);

// Снимаем галочку — карточка гаснет и в экспорт не идёт.
const third = cards()[2];
const box = third.querySelector('[data-role="selected"]');
box.checked = false;
fire(box, "change");
check("Снятая галочка гасит карточку", third.classList.contains("off"));
check("Внизу пересчитано количество",
  doc.getElementById("footnote").textContent.includes("3 из 4"),
  doc.getElementById("footnote").textContent);

// Меняем имя и соотношение сторон.
const second = cards()[1];
const nameInput = second.querySelector('[data-role="name"]');
nameInput.value = "Восточное крыло";
fire(nameInput, "input");
check("Подсказка сцены обновляется на лету",
  second.textContent.includes("Восточное крыло"));

const aspectSelect = second.querySelector('[data-role="aspect"]');
aspectSelect.value = "1:1";
fire(aspectSelect, "change");
check("Размер PNG пересчитан под 1:1",
  second.querySelector('[data-role="px"]').textContent === "9999 × 9999 px",
  second.querySelector('[data-role="px"]')?.textContent);

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
