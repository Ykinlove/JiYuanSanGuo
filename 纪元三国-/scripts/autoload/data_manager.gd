extends Node
## 静态数据管理器（DataManager）
## 职责：从 res://assets/data/*.json 加载静态配置表，并提供查询接口。
## 所有游戏内容（武将、兵种、城池、道具、事件）均由数据表驱动，不写死在代码里。

const DATA_DIR := "res://assets/data/"

## 数据表缓存：表名 -> 数据
var _tables: Dictionary = {}
## 索引缓存：表名 -> { id: 记录 }
var _indexes: Dictionary = {}

## 需要加载的数据表清单
const TABLE_FILES := {
	"characters": "characters.json",
	"units": "units.json",
	"cities": "cities.json",
	"items": "items.json",
	"quests": "quests.json",
	"factions": "factions.json",
	"formations": "formations.json",
	"terrain": "terrain.json",
	"encounters": "encounters.json",
	"npcs": "npcs.json",
	"dialogues": "dialogues.json",
	"formation_slots": "formation_slots.json",
	"combat": "combat.json",
	"barracks": "barracks.json",
	"recruit_pool": "recruit_pool.json",
	"shop_goods": "shop_goods.json",
	"drill": "drill.json",
}


func _ready() -> void:
	load_all()


## 加载全部数据表
func load_all() -> void:
	for table_name in TABLE_FILES.keys():
		_load_table(table_name, TABLE_FILES[table_name])
	print("[DataManager] 已加载数据表：", _tables.keys())


func _load_table(table_name: String, file_name: String) -> void:
	var path := DATA_DIR + file_name
	if not FileAccess.file_exists(path):
		push_warning("[DataManager] 数据表不存在，跳过：%s" % path)
		_tables[table_name] = []
		_indexes[table_name] = {}
		return

	var file := FileAccess.open(path, FileAccess.READ)
	var text := file.get_as_text()
	file.close()

	var json := JSON.new()
	var err := json.parse(text)
	if err != OK:
		push_error("[DataManager] JSON 解析失败：%s 行 %d：%s" % [path, json.get_error_line(), json.get_error_message()])
		_tables[table_name] = []
		_indexes[table_name] = {}
		return

	var data = json.data
	var records: Array = []
	if data is Array:
		records = data
	elif data is Dictionary and data.has("list"):
		records = data["list"]
	elif data is Dictionary:
		# 对象型配置表（如 formation_slots.json）：整表包成单条记录，id 固定为 root
		records = [data.duplicate(true)]
		records[0]["id"] = "root"

	_tables[table_name] = records

	# 建立 id 索引
	var index := {}
	for record in records:
		if record is Dictionary and record.has("id"):
			index[str(record["id"])] = record
	_indexes[table_name] = index


## 获取整张表
func get_table(table_name: String) -> Array:
	return _tables.get(table_name, [])


## 按 id 获取单条记录
func get_record(table_name: String, id: String) -> Dictionary:
	var index: Dictionary = _indexes.get(table_name, {})
	return index.get(id, {})


## 按 id 获取武将
func get_character(id: String) -> Dictionary:
	return get_record("characters", id)


## 按 id 获取兵种
func get_unit(id: String) -> Dictionary:
	return get_record("units", id)


## 按 id 获取城池
func get_city(id: String) -> Dictionary:
	return get_record("cities", id)


## 按 id 获取道具
func get_item(id: String) -> Dictionary:
	return get_record("items", id)


## 按 id 获取势力
func get_faction(id: String) -> Dictionary:
	return get_record("factions", id)


## 按 id 获取阵型
func get_formation(id: String) -> Dictionary:
	return get_record("formations", id)


## 按字段筛选（简单条件查询）
func filter(table_name: String, field: String, value) -> Array:
	var result: Array = []
	for record in get_table(table_name):
		if record is Dictionary and record.get(field) == value:
			result.append(record)
	return result


## ---------- M5 便捷接口 ----------

## 读取兵营配置的 settings 段
func get_barracks_settings() -> Dictionary:
	return get_record("barracks", "root").get("settings", {})


## 读取某兵种的征兵配置
func get_barracks_unit(unit_id: String) -> Dictionary:
	for u in get_record("barracks", "root").get("units", []):
		if str(u.get("unit_id", "")) == unit_id:
			return u
	return {}


## 读取酒馆招募配置
func get_recruit_settings() -> Dictionary:
	return get_record("recruit_pool", "root").get("settings", {})


## 某城池可招募的武将条目
func get_recruit_entries(city_id: String) -> Array:
	var out: Array = []
	for e in get_record("recruit_pool", "root").get("pool", []):
		if str(e.get("city_id", "")) == city_id:
			out.append(e)
	return out


## 读取市集配置
func get_shop_settings() -> Dictionary:
	return get_record("shop_goods", "root").get("settings", {})


func get_market_goods() -> Array:
	return get_record("shop_goods", "root").get("market_goods", [])


func get_smith_goods() -> Array:
	return get_record("shop_goods", "root").get("smith_goods", [])


## 读取演练预设
func get_drill_settings() -> Dictionary:
	return get_record("drill", "root").get("settings", {})


func get_drills() -> Array:
	return get_record("drill", "root").get("drills", [])


func get_drill(id: String) -> Dictionary:
	for d in get_drills():
		if str(d.get("id", "")) == id:
			return d
	return {}
