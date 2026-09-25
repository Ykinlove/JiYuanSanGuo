extends Control
## 战前阵型编辑界面（FormationEditor）· M3 / M5
## 职责：选择阵型、把部队拖入 3×5 阵位、实时显示加成与战力预估、确认后进入战场。
##
## M5 新增「演武场模式」：从城池官府进入时 GameState.drill_mode = true，
##   此时敌方为预设假想敌，布阵结果不写入存档、战斗失败无惩罚。
##
## 布局（横屏 1920×1080 · 水墨描金 UITheme）：
##   顶部 92px  描金标题（44px）+ 右上敌情 + 地形，底缘 2px 金线
##   左侧 360px 可用部队列表 + 自动布阵/清空（触控高 84px）
##   中间 648px 3×5 阵位网格（前军在上，面向敌军），行标签在网格左侧
##   右侧 690px 阵型选择（滚动）+ 战力预估 + 选中阵位详情
##   底部       撤退 / 开战（描金按钮）

const GRID_COLS := 5
const GRID_ROWS := 3
const SLOT_COUNT := GRID_ROWS * GRID_COLS

## 配色（对齐 UITheme 水墨描金；前/中/后军底色为业务语义色的暗调派生）
const C_SLOT_EMPTY := Color(0.06, 0.07, 0.10)     ## = UITheme.INK_DEEP
const C_SLOT_EMPTY_HOVER := Color(0.12, 0.13, 0.16)
const C_SLOT_FRONT := Color(0.34, 0.16, 0.14)     ## 前军底色偏红
const C_SLOT_MID := Color(0.11, 0.11, 0.10)
const C_SLOT_REAR := Color(0.12, 0.17, 0.24)      ## 后军底色偏蓝
const C_ACCENT := UITheme.GOLD

@onready var _troop_list: VBoxContainer = %TroopList
@onready var _grid: GridContainer = %Grid
@onready var _formation_list: VBoxContainer = %FormationList
@onready var _left_panel: Panel = %LeftPanel
@onready var _side_panel: Panel = %SidePanel
@onready var _power_box: Panel = %SidePanel/PowerBox
@onready var _form_detail: Label = %FormDetail
@onready var _my_power: Label = %MyPowerLabel
@onready var _enemy_power: Label = %EnemyPowerLabel
@onready var _win_rate: Label = %WinRateLabel
@onready var _filled_label: Label = %FilledLabel
@onready var _warn_label: Label = %WarnLabel
@onready var _detail_label: Label = %DetailLabel
@onready var _enemy_info: Label = %EnemyInfo
@onready var _terrain_info: Label = %TerrainInfo
@onready var _btn_auto: Button = %BtnAuto
@onready var _btn_clear: Button = %BtnClear
@onready var _btn_back: Button = %BtnBack
@onready var _btn_fight: Button = %BtnFight
@onready var _toast: Label = %ToastLabel

var _calc := FormationCalculator.new()
var _slots: Array = []              ## 长度 15，值为部队索引或 -1
var _selected_troop: int = -1       ## 左侧选中的部队索引
var _selected_slot: int = -1        ## 当前查看详情的阵位
var _slot_nodes: Array = []         ## 15 个阵位节点
var _slot_cards: Array = []         ## 15 个卡片（Node2D 风格的 Control）
var _troop_rows: Array = []         ## 左侧部队行
var _formation_buttons: Array = []  ## 阵型按钮
var _toast_tween: Tween


func _ready() -> void:
	_calc.ensure_loaded()

	# 全局水墨描金风格：三块面板套圆角金边内嵌底，固定按钮套描金样式
	_left_panel.add_theme_stylebox_override("panel", UITheme.inner_style())
	_side_panel.add_theme_stylebox_override("panel", UITheme.inner_style())
	_power_box.add_theme_stylebox_override("panel", UITheme.inner_style())
	for b: Button in [_btn_auto, _btn_clear, _btn_back, _btn_fight]:
		UITheme.style_button(b)

	# 初始化阵位数组（从存档恢复，或空）
	_slots = []
	for i in range(SLOT_COUNT):
		_slots.append(-1)

	var saved: Array = GameState.formation_slots
	if saved.size() == SLOT_COUNT:
		for i in range(SLOT_COUNT):
			_slots[i] = int(saved[i])

	_build_grid()
	_build_formation_list()
	_build_troop_list()
	_show_enemy_info()

	_btn_auto.pressed.connect(_on_auto_arrange)
	_btn_clear.pressed.connect(_on_clear)
	_btn_back.pressed.connect(_on_back)
	_btn_fight.pressed.connect(_on_fight)

	# toast 由全局 ToastLayer autoload 统一消费（B2/B4/B11 一揽子修复），本地不再重复连接

	# 演练模式的按钮文案改为「试演」，提示这是不消耗的沙盘推演
	if GameState.drill_mode:
		_btn_fight.text = "试  演"
		_btn_back.text = "退出演武"

	# 首次进入若无配置，自动布阵，避免玩家面对空网格
	if _count_filled() == 0 and not GameState.troops.is_empty():
		_on_auto_arrange()

	_refresh_all()


## ---------- 样式 helper ----------

## 行按钮（部队行 / 阵型按钮）：常态描金样式，选中态金底金边
func _style_row_btn(btn: Button, selected: bool) -> void:
	if selected:
		btn.add_theme_stylebox_override("normal",
			UITheme.btn_style(UITheme.GOLD_HOVER, UITheme.GOLD_LINE))
	else:
		UITheme.style_button(btn)


## 阵位卡片样式：行底色 + 圆角，选中时 3px 金边
func _slot_style(bg: Color, selected: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = UITheme.GOLD_LINE if selected else UITheme.GOLD_DIM
	sb.set_border_width_all(3 if selected else 1)
	sb.set_corner_radius_all(10)
	return sb


## ---------- 构建：阵位网格 ----------

func _build_grid() -> void:
	for i in range(SLOT_COUNT):
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(124, 156)
		btn.add_theme_font_size_override("font_size", 21)
		btn.clip_text = true
		var idx := i
		btn.pressed.connect(func(): _on_slot_pressed(idx))
		_grid.add_child(btn)
		_slot_nodes.append(btn)


## ---------- 构建：阵型选择列表 ----------

func _build_formation_list() -> void:
	for f in DataManager.get_table("formations"):
		var fid := str(f.get("id", ""))
		var btn := UITheme.button(str(f.get("name", fid)), 21, Vector2(352, 84))
		btn.pressed.connect(func(): _on_formation_chosen(fid))
		_formation_list.add_child(btn)
		_formation_buttons.append({"id": fid, "btn": btn})


## ---------- 构建：可用部队列表 ----------

func _build_troop_list() -> void:
	for child in _troop_list.get_children():
		child.queue_free()
	_troop_rows.clear()

	if GameState.troops.is_empty():
		var empty := Label.new()
		empty.text = "（暂无部队）\n请在兵营征兵"
		empty.add_theme_font_size_override("font_size", 21)
		empty.add_theme_color_override("font_color", UITheme.DIM)
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_troop_list.add_child(empty)
		return

	for i in range(GameState.troops.size()):
		var row := _make_troop_row(i)
		_troop_list.add_child(row)
		_troop_rows.append(row)


func _make_troop_row(index: int) -> Control:
	var troop: Dictionary = GameState.troops[index]
	var unit := DataManager.get_unit(str(troop.get("unit_id", "")))
	var unit_name := str(unit.get("name", troop.get("unit_id", "?")))
	var count := int(troop.get("count", 0))
	var cat := str(unit.get("category", ""))

	var btn := Button.new()
	btn.custom_minimum_size = Vector2(328, 88)
	btn.add_theme_font_size_override("font_size", 21)
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.text = "%s  ×%d\n【%s】" % [unit_name, count, _category_cn(cat)]
	btn.pressed.connect(func(): _on_troop_pressed(index))
	UITheme.style_button(btn)
	return btn


func _category_cn(cat: String) -> String:
	match cat:
		"infantry": return "步兵"
		"cavalry": return "骑兵"
		"archer": return "弓兵"
		"beast": return "兽兵"
		"special": return "特殊"
		"navy": return "水军"
		"elite": return "精锐"
		_: return cat


## ---------- 交互：部队选择 ----------

func _on_troop_pressed(index: int) -> void:
	AudioManager.sfx_click()
	# 再次点击已选中的部队 → 取消选中
	if _selected_troop == index:
		_selected_troop = -1
	else:
		_selected_troop = index
	_refresh_troop_highlight()
	_refresh_grid()


func _refresh_troop_highlight() -> void:
	for i in range(_troop_rows.size()):
		var btn: Button = _troop_rows[i]
		_style_row_btn(btn, i == _selected_troop)


## ---------- 交互：阵位点击 ----------

func _on_slot_pressed(index: int) -> void:
	AudioManager.sfx_click()

	# 情形 A：左侧有选中部队 → 放置
	if _selected_troop >= 0:
		_place_troop(index, _selected_troop)
		return

	# 情形 B：阵位上有部队 → 点击取下（放回左侧）
	if _slots[index] >= 0:
		var removed := int(_slots[index])
		_slots[index] = -1
		show_toast("已取下 %s" % _unit_name_of(removed))
		_selected_slot = index
		_refresh_all()
		return

	# 情形 C：空格 → 仅查看详情
	_selected_slot = index
	_refresh_grid()
	_refresh_detail()


## 放置部队（含"已在别处则移动"逻辑）
func _place_troop(slot_index: int, troop_index: int) -> void:
	var prev_slot := _slots.find(troop_index)

	# 目标格已有其他部队 → 两者互换位置
	var occupant := int(_slots[slot_index])
	if occupant >= 0 and occupant != troop_index:
		if prev_slot >= 0:
			_slots[prev_slot] = occupant
		else:
			_slots[slot_index] = -1   # 目标部队被换出到左侧
		show_toast("%s ⇄ %s" % [_unit_name_of(troop_index), _unit_name_of(occupant)])
	else:
		if prev_slot >= 0:
			_slots[prev_slot] = -1
		show_toast("%s → %s" % [_unit_name_of(troop_index), _calc.slot_label(slot_index)])

	_slots[slot_index] = troop_index
	_selected_slot = slot_index
	_selected_troop = -1
	_refresh_all()


func _unit_name_of(troop_index: int) -> String:
	if troop_index < 0 or troop_index >= GameState.troops.size():
		return "?"
	var troop: Dictionary = GameState.troops[troop_index]
	var unit := DataManager.get_unit(str(troop.get("unit_id", "")))
	return str(unit.get("name", troop.get("unit_id", "?")))


## ---------- 阵型选择 ----------

func _on_formation_chosen(formation_id: String) -> void:
	AudioManager.sfx_click()
	GameState.formation_id = formation_id
	_refresh_formation_list()
	_refresh_power()


func _refresh_formation_list() -> void:
	var current := GameState.formation_id
	var f := DataManager.get_formation(current)
	for entry in _formation_buttons:
		var btn: Button = entry["btn"]
		_style_row_btn(btn, entry["id"] == current)

	# 阵型详情
	if f.is_empty():
		_form_detail.text = "（未选择阵型）"
		return
	var lines: Array[String] = []
	lines.append("效果：%s" % str(f.get("effect_desc", "")))
	lines.append("适用：%s" % str(f.get("best_for", "")))
	var extras: Array[String] = []
	if f.has("flank_bonus"):
		extras.append("侧击 +%d%%" % int(float(f["flank_bonus"]) * 100))
	if f.has("morale_cost"):
		extras.append("士气消耗 ×%.1f" % float(f["morale_cost"]))
	if not extras.is_empty():
		lines.append("附加：" + "，".join(extras))
	_form_detail.text = "\n".join(lines)


## ---------- 自动布阵 / 清空 ----------

func _on_auto_arrange() -> void:
	AudioManager.sfx_confirm()
	_slots = _calc.auto_arrange(GameState.troops)
	_selected_troop = -1
	show_toast("已按兵种自动布阵")
	_refresh_all()


func _on_clear() -> void:
	AudioManager.sfx_click()
	for i in range(SLOT_COUNT):
		_slots[i] = -1
	_selected_troop = -1
	show_toast("已清空阵位")
	_refresh_all()


## ---------- 刷新 ----------

func _refresh_all() -> void:
	_refresh_troop_highlight()
	_refresh_formation_list()
	_refresh_grid()
	_refresh_power()
	_refresh_detail()


func _refresh_grid() -> void:
	for i in range(SLOT_COUNT):
		var btn: Button = _slot_nodes[i]
		var row := FormationCalculator.row_of(i)
		var troop_index := int(_slots[i])
		var is_sel := i == _selected_slot

		# 底色按行区分
		var base := C_SLOT_EMPTY
		match row:
			0: base = C_SLOT_FRONT
			1: base = C_SLOT_MID
			2: base = C_SLOT_REAR

		if troop_index >= 0:
			base = base.lightened(0.22)
		btn.add_theme_stylebox_override("normal", _slot_style(base, is_sel))
		btn.add_theme_stylebox_override("hover",
			_slot_style(base.lightened(0.12) if not is_sel else base.lightened(0.06), is_sel))
		btn.add_theme_stylebox_override("pressed", _slot_style(base.darkened(0.1), is_sel))
		btn.add_theme_stylebox_override("focus", _slot_style(base.lightened(0.12), is_sel))

		# 文本：部队名 + 人数 + 加成摘要
		var sb := _calc.slot_bonus(i)
		var ab := float(sb.get("attack_bonus", 0.0))
		var db := float(sb.get("defense_bonus", 0.0))
		var tag := _bonus_tag(ab, db)

		if troop_index >= 0:
			var troop: Dictionary = GameState.troops[troop_index]
			var unit := DataManager.get_unit(str(troop.get("unit_id", "")))
			var uname := str(unit.get("name", "?"))
			var count := int(troop.get("count", 0))
			btn.text = "%s\n×%d\n%s" % [uname, count, tag]
			btn.add_theme_color_override("font_color", UITheme.TEXT)
		else:
			var short_label := _short_slot_name(i)
			btn.text = "%s\n%s" % [short_label, tag]
			btn.add_theme_color_override("font_color", UITheme.DIM)

		# 选中态高亮：金边（stylebox）+ 字色提亮
		if is_sel:
			btn.add_theme_color_override("font_color", Color(1, 0.95, 0.8))


func _short_slot_name(index: int) -> String:
	var label := _calc.slot_label(index)
	var parts := label.split("·")
	if parts.size() == 2:
		return "%s\n%s" % ["攻" if float(_calc.slot_bonus(index).get("attack_bonus", 0.0)) > 0.0 else "守", parts[1]]
	return label


func _bonus_tag(atk: float, dfn: float) -> String:
	if is_zero_approx(atk) and is_zero_approx(dfn):
		return "－"
	var parts: Array[String] = []
	if not is_zero_approx(atk):
		parts.append("攻%+d" % int(round(atk * 100)))
	if not is_zero_approx(dfn):
		parts.append("防%+d" % int(round(dfn * 100)))
	return " ".join(parts)


func _refresh_power() -> void:
	var formation := DataManager.get_formation(GameState.formation_id)
	var result := _calc.calculate(_slots, GameState.troops, formation)
	var my_power := float(result["total_power"])
	var enemy_power := _calc.estimate_enemy_power(GameState.current_encounter)
	var rate := _calc.estimate_win_rate(my_power, enemy_power)

	_my_power.text = "我方 %d" % int(my_power)
	# 【R1-16】敌方仅按兵力×品质粗估（无武将/阵型/装备加成），标注「约」防玩家按预估轻敌
	_enemy_power.text = "敌方约 %d" % int(enemy_power)
	_win_rate.text = "胜率约 %d%%" % int(round(rate * 100))
	_win_rate.add_theme_color_override("font_color",
		UITheme.GOOD if rate >= 0.6 else (UITheme.POINT if rate >= 0.4 else UITheme.BAD))
	_filled_label.text = "已布置 %d/%d" % [int(result["filled"]), SLOT_COUNT]

	# 汇总警告
	var warns: Array = []
	for d in result["detail"]:
		for w in d.get("warnings", []):
			if not warns.has(w):
				warns.append(w)
	if warns.is_empty():
		_warn_label.text = "布阵合理"
		_warn_label.add_theme_color_override("font_color", UITheme.GOOD)
	else:
		var shown: Array = warns.slice(0, 4)
		_warn_label.text = "· " + "\n· ".join(PackedStringArray(shown))
		_warn_label.add_theme_color_override("font_color", UITheme.WARN)


func _refresh_detail() -> void:
	if not FormationCalculator.is_valid_index(_selected_slot):
		_detail_label.text = "点选阵位查看详情"
		return
	var idx := _selected_slot
	var sb := _calc.slot_bonus(idx)
	var lines: Array[String] = []
	lines.append("【%s】" % _calc.slot_label(idx))
	lines.append(str(sb.get("desc", "")))

	var troop_index := int(_slots[idx])
	if troop_index >= 0:
		var troop: Dictionary = GameState.troops[troop_index]
		var unit := DataManager.get_unit(str(troop.get("unit_id", "")))
		var cat := str(unit.get("category", ""))
		lines.append("")
		lines.append("驻守：%s ×%d" % [str(unit.get("name", "?")), int(troop.get("count", 0))])
		var hero_id := str(troop.get("hero_id", ""))
		if not hero_id.is_empty():
			var hero := DataManager.get_hero_resolved(hero_id)
			if not hero.is_empty():
				var hline := "武将：%s" % str(hero.get("name", "?"))
				var sid := SkillService.hero_troop_skill(hero)
				if sid > 0:
					hline += "　特技：%s（%s）" % [SkillService.skill_name(sid), SkillService.skill_short(sid)]
				lines.append(hline)
		var rm := _calc.row_match_bonus(idx, cat)
		if rm["kind"] == "good":
			lines.append("协同：%s" % rm["desc"])
		elif rm["kind"] == "bad":
			lines.append("冲突：%s" % rm["desc"])
		else:
			lines.append("协同：无特殊加成")
		# 该位战力
		var formation := DataManager.get_formation(GameState.formation_id)
		var result := _calc.calculate(_slots, GameState.troops, formation)
		for d in result["detail"]:
			if int(d["slot"]) == idx:
				lines.append("战力：%d" % int(d["power"]))
				break
	else:
		lines.append("")
		lines.append("（空阵位）")

	_detail_label.text = "\n".join(lines)


func _count_filled() -> int:
	var n := 0
	for v in _slots:
		if int(v) >= 0:
			n += 1
	return n


## ---------- 敌情展示 ----------

func _show_enemy_info() -> void:
	# 演武场模式：显式标注，避免玩家误以为在打真实战役
	if GameState.drill_mode:
		_enemy_info.add_theme_color_override("font_color", UITheme.REL_FRIEND)
		_terrain_info.add_theme_color_override("font_color", UITheme.REL_FRIEND)

	var enc: Dictionary = GameState.current_encounter
	if enc.is_empty():
		_enemy_info.text = "敌情：无（自由演练）"
		_terrain_info.text = "地形：平原"
		return

	var prefix := "演武 · " if GameState.drill_mode else ""
	var enc_name := str(enc.get("name", "敌军"))
	var unit_names: Array[String] = []
	for u in enc.get("enemy_units", []):
		var unit := DataManager.get_unit(str(u.get("unit_id", "")))
		if not unit.is_empty():
			unit_names.append("%s×%d" % [str(unit.get("name", "?")), int(u.get("count", 0))])
	_enemy_info.text = "%s敌情：%s（%s）" % [prefix, enc_name, "、".join(unit_names) if not unit_names.is_empty() else "未知"]
	_terrain_info.text = "地形：%s　天气：晴" % str(enc.get("terrain", "plain"))
	if GameState.drill_mode:
		_terrain_info.text += "　　（演练不消耗兵力，无奖励）"


## ---------- 开战 / 撤退 ----------

func _on_fight() -> void:
	# 【用户需求】不再强制必须布阵：即便没有任何部队、所有阵位全空，
	# 主角单人也可直接开战。布阵功能与提示保留，但不作为开战前置条件。
	# 开战按钮始终可点击。
	# 空阵时给出轻量提示（非阻塞），引导玩家仍可选择手动布阵。
	# 【C3 空阵 1v1】一支部队都没布置时，战场不再摆一场必败的兵力对冲，
	# 而是直接由主角出阵单挑，胜负即整场遭遇的结果（见 battle_scene._on_duel_finished）。
	GameState.duel_only = (_count_filled() == 0)
	if GameState.duel_only:
		show_toast("部队全空，主角将只身迎战")
	AudioManager.sfx_confirm()

	if GameState.drill_mode:
		# 演武场模式：不写回存档、不自动保存，仅把当前摆法带给战场
		show_toast("演武开始——本局不消耗兵力")
		SceneRouter.goto("battle")
		return

	# 写回状态（【R1-21】开战前不再全量写盘——formation_slots 已在 GameState 内存态，
	# 战斗结算侧会统一 auto_save；省掉一场战斗两次全量 JSON 同步写的一次）
	GameState.formation_slots = _slots.duplicate()

	# 进入战场
	SceneRouter.goto("battle")


func _on_back() -> void:
	AudioManager.sfx_cancel()
	# 演练退出时清掉演练标记，避免污染后续真实遭遇
	if GameState.drill_mode:
		GameState.drill_mode = false
		GameState.current_encounter = {}
	SceneRouter.back()


## ---------- 提示 ----------

func show_toast(message: String) -> void:
	_toast.text = message
	_toast.modulate.a = 1.0
	if _toast_tween and _toast_tween.is_valid():
		_toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_interval(1.8)
	_toast_tween.tween_property(_toast, "modulate:a", 0.0, 0.4)
