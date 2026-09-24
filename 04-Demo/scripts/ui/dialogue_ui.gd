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
const OPT_HEIGHT := 62.0         ## 单个选项按钮高度
const OPT_WIDTH := 560.0         ## 单个选项按钮宽度
const OPT_GAP := 12.0            ## 选项间距
const MAX_OPT_VISIBLE := 4       ## 超过这个数量改为两列排布

## ---------------------------------------------------------------
## 对话卡片布局（不再占满屏宽：卡片居中，两侧各留出立绘/背景空间）
## ---------------------------------------------------------------
const CARD_W := 1180.0           ## 对话卡总宽（含立绘栏）
## 【立绘修复】卡高从 286 提到 360：原 254px 立绘框装不下全身立绘，
## KEEP_ASPECT_COVERED 会把头部裁掉 → 玩家只看到下半身。加高后立绘框 328px，
## 配合 KEEP_ASPECT_CENTERED 完整显示立绘。
const CARD_H := 360.0            ## 对话卡总高
## 卡片底边距屏幕底部的距离（避开虚拟摇杆/底栏）。
## 【不要用 1080 反推】写死 1080 时，stretch/aspect=expand 在非 16:9 机型上
## 视口高度不是 1080，卡片会整体上下漂移甚至被切掉。
## 底部锚定后只跟「离底边的距离」有关，与视口高度无关。
const CARD_MARGIN_BOTTOM := 120.0
const PORTRAIT_W := 236.0        ## 左侧立绘栏宽度
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
	ui.set_anchors_preset(Control.PRESET_FULL_RECT)

	var root := Control.new()
	root.name = "RootPanel"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
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

	# 左侧立绘框
	var pbox := Panel.new()
	pbox.name = "PortraitBox"
	pbox.position = Vector2(PORTRAIT_PAD, PORTRAIT_PAD)
	pbox.size = Vector2(PORTRAIT_W, CARD_H - PORTRAIT_PAD * 2.0)
	pbox.self_modulate = UITheme.CARD
	pbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(pbox)
	pbox.add_child(_make_portrait_tex())
	var pchar := Label.new()
	pchar.name = "PortraitChar"
	pchar.set_anchors_preset(Control.PRESET_FULL_RECT)
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
	ob.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	ob.offset_left = 200
	ob.offset_top = -480
	ob.offset_right = -200
	ob.offset_bottom = -160
	ob.grow_horizontal = Control.GROW_DIRECTION_BOTH
	ob.grow_vertical = Control.GROW_DIRECTION_BEGIN
	root.add_child(ob)

	return ui


## 立绘贴图控件（右上对齐、保持长宽比、超出裁切，避免半身像被拉扁）
static func _make_portrait_tex() -> TextureRect:
	var t := TextureRect.new()
	t.name = "PortraitTex"
	t.set_anchors_preset(Control.PRESET_FULL_RECT)
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


func _on_textbox_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		advance()
	elif event is InputEventScreenTouch and event.pressed:
		advance()


## 本次对话的说话人 id（NPC id）。由调用方在 start 前设置，
## 供「交谈」「赠金」类任务目标记账；旁白/剧情演出留空。
var talker_id: String = ""


## 开始一段对话
func start(dialogue_id: String) -> void:
	var data := _find_dialogue(dialogue_id)
	if data.is_empty():
		push_warning("[DialogueUI] 对话不存在：%s" % dialogue_id)
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
	# 【需求2】旁白（无主叙事）与角色对白视觉分离：
	# 旁白隐藏立绘占位、文字居中并弱化，角色对白保持左对齐+立绘。
	# 选项本身位于独立底部选项框（OptionsBox），天然与正文分离。
	if is_narr:
		_portrait_tex.visible = false
		_portrait_char.visible = false
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


func _show_line() -> void:
	if _line_index >= _lines.size():
		_show_options()
		return
	_full_text = str(_lines[_line_index])
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
	# 有选项时由选项按钮驱动


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
	for c in _options_box.get_children():
		c.queue_free()
	_opt_buttons.clear()


## 显示选项按钮（条件置灰 + 自适应高度）
func _show_options() -> void:
	_continue_hint.visible = false
	_clear_options()
	if _options.is_empty():
		return

	var visible_count := 0
	for opt in _options:
		var action := str(opt.get("action", ""))
		# 任务状态过滤：已完成→隐藏选项；进行中→置灰提示，绝不重复接取；
		# 目标全部达成→「接取」位变为「提交任务」，直接向发布人交付
		if action.begins_with("accept_quest:"):
			var qid := action.substr("accept_quest:".length())
			if GameState.completed_quests.has(qid):
				continue
			if GameState.active_quests.has(qid):
				var q := DataManager.get_record("quests", qid)
				if QuestService.can_turn_in(q):
					var done := Button.new()
					done.custom_minimum_size = Vector2(OPT_WIDTH, OPT_HEIGHT)
					done.add_theme_font_size_override("font_size", 25)
					done.text = "提交任务「%s」" % str(q.get("title", qid))
					done.pressed.connect(_on_option_chosen.bind("", "turn_in:" + qid))
					_options_box.add_child(done)
					_opt_buttons.append(done)
				else:
					var hold := Button.new()
					hold.custom_minimum_size = Vector2(OPT_WIDTH, OPT_HEIGHT)
					hold.add_theme_font_size_override("font_size", 25)
					hold.text = "任务进行中（完成目标后再来提交）"
					hold.disabled = true
					_options_box.add_child(hold)
					_opt_buttons.append(hold)
				visible_count += 1
				continue
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(OPT_WIDTH, OPT_HEIGHT)
		btn.add_theme_font_size_override("font_size", 25)
		btn.text = str(opt.get("text", "…"))

		var ok := _check_require(opt.get("require", {}))
		if not ok["pass"]:
			btn.disabled = true
			btn.text += "　（%s）" % ok["reason"]

		var next_id := str(opt.get("next", ""))
		btn.pressed.connect(_on_option_chosen.bind(next_id, action))
		_options_box.add_child(btn)
		_opt_buttons.append(btn)
		visible_count += 1

	# 没有任何可显示选项时给一条兜底「告辞」，保证对话有出口
	if visible_count == 0:
		var bye := Button.new()
		bye.custom_minimum_size = Vector2(OPT_WIDTH, OPT_HEIGHT)
		bye.add_theme_font_size_override("font_size", 25)
		bye.text = "告辞"
		bye.pressed.connect(_close)
		_options_box.add_child(bye)
		_opt_buttons.append(bye)
		visible_count = 1
	# 按实际选项数撑开容器高度（不依赖 tscn 写死高度）
	_options_box.custom_minimum_size.y = visible_count * OPT_HEIGHT \
		+ maxi(0, visible_count - 1) * OPT_GAP
	# 重排一次，避免同帧内尺寸未生效
	_options_box.queue_sort()
	# 让选项出现时有轻微上浮动画，提示玩家"这里可以点"
	_options_box.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(_options_box, "modulate:a", 1.0, 0.16)



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
	return { "pass": true, "reason": "" }


func _on_option_chosen(next_id: String, action: String) -> void:
	AudioManager.sfx_confirm()
	_execute_action(action)
	if next_id.is_empty():
		_close()
	else:
		start(next_id)


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
		"flag_intro":
			# 开场剧情结束时置已完成标志（防止重入）
			GameState.intro_seen = true
		"open_shop":
			EventBus.show_toast("商店界面（待实装）")
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
