extends Node2D
## Generates the town using TileMapLayer with pixel art sprites.
## Walkable tiles (grass, path, floor, door) have navigation polygons in the
## TileSet, so the NavigationRegion is built automatically — no manual outlines.

const TILE_SIZE: int = 32
const MAP_WIDTH: int = 50
const MAP_HEIGHT: int = 40

# Tile IDs (used in the _map array and as TileSet atlas coords)
enum Tile { GRASS1, PATH, WATER, WALL_FRONT, FLOOR, ROOF, DOOR, GRASS2, GRASS3, WALL_SIDE }
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
	{"name": "General Store", "gx": 8, "gy": 6, "w": 6, "h": 5},
	{"name": "Bakery", "gx": 16, "gy": 6, "w": 5, "h": 4},
	{"name": "Tavern", "gx": 23, "gy": 5, "w": 7, "h": 5},
	{"name": "Sheriff Office", "gx": 8, "gy": 15, "w": 5, "h": 4},
	{"name": "Courthouse", "gx": 15, "gy": 15, "w": 7, "h": 5},
	{"name": "Church", "gx": 32, "gy": 5, "w": 6, "h": 7},
	{"name": "House 1", "gx": 5, "gy": 24, "w": 4, "h": 4},
	{"name": "House 2", "gx": 11, "gy": 24, "w": 4, "h": 4},
	{"name": "House 3", "gx": 17, "gy": 24, "w": 4, "h": 4},
	{"name": "House 4", "gx": 23, "gy": 24, "w": 4, "h": 4},
	{"name": "Blacksmith", "gx": 33, "gy": 16, "w": 5, "h": 4},
	{"name": "House 5", "gx": 29, "gy": 24, "w": 4, "h": 4},
]

# Logical map: stores Tile enum values (GRASS1 for all grass initially)
var _map: Array = []

# Building name → which tile IDs belong to it (for roof tinting)
var _building_tiles: Dictionary = {}

var _ground_layer: TileMapLayer
var _building_layer: TileMapLayer
var _label_layer: Node2D
var _tile_set: TileSet


func _ready() -> void:
	_tile_set = _create_tileset()

	_ground_layer = TileMapLayer.new()
	_ground_layer.name = "GroundLayer"
	_ground_layer.tile_set = _tile_set
	add_child(_ground_layer)

	_building_layer = TileMapLayer.new()
	_building_layer.name = "BuildingLayer"
	_building_layer.tile_set = _tile_set
	_building_layer.navigation_enabled = false  # only ground layer provides nav
	add_child(_building_layer)

	_label_layer = Node2D.new()
	_label_layer.name = "LabelLayer"
	add_child(_label_layer)

	_init_map()
	_carve_paths()
	_place_buildings()
	_place_water()
	_render_map()
	_add_building_labels()
	_add_map_boundary()


func _create_tileset() -> TileSet:
	## Builds a TileSet in code with one atlas source containing all tile sprites.
	## Walkable tiles get a navigation polygon; non-walkable get a physics collision.
	var ts := TileSet.new()
	ts.tile_size = Vector2i(TILE_SIZE, TILE_SIZE)

	# Add navigation layer (index 0)
	ts.add_navigation_layer()

	# Add physics layer (index 0) for wall/roof/water collision
	ts.add_physics_layer()
	ts.set_physics_layer_collision_layer(0, 1)
	ts.set_physics_layer_collision_mask(0, 0)

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

	# CRITICAL: add source to TileSet BEFORE creating tiles, so TileData
	# knows about physics/navigation layers (fixes "out of bounds" errors)
	ts.add_source(source)

	# Full navigation polygon (covers entire tile — coordinates from tile center)
	var hs: float = TILE_SIZE / 2.0
	var nav_poly := NavigationPolygon.new()
	nav_poly.vertices = PackedVector2Array([
		Vector2(0, 0), Vector2(TILE_SIZE, 0),
		Vector2(TILE_SIZE, TILE_SIZE), Vector2(0, TILE_SIZE),
	])
	nav_poly.add_polygon(PackedInt32Array([0, 1, 2, 3]))

	# Collision polygon points (relative to tile CENTER, not top-left)
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
			i == Tile.FLOOR or i == Tile.DOOR
		)

		if is_walkable:
			tile_data.set_navigation_polygon(0, nav_poly)
		else:
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
	# Main horizontal road
	for x: int in range(2, MAP_WIDTH - 2):
		_set_tile(x, 12, Tile.PATH)
		_set_tile(x, 13, Tile.PATH)

	# Main vertical road
	for y: int in range(2, MAP_HEIGHT - 2):
		_set_tile(25, y, Tile.PATH)
		_set_tile(26, y, Tile.PATH)

	# Secondary horizontal road (residential area)
	for x: int in range(3, 35):
		_set_tile(x, 22, Tile.PATH)
		_set_tile(x, 23, Tile.PATH)

	# Connecting paths to buildings
	for y: int in range(11, 13):
		_set_tile(10, y, Tile.PATH)
		_set_tile(11, y, Tile.PATH)

	for y: int in range(10, 13):
		_set_tile(18, y, Tile.PATH)

	for y: int in range(10, 13):
		_set_tile(26, y, Tile.PATH)

	for y: int in range(14, 15):
		_set_tile(10, y, Tile.PATH)

	for y: int in range(14, 15):
		_set_tile(18, y, Tile.PATH)

	# Paths down to houses from secondary road
	for hx: int in [6, 12, 18, 24, 30]:
		for y: int in range(22, 25):
			_set_tile(hx, y, Tile.PATH)

	# Path to blacksmith
	for y: int in range(14, 16):
		_set_tile(35, y, Tile.PATH)


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


func _place_water() -> void:
	for y: int in range(30, 35):
		for x: int in range(38, 45):
			var dx: float = x - 41.5
			var dy: float = y - 32.5
			if dx * dx + dy * dy < 12.0:
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

			# Roofs and walls go on building layer (renders above ground)
			if tile_id == Tile.ROOF or tile_id == Tile.WALL_FRONT or tile_id == Tile.WALL_SIDE:
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


func _add_building_labels() -> void:
	for bld: Dictionary in _buildings:
		var gx: int = bld["gx"]
		var gy: int = bld["gy"]
		var w: int = bld["w"]
		var bld_name: String = bld["name"]

		var label := Label.new()
		label.text = bld_name
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
	## Returns {building_name: Vector2} — center of each building's interior floor.
	var positions: Dictionary = {}
	for bld: Dictionary in _buildings:
		var gx: int = bld["gx"]
		var gy: int = bld["gy"]
		var w: int = bld["w"]
		var h: int = bld["h"]
		var pos := Vector2(
			(gx + w / 2.0) * TILE_SIZE,
			(gy + h / 2.0) * TILE_SIZE
		)
		positions[bld["name"]] = pos
	return positions


func get_player_spawn_position() -> Vector2:
	return Vector2(25 * TILE_SIZE + TILE_SIZE / 2.0, 13 * TILE_SIZE + TILE_SIZE / 2.0)
