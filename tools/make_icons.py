#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Генератор иконок плагина "Экспорт фасадов".

Иконки рисуются в 8-кратном разрешении и уменьшаются с LANCZOS —
так получаются аккуратные края и чистая альфа на 24/32 px.

«Экспорт всех фасадов» — сетка 2×2 из четырёх листов-фасадов,
«Экспорт фасада»      — один лист с домом,
у обеих кнопок снизу справа — зелёная стрелка экспорта.

Запуск:  python3 tools/make_icons.py
"""

import math
import os

from PIL import Image, ImageDraw

SS = 8                     # суперсэмплинг
BASE = 256                 # логический размер
CANVAS = BASE * SS

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT_DIR = os.path.join(ROOT, "facade_export", "icons")
DOCS_DIR = os.path.join(ROOT, "docs")

INK      = (37, 52, 78, 255)
INK_SOFT = (150, 166, 190, 255)
PAPER    = (255, 255, 255, 255)
ACCENT   = (16, 154, 88, 255)
BLUE     = (31, 111, 235, 255)


def s(v):
    return int(round(v * SS))


def rounded(draw, box, radius, fill, outline=None, width=0):
    draw.rounded_rectangle(
        [s(box[0]), s(box[1]), s(box[2]), s(box[3])],
        radius=s(radius), fill=fill, outline=outline, width=s(width))


def line(draw, pts, color, width):
    draw.line([(s(x), s(y)) for x, y in pts], fill=color, width=s(width), joint="curve")


def poly(draw, pts, fill, outline=None, width=0):
    draw.polygon([(s(x), s(y)) for x, y in pts], fill=fill, outline=outline,
                 width=s(width) if width else 0)


def scale_poly(pts, cx, cy, k):
    return [(cx + (x - cx) * k, cy + (y - cy) * k) for x, y in pts]


def arrow(draw, cx, top, neck, tip, stem_w, head_w,
          color=ACCENT, outline=INK, outline_w=7):
    """Стрелка вниз единым контуром (без разрыва между древком и остриём)."""
    hs = stem_w / 2.0
    hh = head_w / 2.0
    pts = [(cx - hs, top), (cx + hs, top), (cx + hs, neck), (cx + hh, neck),
           (cx, tip), (cx - hh, neck), (cx - hs, neck)]
    cy = (top + tip) / 2.0
    # белый "зазор" вокруг стрелки
    halo = scale_poly(pts, cx, cy, 1.0 + (2.0 * (outline_w + 4)) / max(tip - top, 1))
    poly(draw, halo, PAPER)
    poly(draw, pts, color, outline, outline_w)


def house(draw, x0, y0, x1, y1, color=INK, w=8, roof=0.36):
    """Силуэт фасада дома внутри прямоугольника."""
    dx = x1 - x0
    dy = y1 - y0
    roof_h = dy * roof
    line(draw, [(x0, y1), (x0, y0 + roof_h)], color, w)
    line(draw, [(x1, y1), (x1, y0 + roof_h)], color, w)
    line(draw, [(x0, y0 + roof_h), ((x0 + x1) / 2.0, y0)], color, w)
    line(draw, [((x0 + x1) / 2.0, y0), (x1, y0 + roof_h)], color, w)
    line(draw, [(x0 - dx * 0.05, y1), (x1 + dx * 0.05, y1)], color, w)
    # окна
    wy0 = y0 + roof_h + dy * 0.18
    wy1 = wy0 + dy * 0.22
    rounded(draw, (x0 + dx * 0.14, wy0, x0 + dx * 0.40, wy1), 2, color)
    rounded(draw, (x1 - dx * 0.40, wy0, x1 - dx * 0.14, wy1), 2, color)


def icon_export_all():
    """Четыре листа-фасада (2×2) + стрелка экспорта."""
    img = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    cells = [(2, 4, 88, 86), (94, 4, 180, 86),
             (2, 92, 88, 174), (94, 92, 180, 174)]
    for (x0, y0, x1, y1) in cells:
        # тень-подложка для объёма
        rounded(d, (x0 + 5, y0 + 6, x1 + 5, y1 + 6), 10, (0, 0, 0, 26))
        rounded(d, (x0, y0, x1, y1), 10, PAPER, INK, 7)
        house(d, x0 + 14, y0 + 14, x1 - 14, y1 - 13, INK, 5)
    arrow(d, cx=210, top=96, neck=170, tip=250, stem_w=34, head_w=84)
    return img


def icon_export_one():
    """Один лист с фасадом + стрелка экспорта."""
    img = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    rounded(d, (18, 26, 236, 216), 18, (0, 0, 0, 26))
    rounded(d, (12, 18, 228, 206), 18, PAPER, INK, 9)
    house(d, 46, 52, 196, 176, INK, 8)
    arrow(d, cx=196, top=150, neck=178, tip=250, stem_w=34, head_w=88)
    return img


def icon_settings():
    """Шестерёнка."""
    img = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    cx, cy = 128, 126
    r_disc, r_tooth, r_hole, r_ring = 80, 116, 32, 54
    for i in range(8):
        ang = math.pi / 4.0 * i
        half_w = 27
        pts = []
        for rr, off in ((r_disc - 8, -half_w), (r_tooth, -half_w * 0.72),
                        (r_tooth, half_w * 0.72), (r_disc - 8, half_w)):
            pts.append((cx + rr * math.cos(ang) - off * math.sin(ang),
                        cy + rr * math.sin(ang) + off * math.cos(ang)))
        poly(d, pts, INK)
    d.ellipse([s(cx - r_disc), s(cy - r_disc), s(cx + r_disc), s(cy + r_disc)], fill=INK)
    d.ellipse([s(cx - r_ring), s(cy - r_ring), s(cx + r_ring), s(cy + r_ring)], fill=PAPER)
    d.ellipse([s(cx - r_ring + 18), s(cy - r_ring + 18),
               s(cx + r_ring - 18), s(cy + r_ring - 18)], fill=INK)
    d.ellipse([s(cx - r_hole), s(cy - r_hole), s(cx + r_hole), s(cy + r_hole)], fill=PAPER)
    return img


def save(img, size, name):
    img.resize((size, size), Image.LANCZOS).save(
        os.path.join(OUT_DIR, name), "PNG", optimize=True)
    print("  %-22s %dx%d" % (name, size, size))


def make_preview(icons):
    """Превью: 24 px и 32 px, а также увеличенные версии."""
    pad, col_w = 24, 216
    width = pad + col_w * len(icons)
    sheet = Image.new("RGBA", (width, 400), (246, 247, 249, 255))
    x = pad
    for key, img in icons:
        sheet.alpha_composite(img.resize((24, 24), Image.LANCZOS), (x, 26))
        sheet.alpha_composite(img.resize((32, 32), Image.LANCZOS), (x + 44, 22))
        sheet.alpha_composite(img.resize((160, 160), Image.LANCZOS), (x, 96))
        x += col_w
    sheet.save(os.path.join(DOCS_DIR, "icons_preview.png"))


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    os.makedirs(DOCS_DIR, exist_ok=True)
    icons = [
        ("export_all", icon_export_all()),
        ("export_one", icon_export_one()),
        ("settings", icon_settings()),
    ]
    print("Записываю иконки в", OUT_DIR)
    for key, img in icons:
        for size in (24, 32):
            save(img, size, "%s_%d.png" % (key, size))
    make_preview(icons)
    print("Превью: docs/icons_preview.png")


if __name__ == "__main__":
    main()
