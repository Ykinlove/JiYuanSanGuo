extends Node2D
class_name BattleUnit
## 战场部队单位（BattleUnit）
## 职责：承载一支部队的全部战斗状态与行为——
##       血量/兵力、士气、移动、索敌、攻击、受击、溃散、阵亡。
##
## 设计要点：
##   · 兵力(count) 与 血量(hp) 双轨：hp 归零或兵力归零即阵亡
##   · 士气独立于血量：士气归零 → 溃散逃跑（不战死，但退出战局）
##   · 位置由阵位决定初始 x（前军贴近敌），但 AI 会主动推进接敌
##   · 完全程序化绘制，贴图就绪后可替换

signal unit_died(unit: BattleUnit)
signal unit_routed(unit: BattleUnit)
signal damage_dealt(unit: BattleUnit, amount: float, is_counter: bool)

enum State { IDLE, ADVANCE, ENGAGE, ROUTED, DEAD }

const HP_BAR_WIDTH := 46.0
## 兵种图标目录（AI 美术批次：assets/sprites/units/<unit_id>.png）
const UNIT_ICON_DIR := "res://assets/sprites/units/"

## ---------- 身份 ----------
var unit_id: String = ""
var unit_name: String = ""
var category: String = ""
var is_ally: bool = true
var troop_index: int = -1

## ---------- 基础数值 ----------
var count: int = 0              ## 当前兵力
var count_max: int = 0          ## 初始兵力
var hp: float = 100.0
var hp_max: float = 100.0
var attack: float = 20.0
var defense: float = 15.0
var speed: float = 100.0
var range_px: float = 92.0      ## 攻击距离（像素，由 range 字段换算）
var morale: float = 100.0

## ---------- 加成 ----------
var attack_mult: float = 1.0    ## 布阵加成（阵型 + 阵位 + 行协同）
var defense_mult: float = 1.0
var morale_decay_mult: float = 1.0   ## 阵型士气消耗倍率（锋矢阵「士气消耗加快」）
var counter_table: Dictionary = {}   ## 敌方 unit_id -> 伤害倍率

## ---------- AI 状态 ----------
var state: int = State.IDLE
var target: BattleUnit = null
var move_dir: float = 1.0       ## 推进方向：我方 +1（向右），敌方 -1
var formation_slot: int = -1
var hold_position: bool = false ## 「固守」指令
var charge_timer: float = 0.0   ## 冲锋剩余时间

# ---------- 武将军团技 ----------
var troop_skill: int = 0        ## 自率武将的军团技 id（SkillService，0=无）
var hero_name: String = ""      ## 持有者武将名（战报用）
var buff_defense_add := 0.0     ## 铁壁：限时防御绝对值
var buff_defense_timer := 0.0   ## 铁壁剩余时间
var buff_rapid_timer := 0.0     ## 连射剩余时间（攻击间隔减半）

## ---------- 内部 ----------
var _cfg: Dictionary = {}
var _attack_cd := 0.0
var _flash_amount := 0.0
var _dead := false
var _fled := false              ## 离场方式：true=溃散逃出战场（非歼灭）
var _bob := 0.0
## 【战斗演出 2026-09-30】出手前突 / 受击击退的**视觉**位移（像素）。
## _vis_off 当前偏移，_vis_vel 偏移速度，按弹簧回中（见 _apply_impulse）。
##
## 【为什么只动视觉、不动 position】
##   ① position 是战斗坐标：AI 推进、接战距离、包围判定全靠它，
##      演出去改它会让"连打几次就把方阵推离战位/推进敌阵"，属于表现污染规则层；
##   ② 弹簧会自动回中，反复触发也不会累积漂移；
##   ③ 血条与名牌不参与偏移，战斗中始终可读。
var _vis_off := Vector2.ZERO
var _vis_vel := Vector2.ZERO
## 弹簧参数（回中刚度 / 阻尼）：越大回得越快
const VIS_SPRING := 90.0
const VIS_DAMP := 12.0

## 绘制节点
var _body: Polygon2D
var _outline: Line2D
var _icon: Sprite2D = null        ## 兵种图标（有贴图时），需跟随视觉偏移一起动
var _hp_bg: ColorRect
var _hp_fill: ColorRect
var _name_label: Label
var _count_label: Label
var _morale_label: Label
var _state_label: Label

## 视觉升级容器（阵营军旗 + 方阵底座 + 投影 的父节点）
var _art: Node2D = null
var _shadow: Polygon2D = null
var _banner_pendant: Node2D = null
var _banner_tween: Tween = null


## 初始化
func setup(unit: Dictionary, troop: Dictionary, cfg: Dictionary, ally: bool) -> void:
	_cfg = cfg
	unit_id = str(unit.get("id", ""))
	unit_name = str(unit.get("name", unit_id))
	category = str(unit.get("category", ""))
	is_ally = ally
	troop_index = int(troop.get("troop_index", -1))

	count = int(troop.get("count", 100))
	count_max = maxi(1, count)
	hp_max = float(unit.get("hp", 100))
	hp = hp_max
	attack = float(unit.get("attack", 20))
	defense = float(unit.get("defense", 15))
	speed = float(unit.get("speed", 100))
	# range 字段：1~2 为近战，>=3 为远程 → 换算成像素
	var rng_val := float(unit.get("range", 1))
	range_px = 92.0 if rng_val < 3.0 else clampf(260.0 + rng_val * 28.0, 260.0, 560.0)

	attack_mult = float(troop.get("attack_mult", 1.0))
	defense_mult = float(troop.get("defense_mult", 1.0))
	morale_decay_mult = float(troop.get("morale_cost", 1.0))

	# 装备绝对值加成（武将自带装备聚合后透传）
	attack += float(troop.get("attack_add", 0))
	defense += float(troop.get("defense_add", 0))
	hp_max += float(troop.get("hp_add", 0))
	hp = hp_max
	speed += float(troop.get("speed_add", 0))
	# 阵型全局移速（长蛇阵「行军速度 +20%」/ 方圆阵「移动 −10%」）
	speed *= float(troop.get("speed_mult", 1.0))

	move_dir = 1.0 if ally else -1.0
	_build_visual(unit)


## 设置克制表
func set_counter_table(table: Dictionary) -> void:
	counter_table = table


## ---------- 视觉 ----------

func _build_visual(unit: Dictionary) -> void:
	var fac := faction_color()
	var accent := category_color(category)
	var size := unit_size()

	# 【视觉升级】以「阵营军旗 + 方阵底座」取代纯几何六边形：
	# ① 阵营色（我方蓝 / 敌方绛红）一眼分敌我，解决原"同兵种双方底色相近"难辨问题；
	# ② 旗杆 + 绕顶端轻摆的战旗制造"军容"；③ 缺兵种贴图时用程序化徽记区分兵种。
	_art = Node2D.new()
	_art.name = "Art"
	add_child(_art)

	# 地面投影：压暗椭圆，给单位重心（不再是浮空色块）
	_shadow = Polygon2D.new()
	var sh := size * 1.55
	_shadow.polygon = _ellipse_points(sh, sh * 0.40, 18)
	_shadow.color = Color(0.0, 0.0, 0.0, 0.30)
	_shadow.position = Vector2(0.0, size * 0.50)
	_art.add_child(_shadow)

	# 方阵底座：宽矮六边形（双层伪造体积：暗底 + 亮顶）
	_body = Polygon2D.new()
	_body.polygon = _phalanx_points(size)
	_body.color = fac
	_art.add_child(_body)

	var hi := Polygon2D.new()
	hi.polygon = _phalanx_top(size)
	hi.color = fac.lightened(0.28)
	_art.add_child(hi)

	_outline = Line2D.new()
	var pts := _phalanx_points(size)
	pts.append(pts[0])
	_outline.points = pts
	_outline.width = 2.0
	_outline.default_color = fac.darkened(0.55)
	_art.add_child(_outline)

	# 兵种图标（有贴图则叠图；缺图则用程序化徽记）
	var icon_tex := _load_unit_icon()
	if icon_tex != null:
		_icon = Sprite2D.new()
		_icon.texture = icon_tex
		var w := float(maxi(1, icon_tex.get_width()))
		_icon.scale = Vector2((size * 1.5) / w, (size * 1.5) / w)
		# 敌军图标偏红压暗，与友军区分；底座颜色已按阵营色
		_icon.modulate = Color(1, 1, 1) if is_ally else Color(1.0, 0.72, 0.68)
		_icon.position = Vector2(0.0, -size * 0.05)
		_art.add_child(_icon)
	else:
		_build_emblem(accent, size)

	# 军旗（旗杆 + 轻摆战旗 + 旗心徽记）
	_build_banner(fac, accent, size)

	if not is_ally:
		modulate = Color(1, 0.96, 0.96)

	# —— 以下血条 / 名牌 / 兵力 / 士气 / 状态 标签全部留在 self 下，
	#    不参与晃动与闪红，保证战况始终可读（延续原设计）——
	_hp_bg = ColorRect.new()
	_hp_bg.color = Color(0.1, 0.08, 0.08, 0.85)
	_hp_bg.size = Vector2(HP_BAR_WIDTH, 7)
	_hp_bg.position = Vector2(-HP_BAR_WIDTH * 0.5, -size - 22.0)
	add_child(_hp_bg)

	_hp_fill = ColorRect.new()
	_hp_fill.color = Color(0.45, 0.85, 0.45) if is_ally else Color(0.9, 0.42, 0.38)
	_hp_fill.size = Vector2(HP_BAR_WIDTH, 7)
	_hp_fill.position = Vector2.ZERO
	_hp_bg.add_child(_hp_fill)

	# 名称
	_name_label = Label.new()
	_name_label.text = unit_name
	_name_label.add_theme_font_size_override("font_size", 17)
	_name_label.add_theme_color_override("font_color", Color(1, 0.97, 0.9))
	_name_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_name_label.add_theme_constant_override("shadow_offset_x", 1)
	_name_label.add_theme_constant_override("shadow_offset_y", 1)
	_name_label.position = Vector2(-38, -size - 20.0)
	add_child(_name_label)

	# 兵力
	_count_label = Label.new()
	_count_label.text = "%d" % count
	_count_label.add_theme_font_size_override("font_size", 16)
	_count_label.add_theme_color_override("font_color", Color(0.88, 0.86, 0.8))
	_count_label.position = Vector2(-16, size + 2.0)
	add_child(_count_label)

	# 士气（低士气才显示）
	_morale_label = Label.new()
	_morale_label.add_theme_font_size_override("font_size", 15)
	_morale_label.add_theme_color_override("font_color", Color(0.95, 0.75, 0.4))
	_morale_label.position = Vector2(-16, size + 20.0)
	_morale_label.visible = false
	add_child(_morale_label)

	# 状态提示（冲锋 / 溃散）
	_state_label = Label.new()
	_state_label.add_theme_font_size_override("font_size", 16)
	_state_label.add_theme_color_override("font_color", Color(1, 0.85, 0.4))
	_state_label.position = Vector2(-30, -size - 40.0)
	_state_label.visible = false
	add_child(_state_label)


## 阵营色：我方蓝、敌方绛红——一眼分敌我（原按兵种上色导致双方相近难辨）
func faction_color() -> Color:
	return Color(0.30, 0.55, 0.95) if is_ally else Color(0.92, 0.30, 0.28)


## 椭圆顶点（地面投影 / 圆形徽记用）
func _ellipse_points(rx: float, ry: float, n: int) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(n):
		var t := float(i) / float(n) * TAU
		pts.append(Vector2(cos(t) * rx, sin(t) * ry))
	return pts


## 方阵底座（宽矮六边形，模拟列阵）
func _phalanx_points(r: float) -> PackedVector2Array:
	var w := r * 1.15
	var h := r * 0.78
	return PackedVector2Array([
		Vector2(-w, 0.0), Vector2(-w * 0.6, -h), Vector2(w * 0.6, -h),
		Vector2(w, 0.0), Vector2(w * 0.55, h), Vector2(-w * 0.55, h)
	])


## 底座顶部高光条（伪造体积）
func _phalanx_top(r: float) -> PackedVector2Array:
	var w := r * 1.15
	var h := r * 0.78
	return PackedVector2Array([
		Vector2(-w * 0.6, -h), Vector2(w * 0.6, -h),
		Vector2(w * 0.5, -h * 0.45), Vector2(-w * 0.5, -h * 0.45)
	])


## 程序化兵种徽记（缺贴图时叠在方阵上，区分兵种）
func _build_emblem(accent: Color, size: float) -> void:
	var e := Polygon2D.new()
	e.color = accent.lightened(0.22)
	e.polygon = _emblem_polygon(category, size * 0.42)
	e.position = Vector2(0.0, -size * 0.05)
	_art.add_child(e)


func _emblem_polygon(cat: String, s: float) -> PackedVector2Array:
	match cat:
		"infantry":
			return PackedVector2Array([Vector2(-s*0.22,-s),Vector2(s*0.22,-s),Vector2(s*0.22,s*0.7),Vector2(-s*0.22,s*0.7)])
		"cavalry":
			return PackedVector2Array([Vector2(-s,-s*0.2),Vector2(s*0.55,-s),Vector2(s*0.55,s),Vector2(-s,-s*0.2),Vector2(-s*0.2,-s*0.2),Vector2(-s*0.2,s*0.2),Vector2(-s,-s*0.2)])
		"archer":
			return _ellipse_points(s, s, 14)
		"beast":
			return PackedVector2Array([Vector2(0.0,s),Vector2(s*0.8,-s*0.7),Vector2(-s*0.8,-s*0.7)])
		"elite":
			return PackedVector2Array([Vector2(0.0,-s),Vector2(s*0.28,-s*0.28),Vector2(s,-s*0.1),Vector2(s*0.28,s*0.28),Vector2(0.0,s),Vector2(-s*0.28,s*0.28),Vector2(-s,-s*0.1),Vector2(-s*0.28,-s*0.28)])
		"special":
			return PackedVector2Array([Vector2(0.0,-s),Vector2(s,-s*0.1),Vector2(s*0.1,s),Vector2(-s*0.1,s),Vector2(-s,-s*0.1)])
		"navy":
			return PackedVector2Array([Vector2(-s,s*0.3),Vector2(-s*0.33,-s*0.3),Vector2(s*0.33,s*0.3),Vector2(s,-s*0.3),Vector2(s,s*0.1),Vector2(-s,s*0.1)])
		_:
			return _ellipse_points(s*0.8, s*0.8, 14)


## 军旗：旗杆 + 绕顶端轻摆的战旗 + 旗心徽记（纯视觉，制造军容）
func _build_banner(fac: Color, accent: Color, size: float) -> void:
	var top_y := -size * 2.5
	var pole := Line2D.new()
	pole.points = PackedVector2Array([Vector2(0.0, -size * 0.1), Vector2(0.0, top_y)])
	pole.width = 3.0
	pole.default_color = Color(0.50, 0.38, 0.26)
	_art.add_child(pole)

	var knob := Polygon2D.new()
	knob.polygon = _ellipse_points(4.0, 4.0, 10)
	knob.color = Color(0.85, 0.70, 0.30)
	knob.position = Vector2(0.0, top_y)
	_art.add_child(knob)

	_banner_pendant = Node2D.new()
	_banner_pendant.position = Vector2(0.0, top_y)
	_art.add_child(_banner_pendant)

	var fw := size * 1.6
	var fh := size * 0.95
	var flag := Polygon2D.new()
	flag.polygon = PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(fw, -fh * 0.28),
		Vector2(fw, fh * 0.50), Vector2(0.0, fh * 0.45)
	])
	flag.color = fac
	_banner_pendant.add_child(flag)

	var fout := Line2D.new()
	fout.points = PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(fw, -fh * 0.28),
		Vector2(fw, fh * 0.50), Vector2(0.0, fh * 0.45), Vector2(0.0, 0.0)
	])
	fout.width = 2.0
	fout.default_color = accent.darkened(0.15)
	_banner_pendant.add_child(fout)

	var mark := Polygon2D.new()
	mark.color = Color(1.0, 1.0, 1.0, 0.92)
	mark.polygon = _emblem_polygon(category, size * 0.26)
	mark.position = Vector2(fw * 0.42, fh * 0.10)
	_banner_pendant.add_child(mark)

	# 旗帜绕旗杆顶端轻摆（布料感）
	_banner_tween = create_tween()
	_banner_tween.set_loops(true)
	_banner_tween.tween_property(_banner_pendant, "rotation", 0.09, 1.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_banner_tween.tween_property(_banner_pendant, "rotation", -0.05, 1.5).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


## 兵种图标贴图：assets/sprites/units/<unit_id>.png（缺失返回 null）
func _load_unit_icon() -> Texture2D:
	if unit_id.is_empty():
		return null
	var path := UNIT_ICON_DIR + unit_id + ".png"
	if ResourceLoader.exists(path):
		var res := load(path)
		if res is Texture2D:
			return res
	return null


func _hex_points(r: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in range(6):
		var t := float(i) / 6.0 * TAU - PI * 0.5
		pts.append(Vector2(cos(t), sin(t)) * r)
	return pts


func unit_size() -> float:
	return 26.0 + clampf(float(count) / 12.0, 0.0, 20.0)


static func category_color(cat: String) -> Color:
	match cat:
		"infantry": return Color(0.4, 0.72, 0.5)
		"cavalry": return Color(0.75, 0.68, 0.35)
		"archer": return Color(0.45, 0.62, 0.85)
		"beast": return Color(0.62, 0.45, 0.72)
		"elite": return Color(0.85, 0.6, 0.3)
		"special": return Color(0.55, 0.72, 0.55)
		"navy": return Color(0.38, 0.6, 0.75)
		_: return Color(0.6, 0.6, 0.6)


## ---------- 主循环 ----------

func tick(delta: float, enemies: Array) -> void:
	if _dead or state == State.DEAD:
		return

	_attack_cd = maxf(0.0, _attack_cd - delta)
	if charge_timer > 0.0:
		charge_timer = maxf(0.0, charge_timer - delta)
	# 武将技能限时 buff 衰减
	if buff_defense_timer > 0.0:
		buff_defense_timer = maxf(0.0, buff_defense_timer - delta)
		if buff_defense_timer <= 0.0:
			buff_defense_add = 0.0
	if buff_rapid_timer > 0.0:
		buff_rapid_timer = maxf(0.0, buff_rapid_timer - delta)

	match state:
		State.ROUTED:
			_do_rout(delta)
		State.ENGAGE:
			_do_engage(delta, enemies)
		State.ADVANCE:
			_do_advance(delta, enemies)
		_:
			_do_idle(delta, enemies)

	_refresh_bar()
	_refresh_flash(delta)
	_bob += delta * 6.0
	# 待机呼吸 + 视觉偏移一次性合成到本体：分两次写会被后者覆盖
	_apply_impulse(delta)


## 推进视觉位移的弹簧，并写到底座 / 描边 / 兵种图标上。
## 血条与名牌**不**参与：它们跟着晃会让战况读不清。
func _apply_impulse(delta: float) -> void:
	if _vis_off != Vector2.ZERO or _vis_vel != Vector2.ZERO:
		# 弹簧回中：a = -k·x - c·v
		_vis_vel += (-_vis_off * VIS_SPRING - _vis_vel * VIS_DAMP) * delta
		_vis_off += _vis_vel * delta
		if _vis_off.length() < 0.15 and _vis_vel.length() < 1.0:
			_vis_off = Vector2.ZERO
			_vis_vel = Vector2.ZERO
	# 整组画面随视觉偏移平移；底座再叠待机呼吸起伏（血条/名牌不参与）
	_art.position = _vis_off
	var bob := Vector2(0.0, sin(_bob) * 1.5)
	_body.position = bob
	_outline.position = bob


## 出手前突：朝目标扑一下（视觉）
func _lunge_toward(other: BattleUnit) -> void:
	if other == null or not is_instance_valid(other):
		return
	var dir := other.position - position
	if dir.length_squared() < 1.0:
		return
	_vis_vel += dir.normalized() * CombatFeelService.lunge_speed()


## 受击击退：沿"攻击者 → 自己"方向退开（视觉）。
## from 为空（主角攻击/大招）时按"向右"退——主角在战场左侧，敌军在右。
func _knock_from(from: BattleUnit) -> void:
	var dir := Vector2(1.0, 0.0)
	if from != null and is_instance_valid(from):
		var d := position - from.position
		if d.length_squared() >= 1.0:
			dir = d.normalized()
	_vis_vel += dir * CombatFeelService.knock_speed()


## 待机：立即找目标
func _do_idle(delta: float, enemies: Array) -> void:
	_acquire_target(enemies)
	if target != null:
		state = State.ENGAGE if _in_range(target) else State.ADVANCE
		return
	# 无目标时缓慢恢复士气（固守恢复更快）
	_recover_morale(delta)


## 士气自然恢复：脱战状态下缓慢回升，固守时加倍
func _recover_morale(delta: float) -> void:
	if state == State.ROUTED:
		return
	var rate := float(_cfg.get("combat", {}).get("morale_recover_rate", 0.9))
	if hold_position:
		rate *= 2.0
	morale = minf(100.0, morale + rate * delta)


## 推进：向目标移动
func _do_advance(delta: float, enemies: Array) -> void:
	if target == null or target.is_gone():
		_acquire_target(enemies)
	if target == null:
		state = State.IDLE
		return

	if _in_range(target):
		state = State.ENGAGE
		return

	# 固守时只做小范围调整，不主动出击
	if hold_position and absf(target.position.x - position.x) > float(_cfg.get("combat", {}).get("engage_range", 110.0)) * 2.5:
		state = State.IDLE
		return

	var spd := speed * _speed_mult()
	var dir := (target.position - position).normalized()
	position += dir * spd * delta
	_face(dir)


## 交战：够到就打
func _do_engage(delta: float, enemies: Array) -> void:
	if target == null or target.is_gone():
		target = null
		state = State.ADVANCE
		_acquire_target(enemies)
		return

	if not _in_range(target):
		state = State.ADVANCE
		return

	_face((target.position - position).normalized())

	# 攻击间隔：与速度挂钩，越快攻速越高；连射期间减半（≈双箭）
	var interval := clampf(1.15 - speed / 400.0, 0.55, 1.2)
	if buff_rapid_timer > 0.0:
		interval *= SkillService.RAPID_FIRE_INTERVAL_MULT
	if _attack_cd <= 0.0:
		_attack_cd = interval
		_strike(target)


## 溃散：向本方后方逃跑，不参战
func _do_rout(delta: float) -> void:
	var spd := speed * float(_cfg.get("combat", {}).get("rout_speed_mult", 1.35))
	position.x -= move_dir * spd * delta
	_bob += delta * 4.0
	# 逃出战场边缘即移除
	# 【修复】敌军侧原本写成 1860（疑似把屏幕宽度复制进来），溃兵要在场上滞留
	# 十几秒才消失，与友军约 4 秒离场形成反差，其间还被友军一路追杀。
	var limit := 60.0
	if (is_ally and position.x < -limit) or (not is_ally and position.x > 1920.0 + limit):
		_die(true)


func _speed_mult() -> float:
	var m := 1.0
	if charge_timer > 0.0:
		m *= float(_cfg.get("combat", {}).get("charge_speed_mult", 1.6))
	return m


func _face(dir: Vector2) -> void:
	# 轻微左右摆动表现朝向（不做翻转，保持简洁）
	_body.scale.x = 1.0 if dir.x >= 0.0 else 1.0


func _in_range(other: BattleUnit) -> bool:
	return position.distance_to(other.position) <= range_px


## ---------- 索敌 ----------

## 目标评分：克制关系 + 低血优先 + 兵种偏好
func _acquire_target(enemies: Array) -> void:
	var best: BattleUnit = null
	var best_score := -INF

	var ai_cfg: Dictionary = _cfg.get("ai", {})
	var pri: Dictionary = ai_cfg.get("target_priority", {})
	var w_counter := float(ai_cfg.get("counter_weight", 0.55))
	var w_hp := float(ai_cfg.get("weak_hp_weight", 0.45))

	for raw in enemies:
		if not (raw is BattleUnit):
			continue
		var e: BattleUnit = raw
		if e.is_gone():
			continue
		# 距离近的优先（近战必须够得着）
		var dist := position.distance_to(e.position)
		var proximity := clampf(1.0 - dist / 1600.0, 0.0, 1.0)

		# 克制加成
		var cm := float(counter_table.get(e.unit_id, 1.0))
		var counter_score := (cm - 1.0) / 0.25      # 1.25 → +1.0，0.8 → -0.8

		# 残血优先
		var hp_ratio: float = e.hp / maxf(1.0, e.hp_max)
		var weak_score: float = 1.0 - hp_ratio

		# 兵种偏好
		var cat_score := float(pri.get(e.category, 1.0)) - 1.0

		var score: float = proximity * 1.2 \
			+ counter_score * w_counter \
			+ weak_score * w_hp \
			+ cat_score * 0.3

		if score > best_score:
			best_score = score
			best = e

	target = best


## ---------- 攻击结算 ----------

func _strike(other: BattleUnit) -> void:
	var dmg := calc_damage(self, other)
	_lunge_toward(other)          ## 出手前突：让"谁在打"看得见
	other.take_damage(dmg, self)
	damage_dealt.emit(self, dmg, dmg > base_damage() * 1.05)


## 基础伤害（不含任何加成），用于判断是否触发克制提示
func base_damage() -> float:
	var scale := float(_cfg.get("combat", {}).get("base_dps_scale", 0.085))
	return maxf(1.0, attack * (float(count) / 100.0) * scale * 10.0)


## 静态：完整伤害公式
##   攻击力 × 兵力系数 × (1+阵型阵位加成) × 克制倍率 ÷ 防御减伤 × 随机浮动
static func calc_damage(attacker: BattleUnit, defender: BattleUnit) -> float:
	if attacker == null or defender == null:
		return 0.0
	var cfg: Dictionary = attacker._cfg.get("combat", {})
	var scale := float(cfg.get("base_dps_scale", 0.085))
	var variance := float(cfg.get("damage_variance", 0.25))
	var min_dmg := float(cfg.get("min_damage", 1.0))

	# 兵力系数：兵力越少输出越低（0.3 ~ 1.0）
	var count_factor := clampf(float(attacker.count) / maxf(30.0, float(attacker.count_max)) * 0.7 + 0.3, 0.3, 1.0)

	# 克制倍率
	var cm := float(attacker.counter_table.get(defender.unit_id, 1.0))

	# 冲锋加成
	var charge := 0.0
	if attacker.charge_timer > 0.0:
		charge = float(cfg.get("charge_mult", 1.55)) - 1.0

	# 固守：攻降防升（攻方固守 → 输出下降）
	var hold_pen := 0.0
	if attacker.hold_position:
		hold_pen = float(cfg.get("hold_attack_penalty", -0.20))

	# 防御减伤：防御越高免伤越多，但保底 defense_floor 有效伤害（含铁壁限时加成）
	# 防御强度分母与保底均提为配置（defense_scale / defense_floor），数值进 JSON 不硬编码
	var total_defense := defender.defense + defender.buff_defense_add
	var defense_scale := float(cfg.get("defense_scale", 120.0))
	var defense_floor := float(cfg.get("defense_floor", 0.35))
	var defense_factor := clampf(1.0 - total_defense * defender.defense_mult / defense_scale, defense_floor, 1.0)

	var raw := attacker.attack \
		* count_factor \
		* (1.0 + attacker.attack_mult + charge + hold_pen) \
		* cm \
		* scale * 10.0

	# 防守方固守 → 额外减伤
	if defender.hold_position:
		raw *= 1.0 - float(cfg.get("hold_defense_bonus", 0.35))

	var final := raw * defense_factor
	# 随机浮动
	final *= 1.0 + randf_range(-variance, variance)
	return maxf(min_dmg, final)


## ---------- 受击 ----------

func take_damage(dmg: float, from: BattleUnit) -> void:
	if _dead:
		return
	var ccfg: Dictionary = _cfg.get("combat", {})

	# 兵力随伤害折损
	var loss := int(ceil(dmg * 0.55))
	count = maxi(0, count - loss)
	hp -= dmg

	# 士气受挫：三个来源叠加，保证「溃散」是战场上真实可见的结局，
	# 而不是所有部队都安静地打到兵力归零。
	#   ① 伤害压力：按本次伤害占最大血量的比例
	#   ② 兵力压力：残兵越少军心越散
	#   ③ 持续压力：每次挨打固定扣一点（久战必疲）
	var morale_pen := float(ccfg.get("morale_decay_per_loss", 1.6))
	var hp_lost_ratio := dmg / maxf(1.0, hp_max)
	var troop_ratio := float(count) / maxf(1.0, float(count_max))

	var dmg_pressure := hp_lost_ratio * 100.0 * 0.45
	var troop_pressure := (1.0 - troop_ratio) * 100.0 * 0.22
	var grind_pressure := 3.2

	morale = maxf(0.0, morale - (dmg_pressure + troop_pressure + grind_pressure) * morale_pen * 0.5 * morale_decay_mult)

	_flash_amount = 1.0
	_count_label.text = "%d" % count
	# 受击击退 + 伤害飘字：把"挨了一下"演出来（此前只有血条在缩）
	_knock_from(from)
	var crit := dmg > maxf(1.0, hp_max) * 0.18
	DamageNumber.pop_damage(get_parent(), position + Vector2(0.0, -unit_size() - 18.0),
		dmg, crit, is_ally)
	_burst(Color(1.0, 0.85, 0.5, 1.0), 8)   # 受击火星

	# 溃散判定（先于阵亡判定：兵败如山倒——人还在，但仗已经不想打了）
	var threshold := float(ccfg.get("rout_morale_threshold", 18.0))
	if morale <= threshold and state != State.ROUTED:
		_begin_rout()
		return

	# 阵亡判定
	if hp <= 0.0 or count <= 0:
		_die(false)


## 士气鼓舞（主角大招 / 友军击杀时调用）
func boost_morale(amount: float) -> void:
	morale = minf(100.0, morale + amount)


## 进入溃散
func _begin_rout() -> void:
	if state == State.ROUTED or _dead:
		return
	state = State.ROUTED
	target = null
	_state_label.text = "溃 散"
	_state_label.add_theme_color_override("font_color", Color(0.95, 0.5, 0.4))
	_state_label.visible = true
	unit_routed.emit(self)


## 阵亡 / 离场
func _die(fled: bool) -> void:
	if _dead:
		return
	_dead = true
	_fled = fled
	state = State.DEAD
	target = null
	unit_died.emit(self)
	_play_death()


## 阵亡演出：下沉 + 变暗 + 缩小 + 淡出，然后才真正离场。
## 【为什么改】旧实现是 `visible = false` —— 部队"啪"一下就没了，
## 玩家根本没看清是哪支队没了，战场读起来非常生硬。
## 注意：_dead 已在前面置真，director 的 _live() 立刻就不把它算作活单位，
## 所以渐隐期间它不会再被选为目标、也不会再参与结算。
func _play_death() -> void:
	_vis_off = Vector2.ZERO
	_vis_vel = Vector2.ZERO
	if _banner_tween != null and _banner_tween.is_valid():
		_banner_tween.kill()
	_art.modulate = Color.WHITE
	_burst(Color(0.60, 0.50, 0.40, 1.0), 14)   # 阵亡尘土迸散
	var life := CombatFeelService.death_fade()
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(self, "position:y", position.y + CombatFeelService.death_sink(), life)
	tw.tween_property(self, "modulate:a", 0.0, life)
	tw.tween_property(self, "scale", Vector2(0.72, 0.72), life)
	tw.chain().tween_callback(func(): visible = false)


## 受击 / 阵亡的粒子迸发（一次性 CPUParticles2D，用后自毁）。
## 受击火星 + 阵亡尘土让"挨打 / 倒下"更可读（纯程序化、零新资源）。
func _burst(color: Color, amount: int) -> void:
	if not is_inside_tree():
		return
	var p := CPUParticles2D.new()
	p.emitting = true
	p.one_shot = true
	p.amount = amount
	p.lifetime = 0.45
	p.direction = Vector2(0.0, -1.0)
	p.spread = 70.0
	p.initial_velocity_min = 30.0
	p.initial_velocity_max = 95.0
	p.gravity = Vector2(0.0, 140.0)
	p.scale_amount_min = 0.4
	p.scale_amount_max = 1.1
	p.color = color
	p.position = Vector2(0.0, -unit_size() * 0.4)
	add_child(p)
	var t := get_tree().create_timer(0.7)
	t.timeout.connect(p.queue_free)


func is_gone() -> bool:
	return _dead or state == State.DEAD


func is_routed() -> bool:
	return state == State.ROUTED


## 是否溃散逃出战场（区别于被歼灭）
func is_fled() -> bool:
	return _fled


## 发起冲锋
func begin_charge() -> void:
	if _dead or state == State.ROUTED:
		return
	charge_timer = float(_cfg.get("combat", {}).get("charge_duration", 2.2))
	_state_label.text = "冲 锋"
	_state_label.add_theme_color_override("font_color", Color(1, 0.85, 0.4))
	_state_label.visible = true


## 设置固守
func set_hold(v: bool) -> void:
	hold_position = v


## ---------- 武将军团技 buff ----------

## 铁壁：防御绝对值提升 duration 秒（重复施加只刷新时间，不叠加数值）
func apply_defense_buff(amount: float, duration: float) -> void:
	if _dead or state == State.ROUTED:
		return
	buff_defense_add = amount
	buff_defense_timer = maxf(buff_defense_timer, duration)


## 连射：攻击间隔减半 duration 秒
func apply_rapid_fire(duration: float) -> void:
	if _dead or state == State.ROUTED:
		return
	buff_rapid_timer = maxf(buff_rapid_timer, duration)


func under_iron_wall() -> bool:
	return buff_defense_timer > 0.0


func under_rapid_fire() -> bool:
	return buff_rapid_timer > 0.0


## ---------- 刷新显示 ----------

func _refresh_bar() -> void:
	var ratio := clampf(hp / maxf(1.0, hp_max), 0.0, 1.0)
	_hp_fill.size.x = HP_BAR_WIDTH * ratio
	if ratio > 0.55:
		_hp_fill.color = Color(0.45, 0.85, 0.45) if is_ally else Color(0.9, 0.42, 0.38)
	elif ratio > 0.25:
		_hp_fill.color = Color(0.92, 0.78, 0.35)
	else:
		_hp_fill.color = Color(0.9, 0.3, 0.28)

	# 士气低于 45 才显示
	if morale < 45.0 and state != State.ROUTED:
		_morale_label.visible = true
		_morale_label.text = "气 %d" % int(morale)
	else:
		_morale_label.visible = false

	# 状态标签优先级：溃散 > 冲锋 > 铁壁 > 速射
	if state == State.ROUTED:
		_show_state_label("溃 散", Color(0.95, 0.5, 0.4))
	elif charge_timer > 0.0:
		_show_state_label("冲 锋", Color(1, 0.85, 0.4))
	elif buff_defense_timer > 0.0:
		_show_state_label("铁 壁", Color(0.55, 0.78, 1))
	elif buff_rapid_timer > 0.0:
		_show_state_label("速 射", Color(0.7, 1, 0.55))
	else:
		_state_label.visible = false


func _show_state_label(text: String, color: Color) -> void:
	_state_label.text = text
	_state_label.add_theme_color_override("font_color", color)
	_state_label.visible = true


func _refresh_flash(delta: float) -> void:
	if _dead:
		return
	if _flash_amount > 0.0:
		_flash_amount = maxf(0.0, _flash_amount - delta * 5.0)
		_art.modulate = Color(1, 1, 1).lerp(Color(2.2, 1.6, 1.6), _flash_amount)
	else:
		_art.modulate = Color(1, 1, 1)
