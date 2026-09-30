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
## 普攻冷却（原先是散在方法里的字面量 0.32，冷却遮罩要用到"总时长"才提出来）
const ATTACK_COOLDOWN := 0.32
## 大招怒气门槛（同样原先是字面量 50，按钮灰化要用）
const RAGE_SKILL_COST := 50.0

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
## 敌方血条当前值（0~100，由存活队数占比换算；血条平滑后不再直接写控件）
var _enemy_hp: float = 100.0
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
## 镜头推近特写用的独立 tween（与 _shake_tween 分别改 zoom/position 与 offset，互不打架）
var _cam_tween: Tween
## 战场氛围容器（地面扬尘 + 远景烟雾），插在背景与单位之间
var _atmos: Node2D = null
## 顿帧截止时刻（真实时钟毫秒）。用真实时钟而非 delta，避免 time_scale 被压到
## 极低时 delta 也随之趋零、倒计时永不推进导致 time_scale 卡死（全局顿帧不再恢复）。
var _hitstop_end_ms := 0
var _shake_tween: Tween
## 【战斗演出 2026-09-30】主角挥砍/大招的瞬时冲量（像素/秒），每帧衰减。
## 用冲量而不是 tween：_drive_player 每帧都在按摇杆改 position，
## tween 覆盖 position 会让"边走边砍"变成互相打断。
## 主角持续挨打的累计伤害与飘字节流（避免每帧刷一片数字）
var _hurt_accum := 0.0
var _hurt_pop_cd := 0.0

## 【HUD 平滑】目标值（_update_bars 只记账，_tick_bars 每帧逼近）
var _target_hp := 100.0
var _target_morale := 100.0
var _target_rage := 0.0
var _target_enemy := 300.0
## 掉血残影条（叠在血条下层的暗红条）与残血警示层
var _hp_ghost_bar: ProgressBar = null
var _low_hp_veil: ColorRect = null
var _ghost_hold := 0.0
var _warn_t := 0.0
## 【按钮冷却遮罩】Button -> ColorRect：普攻/闪避按下后的一层暗色，
## 高度按剩余冷却比例从下往上"退潮"，玩家一眼看出还要等多久。
var _cd_veils: Dictionary = {}
var _skill_ready_t := 0.0
## 【连斩】连续命中计数；中断窗口内没有新命中就清零。
## 军团战里主角一刀刀砍是唯一"亲手"的部分，给它一个成长中的数字，
## 比干巴巴的伤害飘字更能把人留在操作里。
var _combo := 0
var _combo_t := 0.0
var _combo_label: Label = null
var _combo_tween: Tween
## 【转场 2026-09-30】开场黑幕：切进战斗是硬切，先黑一下再淡出战场。
var _curtain: ColorRect = null
## 血条/敌血条上的数值文本（光有占比百分比读不出"还剩多少血"）
var _hp_text: Label = null
var _enemy_text: Label = null
var _morale_text: Label = null
var _rage_text: Label = null
var _enemy_alive_n := 0
var _enemy_total_n := 0


func _ready() -> void:
	AudioManager.play_bgm(CombatFeelService.bgm_prepare())
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
	_build_hud_extras()
	await _setup_battle()
	# 战场摆完再拉开黑幕：玩家看到的是"战场缓缓浮现"，而不是硬切
	_fade_from_black()


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

	# 战场氛围（地面扬尘 + 远景烟雾）：制造「战场在动」的纵深
	_build_battle_atmos()


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
	# 击杀特写：任一支部队被移出战场（阵亡/溃散）即给一次推近 + 短慢镜
	_director.unit_removed.connect(_on_unit_removed)

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
	# 【人物本体容器】行走动画只作用在本体（五边形 + 描边）上；
	# 名字标签留在外层，否则会跟着一起晃。
	var body_root := Node2D.new()
	body_root.name = "Body"
	_player.add_child(body_root)

	var body := Polygon2D.new()
	body.polygon = PackedVector2Array([
		Vector2(0, -30), Vector2(20, -12), Vector2(20, 18),
		Vector2(-20, 18), Vector2(-20, -12)
	])
	body.color = Color(0.32, 0.55, 0.9)
	body_root.add_child(body)

	var outline := Line2D.new()
	outline.points = PackedVector2Array([
		Vector2(0, -30), Vector2(20, -12), Vector2(20, 18),
		Vector2(-20, 18), Vector2(-20, -12), Vector2(0, -30)
	])
	outline.width = 2.5
	outline.default_color = Color(0.12, 0.22, 0.4)
	body_root.add_child(outline)

	# 【行走动画】战场上的主角此前是"贴地滑行"，加一套踏步起伏。
	# 本体是几何体、没有正反朝向，故只保留起伏（关掉旋转与缩放接管）。
	var wa := WalkAnim.attach(_player, body_root)
	if wa != null:
		wa.drive_rotation = false
		wa.drive_scale = false
		wa.bob_amp = 3.6
		wa.idle_amp = 0.5

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


## 【HUD 平滑 2026-09-30】动态补两条血条相关的层：
## ① HPGhostBar —— 与血条完全重叠、压在血条下层的暗红条（残影条）；
## ② LowHPVeil —— 残血时的全屏淡红脉冲层。
## 两条都不进 tscn：它们是纯演出件，写死在场景里会让 tscn 越来越难读，
## 而且只在本脚本一处使用，动态建最省事。
func _build_hud_extras() -> void:
	# --- 残影条 ---
	_hp_ghost_bar = ProgressBar.new()
	_hp_ghost_bar.name = "HPGhostBar"
	# 矩形必须跟 tscn 里的 HPBar 完全一致，否则残影会露出边框。
	# 【本项目的老坑】改了 tscn 忘了改代码（或反过来）→ 这里直接复制 tscn 的值，
	# 并由 _verify_battle_hud.py 拿两边做等值断言兜底。
	_hp_ghost_bar.offset_left = 44.0
	_hp_ghost_bar.offset_top = 40.0
	_hp_ghost_bar.offset_right = 524.0
	_hp_ghost_bar.offset_bottom = 92.0
	_hp_ghost_bar.min_value = 0.0
	_hp_ghost_bar.max_value = _player_hp_max
	_hp_ghost_bar.value = _player_hp_max
	_hp_ghost_bar.show_percentage = false
	_hp_ghost_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ghost_bg := StyleBoxFlat.new()
	ghost_bg.bg_color = Color(0.20, 0.05, 0.05, 0.80)
	var ghost_fg := StyleBoxFlat.new()
	ghost_fg.bg_color = Color(0.88, 0.24, 0.18, 0.92)
	_hp_ghost_bar.add_theme_stylebox_override("background", ghost_bg)
	_hp_ghost_bar.add_theme_stylebox_override("fill", ghost_fg)
	var bars := _hp_bar.get_parent()
	bars.add_child(_hp_ghost_bar)
	# 关键：排在血条之前 → 画在血条下层，血条掉下去时露出的那段就是残影
	bars.move_child(_hp_ghost_bar, _hp_bar.get_index())

	# --- 残血警示层（全屏，压在 UI 最底层，不挡任何按钮） ---
	_low_hp_veil = ColorRect.new()
	_low_hp_veil.name = "LowHPVeil"
	_low_hp_veil.set_anchors_preset(Control.PRESET_FULL_RECT)
	_low_hp_veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_low_hp_veil.color = Color(0.80, 0.10, 0.08, 1.0)
	_low_hp_veil.modulate.a = 0.0
	_low_hp_veil.visible = false
	$UI.add_child(_low_hp_veil)
	$UI.move_child(_low_hp_veil, 0)

	# 敌方血条量程统一到 0~100（tscn 里是 300 的老量程）
	_enemy_hp_bar.max_value = 100.0
	_enemy_hp_bar.value = 100.0
	_snap_bars()
	_build_cd_veil(_btn_attack)
	_build_cd_veil(_btn_dodge)
	_build_combo_label()
	_build_bar_texts()
	_build_curtain()


## 血条数值文本：ProgressBar 自带的百分比（"80%"）读不出还剩多少血，
## 换成绝对值"320 / 400"，残血时玩家才能判断"还能挨几下"。
func _build_bar_texts() -> void:
	# 血条/敌血条：居中显绝对值（"320 / 400"、"敌军 3 / 8 队"）
	_hp_bar.show_percentage = false
	_hp_text = _make_bar_text(_hp_bar, 22, HORIZONTAL_ALIGNMENT_CENTER)
	_enemy_hp_bar.show_percentage = false
	_enemy_text = _make_bar_text(_enemy_hp_bar, 22, HORIZONTAL_ALIGNMENT_CENTER)
	# 士气/怒气：条内左对齐带名字（"士气 78"）—— 两条颜色相近，
	# 没有标签玩家只能靠猜，这是左上角最实际的可用性问题。
	_morale_bar.show_percentage = false
	_morale_text = _make_bar_text(_morale_bar, 20, HORIZONTAL_ALIGNMENT_LEFT)
	_rage_bar.show_percentage = false
	_rage_text = _make_bar_text(_rage_bar, 20, HORIZONTAL_ALIGNMENT_LEFT)


func _make_bar_text(bar: ProgressBar, font_size: int, align: int) -> Label:
	var lb := Label.new()
	lb.name = "BarText"
	lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lb.horizontal_alignment = align
	lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lb.add_theme_font_size_override("font_size", font_size)
	lb.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	lb.add_theme_color_override("font_shadow_color", Color(0.05, 0.05, 0.05, 0.95))
	lb.add_theme_constant_override("shadow_offset_y", 2)
	bar.add_child(lb)
	lb.set_anchors_preset(Control.PRESET_FULL_RECT)
	if align == HORIZONTAL_ALIGNMENT_LEFT:
		lb.offset_left = 10.0      ## 左对齐时留出内边距，别贴着条边框
	return lb


## 开场黑幕：进战斗先全黑，再淡出战场（硬切进战场是最典型的"生硬"）
func _build_curtain() -> void:
	_curtain = ColorRect.new()
	_curtain.name = "SceneCurtain"
	_curtain.color = Color(0.0, 0.0, 0.0, 1.0)
	_curtain.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_curtain.set_anchors_preset(Control.PRESET_FULL_RECT)
	$UI.add_child(_curtain)
	$UI.move_child(_curtain, -1)


## 淡出黑幕（战场准备就绪后调用）
func _fade_from_black() -> void:
	if _curtain == null or not is_instance_valid(_curtain):
		return
	var tw := _curtain.create_tween()
	tw.tween_property(_curtain, "modulate:a", 0.0, 0.45)
	tw.tween_callback(_curtain.queue_free)
	_curtain = null


## 连斩计数：屏幕中上方，命中时弹出放大后回落
func _build_combo_label() -> void:
	_combo_label = Label.new()
	_combo_label.name = "ComboLabel"
	_combo_label.visible = false
	_combo_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_combo_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_combo_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_combo_label.add_theme_font_size_override("font_size", CombatFeelService.combo_font())
	_combo_label.add_theme_color_override("font_color", Color(1.0, 0.87, 0.45))
	_combo_label.add_theme_color_override("font_shadow_color", Color(0.30, 0.10, 0.04, 0.95))
	_combo_label.add_theme_constant_override("shadow_offset_y", 4)
	$UI.add_child(_combo_label)
	# 手写锚点：横向居中、纵向贴顶（preset 在进树前算不准父节点尺寸）
	_combo_label.anchor_left = 0.5
	_combo_label.anchor_right = 0.5
	_combo_label.anchor_top = 0.0
	_combo_label.anchor_bottom = 0.0
	_combo_label.offset_left = -400.0
	_combo_label.offset_right = 400.0
	_combo_label.offset_top = 150.0
	_combo_label.offset_bottom = 246.0
	# 以自身中心为缩放原点（Control 缩放默认绕左上角，不设会往右下抽）
	_combo_label.pivot_offset = Vector2(400.0, 48.0)


## 给动作按钮挂一层冷却遮罩（按钮本身在 tscn 里，遮罩是纯演出件故动态加）
func _build_cd_veil(btn: Button) -> void:
	if btn == null or not is_instance_valid(btn):
		return
	var veil := ColorRect.new()
	veil.name = "CDVeil"
	veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	veil.color = Color(0.04, 0.05, 0.09, 0.66)
	veil.visible = false
	btn.add_child(veil)
	# 手动设锚点而不用 set_anchors_preset：进树前 preset 依赖父节点 rect，
	# 这里父节点尺寸还没布局完，直接写 0/1 最稳。
	veil.anchor_left = 0.0
	veil.anchor_right = 1.0
	veil.anchor_top = 0.0
	veil.anchor_bottom = 0.0
	veil.offset_left = 0.0
	veil.offset_right = 0.0
	_cd_veils[btn] = veil


## 动作按钮状态：普攻/闪避的冷却遮罩 + 大招的怒气就绪态。
## 【为什么需要】此前按钮按下后毫无反馈，玩家不知道是没点到还是还在冷却，
## 只能反复戳 —— 这是"生硬死板"的一大来源。
func _tick_buttons(delta: float) -> void:
	_apply_cd_veil(_btn_attack, _attack_cooldown, ATTACK_COOLDOWN)
	_apply_cd_veil(_btn_dodge, _dodge_cooldown, DODGE_COOLDOWN)
	if _btn_skill == null or not is_instance_valid(_btn_skill):
		return
	var ready := _rage >= RAGE_SKILL_COST and _phase == Phase.FIGHTING
	if ready:
		# 怒气够了：轻微呼吸发光，提示"现在能放了"
		_skill_ready_t += delta
		var g := 1.0 + 0.07 * sin(_skill_ready_t * TAU * 1.3)
		_btn_skill.modulate = Color(g, g, g, 1.0)
	else:
		_skill_ready_t = 0.0
		_btn_skill.modulate = Color(0.52, 0.52, 0.56, 1.0)


## 命中记一次连斩（只在真正打中时调用，挥空不算）
func _bump_combo() -> void:
	if _combo_label == null or not is_instance_valid(_combo_label):
		return
	_combo += 1
	_combo_t = 0.0
	if _combo < CombatFeelService.combo_min():
		return
	_combo_label.visible = true
	_combo_label.text = "%d 连斩" % _combo
	if _combo_tween != null and _combo_tween.is_valid():
		_combo_tween.kill()
	_combo_label.scale = Vector2.ONE * CombatFeelService.combo_pop_scale()
	_combo_tween = _combo_label.create_tween()
	_combo_tween.tween_property(_combo_label, "scale", Vector2.ONE, 0.24) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


## 中断窗口内没有新命中 → 连斩断掉
func _tick_combo(delta: float) -> void:
	if _combo <= 0:
		return
	_combo_t += delta
	if _combo_t > CombatFeelService.combo_window():
		_combo = 0
		_combo_t = 0.0
		if _combo_label != null:
			_combo_label.visible = false


## 遮罩高度按"剩余冷却比例"从下往上退（底部对齐，顶部下压到 h·(1-r)）
func _apply_cd_veil(btn: Button, cd: float, total: float) -> void:
	var veil := _cd_veils.get(btn) as ColorRect
	if veil == null or not is_instance_valid(veil):
		return
	if cd <= 0.0:
		veil.visible = false
		return
	var h := maxf(btn.size.y, btn.custom_minimum_size.y)
	if h <= 0.0:
		return
	veil.visible = true
	var r := clampf(cd / maxf(0.0001, total), 0.0, 1.0)
	veil.offset_top = h * (1.0 - r)
	veil.offset_bottom = h


## 把血条一次性对齐到目标值（开场/换场用，避免从 0 慢慢涨上来）
func _snap_bars() -> void:
	_hp_bar.value = _target_hp
	_morale_bar.value = _target_morale
	_rage_bar.value = _target_rage
	_enemy_hp_bar.value = _target_enemy
	if _hp_ghost_bar != null:
		_hp_ghost_bar.max_value = _hp_bar.max_value
		_hp_ghost_bar.value = _target_hp


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


## 镜头推近特写：固定竞技场不连续跟随（保持全战场可读），
## 改用「推近到焦点 + 回正」制造电影感。zoom 与 position 走独立 tween，
## 与 _shake（改 offset）互不打架。焦点居中并 clamp，避免露出世界外黑边。
func _cam_punch(zoom_target: float, focus: Vector2) -> void:
	if _cam == null or not is_instance_valid(_cam):
		return
	var z := maxf(1.0, zoom_target)
	# 相机 anchor = FIXED_TOP_LEFT：屏幕中心对应的世界坐标 = focus - 视口半幅/zoom
	var half := Vector2(960.0, 540.0) / z
	var pan := focus - half
	var vw := 1920.0 / z
	var vh := 1080.0 / z
	pan.x = clampf(pan.x, 0.0, 1920.0 - vw)
	pan.y = clampf(pan.y, 0.0, 1080.0 - vh)
	if _cam_tween != null and _cam_tween.is_valid():
		_cam_tween.kill()
	_cam_tween = create_tween()
	var tin := CombatFeelService.cam_punch_in()
	var tout := CombatFeelService.cam_punch_out()
	_cam_tween.tween_property(_cam, "zoom", Vector2(z, z), tin)
	_cam_tween.parallel().tween_property(_cam, "position", pan, tin)
	_cam_tween.tween_property(_cam, "zoom", Vector2.ONE, tout)
	_cam_tween.parallel().tween_property(_cam, "position", Vector2.ZERO, tout)


## 击杀特写：任一支部队被移出战场（阵亡/溃散）即推近 + 短慢镜。
## 慢镜复用 _hitstop_end_ms 机制还原 time_scale，避免与结算慢镜打架。
func _on_unit_removed(unit: BattleUnit) -> void:
	if _phase != Phase.FIGHTING:
		return
	_cam_punch(CombatFeelService.cam_zoom("kill"), unit.position)
	var slow := CombatFeelService.cam_kill_slow()
	if slow < 1.0:
		Engine.time_scale = slow
		_hitstop_end_ms = maxi(_hitstop_end_ms,
			Time.get_ticks_msec() + int(CombatFeelService.cam_kill_slow_time() * 1000.0))


## 战场氛围：地面扬尘 + 远景烟雾（Compatibility 下必须用 CPUParticles2D，
## GPU 粒子静默失效）。零新美术资源，纯程序化制造「战场在动」的纵深。
func _build_battle_atmos() -> void:
	_atmos = Node2D.new()
	_atmos.name = "Atmos"
	add_child(_atmos)
	# 插在背景层与单位（Player）之间：既有战场纵深，又不挡主角/部队
	move_child(_atmos, $Player.get_index())

	var dust := CPUParticles2D.new()
	dust.name = "GroundDust"
	dust.emitting = true
	dust.amount = CombatFeelService.atmos_dust_amount()
	dust.lifetime = 2.6
	dust.direction = Vector2(0.0, -1.0)
	dust.spread = 30.0
	dust.initial_velocity_min = 6.0
	dust.initial_velocity_max = 22.0
	dust.gravity = Vector2(0.0, 4.0)
	dust.scale_amount_min = 0.35
	dust.scale_amount_max = 1.1
	dust.color = Color(0.80, 0.72, 0.55, CombatFeelService.atmos_dust_alpha())
	dust.position = Vector2(960.0, 985.0)
	dust.emission_shape = 2   # CPUParticles2D.EMISSION_SHAPE_BOX（矩形区域发射）
	dust.emission_rect_extents = Vector2(900.0, 26.0)
	_atmos.add_child(dust)

	var fog := CPUParticles2D.new()
	fog.name = "FarFog"
	fog.emitting = true
	fog.amount = 10
	fog.lifetime = 6.0
	fog.direction = Vector2(1.0, 0.0)
	fog.spread = 8.0
	fog.initial_velocity_min = 4.0
	fog.initial_velocity_max = 12.0
	fog.gravity = Vector2.ZERO
	fog.scale_amount_min = 2.5
	fog.scale_amount_max = 5.0
	fog.color = Color(0.85, 0.85, 0.88, CombatFeelService.atmos_fog_alpha())
	fog.position = Vector2(960.0, 520.0)
	fog.emission_shape = 2   # CPUParticles2D.EMISSION_SHAPE_BOX（矩形区域发射）
	fog.emission_rect_extents = Vector2(960.0, 360.0)
	_atmos.add_child(fog)


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
		# 【修复】布阵阶段撤退也视作「本场遭遇放弃」：先标记当日已解决，
		# 阻断 EncounterManager 在回大地图后于主角身旁立即刷新同一 NPC
		#（原实现只清 current_encounter 不写 encounter_resolved → 原地/身边重生）。
		# 必须在清空 current_encounter 之前调用（它依赖其中的 _enc_id）。
		_note_encounter_resolved(false)
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
	AudioManager.sfx_charge()   ## 开战即全军出击，冲锋号（用户指定 snd12）
	_phase = Phase.FIGHTING
	_director.start()
	_push_log("两军交锋")
	# 战况三态：准备→交战，切到交战曲
	AudioManager.play_bgm(CombatFeelService.bgm_fight())
	# 开战镜头一紧（推近到战场中心再回正），强化「打起来了」的瞬间感
	_cam_punch(CombatFeelService.cam_zoom("begin"), Vector2(960.0, 540.0))
	# 开战横幅：一行 toast 太轻，"打起来了"这件事值得占半屏
	_banner("交　战", _enemy_name)


## 中央横幅：弹出 → 停留 → 淡出。用于开战等"阶段切换"时刻。
## 【为什么不用 toast】toast 是角落里的小字，阶段切换需要的是"停顿感"，
## 横幅能把玩家的注意力从战前决断面板拉回战场。
func _banner(main_text: String, sub_text: String,
		main_color: Color = Color(1.0, 0.88, 0.50),
		sub_color: Color = Color(0.96, 0.93, 0.84)) -> void:
	var box := Control.new()
	box.name = "BattleBanner"
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.anchor_left = 0.5
	box.anchor_right = 0.5
	box.anchor_top = 0.0
	box.anchor_bottom = 0.0
	box.offset_left = -600.0
	box.offset_right = 600.0
	box.offset_top = 330.0
	box.offset_bottom = 560.0
	# 以自身中心为缩放原点：Control 默认绕左上角缩放，不设会往右下抽
	box.pivot_offset = Vector2(600.0, 115.0)
	$UI.add_child(box)
	$UI.move_child(box, -1)

	var lb_main := Label.new()
	lb_main.text = main_text
	lb_main.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb_main.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lb_main.add_theme_font_size_override("font_size", 96)
	lb_main.add_theme_color_override("font_color", main_color)
	lb_main.add_theme_color_override("font_shadow_color", Color(0.32, 0.10, 0.03, 0.95))
	lb_main.add_theme_constant_override("shadow_offset_y", 6)
	lb_main.set_anchors_preset(Control.PRESET_FULL_RECT)
	lb_main.offset_bottom = -100.0
	box.add_child(lb_main)

	if not sub_text.is_empty():
		var lb_sub := Label.new()
		lb_sub.text = sub_text
		lb_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lb_sub.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lb_sub.add_theme_font_size_override("font_size", 40)
		lb_sub.add_theme_color_override("font_color", sub_color)
		lb_sub.add_theme_color_override("font_shadow_color", Color(0.20, 0.08, 0.03, 0.95))
		lb_sub.add_theme_constant_override("shadow_offset_y", 4)
		lb_sub.set_anchors_preset(Control.PRESET_FULL_RECT)
		lb_sub.offset_top = 130.0
		box.add_child(lb_sub)

	box.scale = Vector2(1.55, 1.55)
	box.modulate.a = 0.0
	var tw := box.create_tween()
	tw.set_parallel(true)
	tw.tween_property(box, "modulate:a", 1.0, 0.14)
	tw.tween_property(box, "scale", Vector2.ONE, 0.30).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.set_parallel(false)
	tw.tween_interval(0.55)
	tw.tween_property(box, "modulate:a", 0.0, 0.32)
	tw.tween_callback(box.queue_free)


## 结算转场：战场慢镜 + 渐暗，再弹结算面板。
## 【为什么】胜负一分出面板就糊上来，玩家来不及看"最后一队是怎么没的"。
## 0.3s 慢镜给出收束感，同时把战场压暗，面板自然成为唯一焦点。
func _play_finish_transition() -> void:
	# 结算前先把可能残留的镜头推近收回，避免特写残留在结算画面上
	if _cam_tween != null and _cam_tween.is_valid():
		_cam_tween.kill()
	if _cam != null and is_instance_valid(_cam):
		_cam.zoom = Vector2.ONE
		_cam.position = Vector2.ZERO
	# 清掉可能残留的顿帧：否则 _tick_hitstop 会把 time_scale 拉回 1，慢镜立刻失效
	_hitstop_end_ms = 0
	Engine.time_scale = 0.35
	var tw := create_tween()
	tw.tween_property(Engine, "time_scale", 1.0, 0.70)

	var veil := ColorRect.new()
	veil.name = "FinishVeil"
	veil.color = Color(0.02, 0.02, 0.03, 1.0)
	veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	veil.set_anchors_preset(Control.PRESET_FULL_RECT)
	veil.modulate.a = 0.0
	$UI.add_child(veil)
	# 压在 UI 最底层：只暗战场与 HUD，结算面板在它之上照常可读
	$UI.move_child(veil, 0)
	var tw2 := veil.create_tween()
	tw2.tween_property(veil, "modulate:a", 0.55, 0.45)


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
	_tick_bars(delta)
	_tick_buttons(delta)
	_tick_combo(delta)
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
	_hurt_pop_cd = maxf(0.0, _hurt_pop_cd - delta)
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
	# 【演出】持续掉血不像单次打击那样好读：攒够一定量再弹一次红字，
	# 既让玩家看见"我在挨打"，又不会每帧刷一片数字。
	_hurt_accum += dps * delta
	if _hurt_pop_cd <= 0.0 and _hurt_accum >= 1.0:
		DamageNumber.pop_damage(_player.get_parent(),
			_player.position + Vector2(0.0, -52.0), _hurt_accum, false, true)
		_hurt_accum = 0.0
		_hurt_pop_cd = 0.55
		_flash(_player)
		# 只震屏、不顿帧：持续掉血若每次都顿帧，战斗会变成一卡一卡的
		_shake(CombatFeelService.shake(CombatFeelService.KIND_LIGHT))
	if _player_hp <= 0.0:
		if _director.ally_alive() > 0 or not _director.had_allies():
			# 挂彩后撤：部曲尚在（或本就孤身作战）不直接判负，
			# 回血喘息并短暂无敌。
			_player_hp = 40.0
			_player_invuln = 2.0
			_rage = maxf(0.0, _rage - 30.0)
			show_toast("身负重伤，暂退阵中！")
		else:
			# 部曲尽墨、主角孤身被击倒 → 真正战败（与主动撤退同走 force_end(false)）。
			_player_hp = 0.0
			_director.force_end(false)
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
	# 只记账不写控件：真实消灭一队时血条才有"滑下去"的过程，而不是瞬间缩一格
	_enemy_hp = clampf(float(sit["enemy_alive"]) / enc_total * 100.0, 0.0, 100.0)
	_enemy_alive_n = int(sit["enemy_alive"])
	_enemy_total_n = int(enc_total)
	_update_bars()


## ---------- 玩家操作 ----------

func _on_attack() -> void:
	if _phase != Phase.FIGHTING or _attack_cooldown > 0.0:
		return
	_attack_cooldown = ATTACK_COOLDOWN
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
	# 朝最近的敌人递一下身位再收回：普攻从此有"挥砍"的形，而不是原地闪一下
	_play_swing(1.0)
	_feedback(CombatFeelService.KIND_LIGHT)
	_bump_combo()


func _on_dodge() -> void:
	if _phase != Phase.FIGHTING or _dodge_cooldown > 0.0:
		return
	AudioManager.sfx_click()
	_rage = minf(100.0, _rage + 4.0)
	_player_invuln = DODGE_INVULN
	_dodge_cooldown = DODGE_COOLDOWN
	show_toast("闪避")
	# 【演出】闪避此前只有一行 toast，玩家看不出主角"躲开了"。
	# 无敌帧内半透明（像化作一道残影），结束自动还原。
	var tw := _player.create_tween()
	tw.tween_property(_player, "modulate:a", 0.42, 0.08)
	tw.tween_interval(maxf(0.05, DODGE_INVULN - 0.28))
	tw.tween_property(_player, "modulate:a", 1.0, 0.2)


func _on_skill() -> void:
	if _phase != Phase.FIGHTING:
		return
	if _rage < RAGE_SKILL_COST:
		show_toast("怒气不足（需 %d）" % int(RAGE_SKILL_COST))
		return
	_rage -= RAGE_SKILL_COST
	# 大招专用音（唢呐扬起+大鼓），替换语义错位的确认弹窗音
	AudioManager.play_sfx("res://assets/audio/sfx/battle_skill.ogg")
	show_toast("释放大招！")
	var mult := 1.0 + _atk_mult
	# 大招吃双倍武器加成（名器爽感）
	var wpn := float(CharacterService.player_weapon_attack())
	_director.player_ultimate((randf_range(48.0, 72.0) + (wpn + _eq_atk) * 2.0) * mult)
	# 大招：更强的前突 + 一层全屏金闪，把"全军技"的气势演出来
	_play_swing(1.7)
	_flash_screen(Color(1.0, 0.86, 0.45), CombatFeelService.ult_flash_peak(),
		CombatFeelService.ult_flash_life())
	_feedback(CombatFeelService.KIND_ULTIMATE)
	# 镜头推近到主角，强化大招的"重"——与击杀特写走同一套机制
	_cam_punch(CombatFeelService.cam_zoom("skill"), _player.position)


func _on_command_charge() -> void:
	if _phase != Phase.FIGHTING:
		return
	AudioManager.sfx_charge()   ## 冲锋号（用户指定 snd12）取代通用点击音
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


## 挥砍前突：朝最近敌人递出去再收回（scale=1.7 用于大招，递得更狠）。
## 【为什么写 WalkAnim.extra_offset】本体 position 每帧被行走动画按
## "基准 + 起伏" 重写，直接 tween 本体会被覆盖；用独立偏移通道两者相加，
## 挥砍与踏步可以同时发生，也不会因为连点而把主角一路推进敌阵。
func _play_swing(scale: float) -> void:
	var wa := _player.get_node_or_null("WalkAnim") as WalkAnim
	if wa == null:
		return
	var push := _dir_to_nearest_enemy() * CombatFeelService.swing_distance() * scale
	var tw := create_tween()
	tw.tween_property(wa, "extra_offset", push, CombatFeelService.swing_out())
	tw.tween_property(wa, "extra_offset", Vector2.ZERO, CombatFeelService.swing_back())


## 指向最近敌军的单位向量（挥砍前突用）。没有活敌人时朝右（敌军在战场右侧）。
func _dir_to_nearest_enemy() -> Vector2:
	var best := INF
	var best_pos := Vector2.ZERO
	for u in _director._enemies:
		if u.is_gone() or u.is_routed():
			continue
		var d := _player.position.distance_to(u.position)
		if d < best:
			best = d
			best_pos = u.position
	if best == INF:
		return Vector2(1.0, 0.0)
	var dir := best_pos - _player.position
	if dir.length_squared() < 1.0:
		return Vector2(1.0, 0.0)
	return dir.normalized()


## 全屏闪（大招/重大事件）：一层纯色快闪后淡出，用完自动回收。
## 挂在 UI 层、不吃鼠标事件，绝不影响战场操作。
func _flash_screen(color: Color, peak: float, life: float) -> void:
	var cr := ColorRect.new()
	cr.name = "ScreenFlash"
	cr.color = color
	cr.set_anchors_preset(Control.PRESET_FULL_RECT)
	cr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cr.modulate.a = 0.0
	$UI.add_child(cr)
	# 先压到 UI 最上层，避免被战报/HUD 盖住
	$UI.move_child(cr, -1)
	var tw := cr.create_tween()
	tw.tween_property(cr, "modulate:a", peak, 0.07)
	tw.tween_property(cr, "modulate:a", 0.0, life)
	tw.tween_callback(cr.queue_free)


## ---------- 结算 ----------

## 【M-4 修复】遭遇战分出胜负后才写「已解决」：胜利=永久解决（不再重生）；
## 战败=记绝对游戏日，当日封锁（防原地死循环），次日 EncounterManager
## 判定过期后原地复活可再战。_enc_id 由触发时注入 def 副本，剧本战/城内战
## 无此键不写。
func _note_encounter_resolved(win: bool) -> void:
	var enc_id := str(GameState.current_encounter.get("_enc_id", ""))
	if enc_id.is_empty():
		# 【撤退循环防护】_enc_id 注入链若意外断开，回退到 def 的 id。
		# 至少能按「同一遭遇 def」挡住当日原地重生，避免静默丢失 → 死循环。
		enc_id = str(GameState.current_encounter.get("id", ""))
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
	# 战斗结束：连斩与残血警示一并收掉，别让演出件残留到结算面板上
	_combo = 0
	_combo_t = 0.0
	if _combo_label != null:
		_combo_label.visible = false
	if _low_hp_veil != null:
		_low_hp_veil.visible = false
	# 慢镜 + 渐暗：胜负刚分出别急着糊面板，先给战场一个收束
	_play_finish_transition()

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
		# 胜利短曲 one-shot（走 SFX bus 叠在 BGM 上，不切曲；用户指定《三国大时代4》snd39）
		AudioManager.sfx_victory()
		# 战况三态：交战→胜利，切到胜利曲
		AudioManager.play_bgm(CombatFeelService.bgm_win())
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
		# 败北演出（与胜利侧对称，消除结算干跳的生硬感）：
		#   · 暗红横幅"败 北"，仪式感收束
		#   · 镜头缓缓推近主角（中近景），看清主角孤身立于战场
		#   · 战乐淡出收束（无 defeat 曲，停战乐比硬切更沉得住）
		_banner("败　北", "我军溃退", Color(0.86, 0.32, 0.28), Color(0.80, 0.78, 0.74))
		_cam_punch(CombatFeelService.cam_zoom("defeat"), _player.position)
		AudioManager.stop_bgm(true)
		_result_label.text = "败  北\n\n我军折损 %d 队\n残余兵力 %d\n\n部队撤退，损失部分兵力" % [
			int(summary["losses"]), int(summary["ally_troops"]),
		]
	EventBus.battle_ended.emit({"win": win, "summary": summary})
	_show_result_after_beat()


## 慢镜走完一拍再上面板（ignore_time_scale=true：慢镜期间仍按真实秒计时）
func _show_result_after_beat() -> void:
	await get_tree().create_timer(0.30, true, false, true).timeout
	if is_instance_valid(_result_panel):
		_pop_result_panel()


## 结算面板弹出：淡入 + 从 0.9 缩放回正。
## 【为什么】面板"啪"地整块糊上来是生硬感的典型来源；0.2s 出头的缓出
## 既顺眼又不拖沓（数值属纯演出，不进 JSON）。
func _pop_result_panel() -> void:
	_result_panel.visible = true
	_result_panel.pivot_offset = _result_panel.size * 0.5
	_result_panel.modulate.a = 0.0
	_result_panel.scale = Vector2(0.9, 0.9)
	var tw := _result_panel.create_tween()
	tw.set_parallel(true)
	tw.tween_property(_result_panel, "modulate:a", 1.0, 0.22)
	tw.tween_property(_result_panel, "scale", Vector2.ONE, 0.28) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


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
	EventBus.drill_finished.emit(drill_id, GameState.last_drill_result)
	_show_result_after_beat()
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
	# 【2026-09-27 死循环修复】战斗结算后必须回大地图并清空路由历史。
	# 旧代码 SceneRouter.back() 弹栈回的是「布阵界面」（攻城/守城/遭遇三类战斗
	# 都经 push_scene("formation") 进入），玩家打完一场又站回布阵、再点开战
	# 循环往复，表现为「杀光敌人也退出不了、结算不了」。goto_fresh 清掉
	# world→formation→battle 的残留历史；世界地图 _ready 按 last_world_pos 恢复位置。
	SceneRouter.goto_fresh("world")


## ---------- UI 辅助 ----------

## 【HUD 平滑 2026-09-30】旧实现是直接 `value = 当前值`：扣血/涨怒都是
## 一格跳到位，读起来"啪"一下，看不出变化过程。改成"记目标值 + 每帧逼近"，
## 血条因此有了流动感；再叠一条**残影条**——掉血时它慢半拍才收，
## 玩家一眼能看清"刚才掉了多少"（格斗游戏常用的读条手法）。
func _update_bars() -> void:
	_hp_bar.max_value = _player_hp_max
	_target_hp = _player_hp
	_target_morale = _morale
	_target_rage = _rage
	_target_enemy = _enemy_hp
	if _hp_ghost_bar != null:
		_hp_ghost_bar.max_value = _player_hp_max


## 每帧逼近目标值（在 _process 里跑）
func _tick_bars(delta: float) -> void:
	_hp_bar.value = CombatFeelService.approach(_hp_bar.value, _target_hp, delta,
		CombatFeelService.bar_smooth("hp"))
	_morale_bar.value = CombatFeelService.approach(_morale_bar.value, _target_morale, delta,
		CombatFeelService.bar_smooth("morale"))
	_rage_bar.value = CombatFeelService.approach(_rage_bar.value, _target_rage, delta,
		CombatFeelService.bar_smooth("rage"))
	_enemy_hp_bar.value = CombatFeelService.approach(_enemy_hp_bar.value, _target_enemy, delta,
		CombatFeelService.bar_smooth("enemy"))
	_tick_hp_ghost(delta)
	_tick_low_hp_warning(delta)
	_tick_bar_texts()


## 血条数值文本跟着**真实血量**走（不是跟着平滑后的控件值），
## 否则数字会因为动画滞后几帧，玩家读到的和看到的对不上。
func _tick_bar_texts() -> void:
	if _hp_text != null:
		_hp_text.text = "%d / %d" % [int(round(_player_hp)), int(round(_player_hp_max))]
	if _enemy_text != null:
		_enemy_text.text = "敌军 %d / %d 队" % [_enemy_alive_n, _enemy_total_n]
	if _morale_text != null:
		_morale_text.text = "士气 %d" % int(round(_morale))
	if _rage_text != null:
		_rage_text.text = "怒气 %d" % int(round(_rage))


## 残影条：掉血后先停 0.35s 再快速追上来；回血时立刻跟上（残影不该领先）
func _tick_hp_ghost(delta: float) -> void:
	if _hp_ghost_bar == null:
		return
	if _hp_bar.value < _hp_ghost_bar.value - 0.5:
		_ghost_hold += delta
		if _ghost_hold > CombatFeelService.ghost_hold():
			_hp_ghost_bar.value = CombatFeelService.approach(_hp_ghost_bar.value, _hp_bar.value,
				delta, CombatFeelService.ghost_catchup())
	else:
		_ghost_hold = 0.0
		_hp_ghost_bar.value = _hp_bar.value


## 残血警示：主角血量低于 30% 时全屏淡红脉冲。
## 【为什么需要】战斗里主角掉血只有左上一条小血条在动，
## 激战中根本注意不到，等发现时已经倒地 —— 边缘红晕是最省事的"快死了"提示。
func _tick_low_hp_warning(delta: float) -> void:
	if _low_hp_veil == null:
		return
	var ratio := _player_hp / maxf(1.0, _player_hp_max)
	var edge := CombatFeelService.low_hp_ratio()
	var danger := ratio < edge and _phase == Phase.FIGHTING
	_low_hp_veil.visible = danger
	if not danger:
		return
	# 越低越红越急：频率与透明度都在配置区间内按危急度插值
	_warn_t += delta
	var urgency := clampf((edge - ratio) / maxf(0.01, edge), 0.0, 1.0)
	var hz := lerpf(CombatFeelService.low_hp_hz_min(), CombatFeelService.low_hp_hz_max(), urgency)
	var amp := lerpf(CombatFeelService.low_hp_alpha_min(), CombatFeelService.low_hp_alpha_max(), urgency)
	_low_hp_veil.modulate.a = amp * (0.5 + 0.5 * sin(_warn_t * TAU * hz))


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
