extends Control
## 新建角色（CreateHero）· 手机横屏版
## 三步流程：姓名/性别 → 四维分配（10 点）→ 天赋（个人技）→ 落 GameState 并开局。
## 【比例规范】面板占视口约 86%×88%（1920×1080 下 ≈1650×950），全部触控目标 ≥84px 高；
## 步骤内容用大块列表 / 2×3 形象格子展示；底部「返回主菜单」独立居左，
## 流程按钮（重置点数/上一步/下一步）大号居右。界面只负责收集与展示，
## 写入一律走 GameState.reset() + 字段赋值 + SaveManager，界面不含规则判断。

# ---------- 步骤 ----------
const STEP_NAME := 0
const STEP_ATTR := 1
const STEP_TALENT := 2

# ---------- 属性分配规则 ----------
## 【四维随机化】用户拍板：思维（四维）每个单项在 60~80 之间随机掷出，
## 点「随 机」时姓名与四维一起重掷；立绘、性别由玩家自己选，随机不碰。
const STAT_MIN := 60      ## 四维随机下限
const STAT_MAX := 80      ## 四维随机上限（也是加点上限）
const BASE_STAT := STAT_MIN  ## 兼容旧引用：加点下限=随机下限
const POOL := 10           ## 可分配点数（在随机基础上微调）
const MAX_STAT := STAT_MAX ## 单项上限（开局四维不超过 80）
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

## 预设：四项之和恒为 10
const PRESETS := [
	{ "name": "猛将", "tip": "力量为主，冲锋陷阵", "add": { "strength": 5, "constitution": 3, "charisma": 1, "intelligence": 1 } },
	{ "name": "谋士", "tip": "智力为主，运筹帷幄", "add": { "intelligence": 5, "charisma": 2, "constitution": 2, "strength": 1 } },
	{ "name": "仁主", "tip": "魅力为主，广纳贤才", "add": { "charisma": 5, "constitution": 2, "intelligence": 2, "strength": 1 } },
	{ "name": "鬼才", "tip": "智体兼顾，奇谋频出", "add": { "intelligence": 5, "constitution": 2, "charisma": 2, "strength": 1 } },
	{ "name": "均衡", "tip": "四项均分，稳扎稳打", "add": { "constitution": 3, "strength": 3, "intelligence": 2, "charisma": 2 } },
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

## 可选主角形象立绘（男 5 / 女 5）
const PORTRAITS := [
	{ "id": "portrait_male_01", "gender": "player_male", "name": "赤甲少将" },
	{ "id": "portrait_male_02", "gender": "player_male", "name": "青衫剑客" },
	{ "id": "portrait_male_03", "gender": "player_male", "name": "羽扇谋士" },
	{ "id": "portrait_male_04", "gender": "player_male", "name": "猎装弓手" },
	{ "id": "portrait_male_05", "gender": "player_male", "name": "玄甲骑将" },
	{ "id": "portrait_female_01", "gender": "player_female", "name": "绯甲女将" },
	{ "id": "portrait_female_02", "gender": "player_female", "name": "紫衣女侠" },
	{ "id": "portrait_female_03", "gender": "player_female", "name": "碧裳医者" },
	{ "id": "portrait_female_04", "gender": "player_female", "name": "红装弓姬" },
	{ "id": "portrait_female_05", "gender": "player_female", "name": "金甲女将" },
]
const PORTRAIT_DIR := "res://assets/sprites/player/"

const KIND_LABEL := { "damage": "攻击", "shield": "护体", "heal": "回复" }

# ---------- 运行时状态 ----------
var _step: int = STEP_NAME
var _gender: String = "player_male"
var _portrait: String = ""
var _adds: Dictionary = { "constitution": 0, "strength": 0, "intelligence": 0, "charisma": 0 }
## 四维随机基数（60~80/项）：进创角掷一次，点「随 机」重掷
var _base_rolls: Dictionary = {}
## 上一次「随 机」生成的名字：用于区分「玩家自拟名」与「随机名」——
## 玩家已自拟名字时随机按钮不再覆盖（名字/性别/立绘由玩家自己定）
var _last_random_name := ""
var _talent_id: int = 1

# ---------- 控件缓存 ----------
var _step_title: Label
var _step_hint: Label
var _dots: Array = []
var _body: VBoxContainer
var _scroll: ScrollContainer        ## 步骤内容滚动区（重建后回顶）
var _name_edit: LineEdit
var _pool_label: Label
var _attr_rows: Array = []
var _talent_rows: Array = []
var _btn_prev: Button
var _btn_next: Button
var _btn_reset: Button
var _av_frame: PanelContainer
var _av: TextureRect
var _pv_name: Label
var _pv_gender: Label
var _pv_stats: VBoxContainer
var _pv_talent: Label
var _pv_talent_desc: Label


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# 创角复用主菜单同曲（同路径不重播），开局前 60 秒不再静音
	AudioManager.play_bgm("res://assets/audio/bgm/main_menu.ogg")
	_talent_id = GameState.personal_skill if SkillService.is_personal_skill(GameState.personal_skill) else 1
	_portrait = _portraits_for_gender(_gender)[0]["id"]
	_roll_stats()
	_build()
	_rebuild_body()
	_refresh_preview()


## 重掷四维随机基数（60~80/项），并清空已加点（重掷即重置微调）
func _roll_stats() -> void:
	for sd in STAT_DEFS:
		_base_rolls[str(sd["key"])] = randi_range(STAT_MIN, STAT_MAX)
	for k in _adds.keys():
		_adds[k] = 0


## ---------- 骨架 ----------
func _build() -> void:
	# 手机横屏：面板占视口 ~86%×~88%（拉伸模式 canvas_items+expand，逻辑视口随设备变宽，
	# 按视口比例取尺寸可自适应超宽屏）；grow BOTH 保证内容再超限也居中扩展不出屏。
	var vp := get_viewport_rect().size
	var cw := maxf(1200.0, vp.x * 0.86)
	var chh := maxf(700.0, vp.y * 0.88)
	var card := PanelContainer.new()
	card.set_anchors_preset(Control.PRESET_CENTER)
	card.grow_horizontal = Control.GROW_DIRECTION_BOTH
	card.grow_vertical = Control.GROW_DIRECTION_BOTH
	card.offset_left = -cw * 0.5
	card.offset_top = -chh * 0.5
	card.offset_right = cw * 0.5
	card.offset_bottom = chh * 0.5
	card.custom_minimum_size = Vector2(cw, chh)
	card.add_theme_stylebox_override("panel", _card_style())
	add_child(card)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 14)
	card.add_child(root)

	# 头部：标题 + 步骤指示
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 24)
	var title := Label.new()
	title.text = "创　角"
	title.add_theme_font_size_override("font_size", 46)
	title.add_theme_color_override("font_color", C_GOLD)
	head.add_child(title)

	var step_box := HBoxContainer.new()
	step_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	step_box.alignment = BoxContainer.ALIGNMENT_END
	step_box.add_theme_constant_override("separation", 18)
	head.add_child(step_box)
	for i in 3:
		var dot := Label.new()
		dot.add_theme_font_size_override("font_size", 26)
		dot.custom_minimum_size = Vector2(140, 0)
		dot.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		step_box.add_child(dot)
		_dots.append(dot)
	root.add_child(head)

	_step_title = Label.new()
	_step_title.add_theme_font_size_override("font_size", 36)
	_step_title.add_theme_color_override("font_color", C_TEXT)
	root.add_child(_step_title)
	_step_hint = Label.new()
	_step_hint.add_theme_font_size_override("font_size", 22)
	_step_hint.add_theme_color_override("font_color", C_DIM)
	_step_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_step_hint)
	root.add_child(HSeparator.new())

	# 主体：左预览 + 右步骤内容
	var mid := HBoxContainer.new()
	mid.add_theme_constant_override("separation", 28)
	mid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(mid)

	mid.add_child(_build_preview())

	var right := PanelContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_theme_stylebox_override("panel", _inner_style())
	mid.add_child(right)

	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(_scroll)
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 16)
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_body)

	root.add_child(HSeparator.new())

	# 底部：返回主菜单独立居左；流程按钮大号居右（触控目标 84px 高）。
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 18)
	root.add_child(foot)

	var btn_back := Button.new()
	btn_back.text = "返回主菜单"
	btn_back.custom_minimum_size = Vector2(240, 84)
	btn_back.add_theme_font_size_override("font_size", 28)
	btn_back.pressed.connect(_on_back_to_menu)
	foot.add_child(btn_back)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(spacer)

	_btn_reset = Button.new()
	_btn_reset.text = "重置点数"
	_btn_reset.custom_minimum_size = Vector2(210, 84)
	_btn_reset.add_theme_font_size_override("font_size", 26)
	_btn_reset.pressed.connect(_on_reset_points)
	foot.add_child(_btn_reset)

	_btn_prev = Button.new()
	_btn_prev.text = "上一步"
	_btn_prev.custom_minimum_size = Vector2(210, 84)
	_btn_prev.add_theme_font_size_override("font_size", 28)
	_btn_prev.pressed.connect(_on_prev)
	foot.add_child(_btn_prev)

	_btn_next = Button.new()
	_btn_next.custom_minimum_size = Vector2(300, 84)
	_btn_next.add_theme_font_size_override("font_size", 32)
	_btn_next.pressed.connect(_on_next)
	foot.add_child(_btn_next)

	for b in [btn_back, _btn_reset, _btn_prev, _btn_next]:
		(b as Button).add_theme_stylebox_override("normal", _btn_style(C_INK_DEEP, C_GOLD_DIM))
		(b as Button).add_theme_stylebox_override("hover", _btn_style(Color(0.20, 0.17, 0.11, 0.98), C_GOLD))
		(b as Button).add_theme_stylebox_override("pressed", _btn_style(Color(0.30, 0.24, 0.12, 1.0), C_GOLD))
		(b as Button).add_theme_stylebox_override("focus", _btn_style(Color(0.20, 0.17, 0.11, 0.98), C_GOLD))
		(b as Button).add_theme_color_override("font_color", C_TEXT)
		(b as Button).add_theme_color_override("font_hover_color", Color(1, 1, 1, 1))
		(b as Button).add_theme_color_override("font_pressed_color", Color(1, 0.98, 0.90, 1))
		(b as Button).add_theme_color_override("font_focus_color", Color(1, 0.98, 0.90, 1))


func _build_preview() -> Control:
	# 左预览列：包一层滚动（内容最小高度不顶高整卡），与右列等高。
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(430, 0)
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", _inner_style())
	var pv_scroll := ScrollContainer.new()
	pv_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	panel.add_child(pv_scroll)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 14)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pv_scroll.add_child(vbox)

	_av_frame = PanelContainer.new()
	_av_frame.custom_minimum_size = Vector2(0, 330)
	_av_frame.add_theme_stylebox_override("panel", _inner_style())
	vbox.add_child(_av_frame)

	_av = TextureRect.new()
	_av.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_av.offset_left = 8
	_av.offset_right = -8
	_av.offset_top = 8
	_av.offset_bottom = -8
	_av.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_av.expand_mode = TextureRect.EXPAND_FIT_HEIGHT_PROPORTIONAL
	_av_frame.add_child(_av)

	_pv_name = Label.new()
	_pv_name.add_theme_font_size_override("font_size", 34)
	_pv_name.add_theme_color_override("font_color", C_TEXT)
	_pv_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_pv_name)

	_pv_gender = Label.new()
	_pv_gender.add_theme_font_size_override("font_size", 22)
	_pv_gender.add_theme_color_override("font_color", C_DIM)
	_pv_gender.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pv_gender.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_pv_gender)

	vbox.add_child(HSeparator.new())

	var st := Label.new()
	st.text = "四维"
	st.add_theme_font_size_override("font_size", 26)
	st.add_theme_color_override("font_color", C_GOLD)
	vbox.add_child(st)

	_pv_stats = VBoxContainer.new()
	_pv_stats.add_theme_constant_override("separation", 8)
	vbox.add_child(_pv_stats)

	vbox.add_child(HSeparator.new())

	var tt := Label.new()
	tt.text = "天赋"
	tt.add_theme_font_size_override("font_size", 26)
	tt.add_theme_color_override("font_color", C_GOLD)
	vbox.add_child(tt)

	_pv_talent = Label.new()
	_pv_talent.add_theme_font_size_override("font_size", 28)
	_pv_talent.add_theme_color_override("font_color", C_POINT)
	vbox.add_child(_pv_talent)

	_pv_talent_desc = Label.new()
	_pv_talent_desc.add_theme_font_size_override("font_size", 20)
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
		"取一个乱世中的名字，选定性别。点「随 机」换随机姓名，同时重掷四维资质（每项 60~80）；名字、性别、立绘由你亲自定。",
		"四维已随机掷出（每项 60~80），另有 %d 点自由分配可微调。可先用预设一键铺开，点满方可继续。" % POOL,
		"选定一门随身绝技，它将在战场上由你亲施。",
	][_step]
	for i in _dots.size():
		var d := _dots[i] as Label
		d.text = ["① 姓名", "② 四维", "③ 天赋"][i]
		d.add_theme_color_override("font_color", C_GOLD if i == _step else C_DIM)
	# 重建后回到顶部：否则选性别/形象后界面停在滚动底部，姓名与性别「消失」
	if _scroll != null:
		_scroll.scroll_vertical = 0
	_refresh_nav()


func _build_name_step() -> void:
	# 姓名输入（大输入框 + 大随机钮）
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	var lab := Label.new()
	lab.text = "姓名"
	lab.custom_minimum_size = Vector2(110, 0)
	lab.add_theme_font_size_override("font_size", 28)
	lab.add_theme_color_override("font_color", C_TEXT)
	lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(lab)

	# 选性别会重建本步骤，已输入的名字必须保住，不能被随机名冲掉
	var keep := "" if _name_edit == null else _name_edit.text
	_name_edit = LineEdit.new()
	_name_edit.max_length = NAME_MAX
	# 选性别会重建本步骤：已输入的名字必须保住，不能被随机名冲掉；
	# 初始随机名也要记入 _last_random_name，否则第一次点「随 机」不会换名
	if keep.is_empty():
		_last_random_name = _random_name()
		_name_edit.text = _last_random_name
	else:
		_name_edit.text = keep
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.custom_minimum_size = Vector2(0, 84)
	_name_edit.add_theme_font_size_override("font_size", 30)
	_name_edit.add_theme_color_override("font_color", C_TEXT)
	_name_edit.text_changed.connect(_on_name_changed)
	row.add_child(_name_edit)

	var btn_rand := Button.new()
	btn_rand.text = "随 机"
	btn_rand.custom_minimum_size = Vector2(170, 84)
	btn_rand.add_theme_font_size_override("font_size", 26)
	btn_rand.pressed.connect(_on_reroll)
	_style_small_btn(btn_rand)
	row.add_child(btn_rand)
	_body.add_child(row)

	var hint := Label.new()
	hint.text = "最多 %d 字，可随时再改。" % NAME_MAX
	hint.add_theme_font_size_override("font_size", 20)
	hint.add_theme_color_override("font_color", C_DIM)
	_body.add_child(hint)

	_body.add_child(HSeparator.new())

	var gl := Label.new()
	gl.text = "性　别"
	gl.add_theme_font_size_override("font_size", 30)
	gl.add_theme_color_override("font_color", C_GOLD)
	_body.add_child(gl)

	# 性别：2 列大块（一行两个）
	var ggrid := GridContainer.new()
	ggrid.columns = 2
	ggrid.add_theme_constant_override("h_separation", 16)
	ggrid.add_theme_constant_override("v_separation", 14)
	_body.add_child(ggrid)
	for g in GENDERS:
		ggrid.add_child(_make_gender_row(g))

	_body.add_child(HSeparator.new())

	var il := Label.new()
	il.text = "形　象"
	il.add_theme_font_size_override("font_size", 30)
	il.add_theme_color_override("font_color", C_GOLD)
	_body.add_child(il)

	# 形象：2×3 大格子列表（缩略立绘 + 名称）
	var pgrid := GridContainer.new()
	pgrid.columns = 2
	pgrid.add_theme_constant_override("h_separation", 16)
	pgrid.add_theme_constant_override("v_separation", 14)
	_body.add_child(pgrid)
	for p in _portraits_for_gender(_gender):
		pgrid.add_child(_make_portrait_row(p))


func _make_gender_row(g: Dictionary) -> Control:
	var gid := str(g["id"])
	var row := PanelContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_stylebox_override("panel", _row_style(gid == _gender))
	row.custom_minimum_size = Vector2(0, 120)
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	row.gui_input.connect(func(ev: InputEvent): _on_gender_row_click(ev, gid))
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 20)
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(hb)

	var icon := PanelContainer.new()
	icon.custom_minimum_size = Vector2(80, 80)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.20, 0.22, 0.32, 0.92) if gid == "player_male" else Color(0.32, 0.20, 0.24, 0.92)
	sb.border_color = C_GOLD if gid == _gender else C_GOLD_DIM
	sb.set_border_width_all(2 if gid == _gender else 1)
	sb.set_corner_radius_all(10)
	icon.add_theme_stylebox_override("panel", sb)
	var glyph := Label.new()
	glyph.text = "男" if gid == "player_male" else "女"
	glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	glyph.add_theme_font_size_override("font_size", 36)
	glyph.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	glyph.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	glyph.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon.add_child(glyph)
	hb.add_child(icon)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var nm := Label.new()
	nm.text = str(g["name"])
	nm.add_theme_font_size_override("font_size", 32)
	nm.add_theme_color_override("font_color", C_TEXT)
	nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(nm)
	var ds := Label.new()
	ds.text = str(g["desc"])
	ds.add_theme_font_size_override("font_size", 21)
	ds.add_theme_color_override("font_color", C_DIM)
	ds.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(ds)
	hb.add_child(col)
	return row


func _on_gender_row_click(ev: InputEvent, gid: String) -> void:
	if (ev is InputEventMouseButton and ev.pressed) \
			or (ev is InputEventScreenTouch and ev.pressed):
		_on_pick_gender(gid)


func _portraits_for_gender(gid: String) -> Array:
	var out := []
	for p in PORTRAITS:
		if str(p.get("gender", "")) == gid:
			out.append(p)
	return out


func _make_portrait_row(p: Dictionary) -> Control:
	var pid := str(p["id"])
	var row := PanelContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_stylebox_override("panel", _row_style(pid == _portrait))
	row.custom_minimum_size = Vector2(0, 150)
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	row.gui_input.connect(func(ev: InputEvent): _on_portrait_row_click(ev, pid))
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 20)
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(hb)

	var icon := TextureRect.new()
	icon.custom_minimum_size = Vector2(120, 120)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.expand_mode = TextureRect.EXPAND_FIT_HEIGHT_PROPORTIONAL
	var tex := load(PORTRAIT_DIR + pid + ".png") as Texture2D
	if tex != null:
		icon.texture = tex
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(icon)

	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var nm := Label.new()
	nm.text = str(p["name"])
	nm.add_theme_font_size_override("font_size", 30)
	nm.add_theme_color_override("font_color", C_TEXT)
	nm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(nm)
	hb.add_child(col)
	return row


func _on_portrait_row_click(ev: InputEvent, pid: String) -> void:
	if (ev is InputEventMouseButton and ev.pressed) \
			or (ev is InputEventScreenTouch and ev.pressed):
		_on_pick_portrait(pid)


func _on_pick_portrait(pid: String) -> void:
	_portrait = pid
	AudioManager.sfx_click()
	_rebuild_body()
	_refresh_preview()


func _build_attr_step() -> void:
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 16)
	_pool_label = Label.new()
	_pool_label.add_theme_font_size_override("font_size", 32)
	_pool_label.add_theme_color_override("font_color", C_POINT)
	_pool_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(_pool_label)
	_body.add_child(top)

	var pl := Label.new()
	pl.text = "预　设"
	pl.add_theme_font_size_override("font_size", 26)
	pl.add_theme_color_override("font_color", C_GOLD)
	_body.add_child(pl)

	var grid := GridContainer.new()
	grid.columns = 5
	grid.add_theme_constant_override("h_separation", 14)
	grid.add_theme_constant_override("v_separation", 12)
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
	btn.custom_minimum_size = Vector2(190, 84)
	btn.add_theme_font_size_override("font_size", 27)
	btn.tooltip_text = str(p["tip"])
	btn.pressed.connect(func(): _on_preset(idx))
	_style_small_btn(btn)
	return btn


func _make_attr_row(sd: Dictionary) -> Control:
	var key := str(sd["key"])
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)

	var nm := Label.new()
	nm.text = "%s　%s" % [str(sd["name"]), str(sd["desc"])]
	nm.add_theme_font_size_override("font_size", 28)
	nm.add_theme_color_override("font_color", C_TEXT)
	nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nm.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(nm)

	var btn_sub := Button.new()
	btn_sub.text = "－"
	btn_sub.custom_minimum_size = Vector2(96, 84)
	btn_sub.add_theme_font_size_override("font_size", 38)
	btn_sub.pressed.connect(func(): _on_stat_sub(key))
	_style_small_btn(btn_sub)
	row.add_child(btn_sub)

	var val := Label.new()
	val.add_theme_font_size_override("font_size", 36)
	val.add_theme_color_override("font_color", C_GOOD)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	val.custom_minimum_size = Vector2(150, 0)
	val.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(val)

	var btn_add := Button.new()
	btn_add.text = "＋"
	btn_add.custom_minimum_size = Vector2(96, 84)
	btn_add.add_theme_font_size_override("font_size", 38)
	btn_add.pressed.connect(func(): _on_stat_add(key))
	_style_small_btn(btn_add)
	row.add_child(btn_add)

	_attr_rows.append({ "key": key, "value": val, "add": btn_add, "sub": btn_sub })
	return row


func _build_talent_step() -> void:
	var tip := Label.new()
	tip.text = "战场上由主角亲自施展，冷却结束后可再施。"
	tip.add_theme_font_size_override("font_size", 20)
	tip.add_theme_color_override("font_color", C_DIM)
	_body.add_child(tip)

	for sid in SkillService.PERSONAL_SKILLS:
		_body.add_child(_make_talent_row(int(sid)))
	_refresh_talent_rows()


func _make_talent_row(sid: int) -> Control:
	var meta: Dictionary = SkillService.personal_meta(sid)
	var row := PanelContainer.new()
	row.add_theme_stylebox_override("panel", _row_style(sid == _talent_id))
	row.custom_minimum_size = Vector2(0, 116)
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	row.gui_input.connect(func(ev: InputEvent): _on_row_click(ev, sid))

	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 20)
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(hb)

	# 技能图标：按类型着色的方形徽记
	hb.add_child(_make_skill_icon(str(meta.get("kind", "damage")), sid == _talent_id))

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var line1 := Label.new()
	line1.text = "%s　【%s】　冷却 %.0f 秒" % [
		str(meta.get("name", "技能%d" % sid)),
		str(KIND_LABEL.get(str(meta.get("kind", "damage")), "攻击")),
		float(meta.get("cooldown", 10.0))]
	line1.add_theme_font_size_override("font_size", 29)
	line1.add_theme_color_override("font_color", C_TEXT)
	line1.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(line1)

	var line2 := Label.new()
	line2.text = str(meta.get("desc", ""))
	line2.add_theme_font_size_override("font_size", 21)
	line2.add_theme_color_override("font_color", C_DIM)
	line2.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	line2.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(line2)
	hb.add_child(col)
	return row


## 技能类型图标：方形徽记 + 类型单字，选中时加金边
func _make_skill_icon(kind: String, selected: bool) -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(76, 76)
	panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	match kind:
		"damage": sb.bg_color = Color(0.55, 0.18, 0.15, 0.92)
		"shield": sb.bg_color = Color(0.18, 0.38, 0.55, 0.92)
		"heal":   sb.bg_color = Color(0.18, 0.55, 0.28, 0.92)
		_:       sb.bg_color = Color(0.35, 0.30, 0.22, 0.92)
	sb.border_color = C_GOLD if selected else C_GOLD_DIM
	sb.set_border_width_all(2 if selected else 1)
	sb.set_corner_radius_all(10)
	panel.add_theme_stylebox_override("panel", sb)

	var lab := Label.new()
	match kind:
		"damage": lab.text = "攻"
		"shield": lab.text = "护"
		"heal":   lab.text = "回"
		_:       lab.text = "技"
	lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lab.add_theme_font_size_override("font_size", 34)
	lab.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	lab.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(lab)
	return panel


## 整行点击选中技能（代替仅小圆点可点）
func _on_row_click(ev: InputEvent, sid: int) -> void:
	if (ev is InputEventMouseButton and ev.pressed) \
			or (ev is InputEventScreenTouch and ev.pressed):
		_on_pick_talent(sid)


## ---------- 交互回调 ----------
func _on_name_changed(_t: String) -> void:
	_refresh_preview()


func _on_reroll() -> void:
	AudioManager.sfx_click()
	if _name_edit != null:
		var cur := _name_edit.text.strip_edges()
		# 玩家自拟的名字（非空且不等于上次随机名）保留不动 —— 名字由玩家自己定；
		# 空名或本就是随机名时才换新随机名
		if cur.is_empty() or cur == _last_random_name:
			_last_random_name = _random_name()
			_name_edit.text = _last_random_name
	# 【思维联动】随机姓名时四维资质一起重掷（用户拍板）；
	# 性别与立绘不受随机影响，始终由玩家亲自选择
	_roll_stats()
	_refresh_attr_rows()
	_refresh_preview()


func _on_pick_gender(gid: String) -> void:
	AudioManager.sfx_click()
	_gender = gid
	# 切换性别时，如果当前形象不属于新性别，默认选新性别的第一个
	var valid := false
	for p in _portraits_for_gender(gid):
		if str(p["id"]) == _portrait:
			valid = true
			break
	if not valid:
		var opts := _portraits_for_gender(gid)
		if not opts.is_empty():
			_portrait = str(opts[0]["id"])
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
	GameState.player_portrait = _portrait
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
	SceneRouter.goto_fresh("world")   # 入世入口：清空菜单残留历史（R1-02）


## ---------- 取值与刷新 ----------
func _pool_left() -> int:
	var used := 0
	for k in _adds.keys():
		used += int(_adds[k])
	return POOL - used


## _stat_of(key) = 随机基数 + 已加点。BASE_STAT 兜底只发生在极端时序（未掷先取）。
func _stat_of(key: String) -> int:
	return int(_base_rolls.get(key, BASE_STAT)) + int(_adds.get(key, 0))


func _final_name() -> String:
	if _name_edit == null:
		return _random_name()
	var s := _name_edit.text.strip_edges()
	if s.is_empty():
		s = _random_name()
		_name_edit.text = s
		_last_random_name = s   ## 记为随机名：后续点「随 机」才会正常替换
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
		var base := int(_base_rolls.get(k, STAT_MIN))
		(r["value"] as Label).text = str(v)
		(r["add"] as Button).disabled = (left <= 0 or v >= MAX_STAT)
		(r["sub"] as Button).disabled = (v <= base)   ## 只能减回到随机基数，不减穿
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
	if _btn_reset != null:
		_btn_reset.visible = (_step == STEP_ATTR)


func _refresh_preview() -> void:
	var nm := _final_name() if _name_edit != null else "无名"
	if _av != null:
		var tex := load(PORTRAIT_DIR + _portrait + ".png") as Texture2D
		_av.texture = tex
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
			lab.add_theme_font_size_override("font_size", 24)
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
	sb.content_margin_left = 30.0
	sb.content_margin_right = 30.0
	sb.content_margin_top = 20.0
	sb.content_margin_bottom = 20.0
	return sb


func _inner_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = C_INK_DEEP
	sb.border_color = C_GOLD_DIM
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 16.0
	sb.content_margin_right = 16.0
	sb.content_margin_top = 12.0
	sb.content_margin_bottom = 12.0
	return sb


func _row_style(selected: bool) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.16, 0.13, 0.08, 0.95) if selected else C_INK_DEEP
	sb.border_color = C_GOLD if selected else C_GOLD_DIM
	sb.set_border_width_all(3 if selected else 1)
	sb.set_corner_radius_all(12)
	sb.content_margin_left = 18.0
	sb.content_margin_right = 18.0
	sb.content_margin_top = 12.0
	sb.content_margin_bottom = 12.0
	return sb


func _btn_style(bg: Color, border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
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
