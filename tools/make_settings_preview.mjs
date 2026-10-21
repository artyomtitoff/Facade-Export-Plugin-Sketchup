// Собирает docs/settings_preview.html — копию окна настроек плагина,
// которую можно открыть в браузере без SketchUp (для проверки вида).
//
//   node tools/make_settings_preview.mjs
//
// Значения по умолчанию берутся из facade_export/config.rb, поэтому
// превью всегда совпадает с реальным окном.

import fs from "node:fs/promises";
import path from "node:path";
import { DefaultRubyVM } from "@ruby/wasm-wasi/dist/browser";

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");

// Ruby-WASM не видит файлы хоста — передаём исходник config.rb строкой.
const configSource = await fs.readFile(path.join(root, "facade_export/config.rb"), "utf8");

const ruby = [
  "require 'stringio'",
  "require 'json'",
  "$stdout = StringIO.new",
  configSource.replace(/^\s*require_relative.*$/gm, ""),
  "JSON.generate(FacadeExport::Config.default_settings)",
].join("\n");

const wasmPath = path.join(root, "node_modules/@ruby/3.3-wasm-wasi/dist/ruby+stdlib.wasm");
const binary = await fs.readFile(wasmPath);
const module = await WebAssembly.compile(binary);
const { vm } = await DefaultRubyVM(module, { consolePrint: false });

let defaults;
try {
  defaults = JSON.parse(vm.eval(ruby).toString());
} catch (e) {
  console.error("Не удалось прочитать config.rb:", (e.message || e).toString().slice(0, 2000));
  process.exit(1);
}

const html = await fs.readFile(path.join(root, "facade_export/html/settings.html"), "utf8");
const injection =
  `<script>window.FACADE_EXPORT_DEMO = ${JSON.stringify(defaults, null, 2)};</script>\n` +
  `<div style="background:#fff8e1;border-bottom:1px solid #f0d48a;padding:8px 18px;font:13px/1.4 sans-serif;color:#6b5b1f">` +
  `Демонстрационная страница окна настроек плагина «Экспорт фасадов». В SketchUp эти же настройки ` +
  `открываются через <b>Расширения → Экспорт фасадов → Настройки…</b></div>`;

const out = html
  .replace("<body>", "<body>\n" + injection)
  .replace("<title>Экспорт фасадов — настройки</title>",
           "<title>Экспорт фасадов — настройки (превью)</title>");

await fs.mkdir(path.join(root, "docs"), { recursive: true });
await fs.writeFile(path.join(root, "docs/settings_preview.html"), out, "utf8");
console.log("Готово: docs/settings_preview.html");
