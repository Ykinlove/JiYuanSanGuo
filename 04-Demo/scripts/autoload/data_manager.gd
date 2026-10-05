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
	"talents6": "talents6.json",                  ## 17 特技
	"titles6": "titles6.json",                    ## 31 称号

	## ---- 本批次新增表 ----
	"achievements": "achievements.json",          ## 成就系统
	"npc_stock": "npc_stock.json",                ## NPC 背包/交易货单
	"item_economy": "item_economy.json",          ## 【第七十五轮】锻造/集市/商城/看广告 配置
	"faction_territory": "faction_territory.json", ## 势力历史版图（AI 攻城范围，反雪球）
	"city_ownership": "city_ownership.json",       ## 治下城池：治理指令 / 叛乱 / 原属势力收复
}


func _ready() -> void:
	load_all()


## 加载全部数据表
func load_all() -> void:
	# 【第五十三轮】表内容会变（重载/热更/调试改表），必须一并失效过滤缓存，
	# 否则 get_heroes6() 会一直返回旧表派生的人物列表。
	# 赋空数组而非 null（带类型标注的 Array 不接受 null）。
	_heroes6_cache = []
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


## 按 id 获取阵型
func get_formation(id: String) -> Dictionary:
	return get_record("formations", id)


## 按字段筛选（简单条件查询）
## ⚠ 坑：记录**没有**该字段时 record.get(field) 返回 null，而 null == false 为假，
##    用 value=false 去筛一个不存在的字段会一条都选不中（get_heroes6 就栽过）。
##    筛「假值」前先确认字段真的存在。
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
## 全部人物（825 人，不含兵种模板）
## 注意：heroes6.json 里根本没有 is_troop_template 字段。
## 原来的 filter("heroes6", "is_troop_template", false) 对缺失字段取到 null，
## 而 null == false 在 GDScript 里恒为假 —— 一条都选不中，人物志长期空白。
	## 改为：字段存在才按字段筛（true 视为模板跳过），不存在一律算人物。
	## 同时剔除 is_dummy 占位行与 name 字面为「无」的哑元武将（id 2/3/4…），
	## 否则它们会以「无」为名混进人物志，表现为异常条目。
func get_heroes6() -> Array:
	# 【第五十三轮·缓存】本函数每次调用都遍历 heroes6 全表（825 条）做过滤并
	# 新建数组。而调用方之一 hero_dex 的搜索框 `text_changed` 直连列表重建 ——
	# 玩家每敲一个字就整表重扫一次并重建最多 300 个按钮节点。
	# 表内容进游戏后不再变动，故缓存一份；load_all() 会一并失效。
	# 注意：带类型标注的 Array **不能赋 null**（GDScript 直接 Parse Error），
	# 故用「未初始化时长度为 0」这个天然状态表示「无缓存」。
	if not _heroes6_cache.is_empty():
		return _heroes6_cache
	var out: Array = []
	for r in get_table("heroes6"):
		if not (r is Dictionary):
			continue
		if r.has("is_troop_template") and bool(r.get("is_troop_template", false)):
			continue
		if bool(r.get("is_dummy", false)):
			continue
		var nm := str(r.get("name", "")).strip_edges()
		if nm.is_empty() or nm == "无":
			continue
		out.append(r)
	_heroes6_cache = out
	return out


## heroes6 过滤结果缓存（get_heroes6 的产物）。
## 返回的是同一个数组实例 —— 调用方若要修改必须自行 duplicate()，
# 当前全部调用方都只读（遍历/取字段），安全。
var _heroes6_cache: Array = []


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


## 按 hero_id 解析到 v6 heroes6 记录（优先），找不到则回退 legacy characters 记录。
## 用于让战斗/布阵等"规则层"从 legacy 字符串 id 无缝切到 v6 四维字段。
## - "" → {}
## - "player_male"/"player_female"/"player" → get_hero6(1)  # 主角约定
## - 纯数字字符串 → get_hero6(int)
## - legacy 字符串 id → 按 name 匹配 heroes6；匹配不到则回退 legacy 记录
func get_hero_resolved(hero_id: String) -> Dictionary:
	if hero_id.is_empty():
		return {}
	if hero_id == "player_male" or hero_id == "player_female" or hero_id == "player":
		return get_hero6(1)
	if hero_id.is_valid_int():
		var r := get_hero6(int(hero_id))
		if not r.is_empty():
			return r
	var legacy := get_character(hero_id)
	var nm := str(legacy.get("name", ""))
	if not nm.is_empty():
		var v6 := _find_hero6_by_name(nm)
		if not v6.is_empty():
			return v6
	return legacy   # 兜底


## heroes6 表 name → 记录的懒缓存索引（避免每次战斗扫 825 行）
var _hero6_name_index: Dictionary = {}


func _find_hero6_by_name(nm: String) -> Dictionary:
	if _hero6_name_index.is_empty():
		for h in get_table("heroes6"):
			if h is Dictionary:
				_hero6_name_index[str(h.get("name", ""))] = h
	return _hero6_name_index.get(nm, {})
