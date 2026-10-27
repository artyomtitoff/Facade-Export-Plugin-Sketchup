// Запуск автотестов плагина без установленного SketchUp (Ruby-WASM + Node).
//
//   npm install
//   npm test
//
// Ruby-код плагина исполняется в WebAssembly-версии Ruby (3.3) поверх
// заглушки SketchUp API из test/mock_sketchup.rb. Файловая система —
// виртуальная (в памяти), поэтому тестовый экспорт ничего не пишет на диск.
//
// Плагин для SketchUp эти файлы не использует.

import fs from "node:fs/promises";
import path from "node:path";
import { DefaultRubyVM } from "@ruby/wasm-wasi/dist/browser";

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");

const LIB_ORDER = [
  "config", "util", "scene_state", "framing", "sun", "glass", "exporter",
  "auto_facades", "auto_export", "dialogs", "main",
];

const read = (rel) => fs.readFile(path.join(root, rel), "utf8");

// Строковый литерал Ruby в двойных кавычках (JSON-экранирование совместимо,
// дополнительно нейтрализуем интерполяцию #{} и #@).
function rubyString(text) {
  return JSON.stringify(text).replace(/#(?=\{|@)/g, "\\#");
}

function strip(code) {
  return code
    .replace(/^\s*require_relative.*$/gm, "")
    .replace(/^\s*require ['"](sketchup(?:\.rb)?|extensions(?:\.rb)?)['"].*$/gm, "");
}

async function bootVm() {
  const wasmPath = path.join(root, "node_modules/@ruby/3.3-wasm-wasi/dist/ruby+stdlib.wasm");
  const binary = await fs.readFile(wasmPath);
  const module = await WebAssembly.compile(binary);
  const { vm } = await DefaultRubyVM(module, { consolePrint: false });
  return vm;
}

// ---------------------------------------------------------------- синтаксис

async function checkSyntax(vm) {
  const targets = ["facade_export.rb", ...LIB_ORDER.map((n) => `facade_export/${n}.rb`)];
  const chunks = targets.map(async (rel) => {
    const source = await read(rel);
    return [
      "begin",
      `  RubyVM::InstructionSequence.compile(${rubyString(source)})`,
      `  results << "OK ${rel}"`,
      "rescue SyntaxError => e",
      `  results << "FAIL ${rel}: " + e.message`,
      "end",
    ].join("\n");
  });
  const code = (await Promise.all(chunks)).join("\n");
  const report = vm
    .eval(`results = []\n${code}\nresults.join("\\n")`)
    .toString();
  const bad = report.split("\n").filter((line) => line.startsWith("FAIL"));
  if (bad.length > 0) {
    console.error("Синтаксис Ruby-файлов: ОШИБКИ");
    console.error(report);
    return false;
  }
  console.log(`Синтаксис Ruby-файлов: в порядке (${targets.length} файлов)`);
  return true;
}

// ------------------------------------------------------------------- тесты

async function runTests(vm) {
  const parts = [await read("test/mock_sketchup.rb")];
  for (const name of LIB_ORDER) {
    parts.push(await read(`facade_export/${name}.rb`));
  }
  parts.push(await read("test/run_tests.rb"));
  const body = strip(parts.join("\n"));

  const script = [
    "require 'stringio'",
    "buf = StringIO.new",
    "old_out = $stdout",
    "$stdout = buf",
    "status = 0",
    "begin",
    body,
    "rescue SystemExit => e",
    "  status = e.status || 0",
    "rescue Exception => e",
    '  buf.puts "ИСКЛЮЧЕНИЕ: #{e.class}: #{e.message}"',
    '  buf.puts e.backtrace.first(20).join("\\n")',
    "  status = 1",
    "ensure",
    "  $stdout = old_out",
    "end",
    `"STATUS=#{status}\\n" + buf.string`,
  ].join("\n");

  try {
    const text = vm.eval(script).toString();
    const idx = text.indexOf("\n");
    const status = Number(text.slice(0, idx).replace("STATUS=", "")) || 0;
    process.stdout.write(text.slice(idx + 1));
    return status === 0;
  } catch (e) {
    console.error("Не удалось выполнить тесты:", (e.message || String(e)).slice(0, 4000));
    return false;
  }
}

// ------------------------------------------------------------------ иконки

async function checkIcons() {
  const dir = path.join(root, "facade_export", "icons");
  let ok = true;
  for (const name of ["export_all", "export_one", "auto", "settings"]) {
    for (const size of [24, 32]) {
      const file = path.join(dir, `${name}_${size}.png`);
      try {
        const stat = await fs.stat(file);
        if (stat.size < 200) throw new Error("слишком маленький файл");
      } catch (e) {
        console.error(`Нет иконки ${file}: ${e.message}`);
        ok = false;
      }
    }
  }
  if (ok) console.log("Иконки кнопок: на месте (24 и 32 px)");
  return ok;
}

// ------------------------------------------------------------------- запуск

const vm = await bootVm();
const syntaxOk = await checkSyntax(vm);
const iconsOk = await checkIcons();
const testsOk = await runTests(vm);

process.exit(syntaxOk && iconsOk && testsOk ? 0 : 1);
