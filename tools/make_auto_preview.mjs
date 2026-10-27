// Собирает docs/auto_preview.html — копию окна «Автоматический вывод фасада»,
// которую можно открыть в браузере без SketchUp (для проверки вида).
//
//   node tools/make_auto_preview.mjs
//
// Данные — как их отдаёт AutoExport.build_payload: контур здания сверху
// (грани, смотрящие вверх, залитые одним цветом), направления стен для
// «магнита» и уже нарисованные пользователем линии (для превью — восемь,
// в настоящем окне на открытии их ноль). Превью фасадов нет.

import fs from "node:fs/promises";
import path from "node:path";

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");

const PLAN_GRID = 40;

// Здание с косым крылом (как в реальном проекте заказчика): П-образный
// контур, одна сторона под 45°, внутренний двор.
const outline = [
  [35, 830], [35, 470], [365, 140], [960, 140],
  [960, 830], [800, 830], [800, 300], [530, 300],
  [200, 630], [200, 830],
];

function insidePolygon(x, y, points) {
  let inside = false;
  let j = points.length - 1;
  for (let i = 0; i < points.length; i++) {
    const [xi, yi] = points[i];
    const [xj, yj] = points[j];
    if (((yi > y) !== (yj > y)) && (x < ((xj - xi) * (y - yi)) / (yj - yi) + xi)) {
      inside = !inside;
    }
    j = i;
  }
  return inside;
}

// Клетки — запасной вариант для окна (и для «попала ли линия в здание»).
const cells = [];
for (let iy = 0; iy < PLAN_GRID; iy++) {
  for (let ix = 0; ix < PLAN_GRID; ix++) {
    const cx = (ix + 0.5) * (1000 / PLAN_GRID);
    const cy = (iy + 0.5) * (1000 / PLAN_GRID);
    if (insidePolygon(cx, cy, outline)) cells.push([ix, iy]);
  }
}

// Стены контура: откуда-куда и куда смотрит фасад (наружу).
const walls = [
  { from: [35, 470], to: [35, 830], normal: [-1, 0], compass: "запад" },
  { from: [35, 470], to: [365, 140], normal: [-0.7071, -0.7071], compass: "северо-запад" },
  { from: [365, 140], to: [960, 140], normal: [0, -1], compass: "север" },
  { from: [960, 140], to: [960, 830], normal: [1, 0], compass: "восток" },
  { from: [800, 830], to: [960, 830], normal: [0, 1], compass: "юг" },
  { from: [800, 300], to: [800, 830], normal: [-1, 0], compass: "двор" },
  { from: [530, 300], to: [800, 300], normal: [0, 1], compass: "двор" },
  { from: [200, 630], to: [530, 300], normal: [0.7071, 0.7071], compass: "двор" },
];

const facades = walls.map((wall, i) => {
  const length = Math.hypot(wall.to[0] - wall.from[0], wall.to[1] - wall.from[1]);
  return {
    index: i + 1,
    compass: wall.compass,
    name: "Фасад " + (i + 1),
    pageName: "Фасад " + (i + 1) + " — " + wall.compass,
    id: i + 1,
    orient: "h",
    ratio: "4:3",
    flip: false,
    selected: true,
    segment: {
      from: wall.from,
      to: wall.to,
      normal: wall.normal,
      area: Math.round(length * 3),
    },
  };
});

const payload = {
  scope: "context",
  plan: { grid: PLAN_GRID, cells, polygons: [outline] },
  origin: { x: 0, y: 0 },
  span: 1000,
  // Направления стен: к ним «магнитится» линия при рисовании.
  magnets: [[1, 0], [0.7071, 0.7071], [0, 1], [-0.7071, 0.7071]],
  magnetTol: 14,
  orients: [["h", "горизонтальное"], ["v", "вертикальное"], ["sq", "квадрат"]],
  // Пропорции — свои для каждой ориентации, без повторов внутри списка.
  ratios: {
    h: [["4:3", "4:3"], ["3:2", "3:2"], ["16:9", "16:9"], ["2:1", "2:1"], ["3:1", "3:1"]],
    v: [["3:4", "3:4"], ["2:3", "2:3"], ["9:16", "9:16"], ["1:2", "1:2"], ["1:3", "1:3"]],
    sq: [["1:1", "1:1"]],
  },
  defaultOrient: "h",
  defaultRatio: "4:3",
  scenePrefix: "Фасад",
  longestSide: 9999,
  deleteScenes: true,
  cutSections: true,
  baseName: "Заречная",
  facades,
};

const html = await fs.readFile(path.join(root, "facade_export/html/auto.html"), "utf8");
const injection =
  `<script>window.FACADE_EXPORT_AUTO_DEMO = ${JSON.stringify(payload, null, 2)};</script>\n` +
  `<div style="background:#fff8e1;border-bottom:1px solid #f0d48a;padding:8px 18px;font:13px/1.4 sans-serif;color:#6b5b1f">` +
  `Демонстрационная страница окна «Автоматический вывод фасада» плагина «Экспорт фасадов». ` +
  `В SketchUp это же окно открывается кнопкой <b>Автоматический вывод фасада</b>.</div>`;

const out = html
  .replace("<body>", "<body>\n" + injection)
  .replace("<title>Экспорт фасадов — автоматический вывод</title>",
           "<title>Экспорт фасадов — автоматический вывод (превью)</title>");

await fs.mkdir(path.join(root, "docs"), { recursive: true });
await fs.writeFile(path.join(root, "docs/auto_preview.html"), out, "utf8");
console.log("Готово: docs/auto_preview.html");
