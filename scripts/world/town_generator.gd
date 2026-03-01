extends Node2D
## Generates the town tilemap at runtime using placeholder colored tiles.
## Buildings are placed as StaticBody2D nodes with collision so the player can't walk through walls.

const TILE_SIZE: int = 32
const MAP_WIDTH: int = 50
const MAP_HEIGHT: int = 40

# Tile colors
const COLOR_GRASS := Color(0.298, 0.6, 0.0)
const COLOR_PATH := Color(0.761, 0.698, 0.502)
const COLOR_WATER := Color(0.2, 0.4, 0.8)
const COLOR_WALL := Color(0.545, 0.353, 0.169)
const COLOR_FLOOR := Color(0.706, 0.627, 0.471)
const COLOR_ROOF := Color(0.698, 0.133, 0.133)
const COLOR_DOOR := Color(0.396, 0.263, 0.129)

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

# Map data: 0=grass, 1=path, 2=water, 3=wall, 4=floor, 5=roof, 6=door
var _map: Array = []

var _ground_layer: Node2D
var _building_layer: Node2D
var _label_layer: Node2D


func _ready() -> void:
	_ground_layer = Node2D.new()
	_ground_layer.name = "GroundLayer"
	add_child(_ground_layer)

	_building_layer = Node2D.new()
	_building_layer.name = "BuildingLayer"
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
	_create_navigation_region()


func _init_map() -> void:
	_map.resize(MAP_HEIGHT)
	for y: int in range(MAP_HEIGHT):
		var row: Array = []
		row.resize(MAP_WIDTH)
		for x: int in range(MAP_WIDTH):
			row[x] = 0  # grass
		_map[y] = row


func _carve_paths() -> void:
	# Main horizontal road
	for x: int in range(2, MAP_WIDTH - 2):
		_set_tile(x, 12, 1)
		_set_tile(x, 13, 1)

	# Main vertical road
	for y: int in range(2, MAP_HEIGHT - 2):
		_set_tile(25, y, 1)
		_set_tile(26, y, 1)

	# Secondary horizontal road (residential area)
	for x: int in range(3, 35):
		_set_tile(x, 22, 1)
		_set_tile(x, 23, 1)

	# Connecting paths to buildings
	# Path from main road to general store
	for y: int in range(11, 13):
		_set_tile(10, y, 1)
		_set_tile(11, y, 1)

	# Path to bakery
	for y: int in range(10, 13):
		_set_tile(18, y, 1)

	# Path to tavern
	for y: int in range(10, 13):
		_set_tile(26, y, 1)

	# Path to sheriff (stop before roof at y=15)
	for y: int in range(14, 15):
		_set_tile(10, y, 1)

	# Path to courthouse (stop before roof at y=15)
	for y: int in range(14, 15):
		_set_tile(18, y, 1)

	# Church door is now at y=11, road at y=12 touches it directly

	# Paths down to houses from secondary road
	for hx: int in [6, 12, 18, 24, 30]:
		for y: int in range(22, 25):
			_set_tile(hx, y, 1)

	# Path to blacksmith (stop before roof at y=16)
	for y: int in range(14, 16):
		_set_tile(35, y, 1)


func _place_buildings() -> void:
	for bld: Dictionary in _buildings:
		var gx: int = bld["gx"]
		var gy: int = bld["gy"]
		var w: int = bld["w"]
		var h: int = bld["h"]

		# Roof (top row)
		for x: int in range(gx, gx + w):
			_set_tile(x, gy, 5)

		# Walls and floor
		for y: int in range(gy + 1, gy + h):
			for x: int in range(gx, gx + w):
				if x == gx or x == gx + w - 1 or y == gy + h - 1:
					_set_tile(x, y, 3)  # wall
				else:
					_set_tile(x, y, 4)  # floor (interior)

		# Door at bottom center
		var door_x: int = gx + w / 2
		_set_tile(door_x, gy + h - 1, 6)


func _place_water() -> void:
	# Small pond in the east
	for y: int in range(30, 35):
		for x: int in range(38, 45):
			var dx: float = x - 41.5
			var dy: float = y - 32.5
			if dx * dx + dy * dy < 12.0:
				_set_tile(x, y, 2)


func _set_tile(x: int, y: int, tile_id: int) -> void:
	if x >= 0 and x < MAP_WIDTH and y >= 0 and y < MAP_HEIGHT:
		_map[y][x] = tile_id


func _get_tile_color(tile_id: int) -> Color:
	match tile_id:
		0: return COLOR_GRASS
		1: return COLOR_PATH
		2: return COLOR_WATER
		3: return COLOR_WALL
		4: return COLOR_FLOOR
		5: return COLOR_ROOF
		6: return COLOR_DOOR
		_: return COLOR_GRASS


func _render_map() -> void:
	for y: int in range(MAP_HEIGHT):
		for x: int in range(MAP_WIDTH):
			var tile_id: int = _map[y][x]
			var color: Color = _get_tile_color(tile_id)

			var rect := ColorRect.new()
			rect.size = Vector2(TILE_SIZE, TILE_SIZE)
			rect.position = Vector2(x * TILE_SIZE, y * TILE_SIZE)
			rect.color = color

			if tile_id == 3 or tile_id == 5:
				# Walls and roofs are solid — add to building layer
				_building_layer.add_child(rect)
			else:
				_ground_layer.add_child(rect)

	# Add collision for walls, roofs, and water
	for bld: Dictionary in _buildings:
		_add_building_collision(bld)
	_add_water_collision()
	_add_map_boundary()


func _add_building_collision(bld: Dictionary) -> void:
	var gx: int = bld["gx"]
	var gy: int = bld["gy"]
	var w: int = bld["w"]
	var h: int = bld["h"]

	# Create collision bodies for walls (not the door or interior)
	for y: int in range(gy, gy + h):
		for x: int in range(gx, gx + w):
			var tile_id: int = _map[y][x]
			if tile_id == 3 or tile_id == 5:  # wall or roof
				var body := StaticBody2D.new()
				body.position = Vector2(x * TILE_SIZE + TILE_SIZE / 2.0, y * TILE_SIZE + TILE_SIZE / 2.0)
				body.collision_layer = 1
				body.collision_mask = 0

				var shape := CollisionShape2D.new()
				var rect_shape := RectangleShape2D.new()
				rect_shape.size = Vector2(TILE_SIZE, TILE_SIZE)
				shape.shape = rect_shape
				body.add_child(shape)

				_building_layer.add_child(body)


func _add_water_collision() -> void:
	for y: int in range(MAP_HEIGHT):
		for x: int in range(MAP_WIDTH):
			if _map[y][x] == 2:
				var body := StaticBody2D.new()
				body.position = Vector2(x * TILE_SIZE + TILE_SIZE / 2.0, y * TILE_SIZE + TILE_SIZE / 2.0)
				body.collision_layer = 1
				body.collision_mask = 0
				var shape := CollisionShape2D.new()
				var rect_shape := RectangleShape2D.new()
				rect_shape.size = Vector2(TILE_SIZE, TILE_SIZE)
				shape.shape = rect_shape
				body.add_child(shape)
				_ground_layer.add_child(body)


func _add_map_boundary() -> void:
	# Four walls around the map edge
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

		# Center label over building
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.size.x = w * TILE_SIZE

		_label_layer.add_child(label)


func _create_navigation_region() -> void:
	var nav_region := NavigationRegion2D.new()
	nav_region.name = "NavigationRegion"

	var nav_poly := NavigationPolygon.new()

	# Build navmesh directly from walkable tiles. Each walkable tile becomes a
	# quad polygon. Adjacent walkable tiles share edge vertices, so the nav
	# server connects them automatically. This avoids the outline approach where
	# shared vertices between wall segments broke make_polygons_from_outlines().
	var verts := PackedVector2Array()
	var vert_map := {}
	var polys: Array = []

	for y: int in range(MAP_HEIGHT):
		for x: int in range(MAP_WIDTH):
			var tile: int = _map[y][x]
			# Walkable: grass(0), path(1), floor(4), door(6)
			if tile == 0 or tile == 1 or tile == 4 or tile == 6:
				var px: int = x * TILE_SIZE
				var py: int = y * TILE_SIZE
				var i_tl: int = _nav_vert(verts, vert_map, px, py)
				var i_tr: int = _nav_vert(verts, vert_map, px + TILE_SIZE, py)
				var i_br: int = _nav_vert(verts, vert_map, px + TILE_SIZE, py + TILE_SIZE)
				var i_bl: int = _nav_vert(verts, vert_map, px, py + TILE_SIZE)
				polys.append(PackedInt32Array([i_tl, i_tr, i_br, i_bl]))

	nav_poly.vertices = verts
	for p: PackedInt32Array in polys:
		nav_poly.add_polygon(p)

	nav_region.navigation_polygon = nav_poly
	add_child(nav_region)


func _nav_vert(verts: PackedVector2Array, vert_map: Dictionary, px: int, py: int) -> int:
	## Returns vertex index for the given pixel coordinate, adding it if new.
	var key := Vector2i(px, py)
	if vert_map.has(key):
		return vert_map[key]
	var idx: int = verts.size()
	verts.append(Vector2(px, py))
	vert_map[key] = idx
	return idx


func get_building_door_positions() -> Dictionary:
	## Returns {building_name: Vector2} — center of each building's interior floor.
	var positions: Dictionary = {}
	for bld: Dictionary in _buildings:
		var gx: int = bld["gx"]
		var gy: int = bld["gy"]
		var w: int = bld["w"]
		var h: int = bld["h"]
		# Center of the interior floor area
		var pos := Vector2(
			(gx + w / 2.0) * TILE_SIZE,
			(gy + h / 2.0) * TILE_SIZE
		)
		positions[bld["name"]] = pos
	return positions


func get_player_spawn_position() -> Vector2:
	# Spawn on the path intersection
	return Vector2(25 * TILE_SIZE + TILE_SIZE / 2.0, 13 * TILE_SIZE + TILE_SIZE / 2.0)
