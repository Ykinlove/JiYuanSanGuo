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
## 闪避：无敌帧时长 + 冷却（无冷却则连点即永久无敌）
const DODGE_INVULN := 0.6
const DODGE_COOLDOWN := 1.2

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
var _dodge_cooldown := 0.0

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

## 战前决断 / 单挑（M7-D）
var _prepare_overlay: Control
var _duel_popup: DuelPopup
var _enc_cfg: Dictionary = {}
var _champ_id := DuelService.PLAYER_ID
var _champ_buttons: Dictionary = {}
var _skill_buttons: Dictionary = {}
var _duel_outcome := ""
## 单挑名声已结算标记：战前可反复点「出阵单挑」，若每次都发名声即可无限刷
var _duel_fame_paid := false
## 「出阵单挑」按钮引用：单挑打过一次就禁用 —— 旧版单挑结束后按钮仍可点，
## 玩家（尤其是失利后）可以无限重开单挑，观感就是「失败后不退出、一直循环单挑」。
var _btn_duel: Button
var _btn_talent: Button
var _talent_cd := 0.0

## 打击感（M16 系统优化）：顿帧 + 震屏
var _cam: Camera2D
## 顿帧截止时刻（真实时钟毫秒）。用真实时钟而非 delta，避免 time_scale 被压到
## 极低时 delta 也随之趋零、倒计时永不推进导致 time_scale 卡死（全局顿帧不再恢复）。
var _hitstop_end_ms := 0
var _shake_tween: Tween


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
	_build_talent_button()
	_duel_popup = DuelPopup.create()
	$UI.add_child(_duel_popup)
	_duel_popup.duel_finished.connect(_on_duel_finished)
	_setup_feel()
	await _setup_battle()


## ---------- 建立战场 ----------

func _setup_battle() -> void:
	# 演练（演武场）不写存档：不参与战斗次数统计，否则读档后统计口径被演练污染
	if not GameState.drill_mode:
		GameState.battle_count += 1

	# 1. 布阵加成
	_apply_formation()

	# 2. 建总指挥
	_director = BattleDirector.new()
	add_child(_director)
	_director.setup(_load_combat_cfg(), _ally_units, _enemy_units)
	_director.battle_finished.connect(_on_battle_finished)
	_director.log_event.connect(_push_log)

	# 3. 摆我军（敌军在战前决断结束、单挑结算后再布置）
	_director.deploy_allies(_deployed, GameState.troops)

	_enc_cfg = (GameState.current_encounter as Dictionary).duplicate(true)
	if _enc_cfg.is_empty():
		_enc_cfg = {}
	else:
		_enemy_name = str(_enc_cfg.get("name", "敌军"))

	# 4. 主角外观
	_build_player_visual()

	# 5. 战前决断（单挑 / 个人技），玩家点"开战"后才布置敌军并开打
	_update_bars()
	_open_prepare()


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


## ---------- 打击感（M16 系统优化） ----------

## 建立震屏相机：FIXED_TOP_LEFT + 位置(0,0) 与「无相机」视图完全一致，
## 只用 offset 做瞬时位移，确保不改变原有战场取景。
func _setup_feel() -> void:
	if _cam != null and is_instance_valid(_cam):
		return
	_cam = Camera2D.new()
	_cam.anchor_mode = Camera2D.ANCHOR_MODE_FIXED_TOP_LEFT
	_cam.position = Vector2.ZERO
	_cam.offset = Vector2.ZERO
	add_child(_cam)
	_cam.make_current()


## 命中反馈：按档位施加顿帧 + 震屏（参数出自 CombatFeelService，场景不内联数值）
func _feedback(kind: String) -> void:
	if _phase != Phase.FIGHTING:
		return
	var fb := CombatFeelService.feedback(kind)
	var stop := float(fb["hitstop"])
	if stop > 0.0:
		# 下限 0.05：time_scale 一旦为 0 即等于暂停，会拖慢顿帧倒计时且手感全失
		Engine.time_scale = clampf(float(fb["time_scale"]), 0.05, 1.0)
		_hitstop_end_ms = maxi(_hitstop_end_ms, Time.get_ticks_msec() + int(stop * 1000.0))
	_shake(float(fb["shake"]))


## 震屏：相机 offset 快速抖动后归零
func _shake(amount: float) -> void:
	if _cam == null or not is_instance_valid(_cam) or amount <= 0.0:
		return
	if _shake_tween and _shake_tween.is_valid():
		_shake_tween.kill()
	_shake_tween = create_tween()
	var steps := 4
	for i in range(steps):
		var decay := amount * (1.0 - float(i) / float(steps))
		var off := Vector2(randf_range(-decay, decay), randf_range(-decay, decay))
		_shake_tween.tween_property(_cam, "offset", off, 0.03)
	_shake_tween.tween_property(_cam, "offset", Vector2.ZERO, 0.05)


## 顿帧判定：以真实时钟为准（不依赖被 time_scale 缩放的 delta），
## 保证无论慢放到什么程度都能如期还原 time_scale。
func _tick_hitstop(_delta: float) -> void:
	if _hitstop_end_ms <= 0:
		return
	if Time.get_ticks_msec() < _hitstop_end_ms:
		return
	_hitstop_end_ms = 0
	Engine.time_scale = 1.0


func _exit_tree() -> void:
	# 兜底：离开战斗必须还原时间缩放，否则全局卡慢（M17 稳定性）
	Engine.time_scale = 1.0


## ---------- 战前决断（M7-D） ----------

func _open_prepare() -> void:
	_champ_id = DuelService.PLAYER_ID
	_duel_outcome = ""
	_champ_buttons.clear()
	_skill_buttons.clear()

	var overlay := Control.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	$UI.add_child(overlay)
	_prepare_overlay = overlay

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.02, 0.03, 0.7)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(dim)

	var panel := Panel.new()
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.offset_left = -430.0
	panel.offset_right = 430.0
	panel.offset_top = -360.0
	panel.offset_bottom = 360.0
	panel.self_modulate = Color(0.07, 0.06, 0.05, 0.98)
	overlay.add_child(panel)

	var box := VBoxContainer.new()
	box.position = Vector2(30, 22)
	box.size = Vector2(800, 676)
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)

	var enemy := DuelService.enemy_of_encounter(_enc_cfg)
	# 【C3 空阵 1v1】没布任何部队且敌阵有将时，这一战就只有一场单挑。
	var solo := GameState.duel_only and not enemy.is_empty()
	if GameState.duel_only and enemy.is_empty():
		# 敌阵无将可挑 → 无法走单挑决战，退回常规流程（并告知玩家）
		GameState.duel_only = false

	var title := Label.new()
	title.text = "孤身赴敌" if solo else "战前决断"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 32)
	box.add_child(title)

	var info := Label.new()
	info.add_theme_font_size_override("font_size", 21)
	info.modulate = Color(0.9, 0.82, 0.6)
	if solo:
		info.text = "遭遇：%s　·　你未率一兵一卒，此战胜负系于阵前这一场单挑。" % _enemy_name
	elif enemy.is_empty():
		info.text = "遭遇：%s　（敌阵无将，不可单挑）你将亲自持械上阵，以一当千。" % _enemy_name
	else:
		info.text = "遭遇：%s　·　敌将【%s】（武勇 %d）阵前搦战！胜则敌军折锐、我军夺气。" % [
			_enemy_name, str(enemy["name"]), int(enemy["force"])]
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.custom_minimum_size = Vector2(800, 56)
	box.add_child(info)

	if solo:
		box.add_child(_mk_section_label("一、无兵可调"))
		var solo_hint := Label.new()
		solo_hint.text = "胜负全凭一身武艺 —— 猛攻克佯攻、佯攻克稳守、稳守克猛攻。"
		solo_hint.add_theme_font_size_override("font_size", 20)
		solo_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		solo_hint.modulate = Color(0.75, 0.82, 0.95)
		solo_hint.custom_minimum_size = Vector2(800, 40)
		box.add_child(solo_hint)
	else:
		box.add_child(_mk_section_label("一、点将出阵（单挑用）"))
		var champ_grid := GridContainer.new()
		champ_grid.columns = 3
		champ_grid.add_theme_constant_override("h_separation", 8)
		champ_grid.add_theme_constant_override("v_separation", 8)
		for c in DuelService.champions():
			var b := Button.new()
			b.custom_minimum_size = Vector2(250, 50)
			b.add_theme_font_size_override("font_size", 20)
			b.text = "%s（武 %d）" % [str(c["name"]), int(c["force"])]
			b.pressed.connect(_on_pick_champ.bind(str(c["id"])))
			champ_grid.add_child(b)
			_champ_buttons[str(c["id"])] = b
		box.add_child(champ_grid)

		box.add_child(_mk_section_label("二、装配个人技（战场可释放，冷却制）"))
		var skill_box := VBoxContainer.new()
		skill_box.add_theme_constant_override("separation", 6)
		for sid in SkillService.available_personal_skills():
			var m: Dictionary = SkillService.personal_meta(sid)
			var sb := Button.new()
			sb.custom_minimum_size = Vector2(800, 46)
			sb.add_theme_font_size_override("font_size", 19)
			sb.text = "%s（%d 秒冷却）　%s" % [str(m["name"]), int(round(float(m["cooldown"]))), str(m["desc"])]
			sb.pressed.connect(_on_pick_skill.bind(sid))
			skill_box.add_child(sb)
			_skill_buttons[sid] = sb
		box.add_child(skill_box)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(spacer)

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 16)
	footer.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(footer)
	var btn_duel := Button.new()
	btn_duel.text = "出阵单挑"
	btn_duel.custom_minimum_size = Vector2(220, 60)
	btn_duel.add_theme_font_size_override("font_size", 26)
	# 演练也能单挑：空阵演练走的正是单挑决战，不能在这里禁掉
	btn_duel.disabled = enemy.is_empty()
	btn_duel.pressed.connect(_on_start_duel)
	footer.add_child(btn_duel)
	_btn_duel = btn_duel
	if not solo:
		var btn_fight := Button.new()
		btn_fight.text = "即刻开战"
		btn_fight.custom_minimum_size = Vector2(220, 60)
		btn_fight.add_theme_font_size_override("font_size", 26)
		btn_fight.pressed.connect(_begin_battle)
		footer.add_child(btn_fight)

	# 【返回按钮】单挑结束回到此面板时「出阵单挑」已置灰，给一个明确的离开出口，
	# 避免「赢了单挑却卡在决断界面没有返回」的观感。始终显示（solo/非 solo 都可退场）。
	var btn_back := Button.new()
	btn_back.text = "返  回"
	btn_back.custom_minimum_size = Vector2(180, 60)
	btn_back.add_theme_font_size_override("font_size", 26)
	btn_back.pressed.connect(_on_prepare_return)
	footer.add_child(btn_back)

	_refresh_prepare_selection()


func _mk_section_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 22)
	l.modulate = Color(0.75, 0.82, 0.95)
	return l


func _refresh_prepare_selection() -> void:
	for cid in _champ_buttons:
		var b: Button = _champ_buttons[cid]
		b.text = b.text.trim_prefix("● ")
		if str(cid) == _champ_id:
			b.text = "● " + b.text
	for sid in _skill_buttons:
		var sb: Button = _skill_buttons[sid]
		sb.disabled = int(sid) == GameState.personal_skill


## 决断界面「返回」：放弃本场遭遇，回到大地图
func _on_prepare_return() -> void:
	AudioManager.sfx_cancel()
	GameState.duel_only = false
	if _prepare_overlay != null and is_instance_valid(_prepare_overlay):
		_prepare_overlay.queue_free()
		_prepare_overlay = null
	SceneRouter.back()


func _on_pick_champ(cid: String) -> void:
	AudioManager.sfx_click()
	_champ_id = cid
	_refresh_prepare_selection()


func _on_pick_skill(sid: int) -> void:
	if not SkillService.is_personal_skill(sid):
		return
	AudioManager.sfx_click()
	GameState.personal_skill = sid
	_refresh_prepare_selection()
	_refresh_talent_button()


func _on_start_duel() -> void:
	var champ := DuelService.champion_by_id(_champ_id)
	var enemy := DuelService.enemy_of_encounter(_enc_cfg)
	if champ.is_empty() or enemy.is_empty():
		show_toast("无法单挑")
		return
	AudioManager.sfx_confirm()
	_duel_popup.get_parent().move_child(_duel_popup, -1)
	_duel_popup.open(champ, enemy)


func _on_duel_finished(outcome: String) -> void:
	_duel_outcome = outcome
	# 【每场限一次】单挑已分胜负：禁用「出阵单挑」，防反复重开单挑刷结果
	if _btn_duel != null and is_instance_valid(_btn_duel):
		_btn_duel.disabled = true
	var effects := DuelService.battle_effects(outcome)
	# 演武演练不写存档：不发名声；同一场战斗只结算一次，避免反复单挑刷名声
	var award := not GameState.drill_mode and not _duel_fame_paid
	if award:
		_duel_fame_paid = true
		DuelService.apply_fame(effects)

	# 【C3 空阵 1v1】单挑即决战：胜负直接定下整场遭遇的结果，不再摆兵力对冲。
	if GameState.duel_only:
		GameState.duel_only = false
		var win := (outcome == "win")
		_director.stop()
		_on_battle_finished(win, {
			"ally_initial": 0, "ally_alive": 0, "ally_troops": 0,
			"enemy_initial": 0, "enemy_alive": 0,
			"kills": 0, "routs": 0, "losses": 0, "win": win,
		})
		return

	match outcome:
		"win":
			show_toast("单挑获胜！敌军折锐，我军夺气（名声 +%d）" % int(effects["fame"]))
		"lose":
			show_toast("单挑失利，主角带伤上阵")
		_:
			show_toast("单挑平手，各自归阵")


func _begin_battle() -> void:
	AudioManager.sfx_confirm()
	# 应用单挑战果
	var effects := DuelService.battle_effects(_duel_outcome)
	var scale := float(effects.get("enemy_count_scale", 1.0))
	if scale != 1.0:
		for u in _enc_cfg.get("enemy_units", []):
			u["count"] = maxi(10, int(round(int(u.get("count", 60)) * scale)))
	_director.deploy_enemies(_enc_cfg)

	_player_hp = _player_hp_max * float(effects.get("player_hp_scale", 1.0))
	_rage = float(effects.get("start_rage", 0.0))
	_update_bars()

	if is_instance_valid(_prepare_overlay):
		_prepare_overlay.queue_free()
	_prepare_overlay = null

	var msg := "开战！" if _duel_outcome.is_empty() else "单挑已决，全军出击！"
	if not _formation_name.is_empty():
		msg += "（布阵「%s」）" % _formation_name
	show_toast(msg)
	_phase = Phase.FIGHTING
	_director.start()
	_push_log("两军交锋")


## ---------- 战场个人技按钮（M7-D） ----------

func _build_talent_button() -> void:
	_btn_talent = Button.new()
	_btn_talent.custom_minimum_size = Vector2(150, 100)
	_btn_talent.add_theme_font_size_override("font_size", 28)
	_btn_talent.pressed.connect(_on_talent)
	$UI/ActionButtons.add_child(_btn_talent)
	$UI/ActionButtons.move_child(_btn_talent, 0)
	_refresh_talent_button()


func _refresh_talent_button() -> void:
	if _btn_talent == null:
		return
	var m: Dictionary = SkillService.personal_meta(GameState.personal_skill)
	if m.is_empty():
		_btn_talent.text = "个人技"
		_btn_talent.disabled = true
		return
	_btn_talent.text = str(m["name"])
	_btn_talent.disabled = _phase != Phase.FIGHTING or _talent_cd > 0.0


func _tick_talent_button(delta: float) -> void:
	if _btn_talent == null:
		return
	if _talent_cd > 0.0:
		_talent_cd = maxf(0.0, _talent_cd - delta)
		var m: Dictionary = SkillService.personal_meta(GameState.personal_skill)
		if _talent_cd > 0.0:
			_btn_talent.text = "%.0f" % ceil(_talent_cd)
		else:
			_refresh_talent_button()
	elif _btn_talent.disabled and _phase == Phase.FIGHTING:
		_refresh_talent_button()


func _on_talent() -> void:
	if _phase != Phase.FIGHTING or _talent_cd > 0.0:
		return
	var m: Dictionary = SkillService.personal_meta(GameState.personal_skill)
	if m.is_empty():
		return
	_talent_cd = float(m["cooldown"])
	AudioManager.sfx_confirm()
	var mult := 1.0 + _atk_mult
	var wpn := float(CharacterService.player_weapon_attack())
	match str(m["kind"]):
		SkillService.PERSONAL_KIND_DAMAGE:
			var dmg := (float(m["power"]) + wpn * 0.5) * mult
			if bool(m["aoe"]):
				_director.player_ultimate(dmg)
				_feedback(CombatFeelService.KIND_ULTIMATE)
			else:
				_director.player_strike(dmg)
				_feedback(CombatFeelService.KIND_HEAVY)
			_flash(_player)
		SkillService.PERSONAL_KIND_SHIELD:
			_player_invuln = maxf(_player_invuln, float(m["power"]))
		SkillService.PERSONAL_KIND_HEAL:
			_player_hp = minf(_player_hp_max, _player_hp + float(m["power"]))
			_update_bars()
	show_toast("个人技·%s" % str(m["name"]))
	_refresh_talent_button()


## ---------- 主循环 ----------

func _process(delta: float) -> void:
	if _phase == Phase.FIGHTING:
		_drive_player(delta)
		_director.process_delta(delta)
		_refresh_hud()
	elif _phase == Phase.PREPARE:
		# 准备阶段也跑一下，让部队站位稳定
		pass
	_tick_talent_button(delta)
	_tick_hitstop(delta)


func _drive_player(delta: float) -> void:
	var mv := _joystick.output
	if mv.length() > 0.05:
		_player.position += mv * PLAYER_SPEED * delta
	_player.position.x = clampf(_player.position.x, 60.0, 1860.0)
	_player.position.y = clampf(_player.position.y, PLAYER_BOUNDS_TOP, PLAYER_BOUNDS_BOTTOM)

	_attack_cooldown = maxf(0.0, _attack_cooldown - delta)
	_player_invuln = maxf(0.0, _player_invuln - delta)
	_dodge_cooldown = maxf(0.0, _dodge_cooldown - delta)
	_rage = minf(100.0, _rage + delta * 4.5)
	_apply_contact_damage(delta)


## 近身敌兵对主角的削血（护体/闪避/回春个人技因此有意义）。
## 130px 内最近的存活敌队持续造成伤害；布阵防御加成可减免。
func _apply_contact_damage(delta: float) -> void:
	if _player_invuln > 0.0:
		return
	var best := INF
	for u in _director._enemies:
		if u.is_gone() or u.is_routed():
			continue
		best = minf(best, _player.position.distance_to(u.position))
	if best > 130.0:
		return
	var dps := 9.0 * (1.0 - clampf(_def_mult, -0.5, 0.9))
	_player_hp -= dps * delta
	if _player_hp <= 0.0:
		# 挂彩后撤：不直接判负，回血喘息并短暂无敌
		_player_hp = 40.0
		_player_invuln = 2.0
		_rage = maxf(0.0, _rage - 30.0)
		show_toast("身负重伤，暂退阵中！")
	_update_bars()


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
	_feedback(CombatFeelService.KIND_LIGHT)


func _on_dodge() -> void:
	if _phase != Phase.FIGHTING or _dodge_cooldown > 0.0:
		return
	AudioManager.sfx_click()
	_rage = minf(100.0, _rage + 4.0)
	_player_invuln = DODGE_INVULN
	_dodge_cooldown = DODGE_COOLDOWN
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
	_feedback(CombatFeelService.KIND_ULTIMATE)


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
		# 任务系统记账：battle 目标取遭遇表 quest_target（无则用遭遇 id）
		var qtarget := str(GameState.current_encounter.get("quest_target",
			GameState.current_encounter.get("id", "")))
		if not qtarget.is_empty():
			QuestService.record_event("battle", qtarget)
		# 主线记账（mainline_service.gd）：黄巾残党清剿 / 张角决战第一章结算
		MainlineService.on_battle_win(qtarget)
		# 奖励统一走规则层（基数 combat.json，遭遇表 rewards 覆盖）
		var reward := BattleRewardService.apply(GameState.current_encounter,
			int(summary["kills"]), int(summary["routs"]))
		var exp_gain := int(reward["exp"])
		var gold_gain := int(reward["gold"])
		var cap_msg := _try_capture()
		var extra := ""
		if int(reward["fame"]) > 0:
			extra += "\n名声 +%d" % int(reward["fame"])
		var mats: Array = reward.get("materials", [])
		if not mats.is_empty():
			var names: Array[String] = []
			for mid in mats:
				var mi := DataManager.get_item(str(mid))
				names.append(str(mi.get("name", mid)) if not mi.is_empty() else str(mid))
			extra += "\n缴获：%s" % "、".join(names)
		# 成就判定：本场胜利后统一扫描（胜场/兵力/金钱/名声/等级等）
		AchievementService.check_all()
		_result_label.text = "胜  利\n\n歼敌 %d 队　敌溃散 %d 队\n我军折损 %d 队\n\n获得经验 %d\n获得金钱 %d%s%s" % [
			int(summary["kills"]), int(summary["routs"]),
			int(summary["losses"]), exp_gain, gold_gain,
			extra, cap_msg,
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
