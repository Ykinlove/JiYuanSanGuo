extends Control
## 新建角色（CreateHero）
## 三步流程：姓名/性别 → 四维分配（20 点）→ 天赋（个人技）→ 落 GameState 并开局。
## 界面只负责收集与展示；写入一律走 GameState.reset() + 字段赋值 + SaveManager，界面不含规则判断。
## 风格：水墨描金暗色（墨底 #171B26 / 描金 #C7A45C），与 interaction_menu / world_map 一致。

# ---------- 步骤 ----------
const STEP_NAME := 0
const STEP_ATTR := 1
const STEP_TALENT := 2

# ---------- 属性分配规则 ----------
const BASE_STAT := 10      ## 四维基础值（与 GameState.reset() 保持一致）
const POOL := 20           ## 可分配点数
const MAX_STAT := 30       ## 单项上限
const NAME_MAX := 8

# ---------- 水墨描金调色板 ----------
const C_INK := Color(0.09, 0.11, 0.15, 0.96)          ## 墨底 #171B26
const C_INK_DEEP := Color(0.06, 0.07, 0.10, 0.96)
const C_GOLD := Color(0.78, 0.64, 0.36, 1.0)          ## 描金 #C7A45C
const C_GOLD_DIM := Color(0.62, 0.52, 0.32, 0.92)
const C_TEXT := Color(0.92, 0.88, 0.80, 1.0)
const C_DIM := Color(0.64, 0.60, 0.54, 1.0)
const C_GOOD := Color(0.62, 0.84, 0.62, 1.0)
const C_POINT := Color(0.96, 0.82, 0.40, 1.0)

# ---------- 数据 ----------
const STAT_DEFS := [
	{ "key": "constitution", "name": "体质", "desc": "影响生命与负重" },
	{ "key": "strength",     "name": "力量", "desc": "影响物理攻击与带兵" },
	{ "key": "intelligence", "name": "智力", "desc": "影响策略与计谋" },
	{ "key": "charisma",     "name": "魅力", "desc": "影响招募与外交" },
]

## 预设：四项之和恒为 20
const PRESETS := [
	{ "name": "猛将", "tip": "力量为主，冲锋陷阵", "add": { "strength": 10, "constitution": 6, "charisma": 3, "intelligence": 1 } },
	{ "name": "谋士", "tip": "智力为主，运筹帷幄", "add": { "intelligence": 10, "charisma": 5, "constitution": 3, "strength": 2 } },
	{ "name": "仁主", "tip": "魅力为主，广纳贤才", "add": { "charisma": 10, "constitution": 5, "intelligence": 3, "strength": 2 } },
	{ "name": "鬼才", "tip": "智体兼顾，奇谋频出", "add": { "intelligence": 10, "constitution": 4, "charisma": 4, "strength": 2 } },
	{ "name": "均衡", "tip": "四项均分，稳扎稳打", "add": { "constitution": 5, "strength": 5, "intelligence": 5, "charisma": 5 } },
]

const SURNAMES := ["刘", "关", "张", "赵", "马", "黄", "孙", "周", "曹", "荀",
	"郭", "吕", "许", "袁", "徐", "朱", "陆", "姜", "邓", "钟",
	"司马", "诸葛", "夏侯", "公孙", "太史", "皇甫"]
const GIVEN_NAMES := ["玄德", "云长", "翼德", "子龙", "孟起", "汉升", "仲谋", "公瑾", "孟德", "文若",
	"奉孝", "奉先", "仲康", "本初", "文远", "公覆", "伯言", "伯约", "士载", "士季",
	"子瑜", "元直", "子廉", "伯珪", "子义", "威明"]

## 性别：id 与 DataManager.get_hero_resolved() 的主角约定一致
const GENDERS := [
	{ "id": "player_male",   "name": "男", "desc": "少年轻侠，仗剑走四方" },
	{ "id": "player_female", "name": "女", "desc": "乱世巾帼，智勇不让须眉" },
]

const KIND_LABEL := { "damage": "攻击", "shield": "护体", "heal": "回复" }

# ---------- 运行时状态 ----------
var _step: int = STEP_NAME
var _gender: String = "player_male"
var _adds: Dictionary = { "constitution": 0, "strength": 0, "intelligence": 0, "charisma": 0 }
var _talent_id: int = 1

# ---------- 控件缓存 ----------
var _step_title: Label
var _step_hint: Label
var _dots: Array = []
var _body: VBoxContainer
var _name_edit: LineEdit
var _pool_label: Label
var _attr_rows: Array = []
var _talent_rows: Array = []
var _btn_prev: Button
var _btn_next: Button
var _btn_reroll: Button
var _btn_reset: Button
var _av: Label
var _pv_name: Label
var _pv_gender: Label
var _pv_stats: VBoxContainer
var _pv_talent: Label
var _pv_talent_desc: Label


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_talent_id = GameState.personal_skill if SkillService.is_personal_skill(GameState.personal_skill) else 1
	_build()
	_rebuild_body()
	_refresh_preview()


## ---------- 骨架 ----------
func _build() -> void:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var card := PanelContainer.new()
	var vp := get_viewport_rect().size
	card.custom_minimum_size = Vector2(minf(1560.0, maxf(900.0, vp.x - 80.0)),
		minf(920.0, maxf(520.0, vp.y - 80.0)))
	card.add_theme_stylebox_override("panel", _card_style())
	center.add_child(card)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 14)
	card.add_child(root)

	# 头部：标题 + 步骤指示
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 20)
	var title := Label.new()
	title.text = "创　角"
	title.add_theme_font_size_override("font_size", 40)
	title.add_theme_color_override("font_color", C_GOLD)
	head.add_child(title)

	var step_box := HBoxContainer.new()
	step_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	step_box.alignment = BoxContainer.ALIGNMENT_END
	step_box.add_theme_constant_override("separation", 12)
	head.add_child(step_box)
	for i in 3:
		var dot := Label.new()
		dot.add_theme_font_size_override("font_size", 22)
		dot.custom_minimum_size = Vector2(120, 0)
		dot.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		step_box.add_child(dot)
		_dots.append(dot)
	root.add_child(head)

	_step_title = Label.new()
	_step_title.add_theme_font_size_override("font_size", 30)
	_step_title.add_theme_color_override("font_color", C_TEXT)
	root.add_child(_step_title)
	_step_hint = Label.new()
	_step_hint.add_theme_font_size_override("font_size", 20)
	_step_hint.add_theme_color_override("font_color", C_DIM)
	_step_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_step_hint)
	root.add_child(HSeparator.new())

	# 主体：左预览 + 右步骤内容
	var mid := HBoxContainer.new()
	mid.add_theme_constant_override("separation", 24)
	mid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(mid)

	mid.add_child(_build_preview())

	var right := PanelContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_theme_stylebox_override("panel", _inner_style())
	mid.add_child(right)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(scroll)
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 14)
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_body)

	root.add_child(HSeparator.new())

	# 底部按钮
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 16)
	foot.alignment = BoxContainer.ALIGNMENT_END
	root.add_child(foot)

	_btn_reroll = Button.new()
	_btn_reroll.text = "换名"
	_btn_reroll.custom_minimum_size = Vector2(140, 58)
	_btn_reroll.add_theme_font_size_override("font_size", 22)
	_btn_reroll.pressed.connect(_on_reroll)
	foot.add_child(_btn_reroll)

	_btn_reset = Button.new()
	_btn_reset.text = "重置点数"
	_btn_reset.custom_minimum_size = Vector2(160, 58)
	_btn_reset.add_theme_font_size_override("font_size", 22)
	_btn_reset.pressed.connect(_on_reset_points)
	foot.add_child(_btn_reset)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(spacer)

	var btn_back := Button.new()
	btn_back.text = "返回主菜单"
	btn_back.custom_minimum_size = Vector2(180, 58)
	btn_back.add_theme_font_size_override("font_size", 22)
	btn_back.pressed.connect(_on_back_to_menu)
	foot.add_child(btn_back)

	_btn_prev = Button.new()
	_btn_prev.text = "上一步"
	_btn_prev.custom_minimum_size = Vector2(160, 58)
	_btn_prev.add_theme_font_size_override("font_size", 22)
	_btn_prev.pressed.connect(_on_prev)
	foot.add_child(_btn_prev)

	_btn_next = Button.new()
	_btn_next.custom_minimum_size = Vector2(200, 58)
	_btn_next.add_theme_font_size_override("font_size", 24)
	_btn_next.pressed.connect(_on_next)
	foot.add_child(_btn_next)

	for b in [_btn_reroll, _btn_reset, btn_back, _btn_prev, _btn_next]:
		(b as Button).add_theme_stylebox_override("normal", _btn_style(C_INK_DEEP, C_GOLD_DIM))
		(b as Button).add_theme_stylebox_override("hover", _btn_style(Color(0.20, 0.17, 0.11, 0.98), C_GOLD))
		(b as Button).add_theme_stylebox_override("pressed", _btn_style(Color(0.30, 0.24, 0.12, 1.0), C_GOLD))
		(b as Button).add_theme_stylebox_override("focus", _btn_style(Color(0.20, 0.17, 0.11, 0.98), C_GOLD))
		(b as Button).add_theme_color_override("font_color", C_TEXT)
		(b as Button).add_theme_color_override("font_hover_color", Color(1, 1, 1, 1))
		(b as Button).add_theme_color_override("font_pressed_color", Color(1, 0.98, 0.90, 1))
		(b as Button).add_theme_color_override("font_focus_color", Color(1, 0.98, 0.90, 1))


func _build_preview() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(360, 0)
	panel.add_theme_stylebox_override("panel", _inner_style())
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	panel.add_child(vbox)

	_av = Label.new()
	_av.custom_minimum_size = Vector2(0, 150)
	_av.add_theme_font_size_override("font_size", 84)
	_av.add_theme_color_override("font_color", C_GOLD)
	_av.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_av.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_av.add_theme_stylebox_override("normal", _inner_style())
	vbox.add_child(_av)

	_pv_name = Label.new()
	_pv_name.add_theme_font_size_override("font_size", 30)
	_pv_name.add_theme_color_override("font_color", C_TEXT)
	_pv_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_pv_name)

	_pv_gender = Label.new()
	_pv_gender.add_theme_font_size_override("font_size", 20)
	_pv_gender.add_theme_color_override("font_color", C_DIM)
	_pv_gender.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_pv_gender)

	vbox.add_child(HSeparator.new())

	var st := Label.new()
	st.text = "四维"
	st.add_theme_font_size_override("font_size", 22)
	st.add_theme_color_override("font_color", C_GOLD)
	vbox.add_child(st)

	_pv_stats = VBoxContainer.new()
	_pv_stats.add_theme_constant_override("separation", 6)
	vbox.add_child(_pv_stats)

	vbox.add_child(HSeparator.new())

	var tt := Label.new()
	tt.text = "天赋"
	tt.add_theme_font_size_override("font_size", 22)
	tt.add_theme_color_override("font_color", C_GOLD)
	vbox.add_child(tt)

	_pv_talent = Label.new()
	_pv_talent.add_theme_font_size_override("font_size", 24)
	_pv_talent.add_theme_color_override("font_color", C_POINT)
	vbox.add_child(_pv_talent)

	_pv_talent_desc = Label.new()
	_pv_talent_desc.add_theme_font_size_override("font_size", 18)
	_pv_talent_desc.add_theme_color_override("font_color", C_DIM)
	_pv_talent_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_pv_talent_desc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_pv_talent_desc)

	return panel


## ---------- 步骤内容 ----------
func _rebuild_body() -> void:
	for c in _body.get_children():
		c.queue_free()
	_attr_rows.clear()
	_talent_rows.clear()

	match _step:
		STEP_NAME:
			_build_name_step()
		STEP_ATTR:
			_build_attr_step()
		_:
			_build_talent_step()

	_step_title.text = ["一、姓名与性别", "二、四维分配", "三、天赋选择"][_step]
	_step_hint.text = [
		"取一个乱世中的名字，选定性别。名字留空则沿用随机赐名。",
		"将 %d 点分配到四维之上，点满方可继续。可先用预设一键铺开，再微调。" % POOL,
		"选定一门随身绝技，它将在战场上由你亲施。",
	][_step]
	for i in _dots.size():
		var d := _dots[i] as Label
		d.text = ["① 姓名", "② 四维", "③ 天赋"][i]
		d.add_theme_color_override("font_color", C_GOLD if i == _step else C_DIM)
	_refresh_nav()


func _build_name_step() -> void:
	# 姓名输入
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	var lab := Label.new()
	lab.text = "姓名"
	lab.custom_minimum_size = Vector2(120, 0)
	lab.add_theme_font_size_override("font_size", 24)
	lab.add_theme_color_override("font_color", C_TEXT)
	lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(lab)

	# 选性别会重建本步骤，已输入的名字必须保住，不能被随机名冲掉
	var keep := "" if _name_edit == null else _name_edit.text
	_name_edit = LineEdit.new()
	_name_edit.max_length = NAME_MAX
	_name_edit.text = keep if not keep.is_empty() else _random_name()
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.custom_minimum_size = Vector2(0, 60)
	_name_edit.add_theme_font_size_override("font_size", 26)
	_name_edit.add_theme_color_override("font_color", C_TEXT)
	_name_edit.text_changed.connect(_on_name_changed)
	row.add_child(_name_edit)

	var btn_rand := Button.new()
	btn_rand.text = "随机"
	btn_rand.custom_minimum_size = Vector2(130, 58)
	btn_rand.add_theme_font_size_override("font_size", 22)
	btn_rand.pressed.connect(_on_reroll)
	row.add_child(btn_rand)
	_body.add_child(row)

	var hint := Label.new()
	hint.text = "最多 %d 字，可随时再改。" % NAME_MAX
	hint.add_theme_font_size_override("font_size", 18)
	hint.add_theme_color_override("font_color", C_DIM)
	_body.add_child(hint)

	_body.add_child(HSeparator.new())

	var gl := Label.new()
	gl.text = "性别"
	gl.add_theme_font_size_override("font_size", 26)
	gl.add_theme_color_override("font_color", C_GOLD)
	_body.add_child(gl)

	for g in GENDERS:
		_body.add_child(_make_gender_row(g))


func _make_gender_row(g: Dictionary) -> Control:
	var gid := str(g["id"])
	var row := PanelContainer.new()
	row.add_theme_stylebox_override("panel", _row_style(gid == _gender))
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 16)
	row.add_child(hb)

	var btn := Button.new()
	btn.text = "●" if gid == _gender else "○"
	btn.custom_minimum_size = Vector2(72, 60)
	btn.add_theme_font_size_override("font_size", 26)
	btn.pressed.connect(func(): _on_pick_gender(gid))
	hb.add_child(btn)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var nm := Label.new()
	nm.text = str(g["name"])
	nm.add_theme_font_size_override("font_size", 26)
	nm.add_theme_color_override("font_color", C_TEXT)
	col.add_child(nm)
	var ds := Label.new()
	ds.text = str(g["desc"])
	ds.add_theme_font_size_override("font_size", 19)
	ds.add_theme_color_override("font_color", C_DIM)
	col.add_child(ds)
	hb.add_child(col)
	return row


func _build_attr_step() -> void:
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 16)
	_pool_label = Label.new()
	_pool_label.add_theme_font_size_override("font_size", 28)
	_pool_label.add_theme_color_override("font_color", C_POINT)
	_pool_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_pool_label)
	_body.add_child(top)

	var pl := Label.new()
	pl.text = "预设"
	pl.add_theme_font_size_override("font_size", 22)
	pl.add_theme_color_override("font_color", C_GOLD)
	_body.add_child(pl)

	var grid := GridContainer.new()
	grid.columns = 5
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 10)
	_body.add_child(grid)
	for i in PRESETS.size():
		grid.add_child(_make_preset_btn(i))

	_body.add_child(HSeparator.new())

	for sd in STAT_DEFS:
		_body.add_child(_make_attr_row(sd))

	_refresh_attr_rows()


func _make_preset_btn(idx: int) -> Control:
	var p: Dictionary = PRESETS[idx]
	var btn := Button.new()
	btn.text = str(p["name"])
	btn.custom_minimum_size = Vector2(150, 62)
	btn.add_theme_font_size_override("font_size", 23)
	btn.tooltip_text = str(p["tip"])
	btn.pressed.connect(func(): _on_preset(idx))
	_style_small_btn(btn)
	return btn


func _make_attr_row(sd: Dictionary) -> Control:
	var key := str(sd["key"])
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)

	var nm := Label.new()
	nm.text = "%s　%s" % [str(sd["name"]), str(sd["desc"])]
	nm.add_theme_font_size_override("font_size", 24)
	nm.add_theme_color_override("font_color", C_TEXT)
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nm.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(nm)

	var btn_sub := Button.new()
	btn_sub.text = "－"
	btn_sub.custom_minimum_size = Vector2(72, 58)
	btn_sub.add_theme_font_size_override("font_size", 26)
	btn_sub.pressed.connect(func(): _on_stat_sub(key))
	_style_small_btn(btn_sub)
	row.add_child(btn_sub)

	var val := Label.new()
	val.add_theme_font_size_override("font_size", 28)
	val.add_theme_color_override("font_color", C_GOOD)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	val.custom_minimum_size = Vector2(120, 0)
	val.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(val)

	var btn_add := Button.new()
	btn_add.text = "＋"
	btn_add.custom_minimum_size = Vector2(72, 58)
	btn_add.add_theme_font_size_override("font_size", 26)
	btn_add.pressed.connect(func(): _on_stat_add(key))
	_style_small_btn(btn_add)
	row.add_child(btn_add)

	_attr_rows.append({ "key": key, "value": val, "add": btn_add, "sub": btn_sub })
	return row


func _build_talent_step() -> void:
	var tip := Label.new()
	tip.text = "战场上由主角亲自施展，冷却结束后可再施。"
	tip.add_theme_font_size_override("font_size", 18)
	tip.add_theme_color_override("font_color", C_DIM)
	_body.add_child(tip)

	for sid in SkillService.PERSONAL_SKILLS:
		_body.add_child(_make_talent_row(int(sid)))
	_refresh_talent_rows()


func _make_talent_row(sid: int) -> Control:
	var meta: Dictionary = SkillService.personal_meta(sid)
	var row := PanelContainer.new()
	row.add_theme_stylebox_override("panel", _row_style(sid == _talent_id))
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 16)
	row.add_child(hb)

	var btn := Button.new()
	btn.text = "●" if sid == _talent_id else "○"
	btn.custom_minimum_size = Vector2(72, 60)
	btn.add_theme_font_size_override("font_size", 26)
	btn.pressed.connect(func(): _on_pick_talent(sid))
	_style_small_btn(btn)
	hb.add_child(btn)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var line1 := Label.new()
	line1.text = "%s　【%s】　冷却 %.0f 秒" % [
		str(meta.get("name", "技能%d" % sid)),
		str(KIND_LABEL.get(str(meta.get("kind", "damage")), "攻击")),
		float(meta.get("cooldown", 10.0))]
	line1.add_theme_font_size_override("font_size", 25)
	line1.add_theme_color_override("font_color", C_TEXT)
	col.add_child(line1)

	var line2 := Label.new()
	line2.text = str(meta.get("desc", ""))
	line2.add_theme_font_size_override("font_size", 19)
	line2.add_theme_color_override("font_color", C_DIM)
	line2.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(line2)
	hb.add_child(col)
	return row


## ---------- 交互回调 ----------
func _on_name_changed(_t: String) -> void:
	_refresh_preview()


func _on_reroll() -> void:
	AudioManager.sfx_click()
	if _name_edit != null:
		_name_edit.text = _random_name()
	_refresh_preview()


func _on_pick_gender(gid: String) -> void:
	AudioManager.sfx_click()
	_gender = gid
	_rebuild_body()
	_refresh_preview()


func _on_stat_add(key: String) -> void:
	if _pool_left() <= 0:
		AudioManager.sfx_cancel()
		EventBus.toast.emit("点数已分配完了。")
		return
	if _stat_of(key) >= MAX_STAT:
		AudioManager.sfx_cancel()
		EventBus.toast.emit("单项最高 %d 点。" % MAX_STAT)
		return
	# 注意：_adds 存的是「加点数」而非总值，不能拿 _stat_of()（含基础值）回写
	_adds[key] = int(_adds.get(key, 0)) + 1
	AudioManager.sfx_click()
	_refresh_attr_rows()
	_refresh_preview()


func _on_stat_sub(key: String) -> void:
	if int(_adds.get(key, 0)) <= 0:
		AudioManager.sfx_cancel()
		return
	_adds[key] = int(_adds.get(key, 0)) - 1
	AudioManager.sfx_click()
	_refresh_attr_rows()
	_refresh_preview()


func _on_preset(idx: int) -> void:
	var p: Dictionary = PRESETS[idx]
	var add: Dictionary = p["add"]
	for k in _adds.keys():
		_adds[k] = int(add.get(k, 0))
	AudioManager.sfx_confirm()
	_refresh_attr_rows()
	_refresh_preview()
	EventBus.toast.emit("已套用预设「%s」。" % str(p["name"]))


func _on_reset_points() -> void:
	for k in _adds.keys():
		_adds[k] = 0
	AudioManager.sfx_click()
	_refresh_attr_rows()
	_refresh_preview()


func _on_pick_talent(sid: int) -> void:
	_talent_id = sid
	AudioManager.sfx_click()
	_rebuild_body()
	_refresh_preview()


func _on_prev() -> void:
	if _step <= STEP_NAME:
		return
	AudioManager.sfx_click()
	_step -= 1
	_rebuild_body()


func _on_next() -> void:
	if _step == STEP_ATTR and _pool_left() > 0:
		AudioManager.sfx_cancel()
		EventBus.toast.emit("还有 %d 点未分配。" % _pool_left())
		return
	if _step >= STEP_TALENT:
		_confirm()
		return
	AudioManager.sfx_click()
	_step += 1
	_rebuild_body()


func _on_back_to_menu() -> void:
	AudioManager.sfx_cancel()
	SceneRouter.goto("main_menu")


## ---------- 落档开局 ----------
func _confirm() -> void:
	AudioManager.sfx_confirm()
	GameState.reset()
	GameState.player_name = _final_name()
	GameState.player_hero_id = _gender
	GameState.player_stats = {
		"constitution": _stat_of("constitution"),
		"strength": _stat_of("strength"),
		"intelligence": _stat_of("intelligence"),
		"charisma": _stat_of("charisma"),
	}
	GameState.player_attr_points = 0
	GameState.personal_skill = _talent_id
	GameState.player_talent = str(SkillService.personal_meta(_talent_id).get("name", "奇才"))
	EventBus.player_stats_changed.emit()
	SaveManager.auto_save()
	SceneRouter.push_scene("world")


## ---------- 取值与刷新 ----------
func _pool_left() -> int:
	var used := 0
	for k in _adds.keys():
		used += int(_adds[k])
	return POOL - used


func _stat_of(key: String) -> int:
	return BASE_STAT + int(_adds.get(key, 0))


func _final_name() -> String:
	if _name_edit == null:
		return _random_name()
	var s := _name_edit.text.strip_edges()
	if s.is_empty():
		s = _random_name()
		_name_edit.text = s
	return s.substr(0, NAME_MAX)


func _random_name() -> String:
	var s: String = str(SURNAMES[randi() % SURNAMES.size()])
	var g: String = str(GIVEN_NAMES[randi() % GIVEN_NAMES.size()])
	return (s + g).substr(0, NAME_MAX)


func _refresh_attr_rows() -> void:
	var left := _pool_left()
	if _pool_label != null:
		_pool_label.text = "剩余可分配　%d / %d" % [left, POOL]
	for r in _attr_rows:
		var k := str(r["key"])
		var v := _stat_of(k)
		(r["value"] as Label).text = str(v)
		(r["add"] as Button).disabled = (left <= 0 or v >= MAX_STAT)
		(r["sub"] as Button).disabled = (v <= BASE_STAT)
	_refresh_nav()


func _refresh_talent_rows() -> void:
	# 选中态由面板样式区分，重建时已带上；此处仅保证文案同步
	_refresh_nav()


func _refresh_nav() -> void:
	if _btn_prev != null:
		_btn_prev.disabled = (_step == STEP_NAME)
	if _btn_next != null:
		_btn_next.text = "就此启程" if _step == STEP_TALENT else "下一步"
		_btn_next.disabled = (_step == STEP_ATTR and _pool_left() > 0)
	if _btn_reroll != null:
		_btn_reroll.visible = (_step == STEP_NAME)
	if _btn_reset != null:
		_btn_reset.visible = (_step == STEP_ATTR)


func _refresh_preview() -> void:
	var nm := _final_name() if _name_edit != null else "无名"
	if _av != null:
		_av.text = nm.left(1) if not nm.is_empty() else "主"
	if _pv_name != null:
		_pv_name.text = nm
	if _pv_gender != null:
		for g in GENDERS:
			if str(g["id"]) == _gender:
				_pv_gender.text = "%s　·　%s" % [str(g["name"]), str(g["desc"])]
				break
	if _pv_stats != null:
		for c in _pv_stats.get_children():
			c.queue_free()
		for sd in STAT_DEFS:
			var k := str(sd["key"])
			var lab := Label.new()
			lab.text = "%s　%d" % [str(sd["name"]), _stat_of(k)]
			lab.add_theme_font_size_override("font_size", 21)
			lab.add_theme_color_override("font_color", C_TEXT)
			_pv_stats.add_child(lab)
	if _pv_talent != null:
		var meta: Dictionary = SkillService.personal_meta(_talent_id)
		_pv_talent.text = str(meta.get("name", "雷霆击"))
	if _pv_talent_desc != null:
		var meta2: Dictionary = SkillService.personal_meta(_talent_id)
		_pv_talent_desc.text = str(meta2.get("desc", ""))


## ---------- 样式 ----------
func _card_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_INK
	sb.border_color = C_GOLD
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(14)
	sb.content_margin_left = 26.0
	sb.content_margin_right = 26.0
	sb.content_margin_top = 18.0
	sb.content_margin_bottom = 18.0
	return sb


func _inner_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_INK_DEEP
	sb.border_color = C_GOLD_DIM
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 14.0
	sb.content_margin_right = 14.0
	sb.content_margin_top = 10.0
	sb.content_margin_bottom = 10.0
	return sb


func _row_style(selected: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.16, 0.13, 0.08, 0.95) if selected else C_INK_DEEP
	sb.border_color = C_GOLD if selected else C_GOLD_DIM
	sb.set_border_width_all(2 if selected else 1)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 14.0
	sb.content_margin_right = 14.0
	sb.content_margin_top = 8.0
	sb.content_margin_bottom = 8.0
	return sb


func _btn_style(bg: Color, border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(8)
	return sb


func _style_small_btn(b: Button) -> void:
	b.add_theme_stylebox_override("normal", _btn_style(C_INK_DEEP, C_GOLD_DIM))
	b.add_theme_stylebox_override("hover", _btn_style(Color(0.20, 0.17, 0.11, 0.98), C_GOLD))
	b.add_theme_stylebox_override("pressed", _btn_style(Color(0.30, 0.24, 0.12, 1.0), C_GOLD))
	b.add_theme_stylebox_override("focus", _btn_style(Color(0.20, 0.17, 0.11, 0.98), C_GOLD))
	b.add_theme_color_override("font_color", C_TEXT)
	b.add_theme_color_override("font_hover_color", Color(1, 1, 1, 1))
	b.add_theme_color_override("font_pressed_color", Color(1, 0.98, 0.90, 1))
	b.add_theme_color_override("font_focus_color", Color(1, 0.98, 0.90, 1))


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		if _step > STEP_NAME:
			_on_prev()
		else:
			_on_back_to_menu()
