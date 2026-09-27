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
## 主角 6 槽装备（含强化等级）战场加成【H 修复】：此前只有 weapon1 经
## player_weapon_attack() 生效，护甲/头盔/宝物/坐骑全是死数据。
var _eq_hp := 0.0          ## 血量上限加成（护甲/宝物）
var _eq_def := 0.0         ## 近身削血减免（护甲/头盔/宝物防御值）
var _eq_atk := 0.0         ## 非武器攻击加成（武盔/宝物），weapon1 已单独计入故扣除
var _eq_spd_mult := 1.0    ## 坐骑速度倍率（收益递减封顶）
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
	_setup_background()
	_phase = Phase.PREPARE
	_calc.ensure_loaded()
	# 主角装备接入战场（H 修复）：with_levels 计入铁匠铺强化等级。
	# weapon1 攻击已由 player_weapon_attack() 单独取数，此处扣回避免双计。
	var eq := CharacterService.equipment_bonuses(GameState.equipment, true)
	_eq_hp = float(eq["hp"])
	_eq_def = float(eq["defense"])
	_eq_atk = maxf(0.0, float(eq["attack"]) - float(CharacterService.player_weapon_attack()))
	_eq_spd_mult = 1.0 + minf(0.25, float(eq["speed"]) * 0.005)
	_player_hp_max = 100.0 + _eq_hp
	_player_hp = _player_hp_max

	_joystick.changed.connect(_on_joystick_changed)
	_btn_attack.pressed.connect(_on_attack)
	_btn_dodge.pressed.connect(_on_dodge)
	_btn_skill.pressed.connect(_on_skill)
	_btn_charge.pressed.connect(_on_command_charge)
	_btn_hold.pressed.connect(_on_command_hold)
	_btn_retreat.pressed.connect(_on_retreat)
	_btn_result_ok.pressed.connect(_on_result_ok)

	_result_panel.visible = false
	# toast 由全局 ToastLayer autoload 统一消费（B2/B4/B11 一揽子修复），本地不再重复连接
	_build_talent_button()
	_duel_popup = DuelPopup.create()
	$UI.add_child(_duel_popup)
	_duel_popup.duel_finished.connect(_on_duel_finished)
	_setup_feel()
	await _setup_battle()


## ---------- 建立战场 ----------

## 随机战场背景图（battle_bg_1..5，AI 全景水墨古战场）
const BATTLE_BG_COUNT := 5


func _setup_background() -> void:
	# 【R3-12】遭遇表可选 battle_bg 字段（1..5）语义锁图；未配置则随机铺一张。
	# 加载失败（未导入/缺文件）时保留纯色兜底
	var idx := int(GameState.current_encounter.get("battle_bg", 0))
	if idx < 1 or idx > BATTLE_BG_COUNT:
		idx = randi_range(1, BATTLE_BG_COUNT)
	var tex: Texture2D = load("res://assets/sprites/battle/battle_bg_%d.png" % idx)
	if tex == null:
		return
	var tr := TextureRect.new()
	tr.name = "BattleBg"
	tr.texture = tex
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	tr.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	tr.modulate = Color(0.85, 0.85, 0.85)   # 轻压亮度，保证上层 UI 与单位可读
	add_child(tr)
	move_child(tr, 1)   # 插在 Background(0) 与 GroundLine(1) 之间
	# 有图时地面线调淡为若隐若现的分界，避免生硬色块压住画面下部
	($GroundLine as ColorRect).modulate.a = 0.35
	# 【R3-08】渐晕治理：顶/底 160px 黑渐变带压住背景上下边缘，
	# 消除「四角与中央等亮」的平贴感，画面重心收向中轴
	for top_edge: bool in [true, false]:
		var g := Gradient.new()
		g.offsets = PackedFloat32Array([0.0, 1.0])
		g.colors = PackedColorArray([
			Color(0.0, 0.0, 0.0, 0.0), Color(0.0, 0.0, 0.0, 0.55),
		]) if top_edge else PackedColorArray([
			Color(0.0, 0.0, 0.0, 0.55), Color(0.0, 0.0, 0.0, 0.0),
		])
		var gt := GradientTexture2D.new()
		gt.gradient = g
		gt.fill_from = Vector2(0.0, 0.0)
		gt.fill_to = Vector2(0.0, 1.0)
		gt.width = 1920
		gt.height = 160
		var band := TextureRect.new()
		band.name = "VignetteTop" if top_edge else "VignetteBottom"
		band.texture = gt
		band.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		band.stretch_mode = TextureRect.STRETCH_SCALE
		band.set_anchors_and_offsets_preset(
			Control.PRESET_TOP_WIDE if top_edge else Control.PRESET_BOTTOM_WIDE)
		if top_edge:
			band.offset_bottom = 160.0
		else:
			band.offset_top = -160.0
		add_child(band)
		move_child(band, 2)   # 紧随 BattleBg（1）之后、GroundLine 之前


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
			b.custom_minimum_size = Vector2(250, UITheme.TOUCH_H)   ## 【触控铁律】50→84
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
			sb.custom_minimum_size = Vector2(800, UITheme.TOUCH_H)   ## 【触控铁律】46→84
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
	btn_duel.custom_minimum_size = Vector2(220, UITheme.TOUCH_H)   ## 【触控铁律】60→84
	btn_duel.add_theme_font_size_override("font_size", 26)
	# 演练也能单挑：空阵演练走的正是单挑决战，不能在这里禁掉
	btn_duel.disabled = enemy.is_empty()
	btn_duel.pressed.connect(_on_start_duel)
	footer.add_child(btn_duel)
	_btn_duel = btn_duel
	if not solo:
		var btn_fight := Button.new()
		btn_fight.text = "即刻开战"
		btn_fight.custom_minimum_size = Vector2(220, UITheme.TOUCH_H)   ## 【触控铁律】60→84
		btn_fight.add_theme_font_size_override("font_size", 26)
		btn_fight.pressed.connect(_begin_battle)
		footer.add_child(btn_fight)

	# 【返回按钮】单挑结束回到此面板时「出阵单挑」已置灰，给一个明确的离开出口，
	# 避免「赢了单挑却卡在决断界面没有返回」的观感。始终显示（solo/非 solo 都可退场）。
	var btn_back := Button.new()
	btn_back.text = "返  回"
	btn_back.custom_minimum_size = Vector2(180, UITheme.TOUCH_H)   ## 【触控铁律】60→84
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
	# 放弃的遭遇一并清掉：留着的话下次触发新遭遇前的任何读取
	#（布阵敌情显示等）都会拿到陈旧的上一场配置。
	# 演武除外——回布阵界面还要用它显示假想敌，退出演武时由 formation_editor 清
	if not GameState.drill_mode:
		GameState.current_encounter = {}
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
		# 先收掉战前决断遮罩再进结算：overlay 是运行时追加在 $UI 末尾的全屏
		# STOP 层，画在 tscn 的 ResultPanel 之上——不收掉结算面板被它永久
		# 挡住，BtnOk 点不到，空阵单挑整条流程软锁
		if _prepare_overlay != null and is_instance_valid(_prepare_overlay):
			_prepare_overlay.queue_free()
			_prepare_overlay = null
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
			var dmg := (float(m["power"]) + (wpn + _eq_atk) * 0.5) * mult
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
		_player.position += mv * PLAYER_SPEED * _eq_spd_mult * delta
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
	var base_dps := 9.0 * (1.0 - clampf(_def_mult, -0.5, 0.9))
	# 护甲减免（H 修复）：防御绝对值 → 减伤系数 100/(100+def)，收益递减有界
	var dps := base_dps * 100.0 / (100.0 + _eq_def)
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
	# 敌方血条 = 敌方存活队数占比（含兵力的加权式从未生效，删）
	var enc_total := maxf(1.0, float(_director._initial_enemy_count))
	_enemy_hp_bar.max_value = 100.0
	_enemy_hp_bar.value = clampf(float(sit["enemy_alive"]) / enc_total * 100.0, 0.0, 100.0)
	_update_bars()


## ---------- 玩家操作 ----------

func _on_attack() -> void:
	if _phase != Phase.FIGHTING or _attack_cooldown > 0.0:
		return
	_attack_cooldown = 0.32
	_rage = minf(100.0, _rage + 8.0)
	# 只打得到附近敌人时才算命中（离最近敌军 260px 内）
	var reach := 260.0
	var front := _nearest_enemy_dist()
	var mult := 1.0 + _atk_mult
	# 基础伤害 + 主武器攻击绝对值（装备生效）+ 武盔/宝物攻击加成（H 修复）
	var dmg := (randf_range(14.0, 24.0) + float(CharacterService.player_weapon_attack()) + _eq_atk) * mult
	if front > reach:
		show_toast("距离过远，未能命中")
		return
	# 打击音移到命中判定后：挥空不再出兵刃声（音画一致）
	AudioManager.sfx_hit()
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
	# 大招专用音（唢呐扬起+大鼓），替换语义错位的确认弹窗音
	AudioManager.play_sfx("res://assets/audio/sfx/battle_skill.ogg")
	show_toast("释放大招！")
	var mult := 1.0 + _atk_mult
	# 大招吃双倍武器加成（名器爽感）
	var wpn := float(CharacterService.player_weapon_attack())
	_director.player_ultimate((randf_range(48.0, 72.0) + (wpn + _eq_atk) * 2.0) * mult)
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

## 【M-4 修复】遭遇战分出胜负后才写「已解决」：胜利=永久解决（不再重生）；
## 战败=记绝对游戏日，当日封锁（防原地死循环），次日 EncounterManager
## 判定过期后原地复活可再战。_enc_id 由触发时注入 def 副本，剧本战/城内战
## 无此键不写。
func _note_encounter_resolved(win: bool) -> void:
	var enc_id := str(GameState.current_encounter.get("_enc_id", ""))
	if enc_id.is_empty():
		return
	# 胜利 → 永久解决；战败 → 记绝对游戏日（当日封锁，次日复活）
	# 注意：此函数排在大战斗结算之前，勿写成与结算块相同的胜负分支字面
	# 结构——_verify_m6 按首个该结构切源码做静态断言，会切到此函数。
	var resolved_value: Variant = true
	if not win:
		resolved_value = GameState.total_days()
	GameState.encounter_resolved[enc_id] = resolved_value


func _on_battle_finished(win: bool, summary: Dictionary) -> void:
	if _phase == Phase.RESULT:
		return
	_phase = Phase.RESULT
	_director.stop()

	# 演武场模式：只出结果，不结算奖励/惩罚，不动存档
	if GameState.drill_mode:
		_on_drill_finished(win, summary)
		return

	# 【M-4 修复】遭遇战分出胜负后才写「已解决」（原实现在触发时就写：
	# 战败/撤退也永久移除遭遇）。胜利=永久解决；战败=仅当日封锁、次日
	# 复活可再战。_enc_id 由 EncounterManager 触发时注入 def 副本，
	# 剧本战/城内战无此键不受影响。
	_note_encounter_resolved(win)

	if win:
		GameState.battle_win_count += 1
		# 胜利短曲 one-shot（走 SFX bus 叠在 BGM 上，不切曲；【音频三批】升格完整胜利乐句）
		AudioManager.play_sfx("res://assets/audio/sfx/victory.ogg")
		# 任务系统记账：battle 目标取遭遇表 quest_target（无则用遭遇 id）
		var qtarget := str(GameState.current_encounter.get("quest_target",
			GameState.current_encounter.get("id", "")))
		if not qtarget.is_empty():
			QuestService.record_event("battle", qtarget)
		# 主线记账（mainline_service.gd）：黄巾残党清剿 / 张角决战第一章结算
		MainlineService.on_battle_win(qtarget)
		# 【P0-2 审计修复】胜利也结转战场折损（下限 50%）——补兵成为常态经济循环
		var attrition := BattleRewardService.apply_attrition(summary, _total_troop_count(), 0.5)
		if attrition < 1.0:
			EventBus.troop_changed.emit(GameState.get_total_troops())
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
		_result_label.text = "胜  利\n\n歼敌 %d 队　敌溃散 %d 队\n我军折损 %d 队　残存兵力 %d\n\n获得经验 %d\n获得金钱 %d%s%s" % [
			int(summary["kills"]), int(summary["routs"]),
			int(summary["losses"]), GameState.get_total_troops(),
			exp_gain, gold_gain,
			extra, cap_msg,
		]
	else:
		# 败北：损失部分兵力（按折损比例）；低锣+下行拨弦沉痛收束
		AudioManager.play_sfx("res://assets/audio/sfx/battle_lose.ogg")
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


## 败北扣减存档兵力——统一走规则层（胜利同源结转见 apply_attrition，下限 25%）
func _apply_defeat_penalty(summary: Dictionary) -> void:
	var keep := BattleRewardService.apply_attrition(summary, _total_troop_count(), 0.25)
	if keep < 1.0:
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
	EventBus.show_toast(message)   # 统一走全局 ToastLayer（横排 + 3~5 秒，2026-09-27）


func _on_joystick_changed(_v: Vector2) -> void:
	pass
