#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Иконка «Автоматический вывод фасада» (32×32, прозрачный фон).

Рисуется в том же стиле, что и иконки автора (tools/icons_src/icon_all.png):
изометрическая коробка с тёмным контуром и розовыми стенами. Отличие —
красные уголки-«прицел» вокруг коробки: кнопка не экспортирует готовый вид,
а сама находит фасады в модели.

Запуск:  python3 tools/make_icon_auto.py
"""

import os

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
SRC_DIR = os.path.join(HERE, "icons_src")
SIZE = 32
SS = 8  # сглаживание: рисуем крупно и уменьшаем

OUTLINE = (60, 60, 60, 255)
PINK = (244, 198, 198, 255)
PINK_SHADE = (238, 182, 182, 255)
WHITE = (255, 255, 255, 255)
RED = (224, 49, 49, 255)


def s(v):
    return v * SS


def draw_cube(draw):
    """Изометрическая коробка: белая крышка, розовые стены."""
    left, right = 6.0, 26.0
    top_y = 5.0
    mid_x = 16.0
    mid_top = 10.0
    mid_bottom = 15.0
    floor_y = 27.0
    wall_y = 21.8

    top = [(mid_x, top_y), (right, mid_top), (mid_x, mid_bottom), (left, mid_top)]
    left_face = [(left, mid_top), (mid_x, mid_bottom), (mid_x, floor_y), (left, wall_y)]
    right_face = [(mid_x, mid_bottom), (right, mid_top), (right, wall_y), (mid_x, floor_y)]

    width = max(1, round(1.1 * SS))
    draw.polygon([(s(x), s(y)) for x, y in left_face], fill=PINK)
    draw.polygon([(s(x), s(y)) for x, y in right_face], fill=PINK_SHADE)
    draw.polygon([(s(x), s(y)) for x, y in top], fill=WHITE)

    for face in (top, left_face, right_face):
        pts = [(s(x), s(y)) for x, y in face]
        draw.line(pts + [pts[0]], fill=OUTLINE, width=width, joint="curve")


def draw_brackets(draw):
    """Красные уголки-«прицел» по углам иконки."""
    pad = 1.2
    arm = 4.2
    width = max(1, round(1.9 * SS))
    corners = [
        (pad, pad, 1, 1),
        (SIZE - pad, pad, -1, 1),
        (pad, SIZE - pad, 1, -1),
        (SIZE - pad, SIZE - pad, -1, -1),
    ]
    for x, y, dx, dy in corners:
        draw.line([(s(x), s(y)), (s(x + arm * dx), s(y))], fill=RED, width=width)
        draw.line([(s(x), s(y)), (s(x), s(y + arm * dy))], fill=RED, width=width)


def main():
    os.makedirs(SRC_DIR, exist_ok=True)
    img = Image.new("RGBA", (SIZE * SS, SIZE * SS), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw_cube(draw)
    draw_brackets(draw)
    icon = img.convert("RGBa").resize((SIZE, SIZE), Image.LANCZOS).convert("RGBA")
    dst = os.path.join(SRC_DIR, "icon_auto.png")
    icon.save(dst, "PNG", optimize=True)
    print("  %s %dx%d" % (os.path.relpath(dst), SIZE, SIZE))


if __name__ == "__main__":
    main()
