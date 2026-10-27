// Собирает docs/auto_preview.html — копию окна «Автоматический вывод фасада»,
// которую можно открыть в браузере без SketchUp (для проверки вида).
//
//   node tools/make_auto_preview.mjs
//
// Данные — как их отдаёт AutoExport.build_payload: одна схема здания сверху
// («жучок») и по одной линии стены на каждый найденный фасад. Превью фасадов
// нет: окно должно открываться мгновенно.

import fs from "node:fs/promises";
import path from "node:path";

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");

// П-образное здание с внутренним двором: ровно тот случай, ради которого
// делались внутренние фасады и секущие плоскости.
const PLAN_GRID = 40;
const CELL = 1000 / PLAN_GRID;

// Крылья в координатах схемы (0..1000, ось Y смотрит вниз).
const wings = [
  { x0: 100, y0: 100, x1: 380, y1: 880 }, // левое крыло
  { x0: 620, y0: 100, x1: 900, y1: 880 }, // правое крыло
  { x0: 100, y0: 100, x1: 900, y1: 380 }  // верхнее крыло
];

function inWings(x, y) {
  return wings.some((w) => x >= w.x0 && x <= w.x1 && y >= w.y0 && y <= w.y1);
}

// Клетки схемы: центр клетки попал в крыло — клетка занята. Двор пустой.
const cells = [];
for (let iy = 0; iy < PLAN_GRID; iy++) {
  for (let ix = 0; ix < PLAN_GRID; ix++) {
    const cx = (ix + 0.5) * CELL;
    const cy = (iy + 0.5) * CELL;
    if (inWings(cx, cy)) cells.push([ix, iy]);
  }
}

const plan = { grid: PLAN_GRID, cells };

// Линии стен: { from, to, normal } в тех же координатах 0..1000, что и схема.
// normal — наружу от стены (для схемы ось Y уже перевёрнута).
const facades = [
  { compass: "север", from: [100, 100], to: [900, 100], normal: [0, -1] },
  { compass: "восток", from: [900, 100], to: [900, 880], normal: [1, 0] },
  { compass: "юг", from: [620, 880], to: [900, 880], normal: [0, 1] },
  { compass: "юг", from: [100, 880], to: [380, 880], normal: [0, 1] },
  { compass: "запад", from: [100, 880], to: [100, 100], normal: [-1, 0] },
  { compass: "двор", from: [380, 380], to: [380, 880], normal: [1, 0] },
  { compass: "двор", from: [620, 880], to: [620, 380], normal: [-1, 0] },
  { compass: "двор", from: [380, 380], to: [620, 380], normal: [0, 1] }
].map((f, i) => ({
  index: i + 1,
  compass: f.compass,
  name: "Фасад " + (i + 1),
  pageName: "Фасад " + (i + 1) + " — " + f.compass,
  aspect: "3:4",
  selected: true,
  segment: {
    from: f.from,
    to: f.to,
    normal: f.normal,
    area: Math.round(Math.hypot(f.to[0] - f.from[0], f.to[1] - f.from[1]) * 3)
  }
}));

const payload = {
  scope: "context",
  plan,
  aspects: [
    ["3:4", "3:4 (по умолчанию)"],
    ["2:3", "2:3"],
    ["9:16", "9:16"],
    ["1:1", "1:1"],
    ["4:3", "4:3"],
    ["3:2", "3:2"],
    ["16:9", "16:9"]
  ],
  defaultAspect: "3:4",
  longestSide: 9999,
  deleteScenes: true,
  cutSections: true,
  baseName: "Заречная",
  facades
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
