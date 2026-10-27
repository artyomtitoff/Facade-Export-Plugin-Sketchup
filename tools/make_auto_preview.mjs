// Собирает docs/auto_preview.html — копию окна «Автоматический вывод фасада»,
// которую можно открыть в браузере без SketchUp (для проверки вида).
//
//   node tools/make_auto_preview.mjs
//
// Данные — как их отдаёт AutoExport.build_payload: упрощённые превью фасадов
// и контур здания сверху для схемы с красной линией.

import fs from "node:fs/promises";
import path from "node:path";

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");

// Здание с внутренним двором (П-образное): именно для такого случая
// и нужны секущие плоскости. Схема сверху — та же сетка клеток, что
// строит AutoFacades#plan_map: двор остаётся пустым.
const PLAN_GRID = 32;
const courtyard = (x, y) => x >= 10 && x <= 21 && y >= 12; // клетки двора
const planCells = [];
for (let y = 0; y < PLAN_GRID; y++) {
  for (let x = 0; x < PLAN_GRID; x++) {
    if (!courtyard(x, y)) planCells.push([x, y]);
  }
}
const plan = { grid: PLAN_GRID, cells: planCells };

// Упрощённые фасады: сетка окон на стене (координаты 0..1000).
function facadePolygons(widthRatio, floors, windows) {
  const polys = [[[0, 0], [1000, 0], [1000, 1000], [0, 1000]]];
  const w = 1000 * widthRatio;
  for (let f = 0; f < floors; f++) {
    for (let c = 0; c < windows; c++) {
      const x0 = Math.round(60 + c * (w - 120) / windows);
      const x1 = Math.round(x0 + (w - 120) / windows * 0.62);
      const y0 = Math.round(80 + f * (900 / floors));
      const y1 = Math.round(y0 + (900 / floors) * 0.5);
      polys.push([[x0, y0], [x1, y0], [x1, y1], [x0, y1]]);
    }
  }
  return polys;
}

const payload = {
  scope: "context",
  scopeText: "открытая группа",
  plan,
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
    { index: 1, compass: "север", normal: [0, 1], polygons: facadePolygons(1, 6, 5) },
    { index: 2, compass: "восток", normal: [1, 0], polygons: facadePolygons(0.62, 6, 3) },
    { index: 3, compass: "юг", normal: [0, -1], polygons: facadePolygons(1, 5, 5) },
    { index: 4, compass: "запад", normal: [-1, 0], polygons: facadePolygons(0.62, 5, 3) },
  ].map((f) => ({
    ...f,
    name: "Фасад " + f.index,
    pageName: "Фасад " + f.index + " — " + f.compass,
    aspect: "3:4",
    selected: true,
  })),
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
