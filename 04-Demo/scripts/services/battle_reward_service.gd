extends RefCounted
class_name BattleRewardService
## 战斗胜利奖励规则层。
## 奖励基数读 combat.json 的 battle_rewards，遭遇表 rewards 可覆盖：
##   exp/gold = 区间随机 + 歼敌队数 × 每队加成
##   fame     = 遭遇表固定名声
##   materials= 遭遇表掉落物 id 列表（各 1 件，入背包）
##   hero_exp = 主角经验 × hero_exp_share（发给所有统兵武将）
## 结算层（battle_scene）只调用本层并应用结果，不写公式。

const DEFAULT_EXP_RANGE: Array[int] = [60, 130]
const DEFAULT_GOLD_RANGE: Array[int] = [90, 210]
const DEFAULT_EXP_PER_KILL := 12
const DEFAULT_GOLD_PER_KILL := 18
const DEFAULT_EXP_PER_ROUT := 6
const DEFAULT_GOLD_PER_ROUT := 8
const DEFAULT_HERO_EXP_SHARE := 0.5


static func _settings() -> Dictionary:
	var rec := DataManager.get_record("combat", "root")
	return rec.get("battle_rewards", {})


static func _range(rew: Dictionary, ov_key: String, cfg_key: String, fallback: Array) -> Array:
	# 遭遇表覆盖键（exp/gold）与 battle_rewards 缺省键（exp_range/gold_range）不同名，必须分开查：
	# 原先统一按 cfg_key 查，导致 JSON 里调 exp_range/gold_range 被静默忽略，永远回落到代码常量。
	var v = rew.get(ov_key, null)
	if v is Array and v.size() == 2:
		return [int(v[0]), int(v[1])]
	var d: Array = _settings().get(cfg_key, fallback)
	return [int(d[0]), int(d[1])]


static func _cfg_int(key: String, fallback: int) -> int:
	return int(_settings().get(key, fallback))


static func _cfg_float(key: String, fallback: float) -> float:
	return float(_settings().get(key, fallback))


## 【P0-3 审计修复】等级差奖励缩放：玩家等级高于遭遇等级带上限越多，
## 经验/金钱按每级 reward_decay_per_level 递减、地板 reward_floor。
## 只缩 exp/gold——fame 是进度门槛（P2-4 立场：不缩）、materials 是内容掉落（不缩）。
static func level_scale_factor(encounter: Dictionary, player_level: int) -> float:
	var lr: Array = encounter.get("level_range", [])
	if lr.size() != 2:
		return 1.0
	var diff := player_level - int(lr[1])
	if diff <= 0:
		return 1.0
	var decay := _cfg_float("reward_decay_per_level", 0.08)
	var floor_v := _cfg_float("reward_floor", 0.3)
	return clampf(1.0 - decay * float(diff), floor_v, 1.0)


## 【P0-2 审计修复】战场折损结转存档：按 战场残余兵力/出发总兵力 比例写回各队
## （胜利下限 0.5、败北下限 0.25，单队保底 10）。胜利也折损=补兵成为常态经济循环。
## 返回实际保留比例（1.0 = 无折损）。纯结算规则，battle_scene 负责发信号。
static func apply_attrition(summary: Dictionary, total_before: int, floor_ratio: float) -> float:
	if GameState.troops.is_empty():
		return 1.0
	# 【修复】分母必须是「出战兵力」而不是全军总兵力：只派一部分部队上阵时，
	# 旧公式把留守部队也算进损失率，没打仗的部队同样被砍到折损下限。
	var deployed := maxi(0, int(summary.get("ally_troops_initial", total_before)))
	if deployed <= 0:
		# 没有任何部队下场（空阵单挑等），谈不上战场折损
		return 1.0
	# 没有出战快照且战场残余为 0（如单挑定胜负的 summary）同样按「无部队下场」处理，
	# 否则会把全军当成全歼砍到折损下限。真实战斗必定带 ally_troops_initial。
	if not summary.has("ally_troops_initial") and int(summary.get("ally_troops", 0)) <= 0:
		return 1.0
	var keep := clampf(
		float(int(summary.get("ally_troops", deployed))) / float(deployed),
		floor_ratio, 1.0)
	if keep >= 1.0:
		return 1.0
	# 【修复】折损只作用于真正出战的部队：旧实现遍历全军，4 队只出 1 队打光时
	# 留守的 3 队也按同一比例缩水（100 兵被砍到 25）。
	# 按下标遍历而非 find(t)：Dictionary 的 == 是按内容比较，两支同配置部队
	# 会命中同一个下标，索引过滤就失效了
	var indexes: Array = summary.get("deployed_indexes", [])
	for i in GameState.troops.size():
		if not indexes.is_empty() and not indexes.has(i):
			continue
		var t: Dictionary = GameState.troops[i]
		var before := int(t.get("count", 0))
		# 【修复】保底 10 的语义是「别全灭」，不能反向把残兵补满：
		# 旧写法 maxi(10, …) 会让 4 人的部队打完仗变成 10 人。
		t["count"] = maxi(mini(10, before), int(float(before) * keep))
	return keep


## 计算一次胜利的奖励（不含应用，纯计算，便于独立校验）。
## kills=歼灭队数（全额缴获），routs=溃散队数（半额缴获，敌军丢盔弃甲而逃）。
## 返回 { exp, gold, fame, materials: Array[String], hero_exp }
static func roll(encounter: Dictionary, kills: int, routs: int = 0) -> Dictionary:
	var rew: Dictionary = encounter.get("rewards", {})

	var er: Array = _range(rew, "exp", "exp_range", DEFAULT_EXP_RANGE)
	var gr: Array = _range(rew, "gold", "gold_range", DEFAULT_GOLD_RANGE)
	# 【P0-3】等级差缩放只作用于基础区间 + 歼敌加成之和（exp/gold），fame/materials 不缩
	var scale := level_scale_factor(encounter, GameState.player_level)
	var exp_amt := int(round(float(randi_range(int(er[0]), int(er[1])) \
		+ kills * _cfg_int("exp_per_kill", DEFAULT_EXP_PER_KILL) \
		+ routs * _cfg_int("exp_per_rout", DEFAULT_EXP_PER_ROUT)) * scale))
	var gold := int(round(float(randi_range(int(gr[0]), int(gr[1])) \
		+ kills * _cfg_int("gold_per_kill", DEFAULT_GOLD_PER_KILL) \
		+ routs * _cfg_int("gold_per_rout", DEFAULT_GOLD_PER_ROUT)) * scale))
	var fame := int(rew.get("fame", _cfg_int("default_fame", 0)))

	var materials: Array[String] = []
	for m in rew.get("materials", []):
		materials.append(str(m))

	var hero_exp := int(round(float(exp_amt) * _cfg_float("hero_exp_share", DEFAULT_HERO_EXP_SHARE)))

	return {
		"exp": maxi(0, exp_amt),
		"gold": maxi(0, gold),
		"fame": maxi(0, fame),
		"materials": materials,
		"hero_exp": maxi(0, hero_exp),
	}


## 应用奖励到 GameState（主角经验/金钱/名声/材料/统兵武将经验）。
## 返回与 roll 相同的结构（便于战报展示）。
static func apply(encounter: Dictionary, kills: int, routs: int = 0) -> Dictionary:
	var r := roll(encounter, kills, routs)
	GameState.add_player_exp(int(r["exp"]))
	GameState.add_gold(int(r["gold"]))
	if int(r["fame"]) > 0:
		GameState.add_fame(int(r["fame"]))
	for item_id in r["materials"]:
		GameState.add_item(str(item_id), 1)
	# 统兵武将经验：所有已编制部队的带队武将共享
	var given: Dictionary = {}
	for t in GameState.troops:
		var hid := str(t.get("hero_id", ""))
		if hid.is_empty() or given.has(hid):
			continue
		given[hid] = true
		GameState.add_hero_exp(hid, int(r["hero_exp"]))
	return r
