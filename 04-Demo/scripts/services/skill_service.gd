extends RefCounted
class_name SkillService
## 武将特技规则层（军团战）。
## 数据源：heroes6.skills[3槽] → talents6.json。
## 三槽结构（全表统计结论）：个人攻击技(1-3) / 个人生存技(4-6) / 军团指挥技(14,15,16)。
## 本阶段只接第三槽军团技，个人技为 ARPG 量级，不接入部队战。
## UI 与战斗只允许调用本层取技能数据与节奏参数，显示层不写公式。

const SKILL_IRON_WALL := 14   ## 铁壁：我方步兵防御 +20，10 秒
const SKILL_RAPID_FIRE := 15  ## 连射：我方弓兵攻速 ×2（攻击间隔减半），10 秒
const SKILL_CHARGE := 16      ## 冲锋：我方骑兵发起冲刺

## 本阶段生效的军团技白名单
const TROOP_SKILLS := [SKILL_IRON_WALL, SKILL_RAPID_FIRE, SKILL_CHARGE]

# ---------- 触发节奏（秒）。实测失衡只调这里 ----------
const FIRST_DELAY := {
	SKILL_CHARGE: 4.0,       ## 开战 4 秒首波冲锋
	SKILL_RAPID_FIRE: 8.0,   ## 开战 8 秒首次连射
}
const IRON_WALL_FIRST_DELAY := 4.0   ## 铁壁兜底：开战 4 秒后若已交火即可放
const IRON_WALL_ARM_DELAY := 1.5     ## 首次步兵交火后再等 1.5 秒（避免接敌瞬间全亮）
const COOLDOWN := {
	SKILL_IRON_WALL: 25.0,
	SKILL_RAPID_FIRE: 25.0,
	SKILL_CHARGE: 22.0,
}
const MAX_USES := 2                 ## 每技能每场最多释放次数
const BUFF_DURATION := 10.0         ## 铁壁/连射 buff 持续
const IRON_WALL_DEFENSE := 20       ## 铁壁防御绝对值
const RAPID_FIRE_INTERVAL_MULT := 0.5  ## 连射攻击间隔倍率

# ---------- 技能作用兵种 ----------
const _AFFECTS_CATEGORY := {
	SKILL_IRON_WALL: "infantry",
	SKILL_RAPID_FIRE: "archer",
	SKILL_CHARGE: "cavalry",
}
const _SHORT_TEXT := {
	SKILL_IRON_WALL: "步兵铁壁（防+%d/%d秒）" % [IRON_WALL_DEFENSE, int(BUFF_DURATION)],
	SKILL_RAPID_FIRE: "弓兵速射（攻速翻倍/%d秒）" % int(BUFF_DURATION),
	SKILL_CHARGE: "骑兵突击",
}
const _CAST_TEXT := {
	SKILL_IRON_WALL: "我军步兵铁壁成形，防御 +%d" % IRON_WALL_DEFENSE,
	SKILL_RAPID_FIRE: "我军弓兵连射，攻速翻倍",
	SKILL_CHARGE: "我军骑兵突击",
}

# ---------- 个人技（M7-D，主角战场内使用，冷却制） ----------
## 个人技白名单：1-3 攻击技，4 群攻，5 护体（生存），6 回春（生存）
const PERSONAL_SKILLS := [1, 2, 3, 4, 5, 6]
const PERSONAL_KIND_DAMAGE := "damage"
const PERSONAL_KIND_SHIELD := "shield"
const PERSONAL_KIND_HEAL := "heal"
## 冷却（秒）
const PERSONAL_COOLDOWN := {1: 8.0, 2: 10.0, 3: 14.0, 4: 16.0, 5: 18.0, 6: 20.0}
## 效果数值（伤害为基础值，战场再乘主角攻击系数；护体为秒；回血为 HP）
const PERSONAL_POWER := {1: 45.0, 2: 70.0, 3: 110.0, 4: 140.0, 5: 4.0, 6: 60.0}
## 3/4 为大范围技（打最靠前两支敌队），其余攻击技打最近一队
const PERSONAL_AOE := [3, 4]
## 战场效果分类
const _PERSONAL_KIND := {
	1: PERSONAL_KIND_DAMAGE, 2: PERSONAL_KIND_DAMAGE,
	3: PERSONAL_KIND_DAMAGE, 4: PERSONAL_KIND_DAMAGE,
	5: PERSONAL_KIND_SHIELD, 6: PERSONAL_KIND_HEAL,
}


## v6 武将记录 → 其持有的军团技 id（skills[] 中落在白名单者），无则 0
static func hero_troop_skill(hero6: Dictionary) -> int:
	if hero6.is_empty():
		return 0
	for sid in hero6.get("skills", []):
		var n := int(sid)
		if n in TROOP_SKILLS:
			return n
	return 0


## talents6 技能定义
## 【缺陷·已修】原式直接 `DataManager.get_talent6(skill_id)`：
##   DataManager 是 autoload，而 `--headless --script` 不加载 autoload
##   （MEMORY 铁律）→ 本文件整体编译失败，连带 BattleUnit 编不过
##   → **任何无头探针都无法实例化 BattleUnit，战斗行为无法被测**。
##   正常运行期同样有风险：战斗已开打才查表，查不到就整层崩掉。
## 现做三层兜底（与 CombatFeelService._section 同款思路）。
static func _data_manager() -> Object:
	if Engine.has_singleton("DataManager"):
		return Engine.get_singleton("DataManager")
	if Engine.get_main_loop() is SceneTree:
		return (Engine.get_main_loop() as SceneTree).root.get_node_or_null(
			"/root/DataManager")
	return null


static func get_skill(skill_id: int) -> Dictionary:
	if skill_id <= 0:
		return {}
	var dm := _data_manager()
	if dm == null or not dm.has_method("get_talent6"):
		return {}
	var t: Variant = dm.call("get_talent6", skill_id)
	return t if t is Dictionary else {}


## 技能名（无技能返回空串）
static func skill_name(skill_id: int) -> String:
	var t := get_skill(skill_id)
	return str(t.get("name", "")) if not t.is_empty() else ""


## 布阵界面短摘要
static func skill_short(skill_id: int) -> String:
	return String(_SHORT_TEXT.get(skill_id, ""))


## 释放战报后缀文案
static func cast_text(skill_id: int) -> String:
	return String(_CAST_TEXT.get(skill_id, ""))


## 技能作用的兵种 category
static func skill_affects_category(skill_id: int) -> String:
	return String(_AFFECTS_CATEGORY.get(skill_id, ""))


# ---------- 个人技接口（M7-D） ----------

## v6 武将记录 → 其个人技 id 列表（skills[] 中 1-6）
static func hero_personal_skills(hero6: Dictionary) -> Array:
	var out: Array = []
	if hero6.is_empty():
		return out
	for sid in hero6.get("skills", []):
		var n := int(sid)
		if n in PERSONAL_SKILLS and not out.has(n):
			out.append(n)
	return out


## 个人技是否合法
static func is_personal_skill(skill_id: int) -> bool:
	return skill_id in PERSONAL_SKILLS


## 个人技战场元数据 {id,name,desc,kind,cooldown,power,aoe}；非法返回空字典
static func personal_meta(skill_id: int) -> Dictionary:
	if not is_personal_skill(skill_id):
		return {}
	var t := get_skill(skill_id)
	return {
		"id": skill_id,
		"name": str(t.get("name", "技能%d" % skill_id)),
		"desc": str(t.get("description", "")),
		"kind": String(_PERSONAL_KIND.get(skill_id, PERSONAL_KIND_DAMAGE)),
		"cooldown": float(PERSONAL_COOLDOWN.get(skill_id, 10.0)),
		"power": float(PERSONAL_POWER.get(skill_id, 0.0)),
		"aoe": skill_id in PERSONAL_AOE,
	}


## 主角战场可选个人技：主角自带 1（雷霆击），并集在队武将的个人技
static func available_personal_skills() -> Array:
	var out: Array = [1]
	# 【缺陷·已修】GameState / DataManager 都是 autoload，
	# 无头环境下二者皆不可用 → 直接崩在**加载期**（编译失败）。
	# 兜底：任一缺失就返回默认集合（至少保留 0 号普攻位），
	# 不让「取技能列表」这种纯查询动作成为整文件的编译阻塞点。
	var gs: Object = null
	if Engine.has_singleton("GameState"):
		gs = Engine.get_singleton("GameState")
	elif Engine.get_main_loop() is SceneTree:
		gs = (Engine.get_main_loop() as SceneTree).root.get_node_or_null(
			"/root/GameState")
	var dm := _data_manager()
	if gs == null or dm == null or not dm.has_method("get_hero_resolved"):
		return out
	for h in gs.get("party"):
		if not (h is Dictionary):
			continue
		var hero: Variant = dm.call("get_hero_resolved", str(h.get("hero_id", "")))
		if not (hero is Dictionary):
			continue
		for sid in hero_personal_skills(hero as Dictionary):
			if not out.has(sid):
				out.append(sid)
	out.sort()
	return out
