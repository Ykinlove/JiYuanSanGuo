extends RefCounted
class_name DuelService
## 战前单挑规则层（combat.json -> duel）。
## 三择相克：猛攻(attack) 克 佯攻(feint)，佯攻 克 稳守(guard)，稳守 克 猛攻。
## 状态机由 UI 持有（start/play_round 纯函数式传递 state），规则层不碰节点。

const MOVE_ATTACK := "attack"
const MOVE_GUARD := "guard"
const MOVE_FEINT := "feint"

const PLAYER_ID := "__player__"

## 出招 → 被其克制的招
const _BEATS := {
	MOVE_ATTACK: MOVE_FEINT,
	MOVE_FEINT: MOVE_GUARD,
	MOVE_GUARD: MOVE_ATTACK,
}

## 被克 → 克制它的招（反向表：想赢 X 就出这个）
const _COUNTERS := {
	MOVE_ATTACK: MOVE_GUARD,
	MOVE_GUARD: MOVE_FEINT,
	MOVE_FEINT: MOVE_ATTACK,
}
const MOVE_NAMES := {
	MOVE_ATTACK: "猛攻",
	MOVE_GUARD: "稳守",
	MOVE_FEINT: "佯攻",
}


static func _cfg() -> Dictionary:
	return DataManager.get_record("combat", "root").get("duel", {})


static func move_name(move: String) -> String:
	return String(MOVE_NAMES.get(move, move))


## 可选出阵武将：主角 + 在队武将。返回 [{id,name,force}]
## 【可玩性调优 2026-09-24】单挑力公式 40+strength×4 在力量 15 就饱和到 100（上限 clamp），
## 属性点几乎全部无效。改为 30+strength×0.5：创角 60 力=force 60，全程加点流
## （力量 140）可达满值 100，属性点在单挑线全程有效。
static func champions() -> Array:
	var out: Array = []
	var st := GameState.player_stats
	out.append({
		"id": PLAYER_ID,
		"name": GameState.player_name,
		"force": clampi(30 + int(round(float(st.get("strength", 10)) * 0.5)), 1, 100),
	})
	for h in GameState.party:
		var hid := str(h.get("hero_id", ""))
		var hero := DataManager.get_hero_resolved(hid)
		if hero.is_empty():
			continue
		out.append({
			"id": hid,
			"name": str(hero.get("name", hid)),
			"force": clampi(int(hero.get("force", 50)), 1, 100),
		})
	return out


## 按 id 取出阵武将（主角或在队武将），无则空字典
static func champion_by_id(cid: String) -> Dictionary:
	for c in champions():
		if str(c["id"]) == cid:
			return c
	return {}


## 敌将记录（遭遇表 boss_hero_id）→ {id,name,force}；无则空字典
static func enemy_of_encounter(enc: Dictionary) -> Dictionary:
	var bid := str(enc.get("boss_hero_id", ""))
	if bid.is_empty():
		return {}
	var hero := DataManager.get_hero_resolved(bid)
	if hero.is_empty():
		return {}
	return {
		"id": bid,
		"name": str(hero.get("name", bid)),
		"force": clampi(int(hero.get("force", 50)), 1, 100),
	}


## 开局状态
static func start(champ: Dictionary, enemy: Dictionary) -> Dictionary:
	var hp := int(_cfg().get("hp", 100))
	return {
		"a": champ,
		"b": enemy,
		"hp_a": hp,
		"hp_b": hp,
		"round": 0,
		"max_rounds": int(_cfg().get("max_rounds", 3)),
		"history_a": [],
		"over": false,
		"outcome": "",
		"log": ["%s 对阵 %s，阵前搦战！" % [champ.get("name", "我将"), enemy.get("name", "敌将")]],
	}


## 伤害公式
static func _hit(damage_force: int, mult: float) -> int:
	var cfg := _cfg()
	var base := float(cfg.get("base_damage", 18)) + float(damage_force) * float(cfg.get("force_weight", 0.25))
	var v := float(cfg.get("damage_variance", 0.2))
	return maxi(1, int(round(base * mult * randf_range(1.0 - v, 1.0 + v))))


## 敌方出招：基础 enemy_bias 加权随机 + Markov 自适应（R2-06）。
## 统计玩家最近 3 招，把 counter_bias（默认 0.3）的概率质量按出现频次
## 分给「克制玩家该招」的选项，其余质量仍走基础 bias——专精一招的玩家
## 会被敌方逐步针对，但单看任何一合仍是随机博弈，不构成必胜读招。
static func _ai_move(history: Array) -> String:
	var bias: Dictionary = _cfg().get("enemy_bias", {})
	var pa := float(bias.get(MOVE_ATTACK, 0.4))
	var pg := float(bias.get(MOVE_GUARD, 0.35))
	var pf := float(bias.get(MOVE_FEINT, maxi(0.0, 1.0 - pa - pg)))
	var weights := {
		MOVE_ATTACK: pa,
		MOVE_GUARD: pg,
		MOVE_FEINT: pf,
	}
	var cb := float(_cfg().get("counter_bias", 0.3))
	var recent := history.slice(maxi(0, history.size() - 3))
	if cb > 0.0 and not recent.is_empty():
		var counts := {}
		for m in recent:
			var key := String(m)
			counts[key] = int(counts.get(key, 0)) + 1
		var counter_mass := {
			MOVE_ATTACK: 0.0,
			MOVE_GUARD: 0.0,
			MOVE_FEINT: 0.0,
		}
		for m in counts:
			var cm: String = _COUNTERS.get(String(m), MOVE_ATTACK)
			counter_mass[cm] = float(counter_mass[cm]) + float(counts[m]) / float(recent.size())
		# 三招统一按 (1-cb) 基础 + cb 计数分布 混合，保证权重和恒为 1
		for m in weights:
			weights[m] = float(weights[m]) * (1.0 - cb) + cb * float(counter_mass[m])
	var r := randf()
	var acc := 0.0
	for m in [MOVE_ATTACK, MOVE_GUARD, MOVE_FEINT]:
		acc += float(weights[m])
		if r < acc:
			return m
	return MOVE_FEINT


## 打一回合。返回更新后的 state（同字典）；log 追加战报。
static func play_round(state: Dictionary, my_move: String) -> Dictionary:
	if bool(state.get("over", false)):
		return state
	var enemy_move := _ai_move(state.get("history_a", []))
	state["round"] = int(state["round"]) + 1
	var an := str(state["a"].get("name", "我将"))
	var bn := str(state["b"].get("name", "敌将"))
	state["history_a"].append(my_move)
	state["log"].append("第 %d 合：%s【%s】，%s【%s】" % [
		int(state["round"]), an, move_name(my_move), bn, move_name(enemy_move)])

	if my_move == enemy_move:
		if my_move == MOVE_ATTACK:
			# 对攻：双方各伤
			var da := _hit(int(state["a"]["force"]), float(_cfg().get("clash_mult", 0.7)))
			var db := _hit(int(state["b"]["force"]), float(_cfg().get("clash_mult", 0.7)))
			state["hp_a"] = maxi(0, int(state["hp_a"]) - da)
			state["hp_b"] = maxi(0, int(state["hp_b"]) - db)
			state["log"].append("双马交错，各中一击（%s -%d / %s -%d）" % [an, da, bn, db])
		else:
			state["log"].append("二人招路相同，各自跃开，未分胜负")
	elif String(_BEATS.get(my_move, "")) == enemy_move:
		var d := _hit(int(state["a"]["force"]), float(_cfg().get("counter_mult", 1.3)))
		state["hp_b"] = maxi(0, int(state["hp_b"]) - d)
		state["log"].append("%s 招招克制，%s 受伤 -%d" % [an, bn, d])
	else:
		var d2 := _hit(int(state["b"]["force"]), float(_cfg().get("counter_mult", 1.3)))
		state["hp_a"] = maxi(0, int(state["hp_a"]) - d2)
		state["log"].append("%s 识破破绽，%s 受伤 -%d" % [bn, an, d2])

	# 阵斩或回合耗尽 → 结算
	# 【修复】同回合双双倒地时，旧代码先判 hp_b 直接算玩家胜，白拿全额胜利收益
	# （敌兵 -25%、名声等）。平局语义在本函数 max_rounds 分支里本就存在，补齐同一分支。
	if int(state["hp_b"]) <= 0 and int(state["hp_a"]) <= 0:
		state["over"] = true
		state["outcome"] = "draw"
		state["log"].append("二将同归于尽，各自鸣金收兵")
	elif int(state["hp_b"]) <= 0:
		state["over"] = true
		state["outcome"] = "win"
		state["log"].append("%s 阵斩 %s，敌军气夺！" % [an, bn])
	elif int(state["hp_a"]) <= 0:
		state["over"] = true
		state["outcome"] = "lose"
		state["log"].append("%s 力怯败退，鸣金收兵" % an)
	elif int(state["round"]) >= int(state["max_rounds"]):
		state["over"] = true
		if int(state["hp_a"]) > int(state["hp_b"]):
			state["outcome"] = "win"
			state["log"].append("三合罢，%s 伤势较轻，敌军认负" % an)
		elif int(state["hp_a"]) < int(state["hp_b"]):
			state["outcome"] = "lose"
			state["log"].append("三合罢，%s 负伤回营" % an)
		else:
			state["outcome"] = "draw"
			state["log"].append("三合罢不分胜负，各自归阵")
	return state


## 单挑结局 → 对野战的影响参数
static func battle_effects(outcome: String) -> Dictionary:
	var cfg := _cfg()
	if outcome == "win":
		return {
			"enemy_count_scale": float(cfg.get("win_enemy_count_scale", 0.75)),
			"start_rage": float(cfg.get("win_start_rage", 50.0)),
			"player_hp_scale": 1.0,
			"fame": int(cfg.get("win_fame", 2)),
		}
	if outcome == "lose":
		return {
			"enemy_count_scale": 1.0,
			"start_rage": 0.0,
			"player_hp_scale": float(cfg.get("lose_player_hp_scale", 0.7)),
			"fame": 0,
		}
	return {"enemy_count_scale": 1.0, "start_rage": 0.0, "player_hp_scale": 1.0, "fame": 0}


## 发放单挑声望（胜利时调用）
static func apply_fame(effects: Dictionary) -> void:
	var f := int(effects.get("fame", 0))
	if f != 0:
		GameState.add_fame(f)
