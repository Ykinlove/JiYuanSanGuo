extends Node
## 存档管理器（SaveManager）
## 职责：多存档槽的存/读档，自动存档，存档列表查询。
## 存档路径：user://saves/slot_{n}.json

const SAVE_DIR := "user://saves/"
const SLOT_COUNT := 3          # 手动存档槽数量
const AUTO_SLOT := 0           # 0 号槽为自动存档

const SAVE_META_FILE := "user://saves/_meta.json"


func _ready() -> void:
	_ensure_dir()


func _ensure_dir() -> void:
	if not DirAccess.dir_exists_absolute(SAVE_DIR):
		DirAccess.make_dir_recursive_absolute(SAVE_DIR)


## 保存到指定槽位
func save_game(slot: int, manual: bool = true) -> bool:
	_ensure_dir()
	var path := _slot_path(slot)
	var payload := {
		"saved_at": Time.get_datetime_string_from_system(false, true),
		"saved_at_unix": Time.get_unix_time_from_system(),
		"manual": manual,
		"game": GameState.to_dict(),
	}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("[SaveManager] 无法写入存档：%s" % path)
		return false
	file.store_string(JSON.stringify(payload, "\t"))
	file.close()

	_update_meta(slot, payload)
	EventBus.game_saved.emit(slot)
	EventBus.show_toast("已保存到存档 %d" % slot)
	return true


## 从指定槽位读取
func load_game(slot: int) -> bool:
	var path := _slot_path(slot)
	if not FileAccess.file_exists(path):
		EventBus.show_toast("存档 %d 不存在" % slot)
		return false

	var file := FileAccess.open(path, FileAccess.READ)
	var text := file.get_as_text()
	file.close()

	var json := JSON.new()
	if json.parse(text) != OK:
		push_error("[SaveManager] 存档解析失败：%s" % path)
		EventBus.show_toast("存档已损坏")
		return false

	var payload = json.data
	if not (payload is Dictionary) or not payload.has("game"):
		push_error("[SaveManager] 存档格式错误：%s" % path)
		return false

	GameState.from_dict(payload["game"])
	EventBus.game_loaded.emit(slot)
	EventBus.show_toast("已读取存档 %d" % slot)
	return true


## 自动存档
func auto_save() -> bool:
	return save_game(AUTO_SLOT, false)


## 删除存档
func delete_save(slot: int) -> void:
	var path := _slot_path(slot)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	_update_meta(slot, null)


## 获取所有槽位的摘要信息（用于存档界面）
func get_save_slots() -> Array:
	var result: Array = []
	for slot in range(0, SLOT_COUNT + 1):
		var path := _slot_path(slot)
		var info := {
			"slot": slot,
			"is_auto": slot == AUTO_SLOT,
			"exists": false,
			"date_text": "",
			"saved_at": "",
			"player_name": "",
			"level": 1,
		}
		if FileAccess.file_exists(path):
			var file := FileAccess.open(path, FileAccess.READ)
			var text := file.get_as_text()
			file.close()
			var json := JSON.new()
			if json.parse(text) == OK and json.data is Dictionary:
				var payload: Dictionary = json.data
				var game: Dictionary = payload.get("game", {})
				info["exists"] = true
				info["saved_at"] = str(payload.get("saved_at", ""))
				info["player_name"] = str(game.get("player_name", ""))
				info["level"] = int(game.get("player_level", 1))
				info["date_text"] = "公元%d年 %d月" % [int(game.get("year", 184)), int(game.get("month", 1))]
		result.append(info)
	return result


func has_any_save() -> bool:
	for slot in range(0, SLOT_COUNT + 1):
		if FileAccess.file_exists(_slot_path(slot)):
			return true
	return false


func _slot_path(slot: int) -> String:
	if slot == AUTO_SLOT:
		return SAVE_DIR + "auto.json"
	return SAVE_DIR + "slot_%d.json" % slot


func _update_meta(slot: int, payload) -> void:
	var meta := {}
	if FileAccess.file_exists(SAVE_META_FILE):
		var f := FileAccess.open(SAVE_META_FILE, FileAccess.READ)
		var json := JSON.new()
		if json.parse(f.get_as_text()) == OK and json.data is Dictionary:
			meta = json.data
		f.close()
	meta[str(slot)] = payload.get("saved_at", "") if payload != null else null
	var out := FileAccess.open(SAVE_META_FILE, FileAccess.WRITE)
	if out == null:   # 【R1-05】磁盘异常/目录不可写时判空，与 save_game 同口径，避免崩溃
		push_error("[SaveManager] 存档元数据写入失败：%s" % SAVE_META_FILE)
		return
	out.store_string(JSON.stringify(meta, "\t"))
	out.close()
