extends Node
## 云影正确性探针（由 _verify_cloud_cache.py 驱动）
## 运行：godot --headless --path<工程> res://tests/cloud_probe.tscn
##
## 【为什么要真跑】`_bake_cloud_texture()` 加了进程内缓存后，插桩显示耗时
## 从 228.9ms 降到 0.2ms。**这个降幅本身可疑** —— 可能是真的省了重复烘焙，
## 也可能是缓存返回了空值、云影彻底消失（功能回归）。
## 静态源码判据抓不到「运行时纹理到底有没有内容」，必须真跑一次把像素读出来。
##
## 输出落 res://cloud_probe_result.txt（Windows 控制台编码兜底）。

var _lines: Array[String] = []


func _say(t: String) -> void:
	print(t)
	_lines.append(t)


func _ready() -> void:
	var amb_script := load("res://scripts/world/world_ambience.gd")
	var amb = amb_script.new()
	# 不add_child：本探针只验「纹理烘焙结果」，不验节点树/演出行为。
	# （_build_clouds 依赖相机与视口，add_child 会引入无关变量。）
	var tex = amb._bake_cloud_texture()
	var tex2 = amb._bake_cloud_texture()

	# 【第七十二轮·判据补强】只验「纹理非空」不够：I2 注入（缓存返回 null）
	# 在纹理层被 cached_same 抓到，但玩家真正看到的是**云 sprite 有没有、
	# 上面挂的 texture 是不是 null**。这里真跑 _build_clouds 把 sprite 建出来，
	# 数一数并检查每只 sprite 的 texture —— 这才是玩家眼睛看到的东西。
	amb._camera = null      # 无相机 ⇒ 出生位置逻辑跳过（不影响本组断言）
	amb._build_clouds()
	var sprites: Array = amb._clouds
	var with_tex := 0
	for sp in sprites:
		if sp != null and sp.texture != null:
			with_tex += 1
	_say("built_sprite_count=%d" % sprites.size())
	_say("sprite_with_texture=%d" % with_tex)

	_say("tex_null=%d" % (1 if tex == null else 0))
	if tex == null:
		_say("DONE=1")
		_write()
		get_tree().quit()
		return

	# 【:=推断坑】tex 来自 load().new() 是 Variant，:= 无法推断 ⇒ 显式标注
	var img: Image = tex.get_image()
	_say("tex_null=0")
	_say("tex_width=%d" % img.get_width())
	_say("tex_height=%d" % img.get_height())

	# 缓存是否真被复用：两次调用应拿到同一实例
	_say("cached_same=%d" % (1 if tex == tex2 else 0))

	# alpha 通道统计：须有梯度（全 0 = 云没了；全 255 = 纯色方块）
	var lo := 255
	var hi := 0
	var mid := 0
	var mid_hits := 0
	var w: int = img.get_width()
	var h: int = img.get_height()
	var step := maxi(1, int(sqrt(float(w * h) / 4000.0)))   # 采样 ~4000 点，够判分布
	for y in range(0, h, step):
		for x in range(0, w, step):
			var a := int(img.get_pixel(x, y).a * 255.0)
			lo = mini(lo, a)
			hi = maxi(hi, a)
			if a > 40 and a < 215:
				mid_hits += 1
	if mid_hits > 0:
		mid = 128# 有中间态即证明是柔和梯度（非二值）
	_say("alpha_min=%d" % lo)
	_say("alpha_max=%d" % hi)
	_say("alpha_mid=%d" % mid)
	_say("mid_hits=%d" % mid_hits)
	_say("sample_step=%d" % step)

	# 云 sprite 数量口径：直接读源码里的常量（CLOUD_BLOBS）。
	# 【为什么不用 amb.get("CLOUD_BLOBS")】get() 取的是**属性**，
	 # 对 const 无效 ⇒ 会返回 null → int(null)=0 → 判据误报「云没了」。
	# 这个坑与「has_meta 守卫」同源：取不存在的东西必须验来源。
	var src := FileAccess.get_file_as_string("res://scripts/world/world_ambience.gd")
	var blobs := 0
	for ln in src.split("\n"):
		if ln.begins_with("const CLOUD_BLOBS"):
			# 形如：const CLOUD_BLOBS := 3
			blobs = int(ln.split(":=")[1].strip_edges().split(" ")[0])
			break
	_say("cloud_sprite_count=%d" % blobs)

	amb.free()
	_say("DONE=1")
	_write()
	get_tree().quit()


func _write() -> void:
	var f := FileAccess.open("res://cloud_probe_result.txt", FileAccess.WRITE)
	if f != null:
		for ln in _lines:
			f.store_line(ln)
		f.close()