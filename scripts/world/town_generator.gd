extends Node2D
## Generates the town using TileMapLayer with pixel art sprites.
## Pathfinding uses AStarGrid2D directly on the tile grid — no NavigationServer needed.

const TILE_SIZE: int = 32
const MAP_WIDTH: int = 60
const MAP_HEIGHT: int = 45

# Tile IDs (used in the _map array and as TileSet atlas coords)
enum Tile { GRASS1, PATH, WATER, WALL_FRONT, FLOOR, ROOF, DOOR, GRASS2, GRASS3, WALL_SIDE,
	COBBLESTONE, DIRT_PATH,
	# --- Furniture ---
	BED, TABLE, COUNTER, OVEN, ANVIL, PEW, ALTAR, BARREL, SHELF, DESK,
	# --- Building Exterior ---
	WINDOW_FRONT, WINDOW_SIDE, AWNING }
# Atlas layout: each tile gets column = Tile enum value, row = 0

# Grass variant weights for visual variety
const GRASS_VARIANTS: Array[int] = [Tile.GRASS1, Tile.GRASS1, Tile.GRASS1, Tile.GRASS1,
	Tile.GRASS1, Tile.GRASS1, Tile.GRASS2, Tile.GRASS2, Tile.GRASS3]

# Roof tints per building type
const ROOF_TINTS: Dictionary = {
	"General Store": Color(0.9, 0.8, 0.6),
	"Bakery": Color(1.2, 0.9, 0.7),
	"Tavern": Color(0.8, 0.6, 0.6),
	"Sheriff Office": Color(0.7, 0.7, 0.9),
	"Courthouse": Color(0.7, 0.7, 0.7),
	"Church": Color(0.7, 0.6, 0.8),
	"Blacksmith": Color(0.5, 0.4, 0.4),
}

# Building definitions: {name, grid_x, grid_y, width, height}
var _buildings: Array[Dictionary] = [
	# --- Commercial row (top) ---
	{"name": "General Store", "gx": 8, "gy": 6, "w": 7, "h": 5},
	{"name": "Bakery", "gx": 17, "gy": 6, "w": 6, "h": 5},
	{"name": "Tavern", "gx": 25, "gy": 5, "w": 8, "h": 6},
	{"name": "Church", "gx": 38, "gy": 5, "w": 7, "h": 8},
	# --- Service row (middle) ---
	{"name": "Sheriff Office", "gx": 8, "gy": 15, "w": 6, "h": 5},
	{"name": "Courthouse", "gx": 16, "gy": 15, "w": 8, "h": 5},
	{"name": "Blacksmith", "gx": 38, "gy": 16, "w": 6, "h": 5},
	# --- Housing row 1 ---
	{"name": "House 1", "gx": 4, "gy": 25, "w": 6, "h": 5},
	{"name": "House 2", "gx": 12, "gy": 25, "w": 6, "h": 5},
	{"name": "House 3", "gx": 20, "gy": 25, "w": 6, "h": 5},
	{"name": "House 4", "gx": 28, "gy": 25, "w": 6, "h": 5},
	{"name": "House 5", "gx": 36, "gy": 25, "w": 6, "h": 5},
	{"name": "House 6", "gx": 44, "gy": 25, "w": 6, "h": 5},
	# --- Housing row 2 ---
	{"name": "House 7", "gx": 4, "gy": 33, "w": 6, "h": 5},
	{"name": "House 8", "gx": 12, "gy": 33, "w": 6, "h": 5},
	{"name": "House 9", "gx": 20, "gy": 33, "w": 6, "h": 5},
	{"name": "House 10", "gx": 28, "gy": 33, "w": 6, "h": 5},
	{"name": "House 11", "gx": 36, "gy": 33, "w": 6, "h": 5},
]

# Logical map: stores Tile enum values (GRASS1 for all grass initially)
var _map: Array = []

# Building name → which tile IDs belong to it (for roof tinting)
var _building_tiles: Dictionary = {}

var _ground_layer: TileMapLayer
var _building_layer: TileMapLayer
var _label_layer: Node2D
var _tile_set: TileSet

# AStarGrid2D for NPC pathfinding — replaces broken NavigationServer2D approach
var _astar: AStarGrid2D

# Door open/close visual system
var _door_closed_tex: Texture2D = null
var _door_open_tex: Texture2D = null
var _door_positions: Dictionary = {}   # {Vector2i: building_name}
var _door_sprites: Dictionary = {}     # {Vector2i: Sprite2D}
var _door_check_counter: int = 0


func _ready() -> void:
	_tile_set = _create_tileset()

	# Load door textures for proximity-based open/close
	_door_closed_tex = load("res://assets/sprites/tiles/door.png")
	_door_open_tex = load("res://assets/sprites/tiles/door_open.png")

	_ground_layer = TileMapLayer.new()
	_ground_layer.name = "GroundLayer"
	_ground_layer.tile_set = _tile_set
	_ground_layer.navigation_enabled = false
	add_child(_ground_layer)

	_building_layer = TileMapLayer.new()
	_building_layer.name = "BuildingLayer"
	_building_layer.tile_set = _tile_set
	_building_layer.navigation_enabled = false
	add_child(_building_layer)

	_label_layer = Node2D.new()
	_label_layer.name = "LabelLayer"
	add_child(_label_layer)

	_init_map()
	_carve_paths()
	_place_buildings()
	_decorate_buildings()
	_place_furniture()
	_register_furniture_objects()
	_place_water()
	_render_map()
	_init_door_sprites()
	_build_astar()
	_add_building_labels()
	_add_map_boundary()


func _create_tileset() -> TileSet:
	## Builds a TileSet in code with one atlas source containing all tile sprites.
	## Non-walkable tiles get physics collision. No navigation layer needed (using AStarGrid2D).
	var ts := TileSet.new()
	ts.tile_size = Vector2i(TILE_SIZE, TILE_SIZE)

	# Add physics layer (index 0) for wall/roof/water collision
	ts.add_physics_layer()
	ts.set_physics_layer_collision_layer(0, 1)
	ts.set_physics_layer_collision_mask(0, 0)

	# No navigation layer — we use AStarGrid2D instead

	# Atlas source: each tile is a separate 32x32 image loaded as a 1-column atlas
	var source := TileSetAtlasSource.new()
	source.texture_region_size = Vector2i(TILE_SIZE, TILE_SIZE)

	var tile_paths: Array[String] = [
		"res://assets/sprites/tiles/grass_1.png",    # 0 = GRASS1
		"res://assets/sprites/tiles/path_center.png", # 1 = PATH
		"res://assets/sprites/tiles/water_1.png",     # 2 = WATER
		"res://assets/sprites/tiles/wall_front.png",  # 3 = WALL_FRONT
		"res://assets/sprites/tiles/floor_wood.png",  # 4 = FLOOR
		"res://assets/sprites/tiles/roof_generic.png", # 5 = ROOF
		"res://assets/sprites/tiles/door.png",        # 6 = DOOR
		"res://assets/sprites/tiles/grass_2.png",     # 7 = GRASS2
		"res://assets/sprites/tiles/grass_3.png",     # 8 = GRASS3
		"res://assets/sprites/tiles/wall_side.png",   # 9 = WALL_SIDE
		"res://assets/sprites/tiles/cobblestone.png", # 10 = COBBLESTONE
		"res://assets/sprites/tiles/dirt_path.png",   # 11 = DIRT_PATH
		# --- Furniture ---
		"res://assets/sprites/tiles/bed.png",         # 12 = BED
		"res://assets/sprites/tiles/table.png",       # 13 = TABLE
		"res://assets/sprites/tiles/counter.png",     # 14 = COUNTER
		"res://assets/sprites/tiles/oven.png",        # 15 = OVEN
		"res://assets/sprites/tiles/anvil.png",       # 16 = ANVIL
		"res://assets/sprites/tiles/pew.png",         # 17 = PEW
		"res://assets/sprites/tiles/altar.png",       # 18 = ALTAR
		"res://assets/sprites/tiles/barrel.png",      # 19 = BARREL
		"res://assets/sprites/tiles/shelf.png",       # 20 = SHELF
		"res://assets/sprites/tiles/desk.png",        # 21 = DESK
		# --- Building Exterior ---
		"res://assets/sprites/tiles/window_front.png", # 22 = WINDOW_FRONT
		"res://assets/sprites/tiles/window_side.png",  # 23 = WINDOW_SIDE
		"res://assets/sprites/tiles/awning.png",       # 24 = AWNING
	]

	# Build a horizontal atlas image (N tiles wide, 1 tile tall)
	var atlas_img := Image.create(TILE_SIZE * tile_paths.size(), TILE_SIZE, false, Image.FORMAT_RGBA8)
	for i: int in range(tile_paths.size()):
		var tex: Texture2D = load(tile_paths[i])
		var img: Image = tex.get_image()
		img.convert(Image.FORMAT_RGBA8)
		atlas_img.blit_rect(img, Rect2i(0, 0, TILE_SIZE, TILE_SIZE), Vector2i(i * TILE_SIZE, 0))

	var atlas_tex := ImageTexture.create_from_image(atlas_img)
	source.texture = atlas_tex

	# Add source to TileSet BEFORE creating tiles
	ts.add_source(source)

	# Collision polygon points (relative to tile CENTER)
	var hs: float = TILE_SIZE / 2.0
	var collision_points := PackedVector2Array([
		Vector2(-hs, -hs), Vector2(hs, -hs),
		Vector2(hs, hs), Vector2(-hs, hs),
	])

	# Create tile data for each tile
	for i: int in range(tile_paths.size()):
		var coord := Vector2i(i, 0)
		source.create_tile(coord)
		var tile_data: TileData = source.get_tile_data(coord, 0)

		var is_walkable: bool = (
			i == Tile.GRASS1 or i == Tile.GRASS2 or
			i == Tile.GRASS3 or i == Tile.PATH or
			i == Tile.FLOOR or i == Tile.DOOR or
			i == Tile.COBBLESTONE or i == Tile.DIRT_PATH
		)

		if not is_walkable:
			# Non-walkable: add physics collision so player can't walk through
			tile_data.add_collision_polygon(0)
			tile_data.set_collision_polygon_points(0, 0, collision_points)

	return ts


func _init_map() -> void:
	_map.resize(MAP_HEIGHT)
	for y: int in range(MAP_HEIGHT):
		var row: Array = []
		row.resize(MAP_WIDTH)
		for x: int in range(MAP_WIDTH):
			row[x] = Tile.GRASS1
		_map[y] = row


func _carve_paths() -> void:
	# === MAIN ROADS (cobblestone) ===
	# East-west highway
	for x: int in range(2, MAP_WIDTH - 2):
		_set_tile(x, 12, Tile.COBBLESTONE)
		_set_tile(x, 13, Tile.COBBLESTONE)
	# North-south highway
	for y: int in range(2, MAP_HEIGHT - 2):
		_set_tile(29, y, Tile.COBBLESTONE)
		_set_tile(30, y, Tile.COBBLESTONE)

	# === HOUSING STREETS (dirt) ===
	for x: int in range(2, MAP_WIDTH - 2):
		_set_tile(x, 23, Tile.DIRT_PATH)
		_set_tile(x, 24, Tile.DIRT_PATH)
	for x: int in range(2, MAP_WIDTH - 2):
		_set_tile(x, 31, Tile.DIRT_PATH)
		_set_tile(x, 32, Tile.DIRT_PATH)

	# === CONNECTORS (dirt) ===
	# To commercial buildings
	for y: int in range(10, 14):
		_set_tile(11, y, Tile.DIRT_PATH)
		_set_tile(20, y, Tile.DIRT_PATH)
		_set_tile(41, y, Tile.DIRT_PATH)
	# To service buildings
	for y: int in range(13, 20):
		_set_tile(11, y, Tile.DIRT_PATH)
		_set_tile(20, y, Tile.DIRT_PATH)
		_set_tile(41, y, Tile.DIRT_PATH)
	# To housing row 1
	for y: int in range(24, 27):
		for hx: int in [7, 15, 23, 31, 39, 47]:
			_set_tile(hx, y, Tile.DIRT_PATH)
	# Between housing rows
	for y: int in range(24, 33):
		for hx: int in [7, 15, 23, 31, 39]:
			_set_tile(hx, y, Tile.DIRT_PATH)
	# To housing row 2
	for y: int in range(32, 35):
		for hx: int in [7, 15, 23, 31, 39]:
			_set_tile(hx, y, Tile.DIRT_PATH)


func _place_buildings() -> void:
	for bld: Dictionary in _buildings:
		var gx: int = bld["gx"]
		var gy: int = bld["gy"]
		var w: int = bld["w"]
		var h: int = bld["h"]

		# Roof (top row)
		for x: int in range(gx, gx + w):
			_set_tile(x, gy, Tile.ROOF)

		# Walls and floor
		for y: int in range(gy + 1, gy + h):
			for x: int in range(gx, gx + w):
				if x == gx or x == gx + w - 1:
					_set_tile(x, y, Tile.WALL_SIDE)
				elif y == gy + h - 1:
					_set_tile(x, y, Tile.WALL_FRONT)
				else:
					_set_tile(x, y, Tile.FLOOR)

		# Door at bottom center
		var door_x: int = gx + w / 2
		_set_tile(door_x, gy + h - 1, Tile.DOOR)
		_door_positions[Vector2i(door_x, gy + h - 1)] = bld["name"]


func _decorate_buildings() -> void:
	## Adds windows to walls and awnings above shop doors.

	var awning_buildings: Array[String] = [
		"General Store", "Bakery", "Tavern"
	]

	for bld: Dictionary in _buildings:
		var bld_name: String = bld["name"]
		var gx: int = bld["gx"]
		var gy: int = bld["gy"]
		var w: int = bld["w"]
		var h: int = bld["h"]
		var door_x: int = gx + w / 2

		# --- FRONT WALL WINDOWS ---
		# On both sides of the door, skip door and adjacent tiles
		if w >= 6:
			for x: int in range(gx + 1, gx + w - 1):
				if x == door_x or x == door_x - 1 or x == door_x + 1:
					continue
				if _map[gy + h - 1][x] == Tile.WALL_FRONT:
					_set_tile(x, gy + h - 1, Tile.WINDOW_FRONT)

		# --- SIDE WALL WINDOWS ---
		if h >= 5:
			var wy: int = gy + 2
			if _map[wy][gx] == Tile.WALL_SIDE:
				_set_tile(gx, wy, Tile.WINDOW_SIDE)
			if _map[wy][gx + w - 1] == Tile.WALL_SIDE:
				_set_tile(gx + w - 1, wy, Tile.WINDOW_SIDE)

		# Church gets extra side windows (tall building)
		if bld_name == "Church" and h >= 7:
			for wy: int in [gy + 2, gy + 4]:
				if _map[wy][gx] == Tile.WALL_SIDE:
					_set_tile(gx, wy, Tile.WINDOW_SIDE)
				if _map[wy][gx + w - 1] == Tile.WALL_SIDE:
					_set_tile(gx + w - 1, wy, Tile.WINDOW_SIDE)

		# --- AWNINGS above shop doors ---
		if bld_name in awning_buildings:
			_set_tile(door_x, gy, Tile.AWNING)
			# Wider awning for bigger shops
			if w >= 7:
				if door_x - 1 > gx:
					_set_tile(door_x - 1, gy, Tile.AWNING)
				if door_x + 1 < gx + w - 1:
					_set_tile(door_x + 1, gy, Tile.AWNING)


func _place_furniture() -> void:
	## Coordinates are interior offsets from (gx+1, gy+1).
	## Each entry: [dx, dy, TileType]

	var layouts: Dictionary = {
		"Church": [
			# 5×6 interior → 11 furniture, 19 walkable
			[1, 0, Tile.ALTAR], [2, 0, Tile.ALTAR], [3, 0, Tile.ALTAR],
			[0, 2, Tile.PEW], [1, 2, Tile.PEW], [3, 2, Tile.PEW], [4, 2, Tile.PEW],
			[0, 4, Tile.PEW], [1, 4, Tile.PEW], [3, 4, Tile.PEW], [4, 4, Tile.PEW],
		],
		"Tavern": [
			# 6×4 interior → 8 furniture, 16 walkable
			[1, 0, Tile.COUNTER], [2, 0, Tile.COUNTER],
			[3, 0, Tile.COUNTER], [4, 0, Tile.COUNTER],
			[0, 0, Tile.BARREL], [5, 0, Tile.BARREL],
			[0, 2, Tile.TABLE], [5, 2, Tile.TABLE],
		],
		"Bakery": [
			# 4×3 interior → 3 furniture, 9 walkable
			[0, 0, Tile.OVEN],
			[0, 2, Tile.COUNTER], [1, 2, Tile.COUNTER],
		],
		"Blacksmith": [
			# 4×3 interior → 3 furniture, 9 walkable
			[0, 0, Tile.SHELF], [1, 0, Tile.ANVIL], [3, 0, Tile.BARREL],
		],
		"General Store": [
			# 5×3 interior → 5 furniture, 10 walkable
			[0, 0, Tile.SHELF], [1, 0, Tile.SHELF], [2, 0, Tile.SHELF],
			[0, 2, Tile.COUNTER], [1, 2, Tile.COUNTER],
		],
		"Sheriff Office": [
			# 4×3 interior → 3 furniture, 9 walkable
			[0, 0, Tile.DESK], [1, 0, Tile.DESK], [3, 0, Tile.SHELF],
		],
		"Courthouse": [
			# 6×3 interior → 6 furniture, 12 walkable
			[0, 0, Tile.DESK], [2, 0, Tile.DESK], [3, 0, Tile.DESK],
			[1, 2, Tile.PEW], [2, 2, Tile.PEW], [4, 2, Tile.PEW],
		],
	}

	# Houses: 4×3 interior = 12 tiles → 3 furniture, 9 walkable
	var house_layout: Array = [
		[0, 0, Tile.BED], [1, 0, Tile.SHELF], [1, 2, Tile.TABLE],
	]

	for bld: Dictionary in _buildings:
		var bld_name: String = bld["name"]
		var interior_x: int = bld["gx"] + 1
		var interior_y: int = bld["gy"] + 1

		var layout: Array = []
		if layouts.has(bld_name):
			layout = layouts[bld_name]
		elif bld_name.begins_with("House"):
			layout = house_layout

		for item: Array in layout:
			_set_tile(interior_x + item[0], interior_y + item[1], item[2])

	# Debug: verify walkable counts
	if OS.is_debug_build():
		var counts: Dictionary = get_building_interior_positions()
		for bld_name: String in counts:
			print("[Furniture] %s: %d walkable tiles" % [bld_name, counts[bld_name].size()])


func _register_furniture_objects() -> void:
	## Scans all buildings and registers placed furniture tiles with WorldObjects.
	var tile_type_names: Dictionary = {
		Tile.BED: "bed", Tile.TABLE: "table", Tile.COUNTER: "counter",
		Tile.OVEN: "oven", Tile.ANVIL: "anvil", Tile.PEW: "pew",
		Tile.ALTAR: "altar", Tile.BARREL: "barrel", Tile.SHELF: "shelf",
		Tile.DESK: "desk",
	}

	for bld: Dictionary in _buildings:
		var bld_name: String = bld["name"]
		var gx: int = bld["gx"]
		var gy: int = bld["gy"]
		var w: int = bld["w"]
		var h: int = bld["h"]
		var type_counts: Dictionary = {}

		for y: int in range(gy + 1, gy + h - 1):
			for x: int in range(gx + 1, gx + w - 1):
				var tile_id: int = _map[y][x]
				if tile_type_names.has(tile_id):
					var type_name: String = tile_type_names[tile_id]
					var count: int = type_counts.get(type_name, 0)
					type_counts[type_name] = count + 1
					var object_id: String = "%s:%s:%d" % [bld_name, type_name, count]
					WorldObjects.register_object(object_id, bld_name, type_name, Vector2i(x, y))

	if OS.is_debug_build():
		print("[TownMap] Registered %d furniture objects with WorldObjects" % WorldObjects._objects.size())


func get_furniture_adjacent_tile(grid_pos: Vector2i) -> Vector2:
	## Returns the world position of the best walkable tile adjacent to a furniture tile.
	## Priority: south (in front), east, west, north.
	var offsets: Array[Vector2i] = [
		Vector2i(0, 1), Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, -1),
	]
	for offset: Vector2i in offsets:
		var check: Vector2i = grid_pos + offset
		if check.x < 0 or check.x >= MAP_WIDTH or check.y < 0 or check.y >= MAP_HEIGHT:
			continue
		var tile_id: int = _map[check.y][check.x]
		if tile_id == Tile.FLOOR or tile_id == Tile.DOOR:
			return Vector2(
				check.x * TILE_SIZE + TILE_SIZE / 2.0,
				check.y * TILE_SIZE + TILE_SIZE / 2.0
			)
	# Fallback: south of furniture
	return Vector2(
		grid_pos.x * TILE_SIZE + TILE_SIZE / 2.0,
		(grid_pos.y + 1) * TILE_SIZE + TILE_SIZE / 2.0
	)


func _place_water() -> void:
	for y: int in range(36, 42):
		for x: int in range(46, 55):
			var dx: float = x - 50.5
			var dy: float = y - 39.0
			if dx * dx + dy * dy < 16.0:
				_set_tile(x, y, Tile.WATER)


func _set_tile(x: int, y: int, tile_id: int) -> void:
	if x >= 0 and x < MAP_WIDTH and y >= 0 and y < MAP_HEIGHT:
		_map[y][x] = tile_id


func _render_map() -> void:
	# Seed for deterministic grass variant placement
	var rng := RandomNumberGenerator.new()
	rng.seed = 42

	for y: int in range(MAP_HEIGHT):
		for x: int in range(MAP_WIDTH):
			var tile_id: int = _map[y][x]

			# Randomize grass variants
			if tile_id == Tile.GRASS1:
				tile_id = GRASS_VARIANTS[rng.randi() % GRASS_VARIANTS.size()]

			var coord := Vector2i(x, y)
			var atlas_coord := Vector2i(tile_id, 0)

			# Roofs, walls, and exterior details go on building layer
			if tile_id == Tile.ROOF or tile_id == Tile.WALL_FRONT or tile_id == Tile.WALL_SIDE or tile_id == Tile.WINDOW_FRONT or tile_id == Tile.WINDOW_SIDE or tile_id == Tile.AWNING:
				_building_layer.set_cell(coord, 0, atlas_coord)
			elif tile_id >= Tile.BED and tile_id <= Tile.DESK:
				# Furniture: floor underneath + furniture sprite on top
				_ground_layer.set_cell(coord, 0, Vector2i(Tile.FLOOR, 0))
				_building_layer.set_cell(coord, 0, atlas_coord)
			else:
				_ground_layer.set_cell(coord, 0, atlas_coord)

	# Apply roof tints per building
	for bld: Dictionary in _buildings:
		var tint: Color = ROOF_TINTS.get(bld["name"], Color.WHITE)
		if tint == Color.WHITE:
			continue
		var gx: int = bld["gx"]
		var gy: int = bld["gy"]
		var w: int = bld["w"]
		for x: int in range(gx, gx + w):
			var data: TileData = _building_layer.get_cell_tile_data(Vector2i(x, gy))
			if data:
				data.modulate = tint


func _init_door_sprites() -> void:
	## Create Sprite2D overlays for each door tile (covers the tilemap door).
	for grid_pos: Vector2i in _door_positions:
		var spr := Sprite2D.new()
		spr.position = Vector2(
			grid_pos.x * TILE_SIZE + TILE_SIZE / 2.0,
			grid_pos.y * TILE_SIZE + TILE_SIZE / 2.0
		)
		spr.z_index = 5  # Above ground tiles, below NPCs
		spr.texture = _door_closed_tex
		add_child(spr)
		_door_sprites[grid_pos] = spr
	print("[TownMap] Created %d door overlays" % _door_sprites.size())


func _process(_delta: float) -> void:
	_door_check_counter += 1
	if _door_check_counter % 5 == 0:
		_update_doors()


func _update_doors() -> void:
	## Check all door positions and swap sprite based on proximity.
	var bodies: Array[Node] = []
	bodies.append_array(get_tree().get_nodes_in_group("npcs"))
	bodies.append_array(get_tree().get_nodes_in_group("player"))

	var threshold: float = TILE_SIZE * 1.8

	for door_grid: Vector2i in _door_positions:
		var door_world := Vector2(
			door_grid.x * TILE_SIZE + TILE_SIZE / 2.0,
			door_grid.y * TILE_SIZE + TILE_SIZE / 2.0
		)

		var anyone_near: bool = false
		for body: Node in bodies:
			if body is CharacterBody2D:
				if body.global_position.distance_to(door_world) < threshold:
					anyone_near = true
					break

		var spr: Sprite2D = _door_sprites[door_grid]
		var target_tex: Texture2D = _door_open_tex if anyone_near else _door_closed_tex
		if spr.texture != target_tex:
			spr.texture = target_tex


func _build_astar() -> void:
	## Builds an AStarGrid2D from the logical tile map.
	## Walkable: GRASS1, GRASS2, GRASS3, PATH, FLOOR, DOOR
	## Solid: WALL_FRONT, WALL_SIDE, ROOF, WATER
	_astar = AStarGrid2D.new()
	_astar.region = Rect2i(0, 0, MAP_WIDTH, MAP_HEIGHT)
	_astar.cell_size = Vector2(TILE_SIZE, TILE_SIZE)
	_astar.offset = Vector2(TILE_SIZE / 2.0, TILE_SIZE / 2.0)  # center of tile
	_astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	_astar.update()

	# Mark non-walkable tiles as solid
	for y: int in range(MAP_HEIGHT):
		for x: int in range(MAP_WIDTH):
			var tile_id: int = _map[y][x]
			var is_walkable: bool = (
				tile_id == Tile.GRASS1 or tile_id == Tile.GRASS2 or
				tile_id == Tile.GRASS3 or tile_id == Tile.PATH or
				tile_id == Tile.FLOOR or tile_id == Tile.DOOR or
				tile_id == Tile.COBBLESTONE or tile_id == Tile.DIRT_PATH
			)
			if not is_walkable:
				_astar.set_point_solid(Vector2i(x, y), true)

	print("[TownMap] AStarGrid2D built: %dx%d, walkable tiles marked" % [MAP_WIDTH, MAP_HEIGHT])


func get_astar() -> AStarGrid2D:
	## Returns the pathfinding grid for NPC navigation.
	return _astar


func _add_building_labels() -> void:
	for bld: Dictionary in _buildings:
		var gx: int = bld["gx"]
		var gy: int = bld["gy"]
		var w: int = bld["w"]
		var bld_name: String = bld["name"]

		var display_name: String = bld_name
		if bld_name == "House 11" and PlayerProfile.is_name_set:
			display_name = "%s's House" % PlayerProfile.player_name

		var label := Label.new()
		label.text = display_name
		label.position = Vector2(gx * TILE_SIZE, (gy - 1) * TILE_SIZE)
		label.add_theme_font_size_override("font_size", 10)
		label.add_theme_color_override("font_color", Color.WHITE)
		label.add_theme_color_override("font_shadow_color", Color.BLACK)
		label.add_theme_constant_override("shadow_offset_x", 1)
		label.add_theme_constant_override("shadow_offset_y", 1)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.size.x = w * TILE_SIZE
		_label_layer.add_child(label)


func _add_map_boundary() -> void:
	var walls: Array[Dictionary] = [
		{"x": MAP_WIDTH * TILE_SIZE / 2.0, "y": -16.0, "w": MAP_WIDTH * TILE_SIZE + 64.0, "h": 32.0},
		{"x": MAP_WIDTH * TILE_SIZE / 2.0, "y": MAP_HEIGHT * TILE_SIZE + 16.0, "w": MAP_WIDTH * TILE_SIZE + 64.0, "h": 32.0},
		{"x": -16.0, "y": MAP_HEIGHT * TILE_SIZE / 2.0, "w": 32.0, "h": MAP_HEIGHT * TILE_SIZE + 64.0},
		{"x": MAP_WIDTH * TILE_SIZE + 16.0, "y": MAP_HEIGHT * TILE_SIZE / 2.0, "w": 32.0, "h": MAP_HEIGHT * TILE_SIZE + 64.0},
	]
	for wall_data: Dictionary in walls:
		var body := StaticBody2D.new()
		body.position = Vector2(wall_data["x"], wall_data["y"])
		body.collision_layer = 1
		body.collision_mask = 0
		var shape := CollisionShape2D.new()
		var rect_shape := RectangleShape2D.new()
		rect_shape.size = Vector2(wall_data["w"], wall_data["h"])
		shape.shape = rect_shape
		body.add_child(shape)
		add_child(body)


func get_building_door_positions() -> Dictionary:
	## Returns {building_name: Vector2} — the DOOR tile position of each building.
	## Targets the door (bottom center), not the building interior center.
	var positions: Dictionary = {}
	for bld: Dictionary in _buildings:
		var gx: int = bld["gx"]
		var gy: int = bld["gy"]
		var w: int = bld["w"]
		var h: int = bld["h"]
		# Door is at bottom center of building, centered in that tile
		var door_x: int = gx + w / 2
		# One tile above the door = inside the building (FLOOR tile)
		var door_y: int = gy + h - 2
		var pos := Vector2(
			door_x * TILE_SIZE + TILE_SIZE / 2.0,
			door_y * TILE_SIZE + TILE_SIZE / 2.0
		)
		positions[bld["name"]] = pos
	return positions


func get_building_interior_positions() -> Dictionary:
	## Returns {building_name: Array[Vector2]} — all walkable FLOOR tiles inside each building.
	var interiors: Dictionary = {}
	for bld: Dictionary in _buildings:
		var gx: int = bld["gx"]
		var gy: int = bld["gy"]
		var w: int = bld["w"]
		var h: int = bld["h"]
		var tiles: Array[Vector2] = []
		# Interior = everything inside walls (skip edges and bottom wall row)
		for y: int in range(gy + 1, gy + h - 1):
			for x: int in range(gx + 1, gx + w - 1):
				var tile_id: int = _map[y][x]
				if tile_id == Tile.FLOOR:
					tiles.append(Vector2(
						x * TILE_SIZE + TILE_SIZE / 2.0,
						y * TILE_SIZE + TILE_SIZE / 2.0
					))
		interiors[bld["name"]] = tiles
	return interiors


# --- Tile Reservation System (anti-stacking) ---

var _reserved_tiles: Dictionary = {}  # {Vector2i: npc_name}


func reserve_tile(grid_pos: Vector2i, npc_name: String) -> bool:
	## Try to reserve a tile for an NPC. Returns false if already claimed by another.
	if _reserved_tiles.has(grid_pos) and _reserved_tiles[grid_pos] != npc_name:
		return false
	_reserved_tiles[grid_pos] = npc_name
	return true


func release_tile(grid_pos: Vector2i, npc_name: String) -> void:
	## Release a tile reservation when NPC leaves.
	if _reserved_tiles.has(grid_pos) and _reserved_tiles[grid_pos] == npc_name:
		_reserved_tiles.erase(grid_pos)


func get_unreserved_interior_tile(building_name: String, npc_name: String) -> Vector2:
	## Returns a random unreserved interior tile. Falls back to first tile if all taken.
	var interiors: Dictionary = get_building_interior_positions()
	if not interiors.has(building_name):
		return Vector2.ZERO
	var tiles: Array = interiors[building_name]
	var shuffled: Array = tiles.duplicate()
	shuffled.shuffle()
	for tile_pos: Vector2 in shuffled:
		var grid: Vector2i = Vector2i(int(tile_pos.x) / TILE_SIZE, int(tile_pos.y) / TILE_SIZE)
		if reserve_tile(grid, npc_name):
			return tile_pos
	return tiles[0]


func get_player_spawn_position() -> Vector2:
	return Vector2(29 * TILE_SIZE + TILE_SIZE / 2.0, 13 * TILE_SIZE + TILE_SIZE / 2.0)
