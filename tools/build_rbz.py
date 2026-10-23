#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Сборка архива расширения SketchUp (.rbz) для плагина "Экспорт фасадов".

  python3 tools/build_rbz.py

Результат: dist/FacadeExport_v<версия>.rbz
Структура архива (как требует Менеджер расширений SketchUp):

  facade_export.rb
  facade_export/*.rb
  facade_export/html/settings.html
  facade_export/icons/*.png
"""

import os
import re
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DIST = os.path.join(ROOT, "dist")

# файлы и папки, которые попадают в архив
INCLUDE = [
    "facade_export.rb",
    "facade_export",
]

# то, что в архив не кладём
EXCLUDE_DIRS = {"__pycache__", ".DS_Store", "node_modules"}
EXCLUDE_EXT = {".bak", ".orig", ".log", ".pyc"}


def read_version():
    path = os.path.join(ROOT, "facade_export", "main.rb")
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    match = re.search(r"VERSION\s*=\s*'([^']+)'", text)
    return match.group(1) if match else "0.0.0"


def iter_files():
    for item in INCLUDE:
        path = os.path.join(ROOT, item)
        if os.path.isfile(path):
            yield path, item
        elif os.path.isdir(path):
            for dirpath, dirnames, filenames in os.walk(path):
                dirnames[:] = sorted(d for d in dirnames if d not in EXCLUDE_DIRS)
                for name in sorted(filenames):
                    if name.startswith(".") or os.path.splitext(name)[1] in EXCLUDE_EXT:
                        continue
                    full = os.path.join(dirpath, name)
                    rel = os.path.relpath(full, ROOT).replace(os.sep, "/")
                    yield full, rel


def check_syntax(files):
    """Простые проверки: UTF-8, отсутствие табуляции в Ruby, баланс end."""
    problems = []
    for full, rel in files:
        if not rel.endswith(".rb"):
            continue
        with open(full, "rb") as fh:
            raw = fh.read()
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            problems.append(f"{rel}: не UTF-8 ({exc})")
            continue
        if "\t" in text:
            problems.append(f"{rel}: содержит табуляцию")
        if not text.startswith("# encoding: utf-8"):
            problems.append(f"{rel}: нет строки '# encoding: utf-8'")
    return problems


def main():
    version = read_version()
    files = list(iter_files())

    problems = check_syntax(files)
    if problems:
        print("Проверка не пройдена:")
        for p in problems:
            print("  -", p)
        return 1

    os.makedirs(DIST, exist_ok=True)
    out = os.path.join(DIST, f"FacadeExport_v{version}.rbz")
    if os.path.exists(out):
        os.remove(out)

    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
        for full, rel in files:
            zf.write(full, rel)

    size = os.path.getsize(out)
    print(f"Готово: {os.path.relpath(out, ROOT)}")
    print(f"  файлов: {len(files)}, размер: {size / 1024.0:.1f} КБ")
    for _full, rel in files:
        print("  ", rel)
    return 0


if __name__ == "__main__":
    sys.exit(main())
