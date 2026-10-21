#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Схема результата: 4 фасада × 4 карты = 16 PNG.

Рисует наглядную схему (не «настоящий» рендер SketchUp) того, что получится
в папке: каждая карта показана своим стилем. Используется в документации.

  python3 tools/make_scheme.py   ->  docs/maps_scheme.png
"""

import os
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT = os.path.join(ROOT, "docs", "maps_scheme.png")

FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
FONT_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"

LEFT = 252            # ширина колонки с названиями карт
CELL_W, CELL_H = 278, 152
GAP_X, GAP_Y = 24, 22
MARGIN = 26
TOP = 118

BG = (247, 248, 250)
PANEL = (255, 255, 255)
BORDER = (223, 227, 233)
INK = (37, 52, 78)
MUTED = (112, 122, 136)
GLASS = (0, 255, 21)
BRICK = (188, 128, 98)
ROOF = (132, 100, 88)
SHADOW = (176, 176, 176)

W = LEFT + 4 * CELL_W + 3 * GAP_X + MARGIN
H = TOP + 4 * CELL_H + 3 * GAP_Y + 86


def font(size, bold=False):
    return ImageFont.truetype(FONT_BOLD if bold else FONT, size)


def draw_house(d, box, *, wall=None, roof=None, outline=INK, windows_fill=None,
               shadow=False, brick=False, width=3):
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    roof_y = y0 + h * 0.30

    # тень на земле: солнце слева сверху -> тень вправо-вниз
    if shadow:
        d.polygon([
            (x0 + w * 0.05, y1),
            (x1 + w * 0.34, y1 + h * 0.10),
            (x1 + w * 0.34, y1 + h * 0.20),
            (x0 + w * 0.05, y1 + h * 0.10),
        ], fill=SHADOW)
        # затенённая правая часть стены
        d.polygon([(x1 - w * 0.10, roof_y), (x1, roof_y), (x1, y1),
                   (x1 - w * 0.10, y1)], fill=(238, 238, 238))

    # стена
    body = [(x0, roof_y), (x1, roof_y), (x1, y1), (x0, y1)]
    if wall:
        d.polygon(body, fill=wall)
    if brick:
        for y in range(int(roof_y) + 10, int(y1), 10):
            d.line([(x0 + 2, y), (x1 - 2, y)], fill=(120, 70, 50), width=1)
    d.line([(x0, y1), (x0, roof_y)], fill=outline, width=width)
    d.line([(x1, y1), (x1, roof_y)], fill=outline, width=width)
    d.line([(x0, y1), (x1, y1)], fill=outline, width=width)

    # крыша
    apex = ((x0 + x1) / 2.0, y0)
    if roof:
        d.polygon([(x0 - 5, roof_y), apex, (x1 + 5, roof_y)], fill=roof)
    d.line([(x0 - 5, roof_y), apex, (x1 + 5, roof_y)], fill=outline, width=width, joint="curve")

    # окна
    wy = roof_y + h * 0.15
    ww, wh = w * 0.19, h * 0.22
    for cx in (x0 + w * 0.21, x0 + w * 0.60):
        rect = [cx, wy, cx + ww, wy + wh]
        if windows_fill:
            d.rectangle(rect, fill=windows_fill, outline=outline, width=2)
        else:
            d.rectangle(rect, outline=outline, width=2)

    # дверь
    door = [(x0 + w * 0.44, y1), (x0 + w * 0.44, y1 - h * 0.22),
            (x0 + w * 0.56, y1 - h * 0.22), (x0 + w * 0.56, y1)]
    if wall:
        d.polygon(door, fill=(96, 74, 62))
    d.line(door[:2], fill=outline, width=2)
    d.line(door[1:3], fill=outline, width=2)
    d.line(door[2:], fill=outline, width=2)


def main():
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img, "RGBA")

    d.text((MARGIN, 24), "Результат: 4 фасада × 4 карты = 16 PNG",
           font=font(25, True), fill=INK)
    d.text((MARGIN, 60),
           "Имя_Фасад_Номер_Карта.png   ·   например  Заречная_Фасад_1_Текстура.png",
           font=font(14), fill=MUTED)

    maps = [
        ("Текстура", ["текстуры,", "без линий"]),
        ("Линии", ["только края"]),
        ("Тени", ["солнце 45°", "слева сверху"]),
        ("Окна", ["стекло", "H 125 / S 100 / L 50"]),
    ]

    for col in range(4):
        x = LEFT + col * (CELL_W + GAP_X)
        d.text((x + CELL_W / 2, TOP - 32), f"Фасад {col + 1}",
               font=font(17, True), fill=INK, anchor="mm")

    for row, (name, subtitle) in enumerate(maps):
        y = TOP + row * (CELL_H + GAP_Y)
        d.text((MARGIN, y + CELL_H / 2 - 26), name, font=font(20, True), fill=INK)
        for i, line in enumerate(subtitle):
            d.text((MARGIN, y + CELL_H / 2 + 2 + i * 17), line, font=font(12), fill=MUTED)

        for col in range(4):
            x = LEFT + col * (CELL_W + GAP_X)
            d.rounded_rectangle([x, y, x + CELL_W, y + CELL_H], radius=10,
                                fill=PANEL, outline=BORDER, width=1)
            box = (x + 66, y + 26, x + CELL_W - 66, y + CELL_H - 34)

            if name == "Текстура":
                draw_house(d, box, wall=BRICK, roof=ROOF, brick=True,
                           windows_fill=(214, 230, 240))
            elif name == "Линии":
                draw_house(d, box)
            elif name == "Тени":
                draw_house(d, box, wall=PANEL, roof=(232, 232, 232), shadow=True)
            else:
                draw_house(d, box, wall=PANEL, roof=(232, 232, 232), windows_fill=GLASS)

            label = f"Заречная_Фасад_{col + 1}_{name}.png"
            d.text((x + CELL_W / 2, y + CELL_H - 14), label,
                   font=font(10), fill=MUTED, anchor="mm")

    footer = ("Все 16 кадров — одного размера и одного масштаба, поэтому карты "
              "совмещаются пиксель в пиксель в фоторедакторе.")
    d.text((MARGIN, H - 34), footer, font=font(12), fill=MUTED)

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    img.save(OUT)
    print("Готово:", os.path.relpath(OUT, ROOT), f"({W}×{H})")


if __name__ == "__main__":
    main()
