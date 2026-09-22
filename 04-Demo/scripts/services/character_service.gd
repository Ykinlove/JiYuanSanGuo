extends RefCounted
class_name CharacterService
## 角色规则层：四维 → 派生属性的统一换算。
## UI 只允许调用这里取数，不允许在显示层写公式。
##
## 【双 Schema 支持】
##   v6     = 三国大时代6 官方表 heroes6：strong(强壮) force(武力) intel(智力) charm(魅力)
##   legacy = 本项目自研表 characters：leadership/might/intellect/politics
## 调用方统一用 four_stats() 取「标签+键名+数值」，无需关心底层是哪种。

## 四维读取器的键名常量（避免各处硬编码字符串）
const V6_KEYS: Array[String] = ["strong", "force", "intel", "charm"]
const LEGACY_KEYS: Array[String] = ["leadership", "might", "intellect", "politics"]


## 判断一条记录用的是哪种 schema
static func schema_of(rec: Dictionary) -> String:
	if rec.has("strong") or rec.has("force") or rec.has("charm"):
		return "v6"
	if rec.has("leadership") or rec.has("might"):
		return "legacy"
	return "unknown"


## 统一四维读取。返回 { labels/keys/values/schema }
## UI 用 labels 显示标题、values 显示数字，完全数据驱动。
static func four_stats(rec: Dictionary) -> Dictionary:
	var keys: Array[String]
	var labels: Array[String]
	if schema_of(rec) == "v6":
		keys = V6_KEYS
		labels = ["强壮", "武力", "智力", "魅力"]
	else:
		keys = LEGACY_KEYS
		labels = ["统率", "武力", "智力", "政治"]

	var values: Array[int] = []
	for k in keys:
		values.append(int(float(rec.get(k, 0))))
	return {"labels": labels, "keys": keys, "values": values, "schema": schema_of(rec)}


## 展示用派生属性（战斗细则仍以 BattleService / formation_calculator 为准）
## v6 语义：强壮=体质(HP/防御)、武力=攻击、智力=命中/策略、魅力=统兵
static func derived(rec: Dictionary) -> Dictionary:
	if schema_of(rec) == "v6":
		var strong := float(rec.get("strong", 50))
		var force := float(rec.get("force", 50))
		var intel := float(rec.get("intel", 50))
		var charm := float(rec.get("charm", 50))
		return {
			"attack": int(force * 2.2 + strong * 0.5),
			"defense": int(strong * 1.8 + force * 0.5),
			"crit": int(4.0 + force * 0.06),
			"hit": int(28.0 + intel * 0.12),
			"hp": int(400.0 + strong * 10.0 + force * 4.0),
			"troop_cap": int(charm * 20.0),
		}

	# legacy
	var lead := float(rec.get("leadership", 50))
	var might := float(rec.get("might", 50))
	var intel2 := float(rec.get("intellect", 50))
	return {
		"attack": int(might * 2.2 + lead * 0.8),
		"defense": int(lead * 1.6 + might * 0.6),
		"crit": int(4.0 + might * 0.06),
		"hit": int(28.0 + intel2 * 0.12),
		"hp": int(400.0 + might * 8.0 + lead * 4.0),
		"troop_cap": int(lead * 20.0),
	}


## 评级文字（S/A/B/C），给四维数值一个直观档位
static func grade(value: float) -> String:
	if value >= 90:
		return "S"
	if value >= 78:
		return "A"
	if value >= 64:
		return "B"
	if value >= 50:
		return "C"
	return "D"


## 特技文字：v6 用 talents(编号数组) 查 talents6 表；legacy 用 traits
static func traits_text(rec: Dictionary) -> String:
	var t: Variant = rec.get("talents")
	if t is Array and not (t as Array).is_empty():
		var parts: Array[String] = []
		for tid in t as Array:
			var info: Dictionary = DataManager.get_talent6(int(tid))
			var nm := str(info.get("name", ""))
			if not nm.is_empty() and nm != "无":
				parts.append(nm)
			elif int(tid) > 0:
				parts.append("特技%d" % int(tid))
		if not parts.is_empty():
			return "、".join(parts)
		return "无"

	var t2: Variant = rec.get("traits")
	if t2 is Array and not (t2 as Array).is_empty():
		var parts2: Array[String] = []
		for item in t2 as Array:
			parts2.append(str(item))
		return "、".join(parts2)
	return str(rec.get("trait", "无"))


## 称号文字（v6）
static func title_text(rec: Dictionary) -> String:
	var tid := int(rec.get("title_id", 0))
	if tid <= 0:
		return ""
	var t: Dictionary = DataManager.get_title6(tid)
	return str(t.get("name", ""))


## 势力名（v6 用 faction_id 查 factions6）
static func faction_text(rec: Dictionary) -> String:
	if rec.has("faction_id"):
		var f: Dictionary = DataManager.get_faction6(int(rec.get("faction_id", 0)))
		var nm := str(f.get("name", ""))
		if not nm.is_empty() and nm != "无":
			return nm
		return "在野"
	return str(rec.get("faction_name", "在野"))


## ---------- 官方 825 人表专属接口 ----------

## 是否可作为 NPC 出场（剔除占位行）
static func is_playable_v6(rec: Dictionary) -> bool:
	if rec.is_empty():
		return false
	if bool(rec.get("is_dummy", false)):
		return false
	return str(rec.get("name", "")).strip_edges() != ""


## 按交互分类取一类 NPC 模板（用于城内各建筑站岗）
## interaction_class: 10村长 11商铺老板 12铁匠 13酒店老板 14药店老板
##                   15旅馆老板 16驯马师 17军官 18书商
static func npc_template_of_class(interaction_class: int) -> Dictionary:
	for c in DataManager.get_table("heroes6"):
		if c is Dictionary and int(c.get("interaction_class", -1)) == interaction_class \
				and is_playable_v6(c):
			return c
	return {}


## 城内建筑 key → 该建筑应有的 NPC 交互分类
const BUILDING_NPC_CLASS := {
	"hall": 10,       # 衙门 → 村长
	"market": 11,     # 商铺 → 商铺老板
	"smith": 12,      # 铁匠铺 → 铁匠
	"tavern": 13,     # 酒馆 → 酒店老板
	"clinic": 14,     # 医馆 → 药店老板
	"inn": 15,        # 旅馆 → 旅馆老板
	"stable": 16,     # 马房 → 驯马师
	"barracks": 17,   # 兵营 → 军官
	"library": 18,    # 书肆 → 书商
}


## ---------- 旧表（legacy）接口，迁移完成后可删 ----------

static func find_character(hero_id: String) -> Dictionary:
	if hero_id.is_empty():
		return {}
	return DataManager.get_record("characters", hero_id)


static func find_recruit_entry(hero_id: String) -> Dictionary:
	if hero_id.is_empty():
		return {}
	var root := DataManager.get_record("recruit_pool", "root")
	for e in root.get("pool", []):
		if e is Dictionary and str(e.get("hero_id", "")) == hero_id:
			return e
	return {}


static func recruit_requirements(entry: Dictionary) -> Dictionary:
	var s := DataManager.get_record("recruit_pool", "root")
	var settings: Dictionary = s.get("settings", {}) if not s.is_empty() else {}
	var diff := float(entry.get("difficulty", 1))
	var gold := float(settings.get("base_gold", 300)) \
		+ diff * float(settings.get("gold_per_difficulty", 450)) \
		+ float(entry.get("gold_extra", 0))
	var fame := float(entry.get("require_fame",
		float(settings.get("base_fame", 0)) + diff * float(settings.get("fame_per_difficulty", 8))))
	return { "gold": int(gold), "fame": int(fame) }
