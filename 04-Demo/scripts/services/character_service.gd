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

# ---------- 结义 ----------
const SWORN_INTIMACY_REQUIRED := 80   ## 结义所需好感
const SWORN_MAX := 3                  ## 结义兄弟名额上限
const SWORN_COMBAT_BONUS := 0.10      ## 结义武将统兵攻防加成（各 +10%）


## 当前已结义人数（party 中 sworn=true）
static func sworn_count(party: Array) -> int:
	var n := 0
	for h in party:
		if bool(h.get("sworn", false)):
			n += 1
	return n


## 该武将是否满足结义好感门槛
static func can_sworn_by_intimacy(intimacy: int) -> bool:
	return intimacy >= SWORN_INTIMACY_REQUIRED


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


## ---------- 装备系统（items6，绝对值加成） ----------
##
## effects 四位语义（由 121 件装备数据 + 旧 items.json 交叉验证得出）：
##   武器 major5：[0]=攻击（[1] 重击向不接）
##   头盔 major2：武盔 [0]/[1] 攻击取向；官帽 [2] 防御
##   护甲 major4：[2]=防御，[3]=HP
##   宝物 major6：[0]/[1] 攻击向，[2] 防御向（[3] 魅力向不接）
##   坐骑 major7：[1]=速度（[0]/[2]/[3] 为个人属性不接）
## weapon2 为备用副武器（726 人统一钢剑），不参与战斗聚合。

const EQUIP_SLOTS: Array[String] = ["weapon1", "weapon2", "helmet", "armor", "treasure", "mount"]
const SLOT_CAT_MAJOR := {"weapon1": 5, "weapon2": 5, "helmet": 2, "armor": 4, "treasure": 6, "mount": 7}
const SLOT_LABELS := {
	"weapon1": "主武器", "weapon2": "副武器", "helmet": "头盔",
	"armor": "护甲", "treasure": "宝物", "mount": "坐骑",
}

## 旧自研 items.json id → items6 数字 id（旧商店/旧档兼容，穿戴时自动转换）
const LEGACY_ITEM_MAP := {
	"sword_iron": 134,       # 铁剑
	"sword_qinggang": 137,   # 青釭剑
	"crossbow_zhuge": 182,   # 诸葛弩
	"armor_leather": 79,     # 薄皮甲
	"armor_iron": 85,        # 铁片鳞甲
	"horse_dilu": 197,       # 的卢
	"horse_chitu": 196,      # 赤兔
}


## 背包 key / 装备槽值 → items6 记录。
## 数字 id（int 或纯数字字符串）走 items6；旧字符串 id 先查兼容映射。
## 注意：JSON 解析的 heroes6.equipment 值可能是 float（170.0），需兼容。
static func resolve_item6(item_key: Variant) -> Dictionary:
	# 直接处理 int / float（最常见路径）
	var t := typeof(item_key)
	if t == TYPE_INT:
		var iid := int(item_key)
		return DataManager.get_item6(iid) if iid > 0 else {}
	if t == TYPE_FLOAT:
		var fid := int(item_key)
		return DataManager.get_item6(fid) if fid > 0 else {}
	# 字符串路径
	var s := str(item_key)
	if s.is_empty() or s == "0":
		return {}
	if s.is_valid_int():
		return DataManager.get_item6(int(s))
	# "170.0" 等 float 字符串
	if s.is_valid_float():
		var fid2 := int(float(s))
		return DataManager.get_item6(fid2) if fid2 > 0 else {}
	var mapped: int = int(LEGACY_ITEM_MAP.get(s, 0))
	if mapped > 0:
		return DataManager.get_item6(mapped)
	return {}


## 旧物品 id 可转换到的 items6 id（0=无映射）
static func legacy_item_mapped(item_key: String) -> int:
	return int(LEGACY_ITEM_MAP.get(item_key, 0))


## 单件 items6 物品 → 战斗四属性绝对值 {attack, defense, hp, speed}
## enhance_lv 为铁匠铺强化等级（每级 ×(1+stat_per_level)，0=白板）
static func item_combat_bonus(item: Dictionary, enhance_lv: int = 0) -> Dictionary:
	var zero := {"attack": 0, "defense": 0, "hp": 0, "speed": 0}
	if item.is_empty():
		return zero
	var e: Array = item.get("effects", [0, 0, 0, 0])
	var atk := 0
	var dfn := 0
	var hp := 0
	var spd := 0
	match int(item.get("cat_major", 0)):
		5:  # 武器：effects[0]=攻击
			atk = _eff(e, 0)
		2:  # 头盔：武盔 [0]/[1] 攻击取向，官帽 [2] 防御
			atk = _eff(e, 0) + _eff(e, 1)
			dfn = _eff(e, 2)
		4:  # 护甲：[2]=防御，[3]=HP
			dfn = _eff(e, 2)
			hp = _eff(e, 3)
		6:  # 宝物：[0]/[1] 攻击向，[2] 防御向
			atk = _eff(e, 0) + _eff(e, 1)
			dfn = _eff(e, 2)
		7:  # 坐骑：[1]=速度
			spd = _eff(e, 1)
	if enhance_lv > 0 and (atk != 0 or dfn != 0 or hp != 0 or spd != 0):
		var mult := 1.0 + float(enhance_lv) * EnhanceService.stat_per_level()
		atk = int(round(float(atk) * mult))
		dfn = int(round(float(dfn) * mult))
		hp = int(round(float(hp) * mult))
		spd = int(round(float(spd) * mult))
	return {"attack": atk, "defense": dfn, "hp": hp, "speed": spd}


static func _eff(e: Array, i: int) -> int:
	return int(e[i]) if i < e.size() else 0


## 6 槽装备 {slot: item_id} → 聚合四属性绝对值（weapon2 不计）
## with_levels=true 时按 GameState.equip_levels 计入主角装备的强化等级
static func equipment_bonuses(equipment: Dictionary, with_levels: bool = false) -> Dictionary:
	var sum := {"attack": 0, "defense": 0, "hp": 0, "speed": 0}
	for slot in EQUIP_SLOTS:
		if slot == "weapon2":
			continue
		var iid := int(equipment.get(slot, 0))
		var item := resolve_item6(equipment.get(slot, 0))
		var lv := EnhanceService.level_of(iid) if with_levels else 0
		var b := item_combat_bonus(item, lv)
		sum["attack"] = int(sum["attack"]) + int(b["attack"])
		sum["defense"] = int(sum["defense"]) + int(b["defense"])
		sum["hp"] = int(sum["hp"]) + int(b["hp"])
		sum["speed"] = int(sum["speed"]) + int(b["speed"])
	return sum


## v6 武将记录 → 其静态自带装备的聚合加成
static func hero_equipment_bonuses(hero6: Dictionary) -> Dictionary:
	if hero6.is_empty():
		return {"attack": 0, "defense": 0, "hp": 0, "speed": 0}
	return equipment_bonuses(hero6.get("equipment", {}))


## 主角当前主武器的攻击绝对值（战场普攻/大招取数，含强化）
static func player_weapon_attack() -> int:
	var wid := int(GameState.equipment.get("weapon1", 0))
	var item := resolve_item6(GameState.equipment.get("weapon1", 0))
	return int(item_combat_bonus(item, EnhanceService.level_of(wid))["attack"])


## 单件物品加成摘要文字（铁匠铺/装备槽显示用），lv=强化等级，无加成返回空串
static func item_bonus_text(item: Dictionary, lv: int = 0) -> String:
	var b := item_combat_bonus(item, lv)
	var parts: Array[String] = []
	if int(b["attack"]) != 0:
		parts.append("攻+%d" % int(b["attack"]))
	if int(b["defense"]) != 0:
		parts.append("防+%d" % int(b["defense"]))
	if int(b["hp"]) != 0:
		parts.append("HP+%d" % int(b["hp"]))
	if int(b["speed"]) != 0:
		parts.append("速+%d" % int(b["speed"]))
	var text := "　".join(parts)
	if lv > 0:
		text = "【强化+%d】%s" % [lv, text]
	return text


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
