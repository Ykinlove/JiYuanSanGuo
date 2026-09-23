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


## 计算一次胜利的奖励（不含应用，纯计算，便于独立校验）。
## kills=歼灭队数（全额缴获），routs=溃散队数（半额缴获，敌军丢盔弃甲而逃）。
## 返回 { exp, gold, fame, materials: Array[String], hero_exp }
static func roll(encounter: Dictionary, kills: int, routs: int = 0) -> Dictionary:
	var rew: Dictionary = encounter.get("rewards", {})

	var er: Array = _range(rew, "exp", "exp_range", DEFAULT_EXP_RANGE)
	var gr: Array = _range(rew, "gold", "gold_range", DEFAULT_GOLD_RANGE)
	var exp_amt := randi_range(int(er[0]), int(er[1])) \
		+ kills * _cfg_int("exp_per_kill", DEFAULT_EXP_PER_KILL) \
		+ routs * _cfg_int("exp_per_rout", DEFAULT_EXP_PER_ROUT)
	var gold := randi_range(int(gr[0]), int(gr[1])) \
		+ kills * _cfg_int("gold_per_kill", DEFAULT_GOLD_PER_KILL) \
		+ routs * _cfg_int("gold_per_rout", DEFAULT_GOLD_PER_ROUT)
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
