// Проверка окна автоматического вывода (facade_export/html/auto.html) без SketchUp:
// страница открывается в jsdom, эмулируется объект `sketchup` из UI::HtmlDialog.
//
// Готовых фасадов больше нет: на открытии список пуст, пользователь рисует
// линии сам. Здесь проверяется рисование, перенос линий, ориентация и
// пропорции кадра, нумерация и обмен данными с Ruby.
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

const plan = {
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
  polygons: [[
    [0, 0], [1000, 0], [1000, 1000], [675, 1000], [675, 450],
    [400, 450], [400, 1000], [0, 1000],
  ]],
};

const orients = [["h", "горизонтальное"], ["v", "вертикальное"], ["sq", "квадрат"]];
// Пропорции приходят разложенными по ориентации: широкие — горизонтальному
// кадру, высокие — вертикальному, у квадрата единственная 1:1.
const ratios = {
  h: [["4:3", "4:3"], ["3:2", "3:2"], ["16:9", "16:9"], ["2:1", "2:1"], ["3:1", "3:1"]],
  v: [["3:4", "3:4"], ["2:3", "2:3"], ["9:16", "9:16"], ["1:2", "1:2"], ["1:3", "1:3"]],
  sq: [["1:1", "1:1"]],
};

const base = {
  scope: "model",
  plan,
  magnets: [[0, -1], [1, 0]],
  magnetTol: 14,
  orients,
  ratios,
  defaultOrient: "h",
  defaultRatio: "4:3",
  origin: { x: 0, y: 0 },
  span: 1000,
  longestSide: 9999,
  deleteScenes: true,
  cutSections: true,
  baseName: "Заречная",
};

// Фасады, которые пользователь уже нарисовал (их вернул Ruby из модели).
const drawn = [
  {
    id: 1, index: 1, name: "Фасад 1", orient: "h", ratio: "4:3", selected: true,
    segment: { from: [90, 120], to: [910, 120], normal: [0, -1], area: 0 },
  },
  {
    id: 2, index: 2, name: "Фасад 2", orient: "h", ratio: "4:3", selected: true,
    segment: { from: [880, 150], to: [880, 880], normal: [1, 0], area: 0 },
  },
  {
    id: 3, index: 3, name: "Фасад 3", orient: "h", ratio: "4:3", selected: true,
    segment: { from: [90, 880], to: [910, 880], normal: [0, 1], area: 0 },
  },
  {
    id: 4, index: 4, name: "Фасад 4", orient: "h", ratio: "4:3", selected: true,
    segment: { from: [120, 150], to: [120, 880], normal: [-1, 0], area: 0 },
  },
];

const html = await fs.readFile(path.join(root, "facade_export/html/auto.html"), "utf8");

// Окно открывается пустым: ни одного готового фасада.
const emptyDom = new JSDOM(html, { runScripts: "dangerously", pretendToBeVisual: true });
const emptyWindow = emptyDom.window;
emptyWindow.sketchup = {
  ready() {
    emptyWindow.FacadeExportAuto.setData(
      JSON.stringify({ ...base, plan, facades: [] })
    );
  },
  export() {},
  cancel() {},
};
emptyWindow.document.dispatchEvent(
  new emptyWindow.Event("DOMContentLoaded", { bubbles: true })
);
const emptyDoc = emptyWindow.document;

// Рабочее окно с четырьмя уже нарисованными фасадами.
const dom = new JSDOM(html, { runScripts: "dangerously", pretendToBeVisual: true });
const { window } = dom;

const calls = {
  ready: 0, exported: null, canceled: 0, drawn: null, moved: null, deleted: null,
};
const payload = { ...base, plan, facades: drawn };

window.sketchup = {
  ready() {
    calls.ready += 1;
    window.FacadeExportAuto.setData(JSON.stringify(payload));
  },
  export(json) {
    calls.exported = json;
  },
  add_facade(json) {
    calls.drawn = JSON.parse(json);
  },
  move_facade(json) {
    calls.moved = JSON.parse(json);
  },
  delete_facade(json) {
    calls.deleted = JSON.parse(json);
  },
  cancel() {
    calls.canceled += 1;
  },
};

window.document.dispatchEvent(new window.Event("DOMContentLoaded", { bubbles: true }));

const doc = window.document;
const fire = (el, type) => el.dispatchEvent(new window.Event(type, { bubbles: true }));
const rows = () => [...doc.querySelectorAll(".facade")];
const walls = (color, width) =>
  [...doc.querySelectorAll(`#canvas svg line[stroke="${color}"][stroke-width="${width}"]`)];
const badges = () => [...doc.querySelectorAll("#canvas svg text")];
const footnote = () => doc.getElementById("footnote").textContent;

console.log("Окно автоматического вывода (auto.html):");

check("Руби-мост вызвал ready", calls.ready === 1);
check("На открытии ни одного готового фасада",
  emptyDoc.querySelectorAll(".facade").length === 0,
  emptyDoc.querySelectorAll(".facade").length);
check("Пустой список объясняет, что делать",
  emptyDoc.querySelector(".list-pane .empty") &&
  emptyDoc.querySelector(".list-pane .empty").textContent.includes("Проведите линию"),
  emptyDoc.querySelector(".list-pane .empty")?.textContent);
check("В пустом окне на схеме ни одной линии",
  emptyDoc.querySelectorAll('#canvas svg line[stroke="#e03131"]').length === 0);
check("Схема в пустом окне всё равно нарисована",
  emptyDoc.querySelectorAll("#canvas svg polygon").length === plan.polygons.length);

check("Одна схема на всё окно", doc.querySelectorAll("#canvas svg").length === 1,
  doc.querySelectorAll("#canvas svg").length);
check("Превью фасадов больше нет", doc.querySelectorAll(".preview").length === 0);
check("В шапке — область анализа и число фасадов",
  doc.getElementById("subtitle").textContent.includes("вся модель") &&
  doc.getElementById("subtitle").textContent.includes("4"),
  doc.getElementById("subtitle").textContent);
check("В шапке нет пустого текста", !doc.getElementById("subtitle").textContent.includes("…"));

const contour = doc.querySelectorAll("#canvas svg polygon");
check("Контур нарисован заливкой граней без обводки",
  contour.length === plan.polygons.length && !contour[0].getAttribute("stroke"),
  contour.length);
check("Внутренний двор на схеме пустой",
  window.FacadeExportAuto._debug.insideBuilding(500, 620) === false);
check("Двор не залит контуром",
  window.FacadeExportAuto._debug.insideBuilding(500, 300) === true);
check("Линия тонкая: 10 px у выбранного фасада", walls("#e03131", 10).length === 4,
  walls("#e03131", 10).length);
check("Толстых линий 14 и 22 px больше нет",
  walls("#e03131", 14).length === 0 && walls("#e03131", 22).length === 0);
check("Стрелка — только треугольник, без древка",
  doc.querySelectorAll("#canvas svg path.arrow").length === 4 &&
  !doc.querySelector("#canvas svg line.arrow-shaft"),
  doc.querySelectorAll("#canvas svg path.arrow").length);
check("Кружок с номером стал больше (r = 23)", (() => {
  const c = doc.querySelector('#canvas svg circle[stroke="#e03131"]');
  return c && Number(c.getAttribute("r")) === 23;
})(), doc.querySelector('#canvas svg circle[stroke="#e03131"]')?.getAttribute("r"));
check("Цифра в кружке крупнее (font-size = 24)", (() => {
  const t = doc.querySelector("#canvas svg text");
  return t && Number(t.getAttribute("font-size")) === 24;
})(), doc.querySelector("#canvas svg text")?.getAttribute("font-size"));
const badgeGaps = [...doc.querySelectorAll("#canvas svg .badge-g")].map((g) => {
  const position = g.getAttribute("data-index");
  const line = doc.querySelector(`#canvas svg .wall-hit[data-index="${position}"] line`);
  const circle = g.querySelector("circle");
  const x1 = Number(line.getAttribute("x1"));
  const y1 = Number(line.getAttribute("y1"));
  const x2 = Number(line.getAttribute("x2"));
  const y2 = Number(line.getAttribute("y2"));
  const x = Number(circle.getAttribute("cx"));
  const y = Number(circle.getAttribute("cy"));
  const vx = x2 - x1;
  const vy = y2 - y1;
  const len = Math.sqrt(vx * vx + vy * vy) || 1;
  // Расстояние от центра кружка до своей линии.
  const t = Math.max(0, Math.min(1, ((x - x1) * vx + (y - y1) * vy) / (len * len)));
  return Math.hypot(x - (x1 + vx * t), y - (y1 + vy * t));
});
check("Кружки стоят вплотную к своим линиям (не дальше 45 px)",
  badgeGaps.length === 4 && badgeGaps.every((d) => d <= 45),
  badgeGaps.map((d) => d.toFixed(1)).join(","));
check("Кружки не наезжают на линию",
  badgeGaps.every((d) => d >= 18), badgeGaps.map((d) => d.toFixed(1)).join(","));
check("Номер фасада на схеме", badges().length === 4 &&
  badges().map((t) => t.textContent.trim()).join(",") === "1,2,3,4",
  badges().map((t) => t.textContent.trim()).join(","));
check("У линии есть кликабельная область", doc.querySelectorAll("#canvas svg .wall-hit").length === 4);
check("У номера есть кликабельная область", doc.querySelectorAll("#canvas svg .badge-g").length === 4);
check("Строка списка на каждый фасад", rows().length === 4, rows().length);

const first = rows()[0];
check("Имя фасада подставлено",
  first.querySelector('[data-role="name"]').value === "Фасад 1",
  first.querySelector('[data-role="name"]')?.value);
check("Ориентация по умолчанию — горизонтальная",
  first.querySelector('[data-role="orient"]').value === "h",
  first.querySelector('[data-role="orient"]')?.value);
check("В списке ориентаций есть вертикальная и квадрат",
  ["h", "v", "sq"].every((v) =>
    [...first.querySelectorAll('[data-role="orient"] option')].some((o) => o.value === v)));
check("Пропорции по умолчанию — 4:3",
  first.querySelector('[data-role="ratio"]').value === "4:3",
  first.querySelector('[data-role="ratio"]')?.value);
const firstRatioOptions = [...first.querySelectorAll('[data-role="ratio"] option')]
  .map((o) => o.value);
check("У горизонтального кадра только широкие пропорции",
  firstRatioOptions.join(",") === "4:3,3:2,16:9,2:1,3:1", firstRatioOptions.join(","));
check("В горизонтальном списке нет вертикальных пар",
  !firstRatioOptions.includes("9:16") && !firstRatioOptions.includes("3:4"));
check("Размер PNG посчитан: горизонтальное 4:3 → 9999×7499",
  first.querySelector('[data-role="px"]').textContent === "9999×7499",
  first.querySelector('[data-role="px"]')?.textContent);
check("Фасад отмечен для экспорта", !first.classList.contains("off"));
check("Внизу — сколько нарисовано и что сцены временные",
  footnote().includes("Нарисовано: 4") && footnote().includes("временные"), footnote());
check("Предела фасадов в подписи больше нет", !footnote().includes("из 30"), footnote());

// Ориентация и пропорции: сначала ориентация, потом пропорции. Каждая
// ориентация показывает только свои пары — без 16:9 рядом с 9:16.
const setOrient = (position, value) => {
  const select = rows()[position].querySelector('[data-role="orient"]');
  select.value = value;
  fire(select, "change");
};
const setRatio = (position, value) => {
  const select = rows()[position].querySelector('[data-role="ratio"]');
  select.value = value;
  fire(select, "change");
};
const ratioOptions = (position) =>
  [...rows()[position].querySelectorAll('[data-role="ratio"] option')].map((o) => o.value);

setOrient(1, "v");
check("После смены ориентации пропорция сбрасывается на 3:4",
  rows()[1].querySelector('[data-role="ratio"]').value === "3:4",
  rows()[1].querySelector('[data-role="ratio"]')?.value);
check("У вертикального кадра только высокие пропорции",
  ratioOptions(1).join(",") === "3:4,2:3,9:16,1:2,1:3", ratioOptions(1).join(","));
check("Вертикальное 3:4 → 7499×9999",
  rows()[1].querySelector('[data-role="px"]').textContent === "7499×9999",
  rows()[1].querySelector('[data-role="px"]')?.textContent);
setRatio(1, "9:16");
check("Вертикальное 9:16 → 5624×9999",
  rows()[1].querySelector('[data-role="px"]').textContent === "5624×9999",
  rows()[1].querySelector('[data-role="px"]')?.textContent);
setOrient(1, "sq");
check("У квадрата единственная пропорция — 1:1",
  ratioOptions(1).join(",") === "1:1", ratioOptions(1).join(","));
check("Квадратная пропорция заблокирована",
  rows()[1].querySelector('[data-role="ratio"]').disabled === true);
check("Квадрат — 9999×9999",
  rows()[1].querySelector('[data-role="px"]').textContent === "9999×9999",
  rows()[1].querySelector('[data-role="px"]')?.textContent);
setOrient(1, "h");
setRatio(1, "3:1");
check("Горизонтальное 3:1 → 9999×3333",
  rows()[1].querySelector('[data-role="px"]').textContent === "9999×3333",
  rows()[1].querySelector('[data-role="px"]')?.textContent);
check("У горизонтального кадра пропорция снова выбирается",
  rows()[1].querySelector('[data-role="ratio"]').disabled === false);
check("Смена ориентации не выключает фасад", !rows()[1].classList.contains("off"));
const second = rows()[1];

// Клик по линии на схеме выключает фасад.
const wallThird = [...doc.querySelectorAll("#canvas svg .wall-hit")]
  .find((n) => n.getAttribute("data-index") === "2");
fire(wallThird, "click");
check("Клик по линии выключает фасад", rows()[2].classList.contains("off"));
check("Выключенная линия серая и тонкая", walls("#b9c1cc", 7).length === 1 &&
  walls("#e03131", 10).length === 3,
  [walls("#b9c1cc", 7).length, walls("#e03131", 10).length]);
check("Внизу пересчитано количество", footnote().includes("3 из 4") ||
  footnote().includes("Выбрано: 3"), footnote());

const badgeFirst = [...doc.querySelectorAll("#canvas svg .badge-g")]
  .find((n) => n.getAttribute("data-index") === "0");
fire(badgeFirst, "click");
check("Клик по номеру выключает фасад", rows()[0].classList.contains("off"));
fire([...doc.querySelectorAll("#canvas svg .badge-g")]
  .find((n) => n.getAttribute("data-index") === "0"), "click");
check("Повторный клик по номеру включает фасад", !rows()[0].classList.contains("off"));

fire(rows()[3].querySelector('[data-role="toggle"]'), "click");
check("Номер в списке переключает фасад", rows()[3].classList.contains("off"));
fire(rows()[3].querySelector('[data-role="toggle"]'), "click");
check("Номер в списке включает фасад обратно", !rows()[3].classList.contains("off"));

const nameInput = second.querySelector('[data-role="name"]');
nameInput.value = "Восточное крыло";
fire(nameInput, "input");
check("Имя фасада меняется без переключения", !second.classList.contains("off"));

// Перенос линии: она уходит в Ruby с новыми концами, но прежним углом.
const before = drawn[0].segment;
window.FacadeExportAuto._move(0, 0, 40);
check("Перенос линии ушёл в Ruby", calls.moved !== null, JSON.stringify(calls.moved));
check("Перенос передан по id фасада", calls.moved && calls.moved.id === 1,
  JSON.stringify(calls.moved));
check("Перенос сдвигает линию в мировых координатах",
  calls.moved && Math.round(calls.moved.y1) === 840 && Math.round(calls.moved.y2) === 840,
  JSON.stringify(calls.moved));
check("Перенос не поворачивает линию",
  calls.moved && Math.round(calls.moved.y1) === Math.round(calls.moved.y2) &&
  Math.round(calls.moved.x1) === 90 && Math.round(calls.moved.x2) === 910,
  JSON.stringify(calls.moved));
check("Длина линии при переносе сохраняется",
  calls.moved && Math.round(calls.moved.x2 - calls.moved.x1) ===
  Math.round(before.to[0] - before.from[0]),
  JSON.stringify(calls.moved));

// Стрелка — треугольник носком к линии, по другую её сторону.
const arrow = doc.querySelector("#canvas svg path.arrow");
const arrowNums = arrow.getAttribute("d").match(/-?\d+/g).map(Number);
check("Стрелка — треугольник из трёх точек",
  (arrow.getAttribute("d").match(/[ML]/g) || []).length === 3, arrow.getAttribute("d"));
const lineOne = doc.querySelector('#canvas svg line[stroke="#e03131"][stroke-width="10"]');
const cy = (Number(lineOne.getAttribute("y1")) + Number(lineOne.getAttribute("y2"))) / 2;
const tipGap = Math.abs(arrowNums[1] - cy);
const baseGap = Math.abs(arrowNums[3] - cy);
check("Носок стрелки почти касается линии",
  tipGap > 0 && tipGap <= 10, [arrowNums[1], cy].join(" / "));
check("Основание треугольника дальше от линии",
  baseGap > tipGap + 20, [tipGap, baseGap].join(" / "));
// Нормаль первого фасада — [0, -1], то есть на схеме вверх: там и камера,
// туда же смотрит стрелка, а номер стоит с противоположной стороны.
check("Стрелка стоит со стороны камеры (по нормали фасада)",
  arrowNums[1] < cy, [arrowNums[1], cy].join(" / "));
const firstBadgeY = Number(doc.querySelector('#canvas svg .badge-g[data-index="0"] circle')
  .getAttribute("cy"));
check("Номер стоит с противоположной стороны линии",
  firstBadgeY > cy, [firstBadgeY, cy].join(" / "));

// Разворот фасада: просим Ruby (там пересчитывается камера).
let inverted = null;
window.sketchup.invert_facade = (json) => { inverted = JSON.parse(json); };
fire(rows()[0].querySelector('[data-role="flip"]'), "click");
check("Кнопка «⇄» просит Ruby развернуть фасад",
  inverted && inverted.id === 1, JSON.stringify(inverted));

// Удаление фасада: тоже через Ruby, чтобы номера остались 1..N.
fire(rows()[1].querySelector('[data-role="remove"]'), "click");
check("Кнопка «×» просит Ruby удалить фасад",
  calls.deleted && calls.deleted.id === 2, JSON.stringify(calls.deleted));

// Ruby перерисовал окно после удаления: номера 1..3 без пропусков,
// настройки строк — те, что успели поменять (их хранит Ruby).
const afterDelete = [
  { id: 1, index: 1, name: "Фасад 1", orient: "h", ratio: "3:4", selected: false,
    segment: drawn[0].segment },
  { id: 3, index: 2, name: "Восточное крыло", orient: "h", ratio: "3:1", selected: true,
    segment: drawn[2].segment },
  { id: 4, index: 3, name: "Фасад 4", orient: "h", ratio: "3:4", selected: false,
    segment: drawn[3].segment },
];
window.FacadeExportAuto.setData(JSON.stringify({ ...base, plan, facades: afterDelete }));
check("После удаления строк стало меньше", rows().length === 3, rows().length);
check("После удаления номера идут 1..3",
  rows().map((r) => r.querySelector(".badge").textContent.trim()).join(",") === "1,2,3",
  rows().map((r) => r.querySelector(".badge").textContent.trim()).join(","));

check("Пока экспорт не нажат, в Ruby ничего не ушло", calls.exported === null);
fire(doc.getElementById("btn-export"), "click");
const sent = JSON.parse(calls.exported);
check("В Ruby ушёл JSON со всеми фасадами", sent.facades.length === 3, sent.facades?.length);
check("Выбор фасадов передан", sent.facades.filter((f) => f.selected).length === 1,
  sent.facades.map((f) => f.selected).join(","));
check("Идентификаторы фасадов переданы",
  sent.facades.map((f) => f.id).join(",") === "1,3,4",
  sent.facades.map((f) => f.id).join(","));
check("Имя фасада передано", sent.facades[1].name === "Восточное крыло",
  sent.facades[1].name);
check("Ориентация передана", sent.facades[1].orient === "h", sent.facades[1].orient);
check("Пропорции переданы", sent.facades[1].ratio === "3:1", sent.facades[1].ratio);

// Рисование мышью: линия уходит в Ruby в координатах модели.
const debug = window.FacadeExportAuto._debug;
check("Контур: точка внутри здания определяется", debug.insideBuilding(200, 200) === true);
check("Контур: двор пустой", debug.insideBuilding(500, 620) === false);
check("Схема переводится в координаты модели",
  debug.toWorld([380, 630]).join(",") === "380,370",
  debug.toWorld([380, 630]).join(","));
window.FacadeExportAuto._draw(200, 620, 800, 620);
check("Нарисованная линия ушла в Ruby", calls.drawn !== null, JSON.stringify(calls.drawn));
check("Линия передана в координатах модели",
  calls.drawn && Math.round(calls.drawn.x1) === 200 && Math.round(calls.drawn.x2) === 800 &&
  Math.round(calls.drawn.y1) === 380 && Math.round(calls.drawn.y2) === 380,
  JSON.stringify(calls.drawn));

const marks = debug.dragMarks([-60, 200, 1060, 200]);
check("Часть линии внутри здания — синяя (сечение)",
  (marks.match(/stroke="#1f6feb"/g) || []).length === 1, marks);
check("Участки линии вне здания — красные",
  (marks.match(/stroke="#e03131"/g) || []).length === 2, marks);

// Ruby вернул новый фасад: строка появляется, номер продолжает список.
window.FacadeExportAuto.addFacade(JSON.stringify({
  ok: true, id: 5, index: 4, name: "Фасад 4", orient: "h", ratio: "4:3", selected: true,
  segment: { from: [120, 150], to: [120, 880], normal: [-1, 0], area: 0 },
}));
check("Добавленный фасад появился в списке", rows().length === 4, rows().length);
check("Добавленный фасад появился на схеме", badges().length === 4, badges().length);
check("Добавленный фасад получил пропорции по умолчанию",
  rows()[3].querySelector('[data-role="ratio"]').value === "4:3",
  rows()[3].querySelector('[data-role="ratio"]')?.value);
window.FacadeExportAuto.addFacade(JSON.stringify({
  ok: false, message: "Не удалось создать фасад по этой линии.",
}));
check("Отказ показан пользователю",
  footnote().includes("Не удалось создать фасад"), footnote());

// Ruby передвинул/развернул фасад: строка обновляется по id.
window.FacadeExportAuto.updateFacade(JSON.stringify({
  ok: true, id: 3, index: 2, name: "Фасад 2", orient: "v", ratio: "9:16",
  segment: { from: [90, 880], to: [910, 880], normal: [0, -1], area: 0 },
}));
const flipped = window.FacadeExportAuto._state().find((s) => s.id === 3);
check("Разворот фасада меняет направление стрелки",
  flipped.segment.normal[1] === -1, JSON.stringify(flipped.segment.normal));
check("Разворот меняет ориентацию строки", flipped.orient === "v", flipped.orient);

// Предела числа нарисованных фасадов больше нет.
const many = [];
for (let i = 0; i < 40; i++) {
  many.push({
    id: i + 1, index: i + 1, name: `Фасад ${i + 1}`, orient: "h", ratio: "4:3",
    selected: true,
    segment: { from: [0 + i, 400], to: [40 + i, 400], normal: [0, -1], area: 0 },
  });
}
window.FacadeExportAuto.setData(JSON.stringify({ ...base, plan, facades: many }));
check("Список показывает все 40 фасадов", rows().length === 40, rows().length);
check("Про предел в подписи ни слова", !footnote().includes("из "), footnote());
calls.drawn = null;
window.FacadeExportAuto._draw(200, 620, 800, 620);
check("Сорок первый фасад нарисовать можно", calls.drawn !== null,
  JSON.stringify(calls.drawn));

// Магнит работает прямо во время протяжки: линия под 13° доворачивается
// к стене ещё до отпускания кнопки — и уходит в Ruby уже ровной.
const snapped = debug.magnetize([100, 300, 900, 300 + 800 * Math.tan(13 * Math.PI / 180)]);
check("Линия под 13° притягивается к стене во время протяжки",
  Math.abs(snapped.line[3] - snapped.line[1]) < 1, snapped.line.join(","));
check("Магнит отмечен как сработавший", snapped.snapped === true);
check("Середина линии при притяжке остаётся на месте",
  Math.abs((snapped.line[0] + snapped.line[2]) / 2 - 500) < 1 &&
  Math.abs((snapped.line[1] + snapped.line[3]) / 2 - 300 - 400 * Math.tan(13 * Math.PI / 180)) < 1,
  snapped.line.join(","));
const notSnapped = debug.magnetize([100, 300, 400, 700]);
check("Линия под 45° не притягивается", notSnapped.snapped === false,
  notSnapped.line.join(","));

// Курсор «перетащить» над линией: видно, что фасад можно двигать.
debug.setHover(false);
check("Без наведения курсор обычный", !doc.getElementById("canvas").classList.contains("draggable"));
debug.setHover(true);
check("Над линией курсор «перетащить»",
  doc.getElementById("canvas").classList.contains("draggable"));
check("В стилях есть grab-курсор", html.includes("cursor: grab") && html.includes("cursor: grabbing"));
debug.setHover(false);

fire(doc.getElementById("btn-cancel"), "click");
check("По «Отмена» вызван Ruby-callback", calls.canceled === 1);

console.log(failures === 0
  ? "\nОкно автоматического вывода: всё в порядке"
  : `\nОкно автоматического вывода: провалов ${failures}`);
process.exit(failures === 0 ? 0 : 1);
