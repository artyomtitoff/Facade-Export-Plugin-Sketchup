#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Генератор иконок плагина "Экспорт фасадов".

Стиль взят с иконок пользователя (icon1.png / icon2.png):

  * открытая изометрическая коробка (макет дома) с белым полом внутри;
  * «Экспорт всех фасадов» — все четыре стены розовые #FFD1D1;
  * «Экспорт фасада»      — только передняя левая стена сиреневая #D7D9FF;
  * контур — #3C3C3C.

Иконки рисуются в 8-кратном разрешении и уменьшаются с LANCZOS —
так получаются аккуратные края и чистая альфа на 24/32 px.

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

INK   = (60, 60, 60, 255)     # #3C3C3C
PINK  = (255, 209, 209, 255)  # #FFD1D1
LILAC = (215, 217, 255, 255)  # #D7D9FF
WHITE = (255, 255, 255, 255)

OUTLINE = 12

# Геометрия коробки (логические координаты 256×256).
TOP_T = (128, 28)
TOP_R = (218, 80)
TOP_B = (128, 132)
TOP_L = (38, 80)
WALL = 84

BOT_R = (TOP_R[0], TOP_R[1] + WALL)
BOT_B = (TOP_B[0], TOP_B[1] + WALL)
BOT_L = (TOP_L[0], TOP_L[1] + WALL)

# Внутренний ромб — пол коробки.
FLOOR = 0.78
FLOOR_T = (128, 80 - (80 - TOP_T[1]) * FLOOR)
FLOOR_R = (128 + (TOP_R[0] - 128) * FLOOR, 80)
FLOOR_B = (128, 80 + (TOP_B[1] - 80) * FLOOR)
FLOOR_L = (128 - (128 - TOP_L[0]) * FLOOR, 80)


def s(v):
    return int(round(v * SS))


def p(pt):
    return (s(pt[0]), s(pt[1]))


def poly(draw, pts, fill, outline=None, width=0):
    pts = [p(pt) for pt in pts]
    if outline and width:
        draw.polygon(pts, fill=fill)
        draw.line(pts + [pts[0]], fill=outline, width=s(width), joint="curve")
    else:
        draw.polygon(pts, fill=fill)


def line(draw, pts, color, width):
    draw.line([p(pt) for pt in pts], fill=color, width=s(width), joint="curve")


def box(body, left_face=None, floor=WHITE):
    """Открытая коробка: стены body, левая стена left_face (если задана)."""
    img = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # 1. Внешний силуэт коробки.
    silhouette = [TOP_T, TOP_R, BOT_R, BOT_B, BOT_L, TOP_L]
    poly(d, silhouette, body, INK, OUTLINE)

    # 2. Левая (передняя левая) стена — другой цвет.
    if left_face:
        wall = [TOP_L, TOP_B, BOT_B, BOT_L]
        poly(d, wall, left_face)
        # верхняя кромка этой стены (часть обода)
        rim = [TOP_L, TOP_B, FLOOR_B, FLOOR_L]
        poly(d, rim, left_face)

    # 3. Внутренний обод: верхняя плоскость стен вокруг проёма.
    rim_outer = [TOP_T, TOP_R, TOP_B, TOP_L]
    line(d, rim_outer + [TOP_T], INK, OUTLINE)

    # 4. Пол внутри коробки.
    floor_pts = [FLOOR_T, FLOOR_R, FLOOR_B, FLOOR_L]
    poly(d, floor_pts, floor, INK, OUTLINE)

    # 5. Переднее вертикальное ребро коробки.
    line(d, [TOP_B, BOT_B], INK, OUTLINE)

    return img


def icon_export_all():
    """Все четыре стены розовые — экспорт всех фасадов."""
    return box(PINK)


def icon_export_one():
    """Только передняя левая стена сиреневая — экспорт одного фасада."""
    return box(WHITE, left_face=LILAC)


def icon_settings():
    """Заглушка шестерёнки в той же палитре (пользователь заменит своей)."""
    img = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    cx, cy = 128, 128
    r_disc, r_tooth, r_hole, r_ring = 78, 114, 30, 52
    for i in range(8):
        ang = math.pi / 4.0 * i
        half_w = 26
        pts = []
        for rr, off in ((r_disc - 8, -half_w), (r_tooth, -half_w * 0.72),
                        (r_tooth, half_w * 0.72), (r_disc - 8, half_w)):
            pts.append((cx + rr * math.cos(ang) - off * math.sin(ang),
                        cy + rr * math.sin(ang) + off * math.cos(ang)))
        poly(d, pts, INK)
    d.ellipse([s(cx - r_disc), s(cy - r_disc), s(cx + r_disc), s(cy + r_disc)], fill=INK)
    d.ellipse([s(cx - r_ring), s(cy - r_ring), s(cx + r_ring), s(cy + r_ring)], fill=WHITE)
    d.ellipse([s(cx - r_ring + 17), s(cy - r_ring + 17),
               s(cx + r_ring - 17), s(cy + r_ring - 17)], fill=INK)
    d.ellipse([s(cx - r_hole), s(cy - r_hole), s(cx + r_hole), s(cy + r_hole)], fill=WHITE)
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
    for _key, img in icons:
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
