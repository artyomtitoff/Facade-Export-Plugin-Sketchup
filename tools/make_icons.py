#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Иконки плагина "Экспорт фасадов" — из эскизов автора, без правок рисунка.

Источники (32×32, прозрачный фон) лежат в tools/icons_src/:

  icon_all.png       — «Экспорт всех фасадов»: раскрытая коробка,
                       все четыре стены розовые;
  icon_one.png       — «Экспорт фасада»: та же коробка,
                       выделена только передняя левая стена;
  icon_settings.png  — «Настройки»: шестерёнка;
  icon_auto.png      — «Автоматический вывод фасада»: такая же коробка,
                       но вокруг неё красные уголки-«прицел» (кнопка сама
                       находит фасады). Этот файл не авторский: его рисует
                       tools/make_icon_auto.py в том же стиле.

Файл *_32.png — это ровно исходный PNG автора (копируется байт в байт).
Файл *_24.png — единственное, что делает скрипт: уменьшение 32 → 24
(панель SketchUp на Windows берёт 24 px). Уменьшение идёт с
премультиплицированной альфой, поэтому по краям не появляется тёмная кайма.

Запуск:  python3 tools/make_icons.py
"""

import os
import shutil

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC_DIR = os.path.join(HERE, "icons_src")
OUT_DIR = os.path.join(ROOT, "facade_export", "icons")
DOCS_DIR = os.path.join(ROOT, "docs")

# файл автора -> имя иконки в плагине
SOURCES = [
    ("icon_all.png", "export_all"),
    ("icon_one.png", "export_one"),
    ("icon_settings.png", "settings"),
    ("icon_auto.png", "auto"),
]

SMALL = 24      # размер для панели инструментов
LARGE = 32      # исходный размер автора (не меняется)


def source_path(name):
    path = os.path.join(SRC_DIR, name)
    if not os.path.exists(path):
        raise SystemExit("Нет файла-источника: %s" % path)
    return path


def copy_large(src, key):
    """32×32 — исходный файл автора без единого изменения."""
    dst = os.path.join(OUT_DIR, "%s_%d.png" % (key, LARGE))
    if os.path.abspath(src) != os.path.abspath(dst):
        shutil.copyfile(src, dst)
    print("  %-22s %dx%d (копия исходника)" % (os.path.basename(dst), LARGE, LARGE))
    return Image.open(dst).convert("RGBA")


def make_small(img, key):
    """24×24 — уменьшение с премультиплицированной альфой."""
    small = img.convert("RGBa").resize((SMALL, SMALL), Image.LANCZOS).convert("RGBA")
    dst = os.path.join(OUT_DIR, "%s_%d.png" % (key, SMALL))
    small.save(dst, "PNG", optimize=True)
    print("  %-22s %dx%d" % (os.path.basename(dst), SMALL, SMALL))
    return small


def make_preview(icons):
    """Превью: 24 px, 32 px и увеличенные версии на светлом и тёмном фоне."""
    pad, col_w = 24, 216
    width = pad + col_w * len(icons)
    sheet = Image.new("RGBA", (width, 470), (246, 247, 249, 255))
    x = pad
    for _key, large, small in icons:
        sheet.alpha_composite(small, (x, 26))
        sheet.alpha_composite(large, (x + 44, 22))
        big = large.convert("RGBa").resize((160, 160), Image.LANCZOS).convert("RGBA")
        sheet.alpha_composite(big, (x, 96))
        dark = Image.new("RGBA", (160, 160), (70, 72, 78, 255))
        dark.alpha_composite(big)
        sheet.alpha_composite(dark, (x, 288))
        x += col_w
    sheet.save(os.path.join(DOCS_DIR, "icons_preview.png"))


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    os.makedirs(DOCS_DIR, exist_ok=True)
    icons = []
    print("Иконки автора (tools/icons_src):")
    for src, key in SOURCES:
        large = copy_large(source_path(src), key)
        small = make_small(large, key)
        icons.append((key, large, small))
    make_preview(icons)
    print("Превью: docs/icons_preview.png")


if __name__ == "__main__":
    main()
