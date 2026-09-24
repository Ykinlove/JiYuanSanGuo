extends SceneTree
## 离线烘焙：把整张世界地图的程序化地势图一次性烘焙成静态 PNG，
## 供 terrain_painter 直接绘制（替代「边走边分块生成」的动态虚拟纹理）。
##
## 运行（项目根目录）：
##   godot --headless --script tools/bake_world_map.gd
##
## 烘焙分辨率 BAKE_W 取 4096（手机 GPU 纹理上限，约 5.2 倍拉伸，静态无加载感）。
## 算法与 terrain_painter._make_geo_image_for_rect 完全一致（同一套噪声/配色/城池蒙版），
## 因此烘焙出的静态图与原本近景分块渲染的观感一致，只是不再逐块流式生成。

const BAKE_W := 4096
const TERRAIN_JSON := "res://assets/data/terrain.json"
const CITIES_JSON := "res://assets/data/cities.json"
const OUT := "res://assets/sprites/terrain/world_static.png"

const MASK_SIZE := 512
const CITY_FLAT_WORLD_R := 950.0


func _initialize() -> void:
	var region := _load_region()
	var world := Vector2(
		float(region.get("width", 21256)),
		float(region.get("height", 21826)))
	var gy := int(round(float(BAKE_W) * world.y / maxf(world.x, 1.0)))
	var img := _bake(world, BAKE_W, gy, true)
	var out_path := ProjectSettings.globalize_path(OUT)
	var err := img.save_png(out_path)
	print("BAKE DONE err=%d size=%dx%d -> %s" % [err, BAKE_W, gy, out_path])
	quit()


func _load_region() -> Dictionary:
	var p := ProjectSettings.globalize_path(TERRAIN_JSON)
	var f := FileAccess.open(p, FileAccess.READ)
	var data: Variant = JSON.parse_string(f.get_as_text())
	for r in data:
		if str(r.get("id", "")) == "china":
			return r
	return {}


## 与 terrain_painter._get_city_mask 完全一致（用 cities.json 的 map_x/map_y 作世界坐标）
func _build_city_mask(world: Vector2) -> PackedFloat32Array:
	var mask_dim := Vector2i(
		clampi(int(world.x / 42.0), 128, MASK_SIZE),
		clampi(int(world.y / 42.0), 128, MASK_SIZE))
	var arr: PackedFloat32Array = []
	arr.resize(mask_dim.x * mask_dim.y)
	var p := ProjectSettings.globalize_path(CITIES_JSON)
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return arr
	var data: Variant = JSON.parse_string(f.get_as_text())
	var scale := Vector2(
		float(mask_dim.x) / maxf(world.x, 1.0),
		float(mask_dim.y) / maxf(world.y, 1.0))
	var r_px := CITY_FLAT_WORLD_R * scale.x
	for city in data:
		if not (city is Dictionary):
			continue
		var c := Vector2(
			float(city.get("map_x", 0.0)) * scale.x,
			float(city.get("map_y", 0.0)) * scale.y)
		var level := maxi(int(city.get("level", 1)), 1)
		var rr := r_px * (1.0 + 0.12 * level)
		var r2 := rr * rr
		var x0 := maxi(int(c.x - rr), 0)
		var x1 := mini(int(c.x + rr), mask_dim.x - 1)
		var y0 := maxi(int(c.y - rr), 0)
		var y1 := mini(int(c.y + rr), mask_dim.y - 1)
		for y in range(y0, y1 + 1):
			for x in range(x0, x1 + 1):
				var dx := float(x) - c.x
				var dy := float(y) - c.y
				var d2 := dx * dx + dy * dy
				if d2 >= r2:
					continue
				var v := 1.0 - sqrt(d2) / rr
				var idx := y * mask_dim.x + x
				if v > arr[idx]:
					arr[idx] = v
	return arr


func _sample_city_mask(mask: PackedFloat32Array, dim: Vector2i, world: Vector2, wx: float, wy: float) -> float:
	if mask.is_empty():
		return 0.0
	var x := clampi(int(wx / maxf(world.x, 1.0) * float(dim.x)), 0, dim.x - 1)
	var y := clampi(int(wy / maxf(world.y, 1.0) * float(dim.y)), 0, dim.y - 1)
	return mask[y * dim.x + x]


func _bake(world: Vector2, gx: int, gy: int, smooth: bool) -> Image:
	var gen_x := maxi(2, gx / 2) if smooth else gx
	var gen_y := maxi(2, gy / 2) if smooth else gy
	var img := Image.create(gen_x, gen_y, false, Image.FORMAT_RGBA8)

	var n_elev := FastNoiseLite.new()
	n_elev.seed = 2026
	n_elev.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n_elev.frequency = 1.0 / 3000.0

	var n_mid := FastNoiseLite.new()
	n_mid.seed = 7788
	n_mid.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n_mid.frequency = 1.0 / 1100.0

	var n_detail := FastNoiseLite.new()
	n_detail.seed = 3344
	n_detail.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n_detail.frequency = 1.0 / 380.0

	var n_humid := FastNoiseLite.new()
	n_humid.seed = 5566
	n_humid.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n_humid.frequency = 1.0 / 2200.0

	var mask: PackedFloat32Array = _build_city_mask(world)
	var dim := Vector2i(
		clampi(int(world.x / 42.0), 128, MASK_SIZE),
		clampi(int(world.y / 42.0), 128, MASK_SIZE))

	for y in range(gen_y):
		var wy: float = (float(y) + 0.5) / float(gen_y) * world.y
		var ny: float = wy / maxf(world.y, 1.0)
		for x in range(gen_x):
			var wx: float = (float(x) + 0.5) / float(gen_x) * world.x
			var nx: float = wx / maxf(world.x, 1.0)

			var west_factor: float = 1.0 - nx
			var elev_base: float = west_factor * west_factor * 0.8
			var elev: float = elev_base \
				+ n_elev.get_noise_2d(wx, wy) * 0.4 \
				+ n_mid.get_noise_2d(wx, wy) * 0.18
			elev = clampf(elev, 0.0, 1.0)
			var humid: float = clampf(
				ny * 0.7 + n_humid.get_noise_2d(wx, wy) * 0.45, 0.0, 1.0)

			var m: float = _sample_city_mask(mask, dim, world, wx, wy)
			if m > 0.0:
				elev = lerpf(elev, 0.28, m * 0.85)

			var col: Color
			if elev > 0.80:
				col = Color(0.50, 0.45, 0.39)
				if elev > 0.90:
					col = col.lerp(Color(0.90, 0.90, 0.93), (elev - 0.90) / 0.10)
			elif elev > 0.62:
				col = Color(0.36, 0.42, 0.26).lerp(Color(0.50, 0.45, 0.39),
					(elev - 0.62) / 0.18)
			elif humid < 0.35:
				col = Color(0.52, 0.50, 0.30) if nx < 0.30 else Color(0.46, 0.48, 0.26)
			elif humid < 0.60:
				col = Color(0.34, 0.46, 0.22)
			else:
				col = Color(0.24, 0.40, 0.18)

			if m > 0.0:
				col = col.lerp(Color(0.46, 0.52, 0.30), m * 0.55)

			var d: float = n_detail.get_noise_2d(wx, wy) * 0.10
			col = col.lightened(d)

			img.set_pixel(x, y, col)

	if smooth and (gen_x != gx or gen_y != gy):
		img.resize(gx, gy, Image.INTERPOLATE_LANCZOS)

	return img
