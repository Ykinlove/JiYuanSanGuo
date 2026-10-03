extends Control
class_name DialogueUI
## 对话界面（DialogueUI）
## 职责：显示对话文本（打字机效果）、选项菜单、属性门槛置灰、执行对话动作。
## 视觉：水墨风对话框 + 扇形选项布局。
##
## 【布局要点】选项容器用「底部对齐 + 自适应高度」，绝对不要写死高度。
## 历史 bug：OptionsBox 曾固定 offset 880~1040（仅 160px），
## 而 3 个选项每项 64px + 间距 12px 需要 216px → 第 3 个选项被裁掉且点不到，
## 玩家表现为「点完对话就卡住」。现改为 VBoxContainer 自适应 + 锚定底部。

signal dialogue_finished()

const TYPE_SPEED := 0.028        ## 每字间隔（秒）
const OPT_HEIGHT := 62.0         ## 单个选项按钮高度（仅为下限参考；实际由 UITheme 工厂
								 ## 抬到 TOUCH_H=84，见 _make_option_btn）
const OPT_GAP := 12.0            ## 选项间距
## 【第六十六轮】对话卡下沿到选项框上沿的间距。
## 不用 OPT_GAP：那是「选项按钮之间」的间距（12px），卡片与选项框之间
## 需要更明显的分隔，否则选项像是直接长在卡片上。
const OPT_BOX_GAP := 24.0
const MAX_OPT_VISIBLE := 4       ## 超过这个数量改为两列排布
## 【第五十一轮·实测】选项区总高上限。
## 复算（1080p、OPT_H=84、GAP=12、底边距 160）：
##   1 列时 7 项=660px、8 项=756px、9 项=852px、10 项=948px，
##   顶边被顶到 y=400，尾部按钮溢出屏幕下边界 140~428px —— 点不到，
##   玩家表现为「选项只显示前几个，后面的怎么点都没反应」。
## 而 dialogues.json 真实存在 13 个超 4 项的对话节点，其中
## liubei_intro 10 项 / caocao_intro 9 / strategist_intro 8 必然触发。
## 【修法】不靠裁切（裁掉即不可点），改为超过 MAX_OPT_VISIBLE 即两列：
##   10 项 → 5 行 ×(84+12) = 468px，稳定落在上限内。
## 上限保留为兜底：万一将来出现超长选项，两列仍兜不住时也不至于顶出屏幕。
const MAX_OPTIONS_H := 520.0
## 两列时每列宽度上限（OptionsBox 左右各留 200，可宽 1520，
## 扣 12px 列间距后每列 754）。取 740 留 14px 余量，避免顶到屏幕边缘。
const TWO_COL_W := 740.0

## ---------------------------------------------------------------
## 对话卡片布局
## 【统一尺寸】旁白卡与角色卡同宽同高（760×250，居中挂屏幕上方）：
## 旧尺寸 1180×360 / 900×180 又宽又高，把大地图遮去一大块（用户反馈）。
## ---------------------------------------------------------------
const CARD_W := 760.0            ## 对话卡统一宽度
const CARD_H := 250.0            ## 对话卡统一高度
const CARD_MARGIN_BOTTOM := 120.0
const NARR_CARD_W := CARD_W      ## 兼容旧引用：旁白卡 = 统一尺寸
const NARR_CARD_H := CARD_H
const NARR_MARGIN_TOP := 60.0
## 对话卡顶部边距（可由场景改写）。
## 大地图 HUD 资源条只到 53px，默认 60 即可避让；
## 城内场景顶栏高达 150（城名 + 城况 + 资源条），city_scene 创建后改写为 164。
## 旧版写死 60 → 城内对话卡直接盖住顶栏（用户反馈「人物语言挡住顶栏内容」）。
var top_margin := NARR_MARGIN_TOP
const PORTRAIT_W := 236.0        ## 左侧立绘栏宽度
const NARR_PORTRAIT_W := 140.0   ## 旁白立绘框宽度（更小）
const PORTRAIT_PAD := 16.0       ## 立绘相对框的内边距
const TEXT_PAD_X := 34.0         ## 文字区左右内边距
const TEXT_PAD_TOP := 22.0       ## 文字区上内边距

## 立绘资源目录（与 CharacterPanel / CityInteriorArt 一致的约定）
const PORTRAIT_DIR := "res://assets/sprites/npcs/"
const PORTRAIT_EXTS: Array[String] = [".png", ".webp", ".jpg"]

## 代码构建一份 DialogueUI（布局与 world_map.tscn 中的节点树一致）。
## 用于城市场景等没有预制对话节点的场景，避免重复维护两套对话 UI。
static func create() -> DialogueUI:
	var ui := DialogueUI.new()
	ui.name = "DialogueUI"
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var root := Control.new()
	root.name = "RootPanel"
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(root)

	# 对话卡：底部居中，宽度固定（不再铺满屏幕）
	var card := Panel.new()
	card.name = "TextBox"
	card.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	card.offset_left = -CARD_W * 0.5
	card.offset_right = CARD_W * 0.5
	# 底部锚定：offset_top = -(底边距 + 卡高)，offset_bottom = -底边距。
	# 历史 bug：这里写成 -(CARD_BOTTOM - (1080 - CARD_H))，算出来只有 -166，
	# 卡片实际高度被压成 46px（立绘栏 254px 直接溢出），
	# 由 create() 生成的对话 UI（城市场景等）文字与立绘全部挤成一团。
	card.offset_top = -(CARD_MARGIN_BOTTOM + CARD_H)
	card.offset_bottom = -CARD_MARGIN_BOTTOM
	card.self_modulate = UITheme.INK
	root.add_child(card)

	# 左侧立绘框（【R3-07A】统一墨色衬底 + 描金细框，与角色详情面板 _portrait_box 同款，
	# 让写实水彩批与扁平二次元批在同屏出现时被同一风格容器收束、弱化批差）
	var pbox := Panel.new()
	pbox.name = "PortraitBox"
	pbox.position = Vector2(PORTRAIT_PAD, PORTRAIT_PAD)
	pbox.size = Vector2(PORTRAIT_W, CARD_H - PORTRAIT_PAD * 2.0)
	pbox.add_theme_stylebox_override("panel", UITheme.inner_style())
	pbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(pbox)
	pbox.add_child(_make_portrait_tex())
	var pchar := Label.new()
	pchar.name = "PortraitChar"
	pchar.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	pchar.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pchar.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	pchar.add_theme_font_size_override("font_size", UITheme.FS_WATERMARK)
	pchar.add_theme_color_override("font_color", UITheme.GOLD_DIM)
	pchar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pbox.add_child(pchar)

	# 说话人名字（在立绘右侧上方）
	var sp := Label.new()
	sp.name = "SpeakerLabel"
	sp.position = Vector2(PORTRAIT_W + PORTRAIT_PAD * 2.0 + TEXT_PAD_X, TEXT_PAD_TOP)
	sp.size = Vector2(CARD_W - PORTRAIT_W - PORTRAIT_PAD * 2.0 - TEXT_PAD_X * 2.0, 48)
	sp.add_theme_font_size_override("font_size", UITheme.FS_TITLE)
	sp.add_theme_color_override("font_color", UITheme.GOLD)
	sp.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	sp.add_theme_constant_override("shadow_offset_x", 2)
	sp.add_theme_constant_override("shadow_offset_y", 2)
	sp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(sp)

	var tl := RichTextLabel.new()
	tl.name = "TextLabel"
	tl.position = Vector2(PORTRAIT_W + PORTRAIT_PAD * 2.0 + TEXT_PAD_X, 76)
	tl.size = Vector2(CARD_W - PORTRAIT_W - PORTRAIT_PAD * 2.0 - TEXT_PAD_X * 2.0,
		CARD_H - 76 - 40)
	tl.bbcode_enabled = true
	tl.add_theme_font_size_override("normal_font_size", UITheme.FS_HEAD)
	tl.add_theme_color_override("default_color", UITheme.TEXT)
	tl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(tl)

	var hint := Label.new()
	hint.name = "ContinueHint"
	hint.text = "▼ 继续"
	hint.add_theme_font_size_override("font_size", UITheme.FS_BODY)
	hint.add_theme_color_override("font_color", UITheme.POINT)
	hint.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	hint.add_theme_constant_override("shadow_offset_x", 2)
	hint.add_theme_constant_override("shadow_offset_y", 2)
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	hint.offset_left = -210
	hint.offset_top = -44
	hint.offset_right = -18
	hint.offset_bottom = -8
	card.add_child(hint)

	var ob := VBoxContainer.new()
	ob.name = "OptionsBox"
	ob.add_theme_constant_override("separation", 12)
	# 【第六十六轮·统一位置】原实现把选项框锚在屏幕底部（BOTTOM_WIDE），
	# 而对话卡挂屏幕上方 —— 于是「有选项的对话」看起来弹在屏幕下方，
	# 「没选项的对白」弹在屏幕上方/中间，同一座城里走两步位置就不一样。
	# 改为：选项框水平居中，垂直紧贴对话卡下沿，两者作为一个整体出现。
	ob.set_anchors_preset(Control.PRESET_CENTER_TOP)
	ob.grow_horizontal = Control.GROW_DIRECTION_BOTH
	ob.grow_vertical = Control.GROW_DIRECTION_END
	root.add_child(ob)

	return ui


## 根据角色/旁白模式重新应用卡片位置与内部尺寸。
## 【统一在上】旁白与角色对话卡一律挂屏幕上方，选项框锚定屏幕底部。
## 历史 bug：角色卡曾锚底部 y600..960，与选项框（y600..920）完全叠在一起，
## 表现为「向导的话和『收下盘缠，出发！』选项重叠、糊成一团」。
func _apply_card_layout(is_narr: bool) -> void:
	# 【统一尺寸】旁白与角色卡同宽同高，只有文字起始 y 不同（角色卡带说话人行）
	var card_w := CARD_W
	var card_h := CARD_H
	var text_y := 20.0 if is_narr else 76.0

	_text_box.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_text_box.offset_left = -card_w * 0.5
	_text_box.offset_right = card_w * 0.5
	_text_box.offset_top = top_margin
	_text_box.offset_bottom = top_margin + card_h

	# 【去立绘框】对话卡不再显示左侧立绘/首字水印框（用户要求：
	# 向导对话左边的「向」大字框去掉），正文与说话人占满整卡宽度。
	var pbox := _portrait_tex.get_parent() as Control
	pbox.visible = false
	var text_x := TEXT_PAD_X
	var text_w := card_w - text_x * 2.0
	_speaker_label.position = Vector2(text_x, TEXT_PAD_TOP)
	_speaker_label.size = Vector2(text_w, 48)
	_text_label.position = Vector2(text_x, text_y)
	_text_label.size = Vector2(text_w, card_h - text_y - 40.0)

	# 【第六十六轮】选项框紧跟对话卡下沿：与卡片同宽、水平居中，
	# 上方留出 OPT_GAP 的间隙。这样「对白 + 选项」是一个整体，
	# 不再出现「有选项弹下方、没选项弹中间」的错位。
	if _options_box != null:
		_options_box.set_anchors_preset(Control.PRESET_CENTER_TOP)
		_options_box.offset_left = -card_w * 0.5
		_options_box.offset_right = card_w * 0.5
		_options_box.offset_top = top_margin + card_h + OPT_BOX_GAP
		_options_box.grow_vertical = Control.GROW_DIRECTION_END


## 立绘贴图控件（右上对齐、保持长宽比、超出裁切，避免半身像被拉扁）
static func _make_portrait_tex() -> TextureRect:
	var t := TextureRect.new()
	t.name = "PortraitTex"
	t.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	t.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	## 【立绘修复】由 KEEP_ASPECT_COVERED 改为 KEEP_ASPECT_CENTERED：
	## COVERED 会把全身立绘的头部裁掉（只露下半身），CENTERED 完整显示立绘。
	t.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	t.visible = false
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return t

@onready var _root_panel: Control = $RootPanel
@onready var _speaker_label: Label = $RootPanel/TextBox/SpeakerLabel
@onready var _text_label: RichTextLabel = $RootPanel/TextBox/TextLabel
@onready var _options_box: VBoxContainer = $RootPanel/OptionsBox
@onready var _continue_hint: Label = $RootPanel/TextBox/ContinueHint
@onready var _text_box: Panel = $RootPanel/TextBox
@onready var _portrait_tex: TextureRect = $RootPanel/TextBox/PortraitBox/PortraitTex
@onready var _portrait_char: Label = $RootPanel/TextBox/PortraitBox/PortraitChar

var _current_id: String = ""
var _line_index: int = 0
var _lines: Array = []
var _options: Array = []
var _typing := false
var _type_timer := 0.0
var _full_text := ""
var _opt_buttons: Array[Button] = []
## 【第五十一轮】选项实际承载容器：单列时 columns=1 等价于原来的 VBox，
## 超 4 项切 columns=2。把 GridContainer 挂在 _options_box 内部而非改造
## _options_box 本身，是为了 tscn（world_map）与 create()（城内）两条构建
## 路径零改动复用同一套逻辑——外层仍负责锚定屏幕底部与限高。
var _opt_grid: GridContainer = null
## 外部（world_map / city_scene）可在 start 前塞入当前交谈对象，用于取立绘
var portrait_key: String = ""


func _ready() -> void:
	visible = false
	_continue_hint.visible = false
	# 点击对话框任意处推进（不必精确点小提示）
	_text_box.gui_input.connect(_on_textbox_input)
	# RichTextLabel 默认 mouse_filter=STOP 会吞掉鼠标事件，
	# 导致点击打在文字上永远到不了 TextBox → 表现为「继续点不了、卡死在对话」。
	# 置为 IGNORE 让点击穿透到 TextBox。
	_text_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 对话为模态界面：整个 RootPanel 也可点击推进（点对话框外的空白处同样有效）
	_root_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_root_panel.gui_input.connect(_on_textbox_input)
	# 实际承载选项的网格（见 _opt_grid 注释）：单列=等价 VBox，超 4 项切两列
	_opt_grid = GridContainer.new()
	_opt_grid.name = "OptGrid"
	_opt_grid.columns = 1
	_opt_grid.add_theme_constant_override("h_separation", OPT_GAP)
	_opt_grid.add_theme_constant_override("v_separation", OPT_GAP)
	_opt_grid.mouse_filter = Control.MOUSE_FILTER_PASS
	_options_box.add_child(_opt_grid)
	# 外层不再需要自己的行距（间距已由 _opt_grid 负责）
	_options_box.add_theme_constant_override("separation", 0)


## 【M5】双事件幂等：一次物理点按会同帧派生 Touch+Mouse 双事件
## （emulate_touch_from_mouse），只认同帧第一次——否则打字中一点跳两行、
## 末行一点双触发关闭。跨帧快速连点不受影响。
var _last_advance_frame := -1


func _on_textbox_input(event: InputEvent) -> void:
	if not event.is_pressed():
		return
	if not (event is InputEventMouseButton or event is InputEventScreenTouch):
		return
	var frame := Engine.get_process_frames()
	if frame == _last_advance_frame:
		return
	_last_advance_frame = frame
	advance()


## 本次对话的说话人 id（NPC id）。由调用方在 start 前设置，
## 供「交谈」「赠金」类任务目标记账；旁白/剧情演出留空。
var talker_id: String = ""


## 开始一段对话
func start(dialogue_id: String) -> void:
	var data := _find_dialogue(dialogue_id)
	if data.is_empty():
		push_warning("[DialogueUI] 对话不存在：%s" % dialogue_id)
		# 根节点此刻必然 visible=false（start 尚未展示），close_immediately 会
		# 因可见性检查提前返回、不发 dialogue_finished——调用方（如 world_map）
		# 的 _busy 将永不复位而软锁。这里临时置可见，保证 _close() 必然执行。
		visible = true
		close_immediately()
		return

	# 与 NPC 交谈本身就是 talk 类任务的事件源（在选项渲染前记账，
	# 使「目标达成后提交」按钮当次对话即可出现）
	if not talker_id.is_empty():
		QuestService.record_event("talk", talker_id)

	_current_id = dialogue_id
	_lines = data.get("lines", [])
	_options = data.get("options", [])
	_line_index = 0

	var spk := str(data.get("speaker", "")).strip_edges()
	var is_narr := spk == "旁白"
	_speaker_label.text = spk if not is_narr else ""
	_refresh_portrait(spk)
	_apply_card_layout(is_narr)
	# 旁白：移到屏幕上方、更小，保留立绘框；文字居中并弱化。
	# 角色：保持底部大卡片、左对齐+立绘、正常色。
	if is_narr:
		_text_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_text_label.add_theme_color_override("default_color", Color(0.80, 0.82, 0.88, 1.0))
	else:
		_text_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		_text_label.add_theme_color_override("default_color", UITheme.TEXT)
	_root_panel.visible = true
	visible = true
	_clear_options()
	EventBus.dialogue_started.emit(dialogue_id)
	_show_line()


## 刷新左栏立绘。
## 候选：外部传入的 portrait_key（NPC id / 武将 role_id）→ 谈话人名字本身。
## 找不到贴图时回退为「名字首字」大字，绝不出现空白栏。
func _refresh_portrait(speaker: String) -> void:
	var tex := _load_portrait_tex(speaker)
	if tex != null:
		_portrait_tex.texture = tex
		_portrait_tex.visible = true
		_portrait_char.visible = false
	else:
		_portrait_tex.visible = false
		_portrait_char.visible = true
		_portrait_char.text = speaker.substr(0, 1) if not speaker.is_empty() else "?"


func _load_portrait_tex(speaker: String) -> Texture2D:
	var keys: Array[String] = []
	if not portrait_key.is_empty():
		keys.append(portrait_key)
	if not speaker.is_empty():
		keys.append(speaker)
	## 主角说话时，优先加载 protagonist 立绘（已从 NPC 素材库导入一张）
	if not speaker.is_empty() and GameState.player_name != "" and speaker == GameState.player_name:
		keys.push_front("protagonist")
	for k in keys:
		for ext in PORTRAIT_EXTS:
			var path: String = PORTRAIT_DIR + k + ext
			if ResourceLoader.exists(path):
				var res := load(path)
				if res is Texture2D:
					return res
	return null


func _find_dialogue(id: String) -> Dictionary:
	if id.is_empty():
		return {}
	for d in DataManager.get_table("dialogues"):
		if str(d.get("id", "")) == id:
			return d
	return {}


# ---------- 台词令牌替换（2026-09-29） ----------
## 剧本里可用的一小组安全令牌（白名单，逐个 replace，不做 % 格式化）：
##   {name}    主角姓名
##   {guohao}  自立国号（未自立 / 未命名 → 回退「新朝」）
##   {capital} 自立都城（未自立 / 未定都 → 回退「都城」）
##   {year}    当前公元年份（如 184）
##   {faction} 当前效力势力名（自由身 → FactionService 返回「无」）
##   {quest}      该 NPC 当前挂着的差事名（NPC 记忆性，见 DialogueService.focus_quest）
##   {quest_goal} 该差事的目标一句话（例「清剿南中的黄巾残党（3）」）
## 未列入白名单的 {xxx} 一律原样保留（不报错、不吞字），避免误伤既有文本。
## 用法：只在「显示层」替换，action / require 等逻辑字段绝不参与替换。
const TOKEN_FALLBACK_GUOHAO := "新朝"
const TOKEN_FALLBACK_CAPITAL := "都城"
## 「无名」是 GameState 的初始占位名（玩家尚未取名 / 旧档），直接念出来很出戏，
## 故 {name} 遇到它时按 NPC 口吻回退成「壮士」。
const TOKEN_FALLBACK_NAME := "壮士"
const TOKEN_FALLBACK_QUEST := "那桩差事"

func _resolve_tokens(text: String) -> String:
	if text.find("{") < 0:
		return text
	var out := text
	var pname := str(GameState.player_name).strip_edges()
	if pname.is_empty() or pname == "无名":
		pname = TOKEN_FALLBACK_NAME
	out = out.replace("{name}", pname)
	out = out.replace("{year}", str(GameState.year))
	var guohao := str(GameState.self_rule_name).strip_edges()
	out = out.replace("{guohao}", guohao if not guohao.is_empty() else TOKEN_FALLBACK_GUOHAO)
	var cap := ""
	var cid := str(GameState.self_rule_city).strip_edges()
	if not cid.is_empty():
		cap = str(DataManager.get_city(cid).get("name", ""))
	out = out.replace("{capital}", cap if not cap.is_empty() else TOKEN_FALLBACK_CAPITAL)
	out = out.replace("{faction}", FactionService.faction_name())
	# 【NPC 记忆性】只有真出现了 {quest*} 才去查任务，避免每次匹配都扫表。
	if out.find("{quest") >= 0:
		var q := DialogueService.focus_quest(_current_id)
		out = out.replace("{quest}", str(q.get("title", "")).strip_edges())
		out = out.replace("{quest_goal}", DialogueService.quest_goal_text(q))
		if out.find("{quest") >= 0:
			# 该 NPC 名下已无活跃差事（异常分支）：念一句不出戏的兜底，绝不吐令牌
			out = out.replace("{quest}", TOKEN_FALLBACK_QUEST)
			out = out.replace("{quest_goal}", TOKEN_FALLBACK_QUEST)
	return out


func _show_line() -> void:
	if _line_index >= _lines.size():
		_show_options()
		return
	_full_text = _resolve_tokens(str(_lines[_line_index]))
	_text_label.text = ""
	_typing = true
	_type_timer = 0.0


func _process(delta: float) -> void:
	if not _typing:
		return
	_type_timer += delta
	if _type_timer >= TYPE_SPEED:
		_type_timer = 0.0
		var shown := _text_label.text.length() + 1
		if shown <= _full_text.length():
			_text_label.text = _full_text.substr(0, shown)
		if _text_label.text.length() >= _full_text.length():
			_finish_typing()


## 点击/按键推进
func advance() -> void:
	if _typing:
		_text_label.text = _full_text
		_finish_typing()
		return
	if _line_index < _lines.size() - 1:
		_line_index += 1
		_show_line()
	elif _options.is_empty():
		_close()
	elif _all_options_disabled():
		# 有选项但全部置灰时，点击空白也要能退出，否则没有任何可点出口
		_close()
	# 有可点选项时由选项按钮驱动


## 已生成的选项按钮是否全部禁用（= 当前无可点出口）
func _all_options_disabled() -> bool:
	if _opt_buttons.is_empty():
		return false
	for b in _opt_buttons:
		if b is Button and not (b as Button).disabled:
			return false
	return true


func _finish_typing() -> void:
	_typing = false
	_text_label.text = _full_text
	if _line_index < _lines.size() - 1:
		_continue_hint.text = "▼ 继续"
		_continue_hint.visible = true
	elif _options.is_empty():
		_continue_hint.text = "▼ 点击关闭"
		_continue_hint.visible = true
	else:
		_show_options()


func _clear_options() -> void:
	# 注意清的是 _opt_grid 的子节点而非 _opt_grid 本身（它挂在 _options_box 里，
	# 生命周期与对话 UI 相同，不该每轮对话重建）
	for c in _opt_grid.get_children():
		# 先摘除再释放：queue_free 帧末才生效，旧按钮本帧仍可被点第二次
		_opt_grid.remove_child(c)
		c.queue_free()
	_opt_buttons.clear()


## 选项按钮工厂：宽度按文本自适应（320~760，水平居中收缩）。
## 【为什么】OptionsBox 锚定 BOTTOM_WIDE（1520 全宽），VBox 子按钮默认 FILL
## 会被拉成通栏长条 —— 用户反馈「选项长条太长了」；且长条贴到屏幕边缘，
## 点选后手指连点容易误触屏边的交互按钮（配合 world_map/city_scene 的
## 对话关闭免疫一起治「重复触发」）。
## 【第五十一轮】改走 UITheme.button() 工厂：此前是裸 Button.new()，绕过工厂导致
## ① 高度只有 OPT_HEIGHT=62，低于 84px 触控铁律（对话选项是全局最高频控件，
## 手指易误触相邻项）；② 渲染成 Godot 默认灰蓝塑料样式，与全工程描金体系脱节；
## ③ 点了没有按键音。工厂层已内置 _touch_size() 84px 兜底 + 全局 ui_click。
## 【第五十一轮·补两列】max_w 由调用方按当前列数给：单列 760、两列 740。
## 宽度是本函数唯一的收放口，两种布局共用，避免两处写死宽度后互相打架。
func _make_option_btn(text: String, disabled: bool, max_w: float = 760.0) -> Button:
	var btn := UITheme.button(text, 25, Vector2(0, OPT_HEIGHT))
	btn.disabled = disabled
	btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	# 工厂的 _touch_size 已把 62 抬到 84，此处按抬后实际最小宽重算，避免长文本被裁
	var need := btn.get_minimum_size().x + 64.0
	btn.custom_minimum_size = Vector2(clampf(need, 320.0, max_w), btn.custom_minimum_size.y)
	return btn


## 预演一遍选项列表，数出真正会显示几条。
## 【为什么要两遍】列数必须在**建按钮之前**定下来（GridContainer.columns 一旦
## 布局已算完再改会有一帧错位），而可见条数要等遍历完才知道（已完成任务会被
## continue 跳过、进行中任务会变成置灰提示）。这里用同一套过滤规则先数一遍，
## 规则与下方主循环保持一致。
func _count_visible_options() -> int:
	var n := 0
	for opt in _options:
		var action := str(opt.get("action", ""))
		if action.begins_with("accept_quest:"):
			var qid := _first_action_arg(action, "accept_quest:")
			if qid.is_empty():
				pass
			elif GameState.completed_quests.has(qid):
				continue
			elif GameState.active_quests.has(qid):
				n += 1
				continue
		n += 1
	return n


## 显示选项按钮（条件置灰 + 自适应高度 + 超量两列）
func _show_options() -> void:
	_continue_hint.visible = false
	_clear_options()
	if _options.is_empty():
		# 无选项时也要给出口提示，否则玩家面对空白正文以为卡死
		_continue_hint.text = "▼ 点击关闭"
		_continue_hint.visible = true
		return

	# 【第五十一轮】先定列数：超 MAX_OPT_VISIBLE 即两列。
	# 5~10 项在两列下压到 3~5 行，彻底避开「尾部按钮溢出屏幕点不到」。
	var plan_n := _count_visible_options()
	var two_col := plan_n > MAX_OPT_VISIBLE
	# 兜底「告辞」会在末尾追加一条，故预演时 +1，避免追加后反而多出一行
	var planned_total := plan_n + 1 if plan_n > 0 else 1
	if planned_total > MAX_OPT_VISIBLE:
		two_col = true
	_opt_grid.columns = 2 if two_col else 1
	var col_w := TWO_COL_W if two_col else 760.0

	var visible_count := 0
	var enabled_count := 0   ## 可点出口数（置灰项只是状态提示，不能当出口）
	for opt in _options:
		var action := str(opt.get("action", ""))
		# 任务状态过滤：已完成→隐藏选项；进行中→置灰提示，绝不重复接取；
		# 目标全部达成→「接取」位变为「提交任务」，直接向发布人交付
		if action.begins_with("accept_quest:"):
			# 【修复·复合 action】本路径必须与 _execute_action 用同一套解析：
			# 旧实现直接 substr 整个尾巴，遇到 "accept_quest:qid,gain_gold:500,..."
			# 这类逗号串联的复合指令时，qid 会连同后续子命令一起被当成任务 id，
			# 导致 completed_quests/active_quests 判定恒为 false——任务做完了选项
			# 不隐藏、进行中该出现的「提交任务」也不出现。改为按逗号切分取首段。
			var qid := _first_action_arg(action, "accept_quest:")
			if qid.is_empty():
				pass   # 复合指令里没有 accept_quest 段，交给后续通用按钮处理
			elif GameState.completed_quests.has(qid):
				continue
			elif GameState.active_quests.has(qid):
				var q := DataManager.get_record("quests", qid)
				if QuestService.can_turn_in(q):
					var done := _make_option_btn(
						"提交任务「%s」" % str(q.get("title", qid)), false, col_w)
					done.pressed.connect(_on_option_chosen.bind("", "turn_in:" + qid))
					_opt_grid.add_child(done)
					_opt_buttons.append(done)
				else:
					var hold := _make_option_btn("任务进行中（完成目标后再来提交）", true, col_w)
					_opt_grid.add_child(hold)
					_opt_buttons.append(hold)
				visible_count += 1
				continue
		var btn := _make_option_btn(_resolve_tokens(str(opt.get("text", "…"))), false, col_w)

		var ok := _check_require(opt.get("require", {}))
		if not ok["pass"]:
			btn.disabled = true
			btn.text += "　（%s）" % ok["reason"]
			# 置灰追加说明后文本变长，重算一次自适应宽
			var need2 := btn.get_minimum_size().x + 64.0
			btn.custom_minimum_size.x = clampf(need2, 320.0, col_w)

		var next_id := str(opt.get("next", ""))
		btn.pressed.connect(_on_option_chosen.bind(next_id, action))
		_opt_grid.add_child(btn)
		_opt_buttons.append(btn)
		visible_count += 1
		if not btn.disabled:
			enabled_count += 1

	# 没有「可点」出口时给一条兜底「告辞」，保证对话有出口。
	# 【修复】旧代码把置灰项也计入 visible_count，像「任务进行中（完成目标后再来
	# 提交）」这种全禁用对话既无按钮可点、又进不了兜底分支，玩家永久卡死在对话框。
	if visible_count == 0 or enabled_count == 0:
		var bye := _make_option_btn("告辞", false, col_w)
		bye.pressed.connect(_close)
		_opt_grid.add_child(bye)
		_opt_buttons.append(bye)
		visible_count = 1
	# 按「实际行数」撑开容器高度（不依赖 tscn 写死高度）
	# 【第五十一轮】改用按钮实际高度（工厂已把 62 抬到 UITheme.TOUCH_H=84），
	# 并按当前列数换算行数：两列时行数 = ceil(n/2)，10 项 = 5 行 = 468px，
	# 稳稳落在 MAX_OPTIONS_H=520 内。超过上限时不再撑高（极端兜底，
	# 此时也只会裁掉末尾而非整段不可点——两列已消化掉全部现有 13 个超量节点）。
	var opt_h: float = UITheme.TOUCH_H
	if not _opt_buttons.is_empty():
		opt_h = maxf(opt_h, _opt_buttons[0].custom_minimum_size.y)
	var cols: int = maxi(1, _opt_grid.columns)
	var rows := int(ceil(float(visible_count) / float(cols)))
	var need_h := rows * opt_h + maxi(0, rows - 1) * OPT_GAP
	_options_box.custom_minimum_size.y = minf(need_h, MAX_OPTIONS_H)
	# 重排一次，避免同帧内尺寸未生效
	_options_box.queue_sort()
	# 让选项出现时有轻微上浮动画，提示玩家"这里可以点"
	_opt_grid.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(_opt_grid, "modulate:a", 1.0, 0.16)



## 校验选项条件
func _check_require(req: Dictionary) -> Dictionary:
	if req.is_empty():
		return { "pass": true, "reason": "" }
	if req.has("gold") and GameState.gold < int(req["gold"]):
		return { "pass": false, "reason": "需金钱 %d" % int(req["gold"]) }
	if req.has("fame") and GameState.fame < int(req["fame"]):
		return { "pass": false, "reason": "需名声 %d" % int(req["fame"]) }
	if req.has("charisma") and int(GameState.player_stats.get("charisma", 0)) < int(req["charisma"]):
		return { "pass": false, "reason": "需魅力 %d" % int(req["charisma"]) }
	# 【三国全史篇】剧情选项按主线章节门控（防过早接取章节任务）
	if req.has("min_chapter") and MainlineService.current_chapter() < int(req["min_chapter"]):
		return { "pass": false,
			"reason": "主线未至·%s" % MainlineService.chapter_title(int(req["min_chapter"])) }
	# 【三国全史篇】give_gold 等资助选项只在对应任务进行中可选
	if req.has("quest_active") and not GameState.active_quests.has(str(req["quest_active"])):
		return { "pass": false, "reason": "时机未到" }
	return { "pass": true, "reason": "" }


func _on_option_chosen(next_id: String, action: String) -> void:
	AudioManager.sfx_confirm()
	_execute_action(action)
	if next_id.is_empty():
		_close()
	else:
		start(next_id)


## 从复合 action 中取出指定子命令的参数（与 _execute_action 同一套逗号切分语义）。
## 形如 "accept_quest:mj_hj_01,gain_gold:500,flag_intro" → 传 "accept_quest:" 返回 "mj_hj_01"。
## 找不到该子命令（或其后无参数）返回空串，供调用方回退到通用处理。
func _first_action_arg(action: String, cmd_prefix: String) -> String:
	for sub in action.split(","):
		var trimmed := sub.strip_edges()
		if not trimmed.begins_with(cmd_prefix):
			continue
		return trimmed.substr(cmd_prefix.length()).strip_edges()
	return ""


## 执行对话动作。
## 支持一条 action 内用逗号串联多个子命令（如 "gain_gold:500,gain_food:800,flag_intro"），
## 逐个按 : 拆成 命令/参数 依次执行。
func _execute_action(action: String) -> void:
	if action.is_empty():
		return
	for sub in action.split(","):
		var trimmed := sub.strip_edges()
		if trimmed.is_empty():
			continue
		var parts := trimmed.split(":", false, 1)
		if parts.size() < 2:
			# 无参子命令（如 flag_intro）：整段即命令名
			_run_action(parts[0], "")
			continue
		_run_action(parts[0], parts[1])


func _run_action(cmd: String, arg: String) -> void:
	match cmd:
		"accept_quest":
			# 接取规则（快照/重复接取防护/抵达类预记账）统一走规则层
			var ar := QuestService.accept(arg)
			if ar["ok"]:
				EventBus.show_toast(str(ar.get("msg", "")))
		"turn_in":
			# 向发布任务的 NPC 交付（目标全部达成后才会出现该选项）
			# arg=all → 交付该 NPC 名下所有已达成的差事（数据侧不必写死任务 id）
			if arg == "all":
				var msg := DialogueService.turn_in_all(_current_id)
				if not msg.is_empty():
					EventBus.show_toast(msg)
			else:
				var r := QuestService.turn_in(arg)
				EventBus.show_toast(str(r.get("msg", "")))
		"give_gold":
			var amount := int(arg)
			if GameState.gold >= amount:
				GameState.add_gold(-amount)
				# 赠金类任务按累计金额记账（目标 NPC 为当前谈话人）
				if not talker_id.is_empty():
					QuestService.record_event("give_gold", talker_id, amount)
				EventBus.show_toast("失去金钱 %d" % amount)
		"gain_gold":
			# 剧情/开场赠送金钱：加到当前值，无上限
			var g := int(arg)
			GameState.add_gold(g)
			EventBus.show_toast("获得金钱 %d" % g)
		"gain_food":
			var f := int(arg)
			GameState.add_food(f)
			EventBus.show_toast("获得粮草 %d" % f)
		"gain_fame":
			# 剧情/开场增加名声（add_fame 会经 EventBus 广播）
			var fm := int(arg)
			GameState.add_fame(fm)
			EventBus.show_toast("名声 +%d" % fm)
		"gain_item":
			# 剧情赠送物品 arg=item_id:数量
			var seg := arg.split(":")
			add_item_action(seg[0], int(seg[1]) if seg.size() > 1 else 1)
		"set_flag":
			# 【霸王立志篇】剧情烙印：写入 story_flags（幂等，重复选择无副作用）
			if not arg.is_empty() and not GameState.story_flags.has(arg):
				GameState.story_flags.append(arg)
		"flag_intro":
			# 开场剧情结束时置已完成标志（防止重入）
			GameState.intro_seen = true
		"open_shop":
			# 【R2-05a】打开当前对话 NPC 的随身货单（与交互菜单「交易」同走 NpcTradePanel/
			# TradeService，货单按 npc_type/tags 从 npc_stock.json 匹配），不再弹「待实装」
			var shop_npc := DataManager.get_record("npcs", talker_id)
			if shop_npc.is_empty():
				EventBus.show_toast("此人没有可交易的货物。")
			else:
				EventBus.npc_shop_requested.emit(shop_npc)
		"recruit":
			EventBus.show_toast("招募：%s" % arg)
		_:
			EventBus.show_toast("动作：%s %s" % [cmd, arg])


## 剧情赠送物品（arg 可能带品质/数量，只取 item_id 主键）
func add_item_action(item_id: String, amount: int) -> void:
	GameState.add_item(item_id, amount)
	var item := DataManager.get_record("items6", item_id)
	EventBus.show_toast("获得物品：%s ×%d" % [str(item.get("name", item_id)), amount])


func _close() -> void:
	visible = false
	_root_panel.visible = false
	_clear_options()
	_typing = false
	EventBus.dialogue_ended.emit(_current_id)
	_current_id = ""
	dialogue_finished.emit()


## 强制关闭（用于找不到对话等异常路径，保证一定有出口）
func close_immediately() -> void:
	if not visible:
		return
	_close()


func is_open() -> bool:
	return visible and _root_panel.visible
