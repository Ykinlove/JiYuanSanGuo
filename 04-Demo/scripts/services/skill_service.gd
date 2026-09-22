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
static func get_skill(skill_id: int) -> Dictionary:
	if skill_id <= 0:
		return {}
	return DataManager.get_talent6(skill_id)


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
