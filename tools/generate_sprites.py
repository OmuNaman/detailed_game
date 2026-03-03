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

# Cobblestone road
COBBLE_BASE  = (140, 135, 125)
COBBLE_LIGHT = (165, 160, 148)
COBBLE_DARK  = (110, 105, 95)
COBBLE_LINE  = (95, 90, 80)

# Dirt path
DIRT_BASE    = (170, 145, 100)
DIRT_DARK    = (145, 120, 78)
DIRT_LIGHT   = (190, 168, 125)

# Furniture
BLANKET_RED   = (180, 60, 60)
BLANKET_DARK  = (140, 45, 45)
PILLOW        = (220, 210, 190)
TABLE_TOP     = (160, 120, 60)
TABLE_DARK    = (120, 85, 40)
COUNTER_TOP   = (170, 140, 80)
COUNTER_DARK  = (130, 100, 55)
BRICK         = (160, 80, 60)
BRICK_DARK    = (120, 55, 40)
FIRE_ORANGE   = (240, 160, 40)
FIRE_YELLOW   = (250, 220, 80)
METAL_DARK    = (60, 55, 50)
METAL_MID     = (90, 85, 80)
METAL_LIGHT   = (130, 125, 120)
PEW_WOOD      = (150, 115, 60)
PEW_DARK      = (120, 88, 42)
ALTAR_WHITE   = (220, 215, 200)
ALTAR_GOLD    = (200, 180, 60)
BARREL_STAVE  = (130, 90, 40)
BARREL_BAND   = (80, 70, 60)
SHELF_BACK    = (110, 80, 50)
BOOK_RED      = (180, 50, 50)
BOOK_BLUE     = (50, 80, 160)
BOOK_GREEN    = (50, 130, 60)

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


def gen_door_open():
    """Open door — floor visible with door edge on right side."""
    img, d = new()
    # Floor shows through (same as floor tile base)
    img.paste(FLOOR_BASE, (0, 0, S, S))
    # Floor plank lines
    for y_line in range(0, S, 8):
        d.line([(0, y_line), (31, y_line)], fill=FLOOR_DARK)
    # Door frame on left and right edges
    d.rectangle([0, 0, 2, 31], fill=DOOR_DARK)    # left frame
    d.rectangle([29, 0, 31, 31], fill=DOOR_DARK)   # right frame
    # Top frame
    d.rectangle([0, 0, 31, 2], fill=DOOR_DARK)
    # Door itself swung open — thin panel on the right
    d.rectangle([26, 3, 28, 30], fill=DOOR_BASE)
    d.rectangle([27, 3, 28, 30], fill=DOOR_LIGHT)
    # Shadow on left where door was
    d.rectangle([3, 3, 5, 30], fill=FLOOR_DARK)
    save(img, "tiles", "door_open.png")


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


def gen_cobblestone():
    """Cobblestone road — main streets. Irregular rounded stones."""
    img, d = new()
    img.paste(COBBLE_BASE, (0, 0, S, S))
    stones = [
        (1, 1, 8, 6), (10, 0, 18, 5), (20, 1, 30, 7),
        (0, 8, 7, 14), (9, 7, 17, 13), (19, 8, 28, 14), (29, 9, 31, 13),
        (2, 16, 10, 22), (12, 15, 20, 21), (22, 16, 31, 22),
        (0, 24, 8, 30), (10, 23, 19, 29), (21, 24, 30, 31),
    ]
    for (x1, y1, x2, y2) in stones:
        d.rectangle([x1, y1, x2, y2], fill=COBBLE_LIGHT)
        d.line([(x1, y2), (x2, y2)], fill=COBBLE_DARK)
        d.line([(x2, y1), (x2, y2)], fill=COBBLE_DARK)
    for (x1, y1, x2, y2) in stones:
        d.line([(x1, y1), (x2, y1)], fill=COBBLE_LINE)
        d.line([(x1, y1), (x1, y2)], fill=COBBLE_LINE)
    for x, y in [(5, 4), (15, 11), (25, 19), (8, 27), (18, 3)]:
        d.point((x, y), fill=COBBLE_DARK)
    save(img, "tiles", "cobblestone.png")


def gen_dirt_path():
    """Worn dirt path — secondary roads. Sandy brown with footprints/tracks."""
    img, d = new()
    img.paste(DIRT_BASE, (0, 0, S, S))
    for x, y in [(4, 3), (12, 7), (22, 5), (28, 12), (6, 18), (16, 14),
                  (24, 20), (8, 26), (18, 24), (30, 28), (2, 12), (14, 30)]:
        d.point((x, y), fill=DIRT_DARK)
    for x, y in [(7, 5), (16, 10), (26, 8), (10, 22), (20, 16), (4, 28)]:
        d.point((x, y), fill=DIRT_LIGHT)
    for sy in range(0, 32, 2):
        d.point((10, sy), fill=DIRT_DARK)
        d.point((21, sy), fill=DIRT_DARK)
    d.point((0, 8), fill=GRASS_DARK)
    d.point((31, 20), fill=GRASS_DARK)
    d.point((1, 24), fill=GRASS)
    d.point((30, 4), fill=GRASS)
    save(img, "tiles", "dirt_path.png")


# ============================================================
# FURNITURE TILES
# ============================================================

def gen_bed():
    """Top-down bed: pillow at top, red blanket."""
    img, d = new()
    d.rectangle([2, 2, 29, 29], fill=WOOD_DARK)
    d.rectangle([3, 3, 28, 28], fill=WOOD)
    d.rectangle([5, 3, 26, 10], fill=PILLOW)
    d.rectangle([6, 4, 25, 9], fill=(235, 230, 215))
    d.rectangle([4, 11, 27, 27], fill=BLANKET_RED)
    d.rectangle([5, 12, 26, 26], fill=BLANKET_DARK)
    d.line([(5, 14), (26, 14)], fill=BLANKET_RED)
    d.line([(5, 20), (26, 20)], fill=BLANKET_RED)
    save(img, "tiles", "bed.png")


def gen_table():
    """Top-down small wooden table."""
    img, d = new()
    d.rectangle([4, 6, 27, 25], fill=TABLE_TOP)
    d.rectangle([5, 7, 26, 24], fill=(175, 135, 70))
    d.line([(4, 25), (27, 25)], fill=TABLE_DARK)
    d.line([(27, 6), (27, 25)], fill=TABLE_DARK)
    d.line([(8, 8), (8, 23)], fill=TABLE_DARK)
    d.line([(15, 8), (15, 23)], fill=TABLE_DARK)
    d.line([(22, 8), (22, 23)], fill=TABLE_DARK)
    for x, y in [(5, 7), (25, 7), (5, 23), (25, 23)]:
        d.rectangle([x-1, y-1, x+1, y+1], fill=WOOD_DARK)
    save(img, "tiles", "table.png")


def gen_counter():
    """Shop counter with items on top."""
    img, d = new()
    d.rectangle([2, 8, 29, 24], fill=COUNTER_TOP)
    d.rectangle([3, 9, 28, 23], fill=(180, 155, 95))
    d.line([(2, 24), (29, 24)], fill=COUNTER_DARK)
    d.rectangle([2, 24, 29, 29], fill=COUNTER_DARK)
    d.rectangle([3, 25, 28, 28], fill=(145, 110, 65))
    d.rectangle([6, 10, 10, 14], fill=BLANKET_RED)
    d.rectangle([14, 11, 17, 14], fill=ALTAR_GOLD)
    d.rectangle([21, 10, 25, 14], fill=BOOK_BLUE)
    save(img, "tiles", "counter.png")


def gen_oven():
    """Brick oven with orange fire glow."""
    img, d = new()
    d.rectangle([2, 2, 29, 29], fill=BRICK)
    d.rectangle([3, 3, 28, 28], fill=BRICK_DARK)
    for row in range(4):
        y = 4 + row * 7
        offset = 0 if row % 2 == 0 else 7
        for sx in range(offset, 28, 14):
            d.line([(sx, y), (sx, y + 5)], fill=BRICK)
        d.line([(3, y + 6), (28, y + 6)], fill=BRICK)
    d.rectangle([10, 16, 21, 26], fill=(40, 30, 25))
    d.rectangle([12, 20, 19, 25], fill=FIRE_ORANGE)
    d.rectangle([13, 22, 18, 24], fill=FIRE_YELLOW)
    d.point((15, 19), fill=FIRE_YELLOW)
    d.point((16, 18), fill=FIRE_ORANGE)
    d.rectangle([12, 2, 19, 5], fill=BRICK_DARK)
    save(img, "tiles", "oven.png")


def gen_anvil():
    """Blacksmith anvil on wooden stump."""
    img, d = new()
    d.rectangle([8, 18, 23, 29], fill=WOOD_DARK)
    d.rectangle([9, 19, 22, 28], fill=WOOD)
    d.rectangle([6, 8, 25, 20], fill=METAL_MID)
    d.rectangle([2, 11, 6, 17], fill=METAL_MID)
    d.rectangle([0, 12, 2, 16], fill=METAL_DARK)
    d.rectangle([25, 10, 30, 18], fill=METAL_MID)
    d.rectangle([7, 9, 24, 12], fill=METAL_LIGHT)
    d.line([(6, 20), (25, 20)], fill=METAL_DARK)
    d.line([(25, 8), (25, 20)], fill=METAL_DARK)
    d.rectangle([12, 5, 14, 9], fill=WOOD)
    d.rectangle([10, 3, 16, 6], fill=METAL_DARK)
    save(img, "tiles", "anvil.png")


def gen_pew():
    """Church pew — wooden bench from above."""
    img, d = new()
    d.rectangle([3, 8, 28, 18], fill=PEW_WOOD)
    d.rectangle([4, 9, 27, 17], fill=(160, 125, 68))
    d.rectangle([3, 4, 28, 8], fill=PEW_DARK)
    d.rectangle([4, 5, 27, 7], fill=PEW_WOOD)
    d.line([(3, 18), (28, 18)], fill=PEW_DARK)
    d.line([(10, 9), (10, 17)], fill=PEW_DARK)
    d.line([(20, 9), (20, 17)], fill=PEW_DARK)
    d.rectangle([2, 5, 4, 18], fill=PEW_DARK)
    d.rectangle([27, 5, 29, 18], fill=PEW_DARK)
    save(img, "tiles", "pew.png")


def gen_altar():
    """Church altar — white marble with gold cross and candles."""
    img, d = new()
    d.rectangle([3, 4, 28, 28], fill=ALTAR_WHITE)
    d.rectangle([4, 5, 27, 27], fill=(230, 225, 210))
    d.line([(3, 28), (28, 28)], fill=(180, 175, 160))
    d.line([(28, 4), (28, 28)], fill=(180, 175, 160))
    d.rectangle([5, 20, 26, 27], fill=(180, 160, 200))
    d.line([(5, 20), (26, 20)], fill=(150, 130, 170))
    d.rectangle([14, 6, 17, 18], fill=ALTAR_GOLD)
    d.rectangle([10, 9, 21, 12], fill=ALTAR_GOLD)
    d.rectangle([15, 7, 16, 17], fill=(220, 200, 80))
    d.rectangle([6, 6, 8, 10], fill=PILLOW)
    d.point((7, 5), fill=FIRE_YELLOW)
    d.rectangle([23, 6, 25, 10], fill=PILLOW)
    d.point((24, 5), fill=FIRE_YELLOW)
    save(img, "tiles", "altar.png")


def gen_barrel():
    """Wooden barrel — circular with metal bands."""
    img, d = new()
    d.ellipse([4, 4, 27, 27], fill=BARREL_STAVE)
    d.ellipse([5, 5, 26, 26], fill=(145, 105, 50))
    d.ellipse([6, 6, 25, 25], outline=BARREL_BAND)
    d.ellipse([9, 9, 22, 22], outline=BARREL_BAND)
    d.line([(15, 5), (15, 26)], fill=BARREL_STAVE)
    d.line([(5, 15), (26, 15)], fill=BARREL_STAVE)
    d.rectangle([13, 13, 18, 18], fill=WOOD_DARK)
    d.rectangle([14, 14, 17, 17], fill=BARREL_STAVE)
    save(img, "tiles", "barrel.png")


def gen_shelf():
    """Wall shelf with books and goods."""
    img, d = new()
    d.rectangle([2, 2, 29, 29], fill=SHELF_BACK)
    d.rectangle([3, 3, 28, 28], fill=(125, 92, 58))
    for sy in [3, 10, 17, 24]:
        d.rectangle([2, sy, 29, sy + 1], fill=WOOD_DARK)
    d.rectangle([5, 4, 8, 9], fill=BOOK_RED)
    d.rectangle([9, 5, 12, 9], fill=BOOK_BLUE)
    d.rectangle([13, 4, 16, 9], fill=BOOK_GREEN)
    d.rectangle([18, 5, 20, 9], fill=BOOK_RED)
    d.rectangle([5, 11, 9, 16], fill=PILLOW)
    d.rectangle([12, 12, 17, 16], fill=BARREL_STAVE)
    d.rectangle([20, 11, 24, 16], fill=PILLOW)
    d.rectangle([4, 18, 10, 23], fill=COUNTER_TOP)
    d.rectangle([13, 19, 18, 23], fill=BLANKET_RED)
    d.rectangle([21, 18, 27, 23], fill=WOOD)
    save(img, "tiles", "shelf.png")


def gen_desk():
    """Work desk with papers, inkwell, book."""
    img, d = new()
    d.rectangle([3, 5, 28, 26], fill=WOOD_DARK)
    d.rectangle([4, 6, 27, 25], fill=(120, 88, 48))
    d.line([(3, 26), (28, 26)], fill=(80, 55, 30))
    d.line([(28, 5), (28, 26)], fill=(80, 55, 30))
    d.rectangle([6, 8, 15, 16], fill=PILLOW)
    d.rectangle([7, 9, 14, 15], fill=(235, 230, 215))
    for ly in [10, 11, 12, 13, 14]:
        d.line([(8, ly), (13, ly)], fill=(180, 175, 170))
    d.rectangle([18, 8, 21, 11], fill=BLACK)
    d.rectangle([19, 9, 20, 10], fill=(30, 30, 60))
    d.line([(21, 7), (25, 11)], fill=PILLOW)
    d.point((21, 7), fill=(200, 180, 140))
    d.rectangle([17, 14, 25, 22], fill=BOOK_RED)
    d.rectangle([18, 15, 24, 21], fill=(160, 40, 40))
    d.line([(20, 14), (20, 22)], fill=(140, 30, 30))
    save(img, "tiles", "desk.png")


# ============================================================
# BUILDING EXTERIOR TILES
# ============================================================

GLASS_LIGHT  = (180, 210, 230)
GLASS_MID    = (140, 175, 200)
GLASS_DARK   = (100, 140, 170)
FRAME_WOOD   = (110, 75, 40)


def gen_window_front():
    """Front wall with a 4-pane glass window."""
    img, d = new()
    # Base wall
    d.rectangle([0, 0, 31, 31], fill=WALL_BROWN)
    for row in range(4):
        y = row * 8
        offset = 0 if row % 2 == 0 else 8
        for sx in range(offset, 32, 16):
            d.line([(sx, y), (sx, y + 7)], fill=WALL_DARK)
        d.line([(0, y), (31, y)], fill=WALL_DARK)
    # Window frame
    d.rectangle([8, 6, 23, 22], fill=FRAME_WOOD)
    # Glass panes (2x2 grid)
    d.rectangle([9, 7, 15, 13], fill=GLASS_MID)
    d.rectangle([16, 7, 22, 13], fill=GLASS_LIGHT)
    d.rectangle([9, 14, 15, 21], fill=GLASS_LIGHT)
    d.rectangle([16, 14, 22, 21], fill=GLASS_MID)
    # Cross frame divider
    d.line([(15, 7), (15, 21)], fill=FRAME_WOOD)
    d.line([(16, 7), (16, 21)], fill=FRAME_WOOD)
    d.line([(9, 13), (22, 13)], fill=FRAME_WOOD)
    d.line([(9, 14), (22, 14)], fill=FRAME_WOOD)
    # Windowsill
    d.rectangle([7, 22, 24, 24], fill=WALL_LIGHT)
    save(img, "tiles", "window_front.png")


def gen_window_side():
    """Side wall with a narrow window."""
    img, d = new()
    # Base wall (vertical planks)
    d.rectangle([0, 0, 31, 31], fill=WOOD)
    for sx in range(0, 32, 6):
        d.line([(sx, 0), (sx, 31)], fill=WOOD_DARK)
    for sy in [8, 16, 24]:
        d.line([(0, sy), (31, sy)], fill=WOOD_DARK)
    # Window
    d.rectangle([10, 6, 21, 22], fill=FRAME_WOOD)
    d.rectangle([11, 7, 20, 21], fill=GLASS_MID)
    d.line([(11, 14), (20, 14)], fill=FRAME_WOOD)
    d.rectangle([12, 8, 14, 12], fill=GLASS_LIGHT)
    d.rectangle([9, 22, 22, 24], fill=WALL_LIGHT)
    save(img, "tiles", "window_side.png")


def gen_awning():
    """Striped awning/canopy above shop entrance."""
    img, d = new()
    for row in range(4):
        y = row * 8
        color = (200, 60, 60) if row % 2 == 0 else (230, 220, 200)
        d.rectangle([0, y, 31, y + 7], fill=color)
    # Bottom fringe
    for x in range(0, 32, 4):
        d.rectangle([x, 28, x + 2, 31], fill=(200, 60, 60))
    # Support rod
    d.line([(0, 0), (31, 0)], fill=(60, 55, 50))
    d.line([(0, 1), (31, 1)], fill=(90, 85, 80))
    # Shadow
    d.rectangle([0, 24, 31, 27], fill=(180, 50, 50))
    save(img, "tiles", "awning.png")


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


def draw_character_sleeping(d: ImageDraw.ImageDraw,
                            hair_color: tuple, shirt_color: tuple, pants_color: tuple,
                            shoe_color: tuple = (80, 50, 30),
                            skin: tuple = SKIN, skin_sh: tuple = SKIN_SHADOW,
                            hair_style: str = "short",
                            shirt_detail: tuple | None = None,
                            wide: bool = False):
    """Draw a sleeping front-facing character — eyes closed (lines instead of dots)."""
    bw = 2 if wide else 0

    # Hair
    if hair_style == "short":
        d.rectangle([12, 4, 19, 8], fill=hair_color)
    elif hair_style == "bun":
        d.rectangle([12, 4, 19, 8], fill=hair_color)
        d.rectangle([14, 2, 17, 4], fill=hair_color)
    elif hair_style == "balding":
        d.rectangle([13, 5, 18, 8], fill=hair_color)
        d.point((12, 6), fill=hair_color)
        d.point((19, 6), fill=hair_color)

    # Head
    d.rectangle([12, 8, 19, 14], fill=skin)
    d.rectangle([12, 12, 19, 14], fill=skin_sh)
    # CLOSED EYES — horizontal lines instead of dots
    d.line([(13, 10), (15, 10)], fill=BLACK)
    d.line([(16, 10), (18, 10)], fill=BLACK)
    # No mouth (sleeping)

    # Shirt / body
    lx = 10 - bw
    rx = 21 + bw
    d.rectangle([lx, 14, rx, 22], fill=shirt_color)
    d.rectangle([lx - 2, 14, lx, 20], fill=shirt_color)
    d.rectangle([rx, 14, rx + 2, 20], fill=shirt_color)
    d.rectangle([lx - 2, 20, lx, 22], fill=skin)
    d.rectangle([rx, 20, rx + 2, 22], fill=skin)

    if shirt_detail:
        d.rectangle([12, 15, 19, 21], fill=shirt_detail)

    d.rectangle([11 - bw, 22, 15, 28], fill=pants_color)
    d.rectangle([16, 22, 20 + bw, 28], fill=pants_color)
    d.rectangle([11 - bw, 28, 15, 30], fill=shoe_color)
    d.rectangle([16, 28, 20 + bw, 30], fill=shoe_color)


def gen_player_sleep():
    img, d = new()
    draw_character_sleeping(d,
        hair_color=(100, 60, 30),
        shirt_color=(50, 100, 180),
        pants_color=(60, 60, 100))
    save(img, "characters", "player_sleep.png")


def gen_maria_sleep():
    img, d = new()
    draw_character_sleeping(d,
        hair_color=(140, 70, 30),
        shirt_color=(220, 100, 120),
        pants_color=(200, 90, 110),
        hair_style="bun",
        shirt_detail=(240, 235, 230))
    save(img, "characters", "maria_sleep.png")


def gen_thomas_sleep():
    img, d = new()
    draw_character_sleeping(d,
        hair_color=(90, 55, 25),
        shirt_color=(60, 140, 60),
        pants_color=(80, 70, 50))
    # White undershirt visible at collar
    d.line([(14, 14), (17, 14)], fill=WHITE)
    save(img, "characters", "thomas_sleep.png")


def gen_elena_sleep():
    img, d = new()
    draw_character_sleeping(d,
        hair_color=(40, 30, 20),
        shirt_color=(50, 90, 140),
        pants_color=(40, 70, 110))
    # Star badge
    d.point((15, 16), fill=(240, 220, 60))
    d.point((16, 16), fill=(240, 220, 60))
    d.point((15, 17), fill=(240, 200, 40))
    d.point((16, 17), fill=(240, 200, 40))
    save(img, "characters", "elena_sleep.png")


def gen_aldric_sleep():
    img, d = new()
    draw_character_sleeping(d,
        hair_color=(190, 190, 190),
        shirt_color=(50, 45, 50),
        pants_color=(45, 40, 45),
        shoe_color=(40, 35, 40),
        hair_style="balding")
    # White collar
    d.line([(13, 14), (18, 14)], fill=WHITE)
    d.point((12, 14), fill=WHITE)
    d.point((19, 14), fill=WHITE)
    save(img, "characters", "aldric_sleep.png")


def gen_gideon_sleep():
    img, d = new()
    draw_character_sleeping(d,
        hair_color=(60, 35, 15),
        shirt_color=(100, 70, 40),
        pants_color=(70, 55, 35),
        wide=True)
    # Leather apron
    d.rectangle([12, 16, 19, 22], fill=(80, 55, 30))
    d.line([(15, 14), (15, 16)], fill=(80, 55, 30))
    d.line([(16, 14), (16, 16)], fill=(80, 55, 30))
    save(img, "characters", "gideon_sleep.png")


def gen_rose_sleep():
    img, d = new()
    draw_character_sleeping(d,
        hair_color=(180, 40, 40),
        shirt_color=(120, 30, 60),
        pants_color=(100, 25, 50),
        hair_style="bun",
        shirt_detail=(200, 180, 140))
    save(img, "characters", "rose_sleep.png")


def gen_finn_sleep():
    img, d = new()
    draw_character_sleeping(d,
        hair_color=(180, 160, 80),
        shirt_color=(140, 160, 100),
        pants_color=(100, 80, 50))
    save(img, "characters", "finn_sleep.png")


def gen_clara_sleep():
    img, d = new()
    draw_character_sleeping(d,
        hair_color=(60, 40, 30),
        shirt_color=(80, 150, 100),
        pants_color=(70, 130, 90))
    save(img, "characters", "clara_sleep.png")


def gen_silas_sleep():
    img, d = new()
    draw_character_sleeping(d,
        hair_color=(200, 200, 200),
        shirt_color=(110, 90, 70),
        pants_color=(80, 70, 55),
        hair_style="balding",
        shoe_color=(60, 45, 30))
    save(img, "characters", "silas_sleep.png")


def gen_bram_sleep():
    img, d = new()
    draw_character_sleeping(d,
        hair_color=(30, 25, 20),
        shirt_color=(130, 90, 60),
        pants_color=(70, 55, 40),
        wide=True)
    save(img, "characters", "bram_sleep.png")


def gen_lyra_sleep():
    img, d = new()
    draw_character_sleeping(d,
        hair_color=(100, 50, 20),
        shirt_color=(70, 60, 110),
        pants_color=(55, 45, 85),
        shirt_detail=(200, 190, 160))
    save(img, "characters", "lyra_sleep.png")


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


def gen_rose():
    img, d = new()
    draw_character(d,
        hair_color=(180, 40, 40),      # red hair
        shirt_color=(120, 30, 60),     # deep red dress
        pants_color=(100, 25, 50),
        hair_style="bun",
        shirt_detail=(200, 180, 140))  # tan apron
    save(img, "characters", "rose_down.png")


def gen_finn():
    img, d = new()
    draw_character(d,
        hair_color=(180, 160, 80),     # straw blond
        shirt_color=(140, 160, 100),   # olive work shirt
        pants_color=(100, 80, 50),
        shirt_detail=None)
    save(img, "characters", "finn_down.png")


def gen_clara():
    img, d = new()
    draw_character(d,
        hair_color=(60, 40, 30),       # dark brown
        shirt_color=(80, 150, 100),    # sage green dress
        pants_color=(70, 130, 90),
        hair_style="short")
    save(img, "characters", "clara_down.png")


def gen_silas():
    img, d = new()
    draw_character(d,
        hair_color=(200, 200, 200),    # white/gray
        shirt_color=(110, 90, 70),     # worn brown
        pants_color=(80, 70, 55),
        hair_style="balding",
        shoe_color=(60, 45, 30))
    save(img, "characters", "silas_down.png")


def gen_bram():
    img, d = new()
    draw_character(d,
        hair_color=(30, 25, 20),       # black hair
        shirt_color=(130, 90, 60),     # tan work shirt
        pants_color=(70, 55, 40),
        wide=True)                     # stocky build
    save(img, "characters", "bram_down.png")


def gen_lyra():
    img, d = new()
    draw_character(d,
        hair_color=(100, 50, 20),      # auburn
        shirt_color=(70, 60, 110),     # purple tunic
        pants_color=(55, 45, 85),
        hair_style="short",
        shirt_detail=(200, 190, 160))  # book/scroll detail
    save(img, "characters", "lyra_down.png")


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
    gen_door_open()
    gen_roof()
    gen_cobblestone()
    gen_dirt_path()

    # Furniture
    print("\n[Furniture]")
    gen_bed()
    gen_table()
    gen_counter()
    gen_oven()
    gen_anvil()
    gen_pew()
    gen_altar()
    gen_barrel()
    gen_shelf()
    gen_desk()

    # Building Exterior
    print("\n[Building Exterior]")
    gen_window_front()
    gen_window_side()
    gen_awning()

    # Characters
    print("\n[Characters]")
    gen_player()
    gen_maria()
    gen_thomas()
    gen_elena()
    gen_aldric()
    gen_gideon()
    gen_rose()
    gen_finn()
    gen_clara()
    gen_silas()
    gen_bram()
    gen_lyra()

    # Sleeping Characters
    print("\n[Sleep sprites]")
    gen_player_sleep()
    gen_maria_sleep()
    gen_thomas_sleep()
    gen_elena_sleep()
    gen_aldric_sleep()
    gen_gideon_sleep()
    gen_rose_sleep()
    gen_finn_sleep()
    gen_clara_sleep()
    gen_silas_sleep()
    gen_bram_sleep()
    gen_lyra_sleep()

    print(f"\nDone! 50 sprites generated.")


if __name__ == "__main__":
    main()
