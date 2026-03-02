#!/usr/bin/env python3
"""Generate all 32x32 pixel art sprites for DeepTown.

GBA Pokemon aesthetic — simple shapes, limited palette, no anti-aliasing.
Run: python tools/generate_sprites.py
"""
import os
from PIL import Image, ImageDraw

# --- Output paths ---
BASE = os.path.join(os.path.dirname(__file__), "..", "assets", "sprites")
TILES = os.path.join(BASE, "tiles")
CHARS = os.path.join(BASE, "characters")

# --- GBA-inspired palette ---
# Grass
GRASS       = (76, 160, 56)
GRASS_DARK  = (56, 130, 40)
GRASS_LIGHT = (96, 180, 72)
FLOWER_Y    = (240, 220, 80)
FLOWER_W    = (240, 240, 230)

# Path
PATH_BASE   = (194, 178, 128)
PATH_DARK   = (166, 144, 96)
PATH_LIGHT  = (210, 196, 152)

# Water
WATER       = (51, 136, 204)
WATER_LIGHT = (85, 160, 220)
WATER_DEEP  = (34, 102, 170)

# Wood / Building
WOOD        = (139, 105, 20)
WOOD_DARK   = (107, 78, 18)
WOOD_LIGHT  = (166, 124, 40)
WALL_BROWN  = (130, 90, 50)
WALL_DARK   = (100, 68, 36)
WALL_LIGHT  = (155, 112, 66)

# Roof
ROOF_BASE   = (179, 48, 48)
ROOF_DARK   = (139, 32, 32)
ROOF_LIGHT  = (204, 68, 68)

# Floor
FLOOR_BASE  = (200, 180, 140)
FLOOR_DARK  = (180, 158, 118)
FLOOR_LIGHT = (218, 200, 164)

# Door
DOOR_BASE   = (101, 67, 33)
DOOR_DARK   = (78, 50, 24)
DOOR_LIGHT  = (126, 86, 44)
DOOR_HANDLE = (200, 180, 60)

# Skin tones
SKIN        = (240, 200, 160)
SKIN_SHADOW = (212, 168, 120)

# Common
BLACK       = (40, 40, 40)
WHITE       = (245, 245, 240)

S = 32  # tile size


def new() -> tuple[Image.Image, ImageDraw.ImageDraw]:
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    return img, ImageDraw.Draw(img)


def save(img: Image.Image, *path_parts: str) -> None:
    p = os.path.join(BASE, *path_parts)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    img.save(p)
    print(f"  {os.path.relpath(p, BASE)}")


# ============================================================
# TILES
# ============================================================

def gen_grass_1():
    img, d = new()
    img.paste(GRASS, (0, 0, S, S))
    # Tufts
    for x, y in [(5,4),(12,8),(22,3),(28,14),(8,18),(18,22),(4,28),(25,26),(15,30),(30,6)]:
        d.point((x, y), fill=GRASS_DARK)
    for x, y in [(7,6),(14,12),(24,8),(10,24),(20,28),(3,16)]:
        d.point((x, y), fill=GRASS_LIGHT)
    save(img, "tiles", "grass_1.png")


def gen_grass_2():
    img, d = new()
    img.paste(GRASS, (0, 0, S, S))
    for x, y in [(3,2),(10,6),(20,4),(28,10),(6,14),(16,18),(26,22),(8,26),(18,30),(2,20)]:
        d.point((x, y), fill=GRASS_DARK)
    for x, y in [(5,10),(15,4),(25,16),(9,22),(19,26),(29,2)]:
        d.point((x, y), fill=GRASS_LIGHT)
    save(img, "tiles", "grass_2.png")


def gen_grass_3():
    img, d = new()
    img.paste(GRASS, (0, 0, S, S))
    for x, y in [(4,3),(18,7),(28,18),(8,24),(22,28)]:
        d.point((x, y), fill=GRASS_DARK)
    # Tiny flower
    d.point((14, 14), fill=FLOWER_Y)
    d.point((13, 13), fill=GRASS_LIGHT)
    d.point((15, 13), fill=GRASS_LIGHT)
    d.point((14, 12), fill=FLOWER_W)
    d.point((14, 15), fill=GRASS_DARK)
    save(img, "tiles", "grass_3.png")


def gen_path():
    img, d = new()
    img.paste(PATH_BASE, (0, 0, S, S))
    # Sandy texture
    for x, y in [(3,2),(8,6),(15,3),(22,8),(28,4),(5,12),(12,16),(20,14),(27,18),(4,24),
                  (10,28),(18,22),(25,26),(30,12),(1,18),(16,30)]:
        d.point((x, y), fill=PATH_DARK)
    for x, y in [(6,4),(14,10),(22,2),(28,16),(10,20),(18,26),(2,28),(26,30)]:
        d.point((x, y), fill=PATH_LIGHT)
    save(img, "tiles", "path_center.png")


def gen_water():
    img, d = new()
    img.paste(WATER, (0, 0, S, S))
    # Wave highlights
    d.line([(4,8),(10,8)], fill=WATER_LIGHT)
    d.line([(16,6),(24,6)], fill=WATER_LIGHT)
    d.line([(6,18),(14,18)], fill=WATER_LIGHT)
    d.line([(20,16),(28,16)], fill=WATER_LIGHT)
    d.line([(2,26),(8,26)], fill=WATER_LIGHT)
    d.line([(18,28),(26,28)], fill=WATER_LIGHT)
    # Depth
    for x, y in [(8,12),(20,10),(12,22),(26,24),(4,30)]:
        d.point((x, y), fill=WATER_DEEP)
    save(img, "tiles", "water_1.png")


def gen_wall_front():
    img, d = new()
    img.paste(WALL_BROWN, (0, 0, S, S))
    # Horizontal plank lines
    for y in [7, 15, 23]:
        d.line([(0, y), (31, y)], fill=WALL_DARK)
        d.line([(0, y+1), (31, y+1)], fill=WALL_DARK)
    # Plank highlight on top edge of each row
    for y in [1, 9, 17, 25]:
        d.line([(0, y), (31, y)], fill=WALL_LIGHT)
    # Vertical grain
    for x in [8, 20]:
        for y in range(0, 32, 4):
            d.point((x, y), fill=WALL_DARK)
    save(img, "tiles", "wall_front.png")


def gen_wall_side():
    img, d = new()
    img.paste(WALL_BROWN, (0, 0, S, S))
    # Vertical plank lines
    for x in [7, 15, 23]:
        d.line([(x, 0), (x, 31)], fill=WALL_DARK)
        d.line([(x+1, 0), (x+1, 31)], fill=WALL_DARK)
    for x in [1, 9, 17, 25]:
        d.line([(x, 0), (x, 31)], fill=WALL_LIGHT)
    # Horizontal grain
    for y in [8, 20]:
        for x in range(0, 32, 4):
            d.point((x, y), fill=WALL_DARK)
    save(img, "tiles", "wall_side.png")


def gen_floor():
    img, d = new()
    img.paste(FLOOR_BASE, (0, 0, S, S))
    # Light wood planks
    for y in [7, 15, 23]:
        d.line([(0, y), (31, y)], fill=FLOOR_DARK)
    for y in [0, 8, 16, 24]:
        d.line([(0, y), (31, y)], fill=FLOOR_LIGHT)
    # Staggered plank joints
    for x in [10, 26]:
        for y in range(0, 8):
            d.point((x, y), fill=FLOOR_DARK)
    for x in [6, 20]:
        for y in range(8, 16):
            d.point((x, y), fill=FLOOR_DARK)
    for x in [14, 28]:
        for y in range(16, 24):
            d.point((x, y), fill=FLOOR_DARK)
    for x in [4, 18]:
        for y in range(24, 32):
            d.point((x, y), fill=FLOOR_DARK)
    save(img, "tiles", "floor_wood.png")


def gen_door():
    img, d = new()
    img.paste(DOOR_BASE, (0, 0, S, S))
    # Frame
    d.rectangle([0, 0, 31, 2], fill=DOOR_DARK)
    d.rectangle([0, 0, 2, 31], fill=DOOR_DARK)
    d.rectangle([29, 0, 31, 31], fill=DOOR_DARK)
    # Panels
    d.rectangle([5, 5, 14, 14], fill=DOOR_DARK)
    d.rectangle([17, 5, 26, 14], fill=DOOR_DARK)
    d.rectangle([5, 17, 14, 28], fill=DOOR_DARK)
    d.rectangle([17, 17, 26, 28], fill=DOOR_DARK)
    # Panel inner highlight
    d.rectangle([6, 6, 13, 13], fill=DOOR_LIGHT)
    d.rectangle([18, 6, 25, 13], fill=DOOR_LIGHT)
    d.rectangle([6, 18, 13, 27], fill=DOOR_LIGHT)
    d.rectangle([18, 18, 25, 27], fill=DOOR_LIGHT)
    # Handle
    d.rectangle([22, 20, 24, 22], fill=DOOR_HANDLE)
    save(img, "tiles", "door.png")


def gen_roof():
    img, d = new()
    for row in range(4):
        y = row * 8
        base = ROOF_BASE if row % 2 == 0 else ROOF_DARK
        d.rectangle([0, y, 31, y+7], fill=base)
        d.line([(0, y+7), (31, y+7)], fill=ROOF_DARK)
        d.line([(0, y), (31, y)], fill=ROOF_LIGHT)
        offset = 0 if row % 2 == 0 else 8
        for sx in range(offset, 32, 16):
            d.line([(sx, y), (sx, y+7)], fill=ROOF_DARK)
    save(img, "tiles", "roof_generic.png")


# ============================================================
# CHARACTERS — shared helper
# ============================================================

def draw_character(d: ImageDraw.ImageDraw,
                   hair_color: tuple, shirt_color: tuple, pants_color: tuple,
                   shoe_color: tuple = (80, 50, 30),
                   skin: tuple = SKIN, skin_sh: tuple = SKIN_SHADOW,
                   hair_style: str = "short",
                   shirt_detail: tuple | None = None,
                   wide: bool = False):
    """Draw a front-facing GBA-style character centered in 32x32."""
    # Body width
    bw = 2 if wide else 0  # extra width for stocky characters

    # Hair
    if hair_style == "short":
        d.rectangle([12, 4, 19, 8], fill=hair_color)
    elif hair_style == "bun":
        d.rectangle([12, 4, 19, 8], fill=hair_color)
        d.rectangle([14, 2, 17, 4], fill=hair_color)  # bun
    elif hair_style == "balding":
        d.rectangle([13, 5, 18, 8], fill=hair_color)
        d.point((12, 6), fill=hair_color)
        d.point((19, 6), fill=hair_color)

    # Head
    d.rectangle([12, 8, 19, 14], fill=skin)
    d.rectangle([12, 12, 19, 14], fill=skin_sh)  # chin shadow
    # Eyes
    d.point((14, 10), fill=BLACK)
    d.point((17, 10), fill=BLACK)
    # Mouth
    d.line([(15, 12), (16, 12)], fill=(200, 120, 120))

    # Shirt / body
    lx = 10 - bw
    rx = 21 + bw
    d.rectangle([lx, 14, rx, 22], fill=shirt_color)
    # Arms
    d.rectangle([lx - 2, 14, lx, 20], fill=shirt_color)
    d.rectangle([rx, 14, rx + 2, 20], fill=shirt_color)
    # Hands
    d.rectangle([lx - 2, 20, lx, 22], fill=skin)
    d.rectangle([rx, 20, rx + 2, 22], fill=skin)

    # Shirt detail (apron, badge, etc.)
    if shirt_detail:
        d.rectangle([12, 15, 19, 21], fill=shirt_detail)

    # Pants
    d.rectangle([11 - bw, 22, 15, 28], fill=pants_color)
    d.rectangle([16, 22, 20 + bw, 28], fill=pants_color)
    # Shoes
    d.rectangle([11 - bw, 28, 15, 30], fill=shoe_color)
    d.rectangle([16, 28, 20 + bw, 30], fill=shoe_color)


def gen_player():
    img, d = new()
    draw_character(d,
        hair_color=(100, 60, 30),
        shirt_color=(50, 100, 180),
        pants_color=(60, 60, 100))
    save(img, "characters", "player_down.png")


def gen_maria():
    img, d = new()
    draw_character(d,
        hair_color=(140, 70, 30),
        shirt_color=(220, 100, 120),  # pink dress
        pants_color=(200, 90, 110),
        hair_style="bun",
        shirt_detail=(240, 235, 230))  # white apron
    save(img, "characters", "maria_down.png")


def gen_thomas():
    img, d = new()
    draw_character(d,
        hair_color=(90, 55, 25),
        shirt_color=(60, 140, 60),   # green vest
        pants_color=(80, 70, 50),
        shirt_detail=None)
    # White undershirt visible at collar
    d.line([(14, 14), (17, 14)], fill=WHITE)
    save(img, "characters", "thomas_down.png")


def gen_elena():
    img, d = new()
    draw_character(d,
        hair_color=(40, 30, 20),     # dark hair
        shirt_color=(50, 90, 140),   # blue uniform
        pants_color=(40, 70, 110))
    # Star badge
    d.point((15, 16), fill=(240, 220, 60))
    d.point((16, 16), fill=(240, 220, 60))
    d.point((15, 17), fill=(240, 200, 40))
    d.point((16, 17), fill=(240, 200, 40))
    save(img, "characters", "elena_down.png")


def gen_aldric():
    img, d = new()
    draw_character(d,
        hair_color=(190, 190, 190),  # gray hair
        shirt_color=(50, 45, 50),    # dark robe
        pants_color=(45, 40, 45),
        shoe_color=(40, 35, 40),
        hair_style="balding")
    # White collar
    d.line([(13, 14), (18, 14)], fill=WHITE)
    d.point((12, 14), fill=WHITE)
    d.point((19, 14), fill=WHITE)
    save(img, "characters", "aldric_down.png")


def gen_gideon():
    img, d = new()
    draw_character(d,
        hair_color=(60, 35, 15),
        shirt_color=(100, 70, 40),   # brown work clothes
        pants_color=(70, 55, 35),
        wide=True)                   # broader shoulders
    # Leather apron
    d.rectangle([12, 16, 19, 22], fill=(80, 55, 30))
    d.line([(15, 14), (15, 16)], fill=(80, 55, 30))  # strap left
    d.line([(16, 14), (16, 16)], fill=(80, 55, 30))  # strap right
    save(img, "characters", "gideon_down.png")


# ============================================================
# Main
# ============================================================

def main():
    print("Generating DeepTown sprites...")
    os.makedirs(TILES, exist_ok=True)
    os.makedirs(CHARS, exist_ok=True)

    # Tiles
    print("\n[Tiles]")
    gen_grass_1()
    gen_grass_2()
    gen_grass_3()
    gen_path()
    gen_water()
    gen_wall_front()
    gen_wall_side()
    gen_floor()
    gen_door()
    gen_roof()

    # Characters
    print("\n[Characters]")
    gen_player()
    gen_maria()
    gen_thomas()
    gen_elena()
    gen_aldric()
    gen_gideon()

    print(f"\nDone! 16 sprites generated.")


if __name__ == "__main__":
    main()
