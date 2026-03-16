#!/usr/bin/env python3
"""Generate 50 new NPC character sprites for DeepTown.

Each NPC gets an awake sprite ({id}_down.png) and a sleep sprite ({id}_sleep.png).
Colors are hand-picked to ensure visual distinctness across all 50 characters.

Run: python tools/generate_npcs.py
"""
import os
import sys

# Add parent dir so we can import from generate_sprites
sys.path.insert(0, os.path.dirname(__file__))
from generate_sprites import (
    new, save, draw_character, draw_character_sleeping, WHITE, BLACK,
    SKIN, SKIN_SHADOW
)

# --- 50 New NPC definitions ---
# Each entry: id, hair_color, shirt_color, pants_color, shoe_color, hair_style, shirt_detail, wide
# Organized by workplace for easy reference

NEW_NPCS = [
    # === LIBRARY ===
    {"id": "mira", "hair": (70, 40, 90), "shirt": (90, 75, 130), "pants": (60, 50, 90), "shoes": (50, 35, 25), "hair_style": "short", "detail": (200, 190, 160), "wide": False},  # Librarian - purple tunic, scroll detail
    {"id": "owen", "hair": (130, 90, 50), "shirt": (80, 100, 70), "pants": (65, 55, 40), "shoes": (60, 40, 25), "hair_style": "short", "detail": None, "wide": False},  # Asst Librarian - olive green

    # === INN ===
    {"id": "hilda", "hair": (160, 100, 40), "shirt": (170, 80, 50), "pants": (130, 60, 40), "shoes": (70, 45, 25), "hair_style": "bun", "detail": (220, 200, 170), "wide": True},  # Innkeeper - orange with apron
    {"id": "bertram", "hair": (40, 35, 30), "shirt": (200, 200, 190), "pants": (80, 75, 65), "shoes": (50, 40, 30), "hair_style": "short", "detail": (180, 60, 60), "wide": True},  # Cook - white with red apron

    # === MARKET ===
    {"id": "jasper", "hair": (100, 70, 30), "shirt": (180, 150, 60), "pants": (100, 85, 55), "shoes": (70, 50, 30), "hair_style": "short", "detail": None, "wide": False},  # Merchant - gold vest
    {"id": "nessa", "hair": (30, 20, 15), "shirt": (180, 100, 50), "pants": (140, 80, 40), "shoes": (60, 40, 25), "hair_style": "bun", "detail": None, "wide": False},  # Merchant - warm orange
    {"id": "victor", "hair": (80, 60, 40), "shirt": (60, 110, 80), "pants": (50, 80, 60), "shoes": (55, 40, 25), "hair_style": "balding", "detail": None, "wide": True},  # Merchant - teal

    # === CARPENTER WORKSHOP ===
    {"id": "magnus", "hair": (150, 110, 60), "shirt": (140, 100, 50), "pants": (90, 70, 40), "shoes": (70, 50, 30), "hair_style": "short", "detail": (100, 70, 35), "wide": True},  # Carpenter - brown with leather apron
    {"id": "rowan", "hair": (180, 130, 70), "shirt": (110, 80, 45), "pants": (80, 60, 35), "shoes": (65, 45, 25), "hair_style": "short", "detail": None, "wide": True},  # Woodcutter - rugged brown

    # === TAILOR SHOP ===
    {"id": "celeste", "hair": (160, 60, 30), "shirt": (130, 80, 140), "pants": (100, 60, 110), "shoes": (60, 40, 50), "hair_style": "bun", "detail": (220, 210, 190), "wide": False},  # Tailor - purple with lace detail
    {"id": "wren", "hair": (50, 35, 25), "shirt": (180, 140, 170), "pants": (140, 100, 130), "shoes": (60, 45, 50), "hair_style": "short", "detail": None, "wide": False},  # Seamstress - lavender

    # === STABLES ===
    {"id": "dale", "hair": (120, 80, 30), "shirt": (100, 120, 80), "pants": (70, 80, 50), "shoes": (80, 55, 30), "hair_style": "short", "detail": None, "wide": True},  # Stablehand - earthy green
    {"id": "kira", "hair": (90, 50, 20), "shirt": (150, 120, 70), "pants": (110, 90, 55), "shoes": (70, 50, 30), "hair_style": "bun", "detail": None, "wide": False},  # Stablehand - tan/khaki

    # === CLINIC ===
    {"id": "elara", "hair": (45, 30, 20), "shirt": (210, 210, 210), "pants": (160, 160, 160), "shoes": (50, 40, 35), "hair_style": "bun", "detail": (180, 50, 50), "wide": False},  # Doctor - white coat, red cross
    {"id": "heath", "hair": (110, 70, 30), "shirt": (200, 210, 220), "pants": (140, 150, 160), "shoes": (55, 45, 35), "hair_style": "short", "detail": None, "wide": False},  # Nurse - light blue scrubs

    # === SCHOOL ===
    {"id": "professor_ward", "hair": (170, 170, 170), "shirt": (70, 55, 40), "pants": (50, 40, 30), "shoes": (40, 30, 25), "hair_style": "balding", "detail": (200, 180, 140), "wide": False},  # Teacher - brown jacket, elbow patches
    {"id": "pip", "hair": (200, 170, 80), "shirt": (60, 120, 170), "pants": (50, 80, 110), "shoes": (60, 45, 30), "hair_style": "short", "detail": None, "wide": False},  # Student - blue uniform
    {"id": "tamsin", "hair": (80, 40, 20), "shirt": (60, 120, 170), "pants": (50, 80, 110), "shoes": (55, 40, 30), "hair_style": "short", "detail": None, "wide": False},  # Student - blue uniform (darker hair)
    {"id": "colby", "hair": (140, 100, 50), "shirt": (60, 120, 170), "pants": (50, 80, 110), "shoes": (60, 45, 30), "hair_style": "short", "detail": None, "wide": False},  # Student - blue uniform (sandy)

    # === SHERIFF OFFICE (extra guard) ===
    {"id": "marshal", "hair": (50, 40, 30), "shirt": (50, 80, 120), "pants": (40, 60, 90), "shoes": (50, 35, 25), "hair_style": "short", "detail": (220, 200, 50), "wide": True},  # Guard - blue uniform, badge

    # === TAVERN (extra staff) ===
    {"id": "ivy", "hair": (140, 50, 30), "shirt": (150, 50, 70), "pants": (120, 40, 55), "shoes": (60, 40, 30), "hair_style": "bun", "detail": (210, 190, 150), "wide": False},  # Barmaid - deep red, apron
    {"id": "barley", "hair": (180, 150, 90), "shirt": (120, 90, 50), "pants": (90, 70, 40), "shoes": (65, 45, 25), "hair_style": "short", "detail": None, "wide": True},  # Brewer - earthy brown, stocky

    # === GENERAL STORE (extra farmers/workers) ===
    {"id": "cora", "hair": (70, 45, 25), "shirt": (160, 180, 120), "pants": (110, 130, 80), "shoes": (70, 50, 30), "hair_style": "bun", "detail": None, "wide": False},  # Farmer - sage green
    {"id": "seth", "hair": (160, 130, 70), "shirt": (140, 150, 100), "pants": (100, 90, 60), "shoes": (75, 55, 30), "hair_style": "short", "detail": None, "wide": True},  # Farmer - olive, stocky
    {"id": "hazel", "hair": (100, 55, 25), "shirt": (170, 140, 90), "pants": (130, 105, 65), "shoes": (65, 45, 25), "hair_style": "short", "detail": None, "wide": False},  # Farmer - warm khaki

    # === CHURCH (extra helpers) ===
    {"id": "sister_mabel", "hair": (80, 60, 50), "shirt": (60, 55, 65), "pants": (50, 45, 55), "shoes": (40, 35, 30), "hair_style": "bun", "detail": (230, 225, 220), "wide": False},  # Nun - dark habit, white collar
    {"id": "deacon_miles", "hair": (90, 70, 40), "shirt": (55, 50, 55), "pants": (45, 40, 45), "shoes": (40, 35, 30), "hair_style": "short", "detail": (230, 225, 220), "wide": False},  # Deacon - dark robe

    # === BLACKSMITH (extra worker) ===
    {"id": "forge", "hair": (30, 25, 20), "shirt": (110, 80, 50), "pants": (80, 60, 40), "shoes": (70, 50, 30), "hair_style": "short", "detail": (90, 60, 35), "wide": True},  # Apprentice 2 - leather apron

    # === COURTHOUSE (extra clerk) ===
    {"id": "quill", "hair": (120, 100, 70), "shirt": (80, 70, 100), "pants": (60, 55, 75), "shoes": (50, 40, 35), "hair_style": "balding", "detail": None, "wide": False},  # Scribe - muted purple

    # === RETIRED / TAVERN REGULARS ===
    {"id": "granny_oak", "hair": (210, 210, 210), "shirt": (140, 100, 80), "pants": (110, 80, 60), "shoes": (60, 45, 30), "hair_style": "bun", "detail": None, "wide": False},  # Retired - warm brown
    {"id": "barnaby", "hair": (180, 180, 175), "shirt": (100, 110, 90), "pants": (75, 80, 65), "shoes": (55, 45, 30), "hair_style": "balding", "detail": None, "wide": True},  # Retired - faded green, stocky
    {"id": "peg", "hair": (190, 160, 120), "shirt": (130, 80, 90), "pants": (100, 65, 70), "shoes": (55, 40, 30), "hair_style": "bun", "detail": None, "wide": False},  # Retired - dusty rose

    # === VARIOUS TOWNSFOLK ===
    {"id": "flint", "hair": (40, 30, 25), "shirt": (90, 90, 100), "pants": (65, 65, 75), "shoes": (50, 40, 30), "hair_style": "short", "detail": None, "wide": True},  # Miner - slate gray
    {"id": "marina", "hair": (60, 80, 100), "shirt": (70, 130, 160), "pants": (50, 100, 130), "shoes": (55, 40, 30), "hair_style": "short", "detail": None, "wide": False},  # Fisherman - sea blue
    {"id": "edgar", "hair": (100, 80, 50), "shirt": (160, 130, 80), "pants": (120, 100, 60), "shoes": (70, 50, 30), "hair_style": "balding", "detail": None, "wide": False},  # Handyman - tan
    {"id": "felicity", "hair": (180, 120, 50), "shirt": (200, 160, 100), "pants": (160, 130, 80), "shoes": (65, 45, 30), "hair_style": "bun", "detail": (240, 220, 180), "wide": False},  # Baker's apprentice - golden
    {"id": "greta", "hair": (120, 60, 30), "shirt": (100, 140, 120), "pants": (75, 110, 90), "shoes": (55, 40, 25), "hair_style": "bun", "detail": None, "wide": False},  # Herbalist - sage/teal
    {"id": "hollis", "hair": (70, 50, 30), "shirt": (140, 110, 70), "pants": (100, 80, 50), "shoes": (65, 45, 25), "hair_style": "short", "detail": None, "wide": True},  # Laborer - dusty tan
    {"id": "ingrid", "hair": (200, 180, 130), "shirt": (100, 60, 80), "pants": (80, 50, 65), "shoes": (50, 35, 30), "hair_style": "bun", "detail": None, "wide": False},  # Weaver - deep plum
    {"id": "juno", "hair": (30, 30, 40), "shirt": (170, 100, 60), "pants": (130, 80, 45), "shoes": (60, 40, 25), "hair_style": "short", "detail": None, "wide": False},  # Courier - rust orange
    {"id": "klaus", "hair": (80, 55, 25), "shirt": (60, 80, 50), "pants": (45, 60, 35), "shoes": (55, 40, 25), "hair_style": "short", "detail": None, "wide": True},  # Woodsman - forest green
    {"id": "lottie", "hair": (150, 80, 40), "shirt": (190, 170, 140), "pants": (150, 130, 110), "shoes": (60, 45, 30), "hair_style": "bun", "detail": None, "wide": False},  # Housewife - cream
    {"id": "mortimer", "hair": (60, 50, 45), "shirt": (50, 50, 60), "pants": (40, 40, 50), "shoes": (35, 30, 25), "hair_style": "balding", "detail": (180, 170, 150), "wide": False},  # Undertaker - dark with pocket square
    {"id": "nell", "hair": (170, 100, 60), "shirt": (180, 130, 90), "pants": (140, 100, 65), "shoes": (65, 45, 30), "hair_style": "short", "detail": None, "wide": False},  # Beekeeper - honey tones
    {"id": "osmond", "hair": (140, 120, 100), "shirt": (120, 100, 80), "pants": (90, 75, 55), "shoes": (60, 45, 30), "hair_style": "balding", "detail": None, "wide": True},  # Retired soldier - muted earth
    {"id": "pearl", "hair": (220, 210, 190), "shirt": (160, 140, 180), "pants": (130, 110, 150), "shoes": (55, 45, 40), "hair_style": "bun", "detail": None, "wide": False},  # Elder - soft lavender
    {"id": "rook", "hair": (25, 20, 18), "shirt": (80, 70, 60), "pants": (60, 50, 40), "shoes": (45, 35, 25), "hair_style": "short", "detail": None, "wide": True},  # Bouncer - dark and tough
    {"id": "sable", "hair": (90, 40, 20), "shirt": (150, 80, 100), "pants": (120, 60, 75), "shoes": (55, 40, 30), "hair_style": "short", "detail": None, "wide": False},  # Dancer - magenta tones
    {"id": "thorn", "hair": (60, 45, 30), "shirt": (80, 100, 60), "pants": (60, 75, 45), "shoes": (55, 40, 25), "hair_style": "short", "detail": None, "wide": True},  # Gardener - mossy green
    {"id": "ursa", "hair": (110, 70, 35), "shirt": (170, 120, 80), "pants": (130, 90, 55), "shoes": (70, 50, 30), "hair_style": "bun", "detail": (200, 180, 150), "wide": True},  # Midwife - warm with shawl
]

assert len(NEW_NPCS) == 50, f"Expected 50 NPCs, got {len(NEW_NPCS)}"


def generate_all():
    """Generate awake + sleep sprites for all 50 new NPCs."""
    chars_dir = os.path.join(os.path.dirname(__file__), "..", "assets", "sprites", "characters")
    os.makedirs(chars_dir, exist_ok=True)

    print(f"Generating {len(NEW_NPCS)} new NPC sprites (awake + sleep)...\n")

    for npc in NEW_NPCS:
        npc_id = npc["id"]
        params = {
            "hair_color": npc["hair"],
            "shirt_color": npc["shirt"],
            "pants_color": npc["pants"],
            "shoe_color": npc["shoes"],
            "hair_style": npc["hair_style"],
            "shirt_detail": npc["detail"],
            "wide": npc["wide"],
        }

        # Awake sprite
        img, d = new()
        draw_character(d, **params)
        save(img, "characters", f"{npc_id}_down.png")

        # Sleep sprite
        img, d = new()
        draw_character_sleeping(d, **params)
        save(img, "characters", f"{npc_id}_sleep.png")

    print(f"\nDone! {len(NEW_NPCS) * 2} sprites generated.")


if __name__ == "__main__":
    generate_all()
