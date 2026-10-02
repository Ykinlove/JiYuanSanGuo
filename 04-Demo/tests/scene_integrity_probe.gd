extends Node
## 场景完整性校验（场景式 harness）
## 运行：godot --headless --path <工程> res://tests/scene_integrity_probe.tscn
##
## 目的：_compile_check.py 只校验 81 个 .gd 脚本能否编译，并不验证 .tscn 场景本身
## 能否加载。Godot 里「脚本被改名/移动后，.tscn 仍指向旧 ExtResource 路径」是最常见、
## 且编译期完全抓不到的破坏类——场景会在运行时报缺失、甚至 instantiate 直接崩。
## 本探针递归遍历 res:// 下所有 .tscn，逐一 load() 并 can_instantiate() 确认可实例化，
## 锁住「全工程场景引用闭合」不变量。仅做 load()（解析 + 外部资源解析），不 instantiate、
## 不进 _ready，零状态依赖、零副作用。
##
## 判定：load() 非 null 且为 PackedScene 且 can_instantiate() 为真 → 通过；否则 FAIL
## （覆盖了「返回 null / 非 PackedScene / 引用缺失导致不可实例化」三类破坏）。

var _lines: Array[String] = []


func _say(text: String) -> void:
	print(text)
	_lines.append(text)


func _walk(dir_path: String, out: Array[String]) -> void:
	var d := DirAccess.open(dir_path)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		if name != "." and name != "..":
			if d.current_is_dir():
				_walk(dir_path.path_join(name), out)
			elif name.ends_with(".tscn") and not name.ends_with(".tscn.import"):
				out.append(dir_path.path_join(name))
		name = d.get_next()
	d.list_dir_end()


func _ready() -> void:
	_say("================ 场景完整性校验 ================")
	var scenes: Array[String] = []
	_walk("res://", scenes)
	_say("  扫描到 %d 个 .tscn" % scenes.size())

	var fails := 0
	for p in scenes:
		var res = load(p)
		var ok := false
		if res != null and res is PackedScene:
			ok = (res as PackedScene).can_instantiate()
		if not ok:
			_say("  [FAIL] %s" % p)
			fails += 1
	_say("  可实例化 %d / %d" % [scenes.size() - fails, scenes.size()])

	_say("")
	_say("SCENE_INTEGRITY=%s (total=%d, fail=%d)" % ["PASS" if fails == 0 else "FAIL", scenes.size(), fails])
	var f := FileAccess.open("res://scene_integrity_result.txt", FileAccess.WRITE)
	if f != null:
		for ln in _lines:
			f.store_line(ln)
		f.close()
	get_tree().quit()
