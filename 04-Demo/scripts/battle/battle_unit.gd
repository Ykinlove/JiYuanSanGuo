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

## 绘制节点
var _body: Polygon2D
var _outline: Line2D
var _hp_bg: ColorRect
var _hp_fill: ColorRect
var _name_label: Label
var _count_label: Label
var _morale_label: Label
var _state_label: Label


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
	var color := category_color(category)
	var size := unit_size()

	_body = Polygon2D.new()
	# 六边形底座，模拟"方阵"
	_body.polygon = _hex_points(size)
	_body.color = color
	add_child(_body)

	# 兵种图标（AI 美术批次）：叠在六边形底座上，一眼可辨兵种；缺图则纯几何。
	var icon_tex := _load_unit_icon()
	if icon_tex != null:
		var icon := Sprite2D.new()
		icon.texture = icon_tex
		var w := float(maxi(1, icon_tex.get_width()))
		var isc := (size * 1.7) / w
		icon.scale = Vector2(isc, isc)
		# 敌军图标偏红压暗，与友军区分；底座颜色仍按兵种类别
		icon.modulate = Color(1, 1, 1) if is_ally else Color(1.0, 0.72, 0.68)
		add_child(icon)

	_outline = Line2D.new()
	var pts := _hex_points(size)
	pts.append(pts[0])
	_outline.points = pts
	_outline.width = 2.0
	_outline.default_color = color.darkened(0.5)
	add_child(_outline)

	# 血条
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

	if not is_ally:
		# 敌军整体降低一点亮度以作区分
		modulate = Color(1, 0.96, 0.96)


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
	_body.position.y = sin(_bob) * 1.5


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
	var limit := 60.0 if is_ally else 1860.0
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

	# 防御减伤：防御越高免伤越多，但保底 35% 有效伤害（含铁壁限时加成）
	var total_defense := defender.defense + defender.buff_defense_add
	var defense_factor := clampf(1.0 - total_defense * defender.defense_mult / 120.0, 0.35, 1.0)

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
	visible = false
	unit_died.emit(self)


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
	if _flash_amount > 0.0:
		_flash_amount = maxf(0.0, _flash_amount - delta * 5.0)
		_body.modulate = Color(1, 1, 1).lerp(Color(2.2, 1.6, 1.6), _flash_amount)
	else:
		_body.modulate = Color(1, 1, 1)
