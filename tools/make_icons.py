#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Иконки плагина "Экспорт фасадов" из эскизов автора.

Источники (32×32, прозрачный фон) лежат в tools/icons_src/:

  icon_all.png       — «Экспорт всех фасадов»: раскрытая коробка,
                       все четыре стены розовые;
  icon_one.png       — «Экспорт фасада»: та же коробка,
                       выделена только передняя левая стена;
  icon_settings.png  — «Настройки»: шестерёнка.

Скрипт только приводит их к размерам панели SketchUp (24 и 32 px)
и собирает превью для документации. Рисунок не перерисовывается.

Уменьшение идёт по премультиплицированной альфе (режим RGBa), поэтому
по краям не появляется тёмная кайма от прозрачных пикселей.

Запуск:  python3 tools/make_icons.py
"""

import os

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC_DIR = os.path.join(HERE, "icons_src")
OUT_DIR = os.path.join(ROOT, "facade_export", "icons")
DOCS_DIR = os.path.join(ROOT, "docs")

# имя файла-источника -> имя иконки в плагине
SOURCES = [
    ("icon_all.png", "export_all"),
    ("icon_one.png", "export_one"),
    ("icon_settings.png", "settings"),
]

SIZES = (24, 32)


def load(name):
    path = os.path.join(SRC_DIR, name)
    if not os.path.exists(path):
        raise SystemExit("Нет файла-источника: %s" % path)
    return Image.open(path).convert("RGBA")


def trim(img):
    """Обрезает пустые поля вокруг рисунка, сохраняя пропорции и поля 1 px."""
    box = img.getbbox()
    if box is None:
        return img
    return img.crop(box)


def square_pad(img, pad_ratio=0.06):
    """Кладёт рисунок в квадрат с одинаковыми полями (иконки в панели ровные)."""
    w, h = img.size
    side = max(w, h)
    pad = int(round(side * pad_ratio))
    canvas = Image.new("RGBA", (side + pad * 2, side + pad * 2), (0, 0, 0, 0))
    canvas.paste(img, (pad + (side - w) // 2, pad + (side - h) // 2), img)
    return canvas


def resize(img, size):
    """Уменьшение с премультиплицированной альфой — без тёмной каймы."""
    return img.convert("RGBa").resize((size, size), Image.LANCZOS).convert("RGBA")


def save(img, size, name):
    out = resize(img, size)
    out.save(os.path.join(OUT_DIR, name), "PNG", optimize=True)
    print("  %-22s %dx%d" % (name, size, size))
    return out


def make_preview(icons):
    """Превью: 24 px, 32 px и увеличенная версия на светлом и тёмном фоне."""
    pad, col_w = 24, 216
    width = pad + col_w * len(icons)
    sheet = Image.new("RGBA", (width, 470), (246, 247, 249, 255))
    x = pad
    for _key, img in icons:
        small = resize(img, 24)
        large = resize(img, 32)
        sheet.alpha_composite(small, (x, 26))
        sheet.alpha_composite(large, (x + 44, 22))
        big = resize(img, 160)
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
    print("Готовлю иконки из tools/icons_src:")
    for src, key in SOURCES:
        img = square_pad(trim(load(src)))
        icons.append((key, img))
        for size in SIZES:
            save(img, size, "%s_%d.png" % (key, size))
    make_preview(icons)
    print("Превью: docs/icons_preview.png")


if __name__ == "__main__":
    main()
