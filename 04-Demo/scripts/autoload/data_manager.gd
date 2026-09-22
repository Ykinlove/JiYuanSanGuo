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
	"interaction_menu": "interaction_menu.json",

	## ---- 三国大时代6 官方数据表（V0.3 攻略代码，权威数据源）----
	## 落地为独立表名，避免与上述自研表冲突；迁移完成后 characters 将被 heroes6 取代。
	"heroes6": "heroes6.json",                    ## 825 人（含武将/功能NPC/兵种模板/野兽）
	"factions6": "factions6.json",                ## 46 势力
	"scenes6": "scenes6.json",                    ## 111 地点（城池50/据点60/世界地图1）
	"items6": "items6.json",                      ## 255 物品
	"quests6": "quests6.json",                    ## 45 任务（采购委托类）
	"talents6": "talents6.json",                  ## 17 特技
	"titles6": "titles6.json",                    ## 31 称号
	"npc_affairs": "npc_affairs.json",            ## 21 交互分类事件
	"spt_scripts": "spt_scripts.json",            ## 54 脚本总表
	"script_commands": "script_commands.json",    ## 42 脚本指令
	"script_examples": "script_examples.json",    ## 52 行源表示例脚本

	## ---- 本批次新增表 ----
	"achievements": "achievements.json",          ## 成就系统
	"npc_stock": "npc_stock.json",                ## NPC 背包/交易货单
}


func _ready() -> void:
	load_all()


## 加载全部数据表
func load_all() -> void:
	for table_name in TABLE_FILES.keys():
		_load_table(table_name, TABLE_FILES[table_name])
	print("[DataManager] 已加载数据表：", _tables.keys())


func _load_table(table_name: String, file_name: String) -> void:
	var path: String = DATA_DIR + file_name
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
			# ⚠ 坑：Godot 的 JSON 会把所有数字解析成 float（1 → 1.0），
			# 直接 str(1.0) 得到 "1.0"，而外部用 get_record(t, str(1)) 查的是 "1"，
			# 两者对不上 → 所有「数字 id」的表按 id 查询永远返回空。
			# 这里统一归一化：整数值的 float 还原成 int，并回写到记录本身。
			var rid = record["id"]
			if rid is float and is_equal_approx(rid, roundf(rid)):
				rid = int(rid)
				record["id"] = rid
			index[str(rid)] = record
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


## ---------- 三国大时代6 官方数据表接口 ----------
## 四维字段为 strong(强壮) / force(武力) / intel(智力) / charm(魅力)，
## 与自研表的 leadership/might/intellect/politics 不同，注意区分。

## 按官方数字 id 取人物（825 人表）
func get_hero6(role_id: int) -> Dictionary:
	return get_record("heroes6", str(role_id))


## 全部人物（可交互角色，已剔除兵种模板与非交互占位）
func get_heroes6() -> Array:
	return filter("heroes6", "is_troop_template", false)


## 某势力麾下人物
func get_heroes6_by_faction(faction_id: int) -> Array:
	var out: Array = []
	for c in get_table("heroes6"):
		if c is Dictionary and int(c.get("faction_id", -999)) == faction_id:
			out.append(c)
	return out


## 按官方数字 id 取场景（地点）
func get_scene6(scene_id: int) -> Dictionary:
	return get_record("scenes6", str(scene_id))


## 按分类取地点：1=城池 2=野外据点
func get_scenes6_by_category(category: int) -> Array:
	var out: Array = []
	for s in get_table("scenes6"):
		if s is Dictionary and int(s.get("category", -1)) == category:
			out.append(s)
	return out


## 按名字取地点（用于按地名反查元数据）
func get_scene6_by_name(name: String) -> Dictionary:
	for s in get_table("scenes6"):
		if s is Dictionary and str(s.get("name", "")) == name:
			return s
	return {}


## 势力（官方 46 个）
func get_faction6(faction_id: int) -> Dictionary:
	return get_record("factions6", str(faction_id))


## 官方物品 / 特技 / 称号
func get_item6(item_id: int) -> Dictionary:
	return get_record("items6", str(item_id))


func get_talent6(talent_id: int) -> Dictionary:
	return get_record("talents6", str(talent_id))


func get_title6(title_id: int) -> Dictionary:
	return get_record("titles6", str(title_id))
