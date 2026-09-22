extends Node2D
## 战斗场景（BattleScene）· M4
## 职责：即时战场的总装层——把布阵结果交给 BattleDirector 生成部队，
##       玩家操作主角参战、给部队下指令，HUD 实时显示战况与战斗事件。
##
## 分工：
##   FormationCalculator  算加成（M3）
##   BattleDirector       跑战斗（M4）
##   BattleUnit           单支部队的行为（M4）
##   BattleScene          输入输出、UI、结算（本文件）

enum Phase { PREPARE, FIGHTING, RESULT }

const PLAYER_SPEED := 240.0
const PLAYER_BOUNDS_TOP := 160.0
const PLAYER_BOUNDS_BOTTOM := 940.0

@onready var _joystick: GameJoystick = $UI/VirtualJoystick
@onready var _btn_attack: Button = $UI/ActionButtons/BtnAttack
@onready var _btn_dodge: Button = $UI/ActionButtons/BtnDodge
@onready var _btn_skill: Button = $UI/ActionButtons/BtnSkill
@onready var _btn_charge: Button = $UI/CommandPanel/BtnCharge
@onready var _btn_hold: Button = $UI/CommandPanel/BtnHold
@onready var _btn_retreat: Button = $UI/CommandPanel/BtnRetreat
@onready var _hp_bar: ProgressBar = $UI/StatusBars/HPBar
@onready var _morale_bar: ProgressBar = $UI/StatusBars/MoraleBar
@onready var _rage_bar: ProgressBar = $UI/StatusBars/RageBar
@onready var _enemy_hp_bar: ProgressBar = $UI/StatusBars/EnemyHPBar
@onready var _toast: Label = $UI/ToastLabel
@onready var _result_panel: Control = $UI/ResultPanel
@onready var _result_label: Label = $UI/ResultPanel/VBox/ResultLabel
@onready var _btn_result_ok: Button = $UI/ResultPanel/VBox/BtnOk
@onready var _situation_label: Label = $UI/SituationLabel
@onready var _log_label: Label = $UI/LogLabel

@onready var _player: Node2D = $Player
@onready var _ally_units: Node2D = $AllyUnits
@onready var _enemy_units: Node2D = $EnemyUnits

var _phase: int = Phase.PREPARE
var _player_hp: float = 100.0
var _player_hp_max: float = 100.0
var _morale: float = 100.0
var _rage: float = 0.0
var _attack_cooldown := 0.0
var _player_invuln := 0.0

## 布阵加成（M3）
var _calc := FormationCalculator.new()
var _atk_mult := 1.0
var _def_mult := 1.0
var _formation_name := ""
var _deployed: Array = []

## 战斗总指挥（M4）
var _director: BattleDirector
var _enemy_name := "敌军"
var _log_lines: Array = []
var _toast_tween: Tween


func _ready() -> void:
	AudioManager.play_bgm("res://assets/audio/bgm/battle.ogg")
	_phase = Phase.PREPARE
	_calc.ensure_loaded()

	_joystick.changed.connect(_on_joystick_changed)
	_btn_attack.pressed.connect(_on_attack)
	_btn_dodge.pressed.connect(_on_dodge)
	_btn_skill.pressed.connect(_on_skill)
	_btn_charge.pressed.connect(_on_command_charge)
	_btn_hold.pressed.connect(_on_command_hold)
	_btn_retreat.pressed.connect(_on_retreat)
	_btn_result_ok.pressed.connect(_on_result_ok)

	_result_panel.visible = false
	EventBus.toast.connect(show_toast)
	await _setup_battle()


## ---------- 建立战场 ----------

func _setup_battle() -> void:
	GameState.battle_count += 1

	# 1. 布阵加成
	_apply_formation()

	# 2. 建总指挥
	_director = BattleDirector.new()
	add_child(_director)
	_director.setup(_load_combat_cfg(), _ally_units, _enemy_units)
	_director.battle_finished.connect(_on_battle_finished)
	_director.log_event.connect(_push_log)

	# 3. 摆部队
	_director.deploy_allies(_deployed, GameState.troops)

	var enc: Dictionary = GameState.current_encounter
	if not enc.is_empty():
		_enemy_name = str(enc.get("name", "敌军"))
	_director.deploy_enemies(enc)

	# 4. 主角外观
	_build_player_visual()

	# 5. 开打
	_update_bars()
	var msg := "遭遇 %s！" % _enemy_name if not enc.is_empty() else "战斗开始！"
	if not _formation_name.is_empty():
		msg = "%s · 布阵「%s」" % [_enemy_name, _formation_name]
	show_toast(msg)
	await get_tree().create_timer(0.7).timeout
	_phase = Phase.FIGHTING
	_director.start()
	_push_log("两军交锋")


func _load_combat_cfg() -> Dictionary:
	var rec := DataManager.get_record("combat", "root")
	if not rec.is_empty():
		return rec
	# 回退：直接读文件
	var path := "res://assets/data/combat.json"
	if not FileAccess.file_exists(path):
		push_warning("[BattleScene] combat.json 缺失，使用空配置")
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	var text := f.get_as_text()
	f.close()
	var json := JSON.new()
	if json.parse(text) == OK and json.data is Dictionary:
		return json.data
	return {}


## 计算布阵加成（沿用 M3 逻辑）
func _apply_formation() -> void:
	var formation := DataManager.get_formation(GameState.formation_id)
	_formation_name = str(formation.get("name", ""))

	var slots: Array = GameState.formation_slots
	if slots.size() != FormationCalculator.SLOT_COUNT:
		slots = _calc.auto_arrange(GameState.troops)
		GameState.formation_slots = slots.duplicate()

	var result := _calc.calculate(slots, GameState.troops, formation)
	_deployed = result["detail"]

	var total_power := maxf(1.0, float(result["total_power"]))
	var atk_sum := 0.0
	var def_sum := 0.0
	for d in _deployed:
		var w := float(d["power"]) / total_power
		atk_sum += float(d["attack_bonus"]) * w
		def_sum += float(d["defense_bonus"]) * w

	if _deployed.is_empty():
		_atk_mult = float(formation.get("attack_bonus", 0.0))
		_def_mult = float(formation.get("defense_bonus", 0.0))
	else:
		# 主角伤害 = 基础 × (1 + 平均加成)，乘性转换
		_atk_mult = clampf(atk_sum, -0.5, 1.5)
		_def_mult = clampf(def_sum, -0.5, 1.5)


## 主角占位视觉
func _build_player_visual() -> void:
	if _player.get_child_count() > 0:
		return
	var body := Polygon2D.new()
	body.polygon = PackedVector2Array([
		Vector2(0, -30), Vector2(20, -12), Vector2(20, 18),
		Vector2(-20, 18), Vector2(-20, -12)
	])
	body.color = Color(0.32, 0.55, 0.9)
	_player.add_child(body)

	var outline := Line2D.new()
	outline.points = PackedVector2Array([
		Vector2(0, -30), Vector2(20, -12), Vector2(20, 18),
		Vector2(-20, 18), Vector2(-20, -12), Vector2(0, -30)
	])
	outline.width = 2.5
	outline.default_color = Color(0.12, 0.22, 0.4)
	_player.add_child(outline)

	var lbl := Label.new()
	lbl.text = GameState.player_name
	lbl.add_theme_font_size_override("font_size", 18)
	lbl.add_theme_color_override("font_color", Color(0.9, 0.95, 1))
	lbl.position = Vector2(-30, 22)
	_player.add_child(lbl)


## ---------- 主循环 ----------

func _process(delta: float) -> void:
	if _phase == Phase.FIGHTING:
		_drive_player(delta)
		_director.process_delta(delta)
		_refresh_hud()
	elif _phase == Phase.PREPARE:
		# 准备阶段也跑一下，让部队站位稳定
		pass


func _drive_player(delta: float) -> void:
	var mv := _joystick.output
	if mv.length() > 0.05:
		_player.position += mv * PLAYER_SPEED * delta
	_player.position.x = clampf(_player.position.x, 60.0, 1860.0)
	_player.position.y = clampf(_player.position.y, PLAYER_BOUNDS_TOP, PLAYER_BOUNDS_BOTTOM)

	_attack_cooldown = maxf(0.0, _attack_cooldown - delta)
	_player_invuln = maxf(0.0, _player_invuln - delta)
	_rage = minf(100.0, _rage + delta * 4.5)


func _refresh_hud() -> void:
	var sit := _director.situation()
	_situation_label.text = "我军 %d队 / %d兵　　敌军 %d队 / %d兵" % [
		int(sit["ally_alive"]), int(sit["ally_troops"]),
		int(sit["enemy_alive"]), int(sit["enemy_troops"]),
	]
	# 士气条用我方平均士气
	_morale = float(sit["ally_morale"])
	# 敌方血条 = 敌方兵力占比
	var enc_total := maxf(1.0, float(_director._initial_enemy_count))
	var remain := float(sit["enemy_alive"]) + float(sit["enemy_troops"]) / maxf(1.0, float(_director.enemy_troops() + 1)) * 0.3
	_enemy_hp_bar.max_value = 100.0
	_enemy_hp_bar.value = clampf(float(sit["enemy_alive"]) / enc_total * 100.0, 0.0, 100.0)
	_update_bars()


## ---------- 玩家操作 ----------

func _on_attack() -> void:
	if _phase != Phase.FIGHTING or _attack_cooldown > 0.0:
		return
	_attack_cooldown = 0.32
	AudioManager.sfx_hit()
	_rage = minf(100.0, _rage + 8.0)
	# 只打得到附近敌人时才算命中（离最近敌军 260px 内）
	var reach := 260.0
	var front := _nearest_enemy_dist()
	var mult := 1.0 + _atk_mult
	# 基础伤害 + 主武器攻击绝对值（装备生效）
	var dmg := (randf_range(14.0, 24.0) + float(CharacterService.player_weapon_attack())) * mult
	if front > reach:
		show_toast("距离过远，未能命中")
		return
	_director.player_strike(dmg)
	_flash(_player)


func _on_dodge() -> void:
	if _phase != Phase.FIGHTING:
		return
	AudioManager.sfx_click()
	_rage = minf(100.0, _rage + 4.0)
	_player_invuln = 0.6
	show_toast("闪避")


func _on_skill() -> void:
	if _phase != Phase.FIGHTING:
		return
	if _rage < 50.0:
		show_toast("怒气不足（需 50）")
		return
	_rage -= 50.0
	AudioManager.sfx_confirm()
	show_toast("释放大招！")
	var mult := 1.0 + _atk_mult
	# 大招吃双倍武器加成（名器爽感）
	var wpn := float(CharacterService.player_weapon_attack())
	_director.player_ultimate((randf_range(48.0, 72.0) + wpn * 2.0) * mult)


func _on_command_charge() -> void:
	if _phase != Phase.FIGHTING:
		return
	AudioManager.sfx_click()
	_director.command_charge()
	show_toast("全军突击")


func _on_command_hold() -> void:
	if _phase != Phase.FIGHTING:
		return
	AudioManager.sfx_click()
	_director.command_hold()
	show_toast("全军固守")


func _nearest_enemy_dist() -> float:
	var best := INF
	for u in _director._enemies:
		if u.is_gone() or u.is_routed():
			continue
		best = minf(best, _player.position.distance_to(u.position))
	return best


## ---------- 结算 ----------

func _on_battle_finished(win: bool, summary: Dictionary) -> void:
	if _phase == Phase.RESULT:
		return
	_phase = Phase.RESULT
	_director.stop()

	# 演武场模式：只出结果，不结算奖励/惩罚，不动存档
	if GameState.drill_mode:
		_on_drill_finished(win, summary)
		return

	var lost_ratio := 0.0
	if int(summary["ally_initial"]) > 0:
		lost_ratio = 1.0 - float(summary["ally_alive"]) / float(summary["ally_initial"])

	if win:
		GameState.battle_win_count += 1
		var exp_gain := randi_range(60, 130) + int(summary["kills"]) * 12
		var gold_gain := randi_range(90, 210) + int(summary["kills"]) * 18
		GameState.player_exp += exp_gain
		GameState.add_gold(gold_gain)
		var cap_msg := _try_capture()
		_result_label.text = "胜  利\n\n歼敌 %d 队　敌溃散 %d 队\n我军折损 %d 队\n\n获得经验 %d\n获得金钱 %d%s" % [
			int(summary["kills"]), int(summary["routs"]),
			int(summary["losses"]), exp_gain, gold_gain,
			cap_msg,
		]
	else:
		# 败北：损失部分兵力（按折损比例）
		_apply_defeat_penalty(summary)
		_result_label.text = "败  北\n\n我军折损 %d 队\n残余兵力 %d\n\n部队撤退，损失部分兵力" % [
			int(summary["losses"]), int(summary["ally_troops"]),
		]
	_result_panel.visible = true
	EventBus.battle_ended.emit({"win": win, "summary": summary})


## 胜利后尝试俘虏敌将。返回战报追加文本（无俘虏返回空串）
func _try_capture() -> String:
	var enc: Dictionary = GameState.current_encounter
	var boss_id := str(enc.get("boss_hero_id", ""))
	if boss_id.is_empty():
		return ""
	# 已在队伍或已在监牢则不再俘
	if GameState.has_hero(boss_id) or GameState.has_prisoner(boss_id):
		return ""
	var charm := int(GameState.player_stats.get("charisma", 10))
	var rate := PrisonerService.capture_rate(charm)
	if randf() > rate:
		return ""
	var hero := DataManager.get_hero_resolved(boss_id)
	var hname := str(hero.get("name", boss_id)) if not hero.is_empty() else boss_id
	if not GameState.add_prisoner(boss_id):
		return ""
	EventBus.prisoner_captured.emit(boss_id)
	return "\n\n俘虏了 %s！可在酒馆监牢中招降或处死。" % hname


## 败北扣减存档中的兵力
func _apply_defeat_penalty(summary: Dictionary) -> void:
	if GameState.troops.is_empty():
		return
	var keep_ratio := clampf(float(summary["ally_troops"]) / maxf(1.0, float(_total_troop_count())), 0.25, 1.0)
	for t in GameState.troops:
		t["count"] = maxi(10, int(int(t.get("count", 0)) * keep_ratio))
	EventBus.troop_changed.emit(GameState.get_total_troops())


## ---------- 演武场结算（M5） ----------
## 演练无奖励、无惩罚、不写存档，只输出推演结论，供玩家复盘布阵。

func _on_drill_finished(win: bool, summary: Dictionary) -> void:
	GameState.battle_count += 1
	var drill_id := str(GameState.current_encounter.get("id", ""))
	var drill := DataManager.get_drill(drill_id)
	var drill_name := str(drill.get("name", "演武"))

	GameState.last_drill_result = {
		"drill_id": drill_id,
		"win": win,
		"summary": summary,
	}

	var head := "%s · 推演结束\n\n" % drill_name
	if win:
		head += "推演结果：胜\n"
	else:
		head += "推演结果：败\n"
	head += "歼敌 %d 队　敌溃散 %d 队\n" % [int(summary["kills"]), int(summary["routs"])]
	head += "我军折损 %d 队　残余兵力 %d\n\n" % [int(summary["losses"]), int(summary["ally_troops"])]
	head += "（演武不消耗兵力，无奖励）"
	_result_label.text = head
	_result_panel.visible = true
	EventBus.drill_finished.emit(drill_id, GameState.last_drill_result)
	EventBus.battle_ended.emit({"win": win, "summary": summary, "drill": true})


func _total_troop_count() -> int:
	var n := 0
	for t in GameState.troops:
		n += int(t.get("count", 0))
	return n


func _on_retreat() -> void:
	if _phase != Phase.FIGHTING:
		return
	AudioManager.sfx_cancel()
	_director.force_end(false)


func _on_result_ok() -> void:
	AudioManager.sfx_confirm()
	# 演武场：返回布阵界面继续试摆，保留演练标记与假想敌配置
	if GameState.drill_mode:
		SceneRouter.back()
		return
	GameState.current_encounter = {}
	SaveManager.auto_save()
	SceneRouter.back()


## ---------- UI 辅助 ----------

func _update_bars() -> void:
	_hp_bar.max_value = _player_hp_max
	_hp_bar.value = _player_hp
	_morale_bar.value = _morale
	_rage_bar.value = _rage


func _push_log(text: String) -> void:
	_log_lines.append(text)
	while _log_lines.size() > 4:
		_log_lines.pop_front()
	_log_label.text = "\n".join(PackedStringArray(_log_lines))


func _flash(node: Node2D) -> void:
	var tween := create_tween()
	tween.tween_property(node, "modulate", Color(1.6, 1.6, 1.6), 0.05)
	tween.tween_property(node, "modulate", Color(1, 1, 1), 0.1)


func show_toast(message: String) -> void:
	_toast.text = message
	_toast.modulate.a = 1.0
	if _toast_tween and _toast_tween.is_valid():
		_toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_interval(1.5)
	_toast_tween.tween_property(_toast, "modulate:a", 0.0, 0.4)


func _on_joystick_changed(_v: Vector2) -> void:
	pass
