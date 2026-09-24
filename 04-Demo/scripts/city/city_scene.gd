extends Control
## 城池场景（CityScene）· M5
## 职责：城池经营总界面。五个建筑（酒馆/兵营/市场/铁匠铺/官府）各自打开独立面板，
##       所有规则判定交给 CityService，本文件只负责显示与交互。
##
## 布局（横屏 1920×1080）：
##   顶部 96px  城池名 + 城池信息 + 资源条（金/粮/木/铁）
##   中部       五个建筑入口（大卡片，触屏友好）
##   底部       离开 / 演练
##   面板层     点击建筑后从右侧滑出的功能面板，互不干扰

const C_BG := Color(0.12, 0.10, 0.08)
const C_PANEL := Color(0.16, 0.14, 0.11)
const C_PANEL_DARK := Color(0.11, 0.10, 0.09)
const C_ACCENT := Color(0.92, 0.80, 0.42)
const C_TEXT := Color(0.90, 0.88, 0.84)
const C_DIM := Color(0.62, 0.60, 0.56)
const C_GOOD := Color(0.55, 0.88, 0.55)
const C_BAD := Color(0.92, 0.52, 0.46)

const PANEL_W := 1180.0

@onready var _title: Label = %CityTitle
@onready var _info_label: Label = %CityInfo
@onready var _res_label: Label = %ResLabel
@onready var _place_grid: GridContainer = %PlaceGrid
@onready var _btn_leave: Button = %BtnLeave
@onready var _interior: Node2D = $WorldView/SubViewport/Interior
@onready var _walk_joy: GameJoystick = $WalkUI/Joy
@onready var _walk_enter_btn: Button = $WalkUI/EnterBtn
@onready var _walk_gate_btn: Button = $WalkUI/GateBtn
@onready var _btn_drill: Button = %BtnDrill
@onready var _btn_menu: Button = %BtnMenu
@onready var _panel_layer: Control = %PanelLayer
@onready var _panel_title: Label = %PanelTitle
@onready var _panel_body: ScrollContainer = %PanelBody
@onready var _panel_content: VBoxContainer = %PanelContent
@onready var _panel_footer: HBoxContainer = %PanelFooter
@onready var _panel_root: Control = %PanelRoot
@onready var _btn_panel_close: Button = %PanelClose
@onready var _toast: Label = %ToastLabel

var _svc := CityService.new()
var _city: Dictionary = {}
var _city_id: String = ""
var _cur_panel: String = ""          ## tavern / barracks / market / smith / hall
var _place_buttons: Dictionary = {}  ## building_key -> Button

# ------------------------------------------------------------------
# 城内行走场景（替代纯按钮网格）
# ------------------------------------------------------------------
const INTERIOR_SIZE := Vector2(2400, 1500)
## 建筑布点（与 CityGround 的地基/道路对应）
const BUILDING_SPOTS := [
	{ "key": "hall",     "name": "官  府", "short": "官府",   "pos": Vector2(1200, 460) },
	{ "key": "barracks", "name": "兵  营", "short": "兵营",   "pos": Vector2(430, 560) },
	{ "key": "tavern",   "name": "酒  馆", "short": "酒馆",   "pos": Vector2(1970, 560) },
	{ "key": "market",   "name": "市  场", "short": "市场",   "pos": Vector2(520, 1080) },
	{ "key": "smith",    "name": "铁匠铺", "short": "铁匠铺", "pos": Vector2(1880, 1080) },
]
## 门口 NPC（与建筑一一对应，纯氛围 + 提示用）
const BUILDING_NPCS := {
	"hall": "主簿", "barracks": "教官", "tavern": "酒保",
	"market": "商贩", "smith": "铁匠",
}
## 广场游荡巢点：官府前与市场/铁匠铺之间的开阔地带
const CITY_NPC_HOME_SPOTS: Array[Vector2] = [
	Vector2(1000, 780), Vector2(1420, 780), Vector2(1200, 960),
	Vector2(780, 1020), Vector2(1640, 1020), Vector2(1200, 620),
	Vector2(980, 1180),
]
## 【P3-1】建筑 → NPC 交易身份：对应 npc_stock.json 的货单分组，
## 决定这个补位 NPC 能不能交易、以及他卖什么（merchant/blacksmith/elder/official）
const NPC_TYPE_OF_BUILDING := {
	"hall": "official", "market": "merchant", "smith": "blacksmith",
	"tavern": "merchant", "barracks": "official",
}
## 建筑 → NPC 称谓（无专属对话时的兜底台词也要符合他的身份）
const NPC_TITLE_OF_BUILDING := {
	"hall": "衙署官吏", "market": "市井商贾", "smith": "铁匠铺主",
	"tavern": "酒家主人", "barracks": "军中教头",
}
## 无专属对话时的搭话台词（按身份分）：不能让 NPC 只干巴巴回一串「……」
const NPC_SMALLTALK := {
	"merchant": "客官要点什么？价钱好商量。",
	"blacksmith": "炉子还热着，要不要看看家伙？",
	"official": "此城事务繁杂，下官先失陪了。",
	"elder": "后生，路上小心些。",
	"youth": "听说近来城外不太平……",
	"hero": "阁下若无他事，某先告辞。",
	"resident": "今日天气倒是不错。",
}
## 建筑门口 NPC 的立绘 id（AI 美术批次）：有对应立绘则用贴图，否则自动回退几何小人
const BUILDING_NPC_ART_IDS := {
	"market": "npc_traveler", "smith": "npc_blacksmith",
}
const INTERACT_RADIUS := 210.0     ## 走到多近显示「进入」按钮
const GATE_ZONE_Y := 1400.0        ## 走到此处出现「出城」

var _world: Node2D
var _player: PlayerController
var _joy: GameJoystick
var _enter_btn: Button
var _near_key := ""
var _at_gate := false
var _quest_panel: QuestPanel         ## 任务中心面板
var _panel: CharacterPanel           ## 人物/武将详情面板
var _menu_wheel: MainMenuWheel       ## 圆形图标主菜单
var _hero_dex: HeroDex               ## 人物志浏览器
var _attr_panel: AttributePanel       ## 主角成长 / 属性加点面板
var _ach_panel: AchievementPanel      ## 成就面板
var _diplomacy: DiplomacyPanel        ## 外交面板（圆形菜单外交入口，与大地图一致）
var _self_rule: SelfRulePanel         ## 自立面板（圆形菜单自立入口，与大地图一致）
var _dialogue: DialogueUI             ## 城内对话界面（代码构建，与大地图同一脚本）
var _trade: NpcTradePanel             ## 城内 NPC 背包交易面板
var _walk_trade_btn: Button           ## 「与 X 交易」按钮（靠近商人时出现）
var _city_npcs: Array[Dictionary] = []  ## 本城 NPC：{data, node}
var _near_npc: Dictionary = {}          ## 当前靠近的城内 NPC
var _settings: SettingsPanel            ## 系统设置面板（音量 / 存档 / 返回主菜单）


func _ready() -> void:
	_city_id = GameState.current_city_id
	_city = DataManager.get_city(_city_id)

	AudioManager.play_bgm("res://assets/audio/bgm/city.ogg")

	_build_place_buttons()
	_refresh_header()
	_build_interior()

	# 恢复演练前在城内的位置
	if GameState.return_scene == "city":
		_player.position = GameState.return_pos
		GameState.return_scene = ""

	_btn_leave.pressed.connect(_on_leave)
	_btn_drill.pressed.connect(_open_drill)
	_btn_menu.pressed.connect(_open_menu)
	_btn_panel_close.pressed.connect(_close_panel)
	_walk_enter_btn.pressed.connect(_on_walk_enter)
	_walk_gate_btn.pressed.connect(_on_leave)

	_panel_root.visible = false

	# 任务中心面板（代码创建，挂在本场景 UI 层）
	_quest_panel = QuestPanel.new()
	_quest_panel.name = "QuestPanel"
	add_child(_quest_panel)

	# 人物/武将详情面板（代码创建）
	_panel = CharacterPanel.new()
	_panel.name = "CharacterPanel"
	add_child(_panel)

	# 圆形图标主菜单（代码创建）
	_menu_wheel = MainMenuWheel.new()
	_menu_wheel.name = "MainMenuWheel"
	add_child(_menu_wheel)
	_menu_wheel.selected.connect(_on_wheel_selected)

	# 人物志浏览器（代码创建）
	_hero_dex = HeroDex.new()
	_hero_dex.name = "HeroDex"
	add_child(_hero_dex)
	_hero_dex.picked.connect(_on_hero_picked)

	# 主角成长 / 属性加点面板（代码创建）
	_attr_panel = AttributePanel.new()
	_attr_panel.name = "AttributePanel"
	add_child(_attr_panel)

	# 成就面板（代码创建）
	_ach_panel = AchievementPanel.new()
	_ach_panel.name = "AchievementPanel"
	add_child(_ach_panel)

	# 外交面板（代码创建）
	_diplomacy = DiplomacyPanel.new()
	_diplomacy.name = "DiplomacyPanel"
	add_child(_diplomacy)

	# 自立面板（代码创建）：
	# 【修复】城内菜单此前没有创建 SelfRulePanel、分发也没写 "self_rule" 分支，
	# 点「自立」只会落到默认分支弹「待实装」—— 表现为按钮点击无响应。
	_self_rule = SelfRulePanel.new()
	_self_rule.name = "SelfRulePanel"
	add_child(_self_rule)

	# 系统设置面板（代码创建）
	_settings = SettingsPanel.new()
	_settings.name = "SettingsPanel"
	add_child(_settings)

	# 城内对话界面（与大地图同一 DialogueUI 脚本，代码构建）
	_dialogue = DialogueUI.create()
	_dialogue.name = "DialogueUI"
	add_child(_dialogue)

	# 城内 NPC 背包交易面板（代码创建）
	_trade = NpcTradePanel.new()
	_trade.name = "NpcTradePanel"
	add_child(_trade)

	# 「与 X 交易」按钮（靠近可交易 NPC 时出现，位于交谈按钮下方）
	_walk_trade_btn = Button.new()
	_walk_trade_btn.text = "交易"
	_walk_trade_btn.add_theme_font_size_override("font_size", 28)
	_walk_trade_btn.set_anchors_preset(Control.PRESET_CENTER)
	_walk_trade_btn.offset_left = -110
	_walk_trade_btn.offset_top = 200
	_walk_trade_btn.offset_right = 110
	_walk_trade_btn.offset_bottom = 290
	_walk_trade_btn.visible = false
	_walk_trade_btn.pressed.connect(_on_walk_trade)
	$WalkUI.add_child(_walk_trade_btn)

	EventBus.toast.connect(show_toast)
	EventBus.gold_changed.connect(func(_v): _refresh_header())
	EventBus.food_changed.connect(func(_v): _refresh_header())
	EventBus.wood_changed.connect(func(_v): _refresh_header())
	EventBus.iron_changed.connect(func(_v): _refresh_header())
	EventBus.troop_changed.connect(func(_v): _refresh_header())
	EventBus.inventory_changed.connect(func(_a, _b): _on_inventory_changed())
	EventBus.party_changed.connect(_on_party_changed)


func _unhandled_input(event: InputEvent) -> void:
	# 安卓返回键 / Esc：优先关闭面板
	if event.is_action_pressed("ui_cancel"):
		if _menu_wheel != null and _menu_wheel.is_open():
			_menu_wheel.close()
			get_viewport().set_input_as_handled()
		elif _dialogue != null and _dialogue.is_open():
			_dialogue.close_immediately()
			get_viewport().set_input_as_handled()
		elif _trade != null and _trade.is_open():
			_trade.close()
			get_viewport().set_input_as_handled()
		elif _hero_dex != null and _hero_dex.is_open():
			_hero_dex.close()
			get_viewport().set_input_as_handled()
		elif _quest_panel != null and _quest_panel.is_open():
			_quest_panel.close_panel()
			get_viewport().set_input_as_handled()
		elif _attr_panel != null and _attr_panel.is_open():
			_attr_panel.close_panel()
			get_viewport().set_input_as_handled()
		elif _ach_panel != null and _ach_panel.is_open():
			_ach_panel.close_panel()
			get_viewport().set_input_as_handled()
		elif _diplomacy != null and _diplomacy.is_open():
			_diplomacy.close()
			get_viewport().set_input_as_handled()
		elif _self_rule != null and _self_rule.is_open():
			_self_rule.close()
			get_viewport().set_input_as_handled()
		elif _panel != null and _panel.is_open():
			_panel.close()
			get_viewport().set_input_as_handled()
		elif _settings != null and _settings.is_open():
			_settings.close()
			get_viewport().set_input_as_handled()
		elif _panel_root.visible:
			_close_panel()
			get_viewport().set_input_as_handled()


## ---------- 顶部 ----------

func _refresh_header() -> void:
	var city_name := str(_city.get("name", "")) if not _city.is_empty() else "无名城镇"
	if city_name.is_empty():
		city_name = "无名城镇"
	_title.text = city_name

	if _city.is_empty():
		_info_label.text = "（无城池数据）"
	else:
		var lines: Array[String] = []
		lines.append("%s" % _type_cn(str(_city.get("type", "city"))))
		lines.append("等级 %d" % int(_city.get("level", 1)))
		lines.append("民心 %d" % GameState.get_city_morale(_city_id))
		lines.append("城防 %d" % GameState.get_city_defense(_city_id))
		lines.append("驻军 %d" % int(_city.get("garrison", 0)))
		lines.append("人口 %d" % int(_city.get("population", 0)))
		var spec := str(_city.get("specialty", ""))
		if not spec.is_empty():
			lines.append("特产 %s" % spec)
		_info_label.text = "　|　".join(lines)

	_res_label.text = "金 %d　　粮 %d　　木 %d　　铁 %d　　兵力 %d" % [
		GameState.gold, GameState.food, GameState.wood, GameState.iron,
		GameState.get_total_troops(),
	]


func _type_cn(t: String) -> String:
	match t:
		"city": return "城池"
		"village": return "村寨"
		"pass": return "关隘"
		"ruin": return "遗迹"
		_: return t


## ---------- 建筑入口 ----------

## 建筑定义：key -> { name, desc, building_field }
## building_field 对应 cities.json 里 buildings 数组的标识；空字符串表示无条件开放
const PLACES := [
	{ "key": "tavern",   "name": "酒  馆", "desc": "招募武将\n赠礼交好", "field": "tavern" },
	{ "key": "barracks", "name": "兵  营", "desc": "征兵练兵\n编入武将", "field": "barracks" },
	{ "key": "market",   "name": "市  场", "desc": "买卖物资\n补充给养", "field": "market" },
	{ "key": "smith",    "name": "铁匠铺", "desc": "打造装备\n购置神器", "field": "smith" },
	{ "key": "hall",     "name": "官  府", "desc": "内政建设\n演武操练", "field": "hall" },
]


func _build_place_buttons() -> void:
	for child in _place_grid.get_children():
		child.queue_free()
	_place_buttons.clear()

	var buildings: Array = _city.get("buildings", [])
	var is_city := str(_city.get("type", "city")) == "city"

	for p in PLACES:
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(346, 200)
		btn.add_theme_font_size_override("font_size", 34)
		btn.text = "%s\n%s" % [str(p["name"]), str(p["desc"])]

		# 开放判定：城池才开放全部；村寨/关隘按 buildings 字段
		var field := str(p["field"])
		var open := true
		if not is_city:
			open = (field in buildings) or (field == "hall")
		else:
			# 城池：官府常开，其余看 buildings 字段（缺省视为开放）
			if field != "hall" and not buildings.is_empty():
				open = field in buildings

		btn.disabled = not open
		var key := str(p["key"])
		if open:
			btn.pressed.connect(func(): _open_panel(key))
		else:
			btn.text += "\n（未开放）"
		_place_grid.add_child(btn)
		_place_buttons[key] = btn


## ---------- 城内行走场景 ----------

## 建筑地基（交给 CityGround 画在地面上）
func _building_pads() -> Array:
	var out: Array = []
	for spot in BUILDING_SPOTS:
		var p: Vector2 = spot["pos"]
		out.append({"rect": Rect2(p.x - 190.0, p.y + 46.0, 380.0, 150.0)})
	return out


## 建筑是否开放 —— 与按钮网格同源判定，保证两处表现一致
func _building_open(field: String) -> bool:
	var buildings: Array = _city.get("buildings", [])
	var is_city := str(_city.get("type", "city")) == "city"
	if not is_city:
		return (field in buildings) or (field == "hall")
	if field != "hall" and not buildings.is_empty():
		return field in buildings
	return true


## 构建可行走的城内世界：地面 → 建筑 + 门口 NPC → 城门 → 玩家
func _build_interior() -> void:
	# 旧按钮网格让位给可行走的城内场景
	_place_grid.visible = false

	for child in _interior.get_children():
		child.queue_free()

	# 1. 地面（城墙 / 道路 / 建筑地基）
	var ground := CityGround.new()
	ground.name = "Ground"
	ground.ground_size = INTERIOR_SIZE
	ground.pads = _building_pads()
	_interior.add_child(ground)

	# 2. 建筑实体 + 门口 NPC
	for spot in BUILDING_SPOTS:
		var key: String = str(spot["key"])
		var bpos: Vector2 = spot["pos"]
		var b := CityInteriorArt.build(key, str(spot["name"]), _building_open(key))
		b.position = bpos
		_interior.add_child(b)

		var n := CityInteriorArt.build_npc(
			str(BUILDING_NPCS.get(key, "居民")),
			str(BUILDING_NPC_ART_IDS.get(key, "")))
		n.position = bpos + Vector2(176, 196)
		_interior.add_child(n)

	# 3. 城门守卒（出城点标记）
	var gate := CityInteriorArt.build_npc("守卒")
	gate.position = Vector2(1200.0, INTERIOR_SIZE.y - 190.0)
	_interior.add_child(gate)

	# 4. 玩家（自建，不依赖大地图场景；河流无阻挡，室内自由行走）
	_player = PlayerController.new()
	_player.name = "Player"
	_player.map_size = INTERIOR_SIZE
	_player.auto_zoom = false
	_player.position = Vector2(1200.0, INTERIOR_SIZE.y - 330.0)
	_player.z_index = 20

	var visual := Node2D.new()
	visual.name = "Visual"
	_player.add_child(visual)

	var body := Polygon2D.new()
	body.polygon = PackedVector2Array([
		Vector2(-7, -18), Vector2(7, -18), Vector2(12, 18), Vector2(-12, 18)])
	body.color = Color(0.22, 0.38, 0.62, 1)
	visual.add_child(body)

	var head := Polygon2D.new()
	head.polygon = PackedVector2Array([
		Vector2(9, -26), Vector2(7.79, -21.5), Vector2(4.5, -17), Vector2(0, -17),
		Vector2(-4.5, -17), Vector2(-7.79, -21.5), Vector2(-9, -26), Vector2(-7.79, -30.5),
		Vector2(-4.5, -35), Vector2(0, -35), Vector2(4.5, -35), Vector2(7.79, -30.5)])
	head.color = Color(0.9, 0.74, 0.58, 1)
	visual.add_child(head)

	var outline := Line2D.new()
	outline.points = PackedVector2Array([
		Vector2(-7, -18), Vector2(7, -18), Vector2(12, 18), Vector2(-12, 18), Vector2(-7, -18)])
	outline.width = 2.0
	outline.default_color = Color(0.82, 0.68, 0.32, 1)
	visual.add_child(outline)

	var cam := Camera2D.new()
	cam.name = "Camera2D"
	cam.position_smoothing_enabled = true
	cam.position_smoothing_speed = 6.0
	_player.add_child(cam)

	_interior.add_child(_player)
	cam.zoom = Vector2.ONE * 1.05
	cam.limit_left = 0
	cam.limit_top = 0
	cam.limit_right = int(INTERIOR_SIZE.x)
	cam.limit_bottom = int(INTERIOR_SIZE.y)
	cam.make_current()

	_walk_enter_btn.visible = false
	_walk_gate_btn.visible = false

	# 5. 本城 NPC（在城中活动，随机游荡）
	_spawn_city_npcs()


## 生成本城 NPC：优先按 npcs 表的 city_id 取；表里没有 → 按本城建筑动态补位
func _spawn_city_npcs() -> void:
	_city_npcs.clear()
	var idx := 0
	for npc in DataManager.get_table("npcs"):
		if str(npc.get("city_id", "")) != _city_id:
			continue
		_spawn_one_city_npc(npc, idx)
		idx += 1

	# 【P3-1 城池内 NPC 交互】npcs 表只配了寥寥几座城 —— 全表一共 8 个 NPC，
	# 且全部挂在南中那一座城上。其余上百座城的城里空无一人，玩家走进去只能
	# 对着几栋空房子，"城内 NPC 交互"压根没有东西可交互。
	# 表给不出人时，按本城实际开放的建筑，从 heroes6 里按 interaction_class 取模板人物补位。
	if _city_npcs.is_empty():
		for spot in BUILDING_SPOTS:
			var bkey := str(spot["key"])
			if not _building_open(bkey):
				continue
			var cls := int(CharacterService.BUILDING_NPC_CLASS.get(bkey, -1))
			if cls < 0:
				continue
			var tpl := CharacterService.npc_template_of_class(cls)
			if tpl.is_empty():
				continue
			_spawn_one_city_npc(_npc_from_template(bkey, tpl), idx)
			idx += 1


## 生成一个城内游荡 NPC 节点并登记进 _city_npcs
func _spawn_one_city_npc(npc: Dictionary, idx: int) -> void:
	var node := CityNpc.new()
	node.name = "CityNPC_" + str(npc.get("id", idx))
	node.wander_radius = 200.0
	node.position = CITY_NPC_HOME_SPOTS[idx % CITY_NPC_HOME_SPOTS.size()]
	node.set_meta("npc", npc)
	# 形象：优先立绘贴图（assets/sprites/npcs/<id>.png），缺失回退城内美术小人
	node.add_child(CityInteriorArt.build_npc(
		str(npc.get("name", "居民")), str(npc.get("id", ""))))
	_interior.add_child(node)
	_city_npcs.append({ "data": npc, "node": node })


## 把 heroes6 的模板人物包装成可直接交谈/交易的城内 NPC。
## npc_type 决定他走哪份货单（见 npc_stock.json），title 决定面板抬头。
func _npc_from_template(building_key: String, tpl: Dictionary) -> Dictionary:
	var role_id := int(tpl.get("id", 0))
	return {
		"id": "gen_%s_%d" % [building_key, role_id],
		"name": str(tpl.get("name", "居民")),
		"style_name": str(tpl.get("style_name", "")),
		"npc_type": str(NPC_TYPE_OF_BUILDING.get(building_key, "resident")),
		"city_id": _city_id,
		"role_id": role_id,
		"tags": ["resident"],
		"title": str(NPC_TITLE_OF_BUILDING.get(building_key, "城中居民")),
	}


## 每帧：喂摇杆输入 + 判定「附近建筑 / 已到城门」
func _process(_delta: float) -> void:
	if _player == null:
		return
	# 面板打开时冻结移动，避免误触移动
	if _panel_root.visible:
		_player.set_move_input(Vector2.ZERO)
		_walk_enter_btn.visible = false
		_walk_gate_btn.visible = false
		return
	# 任务中心打开时同样冻结
	if _quest_panel != null and _quest_panel.is_open():
		_player.set_move_input(Vector2.ZERO)
		_walk_enter_btn.visible = false
		_walk_gate_btn.visible = false
		return
	# 圆形主菜单 / 人物志打开时冻结
	if _menu_wheel != null and _menu_wheel.is_open():
		_player.set_move_input(Vector2.ZERO)
		_walk_enter_btn.visible = false
		_walk_gate_btn.visible = false
		return
	if _hero_dex != null and _hero_dex.is_open():
		_player.set_move_input(Vector2.ZERO)
		_walk_enter_btn.visible = false
		_walk_gate_btn.visible = false
		return
	# 人物 / 武将详情面板（CharacterPanel，人物志点选后弹出）打开时冻结
	if _panel != null and _panel.is_open():
		_player.set_move_input(Vector2.ZERO)
		_walk_enter_btn.visible = false
		_walk_gate_btn.visible = false
		return
	# 属性加点 / 成就面板开着时冻结
	if _attr_panel != null and _attr_panel.is_open():
		_player.set_move_input(Vector2.ZERO)
		_walk_enter_btn.visible = false
		_walk_gate_btn.visible = false
		return
	if _ach_panel != null and _ach_panel.is_open():
		_player.set_move_input(Vector2.ZERO)
		_walk_enter_btn.visible = false
		_walk_gate_btn.visible = false
		return
	# 外交面板打开时冻结
	if _diplomacy != null and _diplomacy.is_open():
		_player.set_move_input(Vector2.ZERO)
		_walk_enter_btn.visible = false
		_walk_gate_btn.visible = false
		return
	# 自立面板打开时冻结
	if _self_rule != null and _self_rule.is_open():
		_player.set_move_input(Vector2.ZERO)
		_walk_enter_btn.visible = false
		_walk_gate_btn.visible = false
		return
	# 系统设置面板开着时冻结
	if _settings != null and _settings.is_open():
		_player.set_move_input(Vector2.ZERO)
		_walk_enter_btn.visible = false
		_walk_gate_btn.visible = false
		return
	# 城内对话 / 交易面板开着时冻结
	if (_dialogue != null and _dialogue.is_open()) \
			or (_trade != null and _trade.is_open()):
		_player.set_move_input(Vector2.ZERO)
		_walk_enter_btn.visible = false
		_walk_gate_btn.visible = false
		_walk_trade_btn.visible = false
		return
	_player.set_move_input(_walk_joy.output)
	_update_nearby()


func _update_nearby() -> void:
	var p := _player.position

	# 城门（走到下方即出现「出城」）
	var at_gate := p.y >= GATE_ZONE_Y
	_at_gate = at_gate
	_walk_gate_btn.visible = at_gate

	# 最近的开放建筑
	var near_key := ""
	var near_label := ""
	var best: float = INTERACT_RADIUS
	for spot in BUILDING_SPOTS:
		var key: String = str(spot["key"])
		if not _building_open(key):
			continue
		var bpos: Vector2 = spot["pos"]
		var d := p.distance_to(bpos)
		if d < best:
			best = d
			near_key = key
			near_label = str(spot["short"])
	_near_key = near_key

	# 最近的城内 NPC（与建筑抢最近的交互目标）
	var near_npc: Dictionary = {}
	var npc_label := ""
	var npc_best: float = INTERACT_RADIUS
	for entry in _city_npcs:
		var node: Node2D = entry.get("node")
		var d := p.distance_to(node.position)
		if d < npc_best:
			npc_best = d
			near_npc = entry.get("data")
			npc_label = str(near_npc.get("name", ""))

	# NPC 更近 → 交谈/交易；否则 → 进建筑
	if not near_npc.is_empty() and npc_best <= best:
		_near_npc = near_npc
		_near_key = ""
		_walk_enter_btn.visible = true
		_walk_enter_btn.text = "与 %s 交谈" % npc_label
		var npc_type := str(_near_npc.get("npc_type", ""))
		_walk_trade_btn.visible = npc_type in ["merchant", "blacksmith", "elder", "official"]
	else:
		_near_npc = {}
		_walk_trade_btn.visible = false
		_walk_enter_btn.visible = not near_key.is_empty()
		if not near_key.is_empty():
			_walk_enter_btn.text = "进入 %s" % near_label


func _on_walk_enter() -> void:
	# 靠近的是城内 NPC → 对话（接取/提交任务都在对话里）
	if not _near_npc.is_empty():
		AudioManager.sfx_click()
		var root := str(_near_npc.get("dialogue_root", ""))
		if root.is_empty():
			# 【P3-1】没有专属对话也要说句人话。旧代码只弹一串「……」，
			# 玩家点下去毫无反馈，第一反应就是"NPC 交互坏了"。
			var who := str(_near_npc.get("npc_type", "resident"))
			var line := str(NPC_SMALLTALK.get(who, NPC_SMALLTALK["resident"]))
			show_toast("%s：「%s」" % [str(_near_npc.get("name", "")), line])
			return
		# 对话左栏立绘：NPC 走字符串 id，武将走 heroes6 数字 id（role_id）
		var rid := str(_near_npc.get("role_id", ""))
		_dialogue.portrait_key = rid if (not rid.is_empty() and rid != "0") \
			else str(_near_npc.get("id", ""))
		_dialogue.talker_id = str(_near_npc.get("id", ""))
		_dialogue.start(root)
		return
	if _near_key.is_empty():
		return
	_open_panel(_near_key)


func _on_walk_trade() -> void:
	if _near_npc.is_empty():
		return
	AudioManager.sfx_click()
	_trade.open(_near_npc)


## ---------- 面板：通用 ----------

func _open_panel(key: String) -> void:
	if _cur_panel == key and _panel_root.visible:
		return
	AudioManager.sfx_click()
	_cur_panel = key
	_panel_root.visible = true
	_clear_panel()

	match key:
		"tavern":   _build_tavern()
		"barracks": _build_barracks()
		"market":   _build_market()
		"smith":    _build_smith()
		"hall":     _build_hall()


func _close_panel() -> void:
	AudioManager.sfx_cancel()
	_panel_root.visible = false
	_cur_panel = ""
	_clear_panel()
	_refresh_header()


func _clear_panel() -> void:
	for c in _panel_content.get_children():
		c.queue_free()
	for c in _panel_footer.get_children():
		if str(c.name) != "PanelClose":
			c.queue_free()


func _add_footer_btn(text: String, cb: Callable, primary: bool = false) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(210, 62)
	b.add_theme_font_size_override("font_size", 24)
	b.text = text
	if primary:
		b.add_theme_color_override("font_color", C_ACCENT)
	b.pressed.connect(cb)
	_panel_footer.add_child(b)
	return b


func _add_section(text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 24)
	l.add_theme_color_override("font_color", C_ACCENT)
	_panel_content.add_child(l)


func _add_hint(text: String, color: Color = C_DIM) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 19)
	l.add_theme_color_override("font_color", color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_panel_content.add_child(l)


func _add_row(text: String, cb: Callable, enabled: bool = true, sub: String = "") -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, 74 if sub.is_empty() else 96)
	b.add_theme_font_size_override("font_size", 22)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.text = text if sub.is_empty() else "%s\n%s" % [text, sub]
	b.disabled = not enabled
	if enabled:
		b.pressed.connect(cb)
	_panel_content.add_child(b)
	return b


## ---------- 面板：酒馆 ----------

func _build_tavern() -> void:
	_panel_title.text = "酒  馆"

	# 已入队武将
	_add_section("队伍武将（%d 人）" % GameState.party.size())
	if GameState.party.is_empty():
		_add_hint("尚无武将入队。招募武将为部队任命统兵，可大幅提升战力。")
	else:
		for h in GameState.party:
			var hero := DataManager.get_character(str(h.get("hero_id", "")))
			var stats: Dictionary = hero.get("stats", {})
			var cmd := (float(stats.get("intelligence", 50)) + float(stats.get("charisma", 50))) * 0.5
			_add_hint("· %s（%s）　统率约 %d　等级 %d　好感 %d" % [
				str(hero.get("name", "?")), str(hero.get("style_name", "")),
				int(cmd), int(h.get("level", 1)), int(h.get("intimacy", 0)),
			], C_TEXT)

	# 赠礼（若有美酒）
	if not GameState.party.is_empty() and GameState.get_item_count("consume_wine") > 0:
		_add_section("赠礼交好（美酒 ×%d）" % GameState.get_item_count("consume_wine"))
		for h in GameState.party:
			var hid := str(h.get("hero_id", ""))
			var hero := DataManager.get_character(hid)
			var hname := str(hero.get("name", hid))
			_add_row("赠 %s 美酒（好感 +30）" % hname,
				func(): _do_gift(hid))

	# 结义
	if not GameState.party.is_empty():
		var sworn_n := CharacterService.sworn_count(GameState.party)
		_add_section("桃园结义（%d / %d）" % [sworn_n, CharacterService.SWORN_MAX])
		if sworn_n >= CharacterService.SWORN_MAX:
			_add_hint("结义兄弟名额已满。")
		for h in GameState.party:
			var shid := str(h.get("hero_id", ""))
			var shero := DataManager.get_hero_resolved(shid)
			var shname := str(shero.get("name", shid)) if not shero.is_empty() else shid
			var sint := int(h.get("intimacy", 0))
			if bool(h.get("sworn", false)):
				_add_hint("· %s　已结义（统兵攻防 +%d%%）" % [
					shname, int(CharacterService.SWORN_COMBAT_BONUS * 100)], C_TEXT)
			elif CharacterService.can_sworn_by_intimacy(sint) and sworn_n < CharacterService.SWORN_MAX:
				_add_row("与 %s 结义（好感 %d）" % [shname, sint],
					func(): _do_sworn(shid))
			# 好感不足的不显示按钮，避免噪声

	# 监牢（俘虏）
	if not GameState.prisoners.is_empty():
		_add_section("监  牢（%d 人）" % GameState.prisoners.size())
		var max_party := int(DataManager.get_recruit_settings().get("max_party_size", 8))
		for p in GameState.prisoners:
			var hid := str(p.get("hero_id", ""))
			var hero := DataManager.get_hero_resolved(hid)
			var hname := str(hero.get("name", hid)) if not hero.is_empty() else hid
			var intimacy := int(p.get("intimacy", 0))
			var cost := PrisonerService.recruit_cost(hero)
			var avg := int(PrisonerService.hero_stat_avg(hero))
			_add_hint("· %s　四维均值 %d　好感 %d / %d" % [
				hname, avg, intimacy, PrisonerService.RECRUIT_INTIMACY_THRESHOLD,
			], C_TEXT)
			# 赠美酒
			var wine_cnt := GameState.get_item_count("consume_wine")
			var gift_ok := wine_cnt > 0 and intimacy < 100
			_add_row("赠美酒（好感 +%d，剩余美酒 %d）" % [PrisonerService.GIFT_INTIMACY_GAIN, wine_cnt],
				func(): _do_prisoner_gift(hid), gift_ok,
				"需美酒道具" if not gift_ok else "")
			# 招降
			var gate := PrisonerService.can_recruit(hero, intimacy, GameState.gold, GameState.party.size(), max_party)
			_add_row("招降（金 %d，需好感 %d）" % [cost, PrisonerService.RECRUIT_INTIMACY_THRESHOLD],
				func(): _do_prisoner_recruit(hid), bool(gate["ok"]),
				"" if gate["ok"] else "[%s]" % str(gate["reason"]))
			# 处死
			_add_row("处死（恶名 +%d）" % PrisonerService.EXECUTE_INFAMY_GAIN,
				func(): _do_prisoner_execute(hid), true,
				"斩将立威，无法挽回")

	# 可招募
	_add_section("在野武将")
	var entries := DataManager.get_recruit_entries(_city_id)
	if entries.is_empty():
		_add_hint("此城暂无在野武将到访。")
		return
	for e in entries:
		var hero := DataManager.get_character(str(e.get("hero_id", "")))
		var hid := str(e.get("hero_id", ""))
		var terms := _svc.recruit_hero_terms(e)
		var gate := _svc.can_recruit_hero(e)
		var star := "★".repeat(int(e.get("difficulty", 1)))
		var head := "%s（%s）　%s" % [str(hero.get("name", hid)), str(hero.get("style_name", "")), star]
		var sub := "价 %d 金" % int(terms["gold"])
		if int(terms["fame"]) > 0:
			sub += "　需名声 %d" % int(terms["fame"])
		if int(terms["infamy"]) > 0:
			sub += "　需恶名 %d" % int(terms["infamy"])
		sub += "\n%s" % str(e.get("note", ""))
		if not gate["ok"]:
			sub += "　[%s]" % str(gate["reason"])
		# 【C2 先看后招】点进详情看清楚再决定，不再「点一下直接扣钱入队」。
		# 门槛不满足也不禁用：玩家照样能看属性，只是招募按钮不可点。
		_add_row(head, func(): _open_hero_detail(e), true, sub)



# ------------------------------------------------------------------
# C2：在野武将「先看后招」
# ------------------------------------------------------------------
## 不同难度的在野武将，搭话时的口吻（纯文本表现，无数值副作用）
const WANDERER_LINES: Array[String] = [
	"「闲居无聊，若有用得着某处，尽管开口。」",
	"「这世道，能有一处安身立命便已难得。」",
	"「若明主相邀，某愿效犬马之劳。」",
	"「某平生之志，岂甘碌碌老于林下？」",
	"「天下英雄，唯使君与某耳。」",
]

var _hero_detail_entry: Dictionary = {}   ## 当前查看中的在野武将招募条目


## 打开在野武将详情：属性 / 特技 / 列传 / 招募门槛，全部看完再决定要不要招。
func _open_hero_detail(entry: Dictionary) -> void:
	_hero_detail_entry = entry
	AudioManager.sfx_click()
	_clear_panel()
	_panel_title.text = "在野武将"

	var hero_id := str(entry.get("hero_id", ""))
	var hero := DataManager.get_hero_resolved(hero_id)
	if hero.is_empty():
		hero = DataManager.get_character(hero_id)
	var hname := str(hero.get("name", hero_id))
	var style := str(hero.get("style_name", ""))

	# —— 名片 ——
	_add_section("名　帖")
	_add_hint("%s（%s）　%s" % [hname, style, CharacterService.faction_text(hero)], C_TEXT)
	var title := CharacterService.title_text(hero)
	if not title.is_empty():
		_add_hint("称号：%s" % title, C_ACCENT)

	# —— 能力 ——
	_add_section("能　力")
	var fs := CharacterService.four_stats(hero)
	var labels: Array = fs.get("labels", []) as Array
	var values: Array = fs.get("values", []) as Array
	if labels.is_empty():
		_add_hint("此人底细不明。")
	else:
		var segs: Array[String] = []
		for i in range(mini(labels.size(), values.size())):
			var v := float(values[i])
			segs.append("%s %d(%s)" % [str(labels[i]), int(v), CharacterService.grade(v)])
		_add_hint("　".join(segs), C_TEXT)
		var avg := 0.0
		for v2 in values:
			avg += float(v2)
		avg /= maxf(float(values.size()), 1.0)
		_add_hint("四维均值 %d　评价 %s" % [int(avg), CharacterService.grade(avg)], C_ACCENT)

	# —— 特技 ——
	_add_section("特　技")
	_add_hint(CharacterService.traits_text(hero), C_TEXT)

	# —— 列传 ——
	var desc := str(hero.get("description", ""))
	if desc.is_empty():
		desc = str(hero.get("note", ""))
	var note := str(entry.get("note", ""))
	if not desc.is_empty() or not note.is_empty():
		_add_section("列　传")
		if not desc.is_empty():
			_add_hint(desc, C_TEXT)
		if not note.is_empty() and note != desc:
			_add_hint(note, C_DIM)

	# —— 招募条件 ——
	_add_section("招募条件")
	var terms := _svc.recruit_hero_terms(entry)
	var gate := _svc.can_recruit_hero(entry)
	var terms_txt := "金 %d　难度 %s" % [int(terms["gold"]), "★".repeat(int(terms["difficulty"]))]
	_add_hint(terms_txt, C_ACCENT)
	if int(terms["fame"]) > 0:
		_add_hint("需名声 %d（当前 %d）" % [int(terms["fame"]), GameState.fame],
			C_TEXT if GameState.fame >= int(terms["fame"]) else C_BAD)
	if int(terms["infamy"]) > 0:
		_add_hint("需恶名 %d（当前 %d）" % [int(terms["infamy"]), GameState.infamy],
			C_TEXT if GameState.infamy >= int(terms["infamy"]) else C_BAD)
	_add_hint(str(gate["reason"]) if not bool(gate["ok"]) else "条件已足，可邀其出山。",
		C_BAD if not bool(gate["ok"]) else C_GOOD)

	_add_footer_btn("交谈", func(): _talk_to_wanderer(entry))
	var can_join := bool(gate["ok"])
	var btn_recruit := _add_footer_btn("招  募（%d 金）" % int(terms["gold"]),
		func(): _do_recruit_hero(entry), can_join)
	btn_recruit.disabled = not can_join
	_add_footer_btn("返回名单", _reopen)


## 与在野武将搭话：确认他的态度与眼下卡在哪儿（不改任何数值）
func _talk_to_wanderer(entry: Dictionary) -> void:
	var hero_id := str(entry.get("hero_id", ""))
	var hero := DataManager.get_hero_resolved(hero_id)
	if hero.is_empty():
		hero = DataManager.get_character(hero_id)
	var hname := str(hero.get("name", hero_id))
	var diff := clampi(int(entry.get("difficulty", 1)) - 1, 0, WANDERER_LINES.size() - 1)
	var msg := "%s：%s" % [hname, WANDERER_LINES[diff]]
	var gate := _svc.can_recruit_hero(entry)
	if not bool(gate["ok"]):
		msg += "\n［眼下尚不能同行：%s］" % str(gate["reason"])
	show_toast(msg)
	AudioManager.sfx_click()


func _do_gift(hero_id: String) -> void:
	var r := _svc.give_gift(hero_id, "consume_wine")
	AudioManager.sfx_click() if not r["ok"] else AudioManager.sfx_confirm()
	show_toast(str(r["msg"]))
	_reopen()


## 结义
func _do_sworn(hero_id: String) -> void:
	if GameState.is_sworn(hero_id):
		_reopen()
		return
	if CharacterService.sworn_count(GameState.party) >= CharacterService.SWORN_MAX:
		show_toast("结义名额已满（%d 人）" % CharacterService.SWORN_MAX)
		AudioManager.sfx_cancel()
		return
	var intimacy := 0
	for h in GameState.party:
		if str(h.get("hero_id", "")) == hero_id:
			intimacy = int(h.get("intimacy", 0))
			break
	if not CharacterService.can_sworn_by_intimacy(intimacy):
		show_toast("好感不足（需 %d，当前 %d）" % [CharacterService.SWORN_INTIMACY_REQUIRED, intimacy])
		AudioManager.sfx_cancel()
		return
	GameState.set_sworn(hero_id, true)
	var hero := DataManager.get_hero_resolved(hero_id)
	var hname := str(hero.get("name", hero_id)) if not hero.is_empty() else hero_id
	show_toast("与 %s 结为兄弟！其统兵攻防 +%d%%" % [
		hname, int(CharacterService.SWORN_COMBAT_BONUS * 100)])
	AudioManager.sfx_confirm()
	_reopen()


func _do_recruit_hero(entry: Dictionary) -> void:
	var r := _svc.recruit_hero(entry)
	if r["ok"]:
		AudioManager.sfx_confirm()
	else:
		AudioManager.sfx_cancel()
	show_toast(str(r["msg"]))
	_reopen()


## ---------- 俘虏操作 ----------

func _do_prisoner_gift(hero_id: String) -> void:
	if not GameState.has_item("consume_wine", 1):
		show_toast("没有美酒")
		AudioManager.sfx_cancel()
		return
	GameState.consume_item("consume_wine", 1)
	GameState.add_prisoner_intimacy(hero_id, PrisonerService.GIFT_INTIMACY_GAIN)
	AudioManager.sfx_confirm()
	show_toast("好感 +%d" % PrisonerService.GIFT_INTIMACY_GAIN)
	_reopen()


func _do_prisoner_recruit(hero_id: String) -> void:
	var p := GameState.get_prisoner(hero_id)
	if p.is_empty():
		_reopen()
		return
	var hero := DataManager.get_hero_resolved(hero_id)
	var intimacy := int(p.get("intimacy", 0))
	var max_party := int(DataManager.get_recruit_settings().get("max_party_size", 8))
	var gate := PrisonerService.can_recruit(hero, intimacy, GameState.gold, GameState.party.size(), max_party)
	if not gate["ok"]:
		show_toast(str(gate["reason"]))
		AudioManager.sfx_cancel()
		return
	var cost := int(gate["cost"])
	GameState.add_gold(-cost)
	if not GameState.recruit_hero(hero_id):
		GameState.add_gold(cost)
		show_toast("入队失败")
		AudioManager.sfx_cancel()
		return
	# 继承俘虏期间累积的好感
	for h in GameState.party:
		if str(h.get("hero_id", "")) == hero_id:
			h["intimacy"] = intimacy
			break
	GameState.remove_prisoner(hero_id)
	var hname := str(hero.get("name", hero_id)) if not hero.is_empty() else hero_id
	show_toast("%s 归降！（-金 %d，好感 %d）" % [hname, cost, intimacy])
	AudioManager.sfx_confirm()
	_reopen()


func _do_prisoner_execute(hero_id: String) -> void:
	var p := GameState.get_prisoner(hero_id)
	if p.is_empty():
		_reopen()
		return
	var hero := DataManager.get_hero_resolved(hero_id)
	var hname := str(hero.get("name", hero_id)) if not hero.is_empty() else hero_id
	GameState.remove_prisoner(hero_id)
	var gain := PrisonerService.execute_infamy_gain()
	GameState.add_infamy(gain)
	show_toast("已处死 %s，恶名 +%d" % [hname, gain])
	AudioManager.sfx_cancel()
	_reopen()


## ---------- 面板：兵营 ----------

func _build_barracks() -> void:
	_panel_title.text = "兵  营"

	# 现有部队
	_add_section("现有部队（总兵力 %d）" % GameState.get_total_troops())
	if GameState.troops.is_empty():
		_add_hint("尚无部队，请先征兵。")
	else:
		for i in range(GameState.troops.size()):
			var t: Dictionary = GameState.troops[i]
			var unit := DataManager.get_unit(str(t.get("unit_id", "")))
			var hero_id := str(t.get("hero_id", ""))
			var hero := DataManager.get_character(hero_id) if not hero_id.is_empty() else {}
			var hname := str(hero.get("name", "")) if not hero.is_empty() else "无"
			var lv := int(t.get("level", 1))
			var exp := int(t.get("exp", 0))
			var idx := i
			var txt := "%s ×%d　等级 %d（经验 %d）\n统兵：%s" % [
				str(unit.get("name", "?")), int(t.get("count", 0)), lv, exp, hname,
			]
			_add_row(txt,
				func(): _open_train_menu(idx),
				true,
				"点击可练兵 / 换统兵武将 / 解散")

	# 征兵
	_add_section("征  兵")
	var quota := _svc.remaining_quota(_city_id)
	var morale := GameState.get_city_morale(_city_id)
	var cap_morale := _svc.morale_recruit_capacity(_city_id)
	var gated := _svc.effective_recruit_limit(_city_id)
	_add_hint("每日名额 %d 人　|　民心 %d（可支撑 %d 人）" % [quota, morale, cap_morale], C_DIM)
	# 民心是 Demo 阶段真正的瓶颈，必须让玩家看见
	if cap_morale < quota:
		_add_hint("※ 当前受【民心】限制，实际还可征 %d 人。施赈（官府）可恢复民心。" % gated, C_ACCENT)
	else:
		_add_hint("※ 当前受【每日名额】限制，实际还可征 %d 人。" % gated, C_DIM)

	var units_cfg: Array = DataManager.get_record("barracks", "root").get("units", [])
	for cfg in units_cfg:
		var uid := str(cfg.get("unit_id", ""))
		var unit := DataManager.get_unit(uid)
		if unit.is_empty():
			continue
		var gate := _svc.can_recruit_unit(_city_id, uid)
		var cost10 := _svc.recruit_cost(uid, 10)
		var sub := "10 兵 = 金 %d / 粮 %d　民心 -%d" % [
			int(cost10["gold"]), int(cost10["food"]), _svc.morale_cost_for_batch(),
		]
		if not gate["ok"]:
			sub += "　[%s]" % str(gate["reason"])
		else:
			sub += "　%s" % str(cfg.get("unlock_note", ""))
		_add_row("%s（%s）" % [str(unit.get("name", uid)), _cat_cn(str(unit.get("category", "")))],
			func(): _do_recruit(uid, 10), bool(gate["ok"]), sub)



func _cat_cn(cat: String) -> String:
	match cat:
		"infantry": return "步兵"
		"cavalry": return "骑兵"
		"archer": return "弓兵"
		"beast": return "兽兵"
		"special": return "特殊"
		"navy": return "水军"
		"elite": return "精锐"
		_: return cat


func _do_recruit(unit_id: String, count: int) -> void:
	var r := _svc.recruit(_city_id, unit_id, count)
	if r["ok"]:
		AudioManager.sfx_confirm()
	else:
		AudioManager.sfx_cancel()
	show_toast(str(r["msg"]))
	_reopen()


## 单支部队的操作菜单（练兵 / 换将 / 解散）
func _open_train_menu(troop_index: int) -> void:
	if troop_index < 0 or troop_index >= GameState.troops.size():
		return
	AudioManager.sfx_click()
	_clear_panel()
	# 记成独立子页：否则 _cur_panel 仍为 "barracks"，页脚「返回兵营」会因
	# 「同键且面板已可见」被 _open_panel 提前 return，停留在练兵页出不去。
	_cur_panel = "train"
	_panel_title.text = "部队管理"

	var t: Dictionary = GameState.troops[troop_index]
	var unit := DataManager.get_unit(str(t.get("unit_id", "")))
	_add_section("%s ×%d" % [str(unit.get("name", "?")), int(t.get("count", 0))])

	# 练兵
	var train_cost := int(DataManager.get_barracks_settings().get("train_food_per_10", 8))
	_add_row("练  兵（10 兵 → 耗粮 %d，积累经验）" % train_cost,
		func(): _do_train(troop_index))
	_add_hint("经验满 %d 后晋升为精锐，战力提升。" % int(DataManager.get_barracks_settings().get("veteran_threshold", 100)))

	# 换统兵武将
	_add_section("任命统兵武将")
	_add_row("（撤销当前统兵）", func(): _do_assign(troop_index, ""), not str(t.get("hero_id", "")).is_empty())
	for h in GameState.party:
		var hid := str(h.get("hero_id", ""))
		var hero := DataManager.get_character(hid)
		var stats: Dictionary = hero.get("stats", {})
		var cmd := (float(stats.get("intelligence", 50)) + float(stats.get("charisma", 50))) * 0.5
		var cur := str(t.get("hero_id", "")) == hid
		_add_row("%s%s（统率约 %d）" % ["✓ " if cur else "", str(hero.get("name", hid)), int(cmd)],
			func(): _do_assign(troop_index, hid), not cur)
	if GameState.party.is_empty():
		_add_hint("尚无武将，请先到酒馆招募。")

	# 解散
	_add_section("其他")
	_add_row("解  散  此  部  队", func(): _do_disband(troop_index))

	_add_footer_btn("返回兵营", func(): _open_panel("barracks"))


func _do_train(troop_index: int) -> void:
	var r := _svc.train(_city_id, troop_index, 10)
	AudioManager.sfx_confirm() if r["ok"] else AudioManager.sfx_cancel()
	show_toast(str(r["msg"]))
	_open_train_menu(troop_index)


func _do_assign(troop_index: int, hero_id: String) -> void:
	var r := _svc.assign_hero(troop_index, hero_id)
	AudioManager.sfx_click() if r["ok"] else AudioManager.sfx_cancel()
	show_toast(str(r["msg"]))
	_open_train_menu(troop_index)


func _do_disband(troop_index: int) -> void:
	if troop_index < 0 or troop_index >= GameState.troops.size():
		return
	var t: Dictionary = GameState.troops[troop_index]
	var unit := DataManager.get_unit(str(t.get("unit_id", "")))
	var n := int(t.get("count", 0))
	GameState.remove_troop(troop_index)
	AudioManager.sfx_cancel()
	show_toast("已解散 %s ×%d" % [str(unit.get("name", "?")), n])
	_open_panel("barracks")


## ---------- 面板：市场 ----------

func _build_market() -> void:
	_panel_title.text = "市  场"
	var level := int(_city.get("level", 1))

	_add_section("买  进")
	for g in DataManager.get_market_goods():
		var goods: Dictionary = g
		var is_res := str(goods.get("kind", "")) == "resource"
		if is_res:
			var res := str(goods.get("resource", ""))
			var pack := int(goods.get("pack", 10))
			var base := int(goods.get("price", 0))
			var price := _svc.buy_price(base, level)
			var g2: Dictionary = goods
			_add_row("%s ×%d" % [str(goods.get("name", res)), pack],
				func(): _do_buy_resource(res, pack, price, g2),
				GameState.gold >= price,
				"金 %d　%s" % [price, str(goods.get("desc", ""))])
		else:
			var iid := str(goods.get("item_id", ""))
			var item := DataManager.get_item(iid)
			if item.is_empty():
				continue
			var price2 := _svc.buy_price(int(item.get("price", 0)), level)
			var iid2 := iid
			# 【P3-2 商店库存为 0】旧文案写的是「库存 %d」却取 GameState.get_item_count(iid)
			# —— 那是玩家自己的持有数。商店是无限供货的，玩家身上没有这件东西时
			# 就赫然显示「库存 0」，看着就像这家店的货被谁买空了。
			# 改为明确标注「你持有」，把「商店的货」和「你身上的货」分开。
			_add_row("%s（你持有 %d 件）" % [str(item.get("name", iid)),
					GameState.get_item_count(iid)],
				func(): _do_buy_item(iid2, 1, price2),
				GameState.gold >= price2,
				"金 %d　%s" % [price2, str(goods.get("desc", ""))])

	# 卖出
	# 【P3-3 打开自己背包出售】旧写法遍历的是 market_goods 里 kind=="item" 的区区几件，
	# 于是玩家背包里的战利品、道具一件都卖不掉 —— 明明身上有货，市场却说没得卖。
	# 改为直接遍历真实背包：凡在物品表里查得到、且有定价的东西都能在这里出手。
	_add_section("卖  出")
	var sold_kinds := 0
	for raw_key in GameState.inventory.keys():
		var sid := str(raw_key)
		var cnt := GameState.get_item_count(sid)
		if cnt <= 0:
			continue
		var item3 := DataManager.get_item(sid)
		if item3.is_empty():
			continue
		var base := int(item3.get("price", 0))
		if base <= 0:
			continue   # 无定价之物（任务/剧情道具）不可出售，免得白送给商人
		_add_market_sell_row(sid, str(item3.get("name", sid)), cnt, _svc.sell_price(base, level))
		sold_kinds += 1
	if sold_kinds == 0:
		_add_hint("背包中没有可售出的物品。")

	# 卖出资源
	# 注意：sell_price 内部会再乘一次城池等级系数，此处必须传「基础价」；
	# 传 buy_price 的返回值会把等级系数乘两遍，售价随城池等级虚高。
	_add_section("售出物资")
	_add_resource_sell_rows("food", "粮草", 100, 200)
	_add_resource_sell_rows("wood", "木材", 50, 150)
	_add_resource_sell_rows("iron", "铁矿", 20, 160)



## 市场卖出行（单独成函数：避免 lambda 捕获循环变量导致所有行卖出同一件道具）
func _add_market_sell_row(item_id: String, name: String, cnt: int, unit: int) -> void:
	_add_row("售 %s ×1（持有 %d，+金 %d）" % [name, cnt, unit],
		func(): _do_sell_item(item_id, 1, unit), unit > 0)


func _add_resource_sell_rows(res: String, name: String, pack: int, base_price: int) -> void:
	var have := 0
	match res:
		"food": have = GameState.food
		"wood": have = GameState.wood
		"iron": have = GameState.iron
	if have < pack:
		return
	var sp := _svc.sell_price(base_price, int(_city.get("level", 1)))
	_add_row("售 %s ×%d（+金 %d）" % [name, pack, sp],
		func(): _do_sell_resource(res, pack, sp))


func _do_buy_resource(res: String, pack: int, price: int, _g: Dictionary) -> void:
	var r := _svc.buy_resource(_city_id, res, pack, price)
	AudioManager.sfx_confirm() if r["ok"] else AudioManager.sfx_cancel()
	show_toast(str(r["msg"]))
	_open_panel("market")


func _do_sell_resource(res: String, pack: int, price: int) -> void:
	var r := _svc.sell_resource(_city_id, res, pack, price)
	AudioManager.sfx_confirm() if r["ok"] else AudioManager.sfx_cancel()
	show_toast(str(r["msg"]))
	_open_panel("market")


func _do_buy_item(item_id: String, count: int, price: int) -> void:
	var r := _svc.buy_item(_city_id, item_id, count, price)
	AudioManager.sfx_confirm() if r["ok"] else AudioManager.sfx_cancel()
	show_toast(str(r["msg"]))
	_open_panel("market")


func _do_sell_item(item_id: String, count: int, price: int) -> void:
	var r := _svc.sell_item(_city_id, item_id, count, price)
	AudioManager.sfx_confirm() if r["ok"] else AudioManager.sfx_cancel()
	show_toast(str(r["msg"]))
	_open_panel("market")


## ---------- 面板：铁匠铺 ----------

func _build_smith() -> void:
	_panel_title.text = "铁匠铺"
	var level := int(_city.get("level", 1))
	_add_hint("打造装备需城池等级达标。装备属性详见物品说明。")

	_build_smith_enhance()

	for g in DataManager.get_smith_goods():
		var goods: Dictionary = g
		var iid := str(goods.get("item_id", ""))
		if iid.is_empty():
			if goods.has("_section"):
				_add_section(str(goods["_section"]))
			continue
		# 纯数字 id → items6 新装备表；否则旧 items.json（命运装备）
		var is_v6 := iid.is_valid_int()
		var item: Dictionary = DataManager.get_item6(int(iid)) if is_v6 else DataManager.get_item(iid)
		if item.is_empty():
			continue
		var gate := _svc.can_buy_smith(_city_id, goods)
		var price := _svc.buy_price(int(item.get("price", 0)), level)
		var stat := CharacterService.item_bonus_text(item) if is_v6 else _item_stat_text(item)
		if stat.is_empty():
			stat = str(item.get("description", goods.get("desc", "")))
		var sub := "金 %d　%s" % [price, stat]
		if not gate["ok"]:
			sub += "　[%s]" % str(gate["reason"])
		var g2: Dictionary = goods
		var name_suffix := ""
		if is_v6:
			var qname := str(item.get("quality_name", ""))
			if not qname.is_empty() and qname != "未知":
				name_suffix = "　【%s】" % qname
		else:
			name_suffix = _rarity_mark(str(item.get("rarity", "")))
		_add_row("%s%s" % [str(item.get("name", iid)), name_suffix],
			func(): _do_buy_equipment(g2),
			bool(gate["ok"]) and GameState.gold >= price,
			sub)



## 强化区：列出已拥有（已装备/背包）且有战斗属性的 items6 装备
func _build_smith_enhance() -> void:
	var ids: Array[int] = []
	for slot in ["weapon1", "helmet", "armor", "treasure", "mount"]:
		var eid := int(GameState.equipment.get(slot, 0))
		if eid > 0 and not ids.has(eid):
			ids.append(eid)
	for key in GameState.inventory.keys():
		var kid := str(key)
		if kid.is_valid_int() and GameState.get_item_count(kid) > 0:
			var nid := kid.to_int()
			if not ids.has(nid):
				ids.append(nid)

	var shown := 0
	for id in ids:
		var item := DataManager.get_item6(id)
		if item.is_empty():
			continue
		var base := CharacterService.item_combat_bonus(item, 0)
		var has_stat := false
		for k in ["attack", "defense", "hp", "speed"]:
			if int(base.get(k, 0)) != 0:
				has_stat = true
				break
		if not has_stat:
			continue
		if shown == 0:
			_add_section("强化装备")
			_add_hint("每级战斗属性 +15%%，最高 +%d。失败装备不碎，可能掉一级。" % EnhanceService.max_level())
		shown += 1
		var lv := EnhanceService.level_of(id)
		var nm := str(item.get("name", str(id)))
		var t := EnhanceService.terms(id)
		var gate := EnhanceService.can_enhance(item, id)
		var sub := CharacterService.item_bonus_text(item, lv)
		var label := "%s　+%d" % [nm, lv]
		if bool(t.get("at_max", false)):
			sub += "　[已达最高级]"
		else:
			sub += "　→　金 %d / 铁 %d　成功率 %d%%" % [
				int(t["gold"]), int(t["iron"]), int(round(float(t["rate"]) * 100.0))]
			if not gate["ok"]:
				sub += "　[%s]" % str(gate["reason"])
		_add_row(label, func(): _do_enhance(id), bool(gate["ok"]), sub)


func _do_enhance(item_id6: int) -> void:
	var r := EnhanceService.enhance(item_id6)
	AudioManager.sfx_confirm() if bool(r.get("success", false)) else AudioManager.sfx_hit()
	if not bool(r.get("ok", false)):
		AudioManager.sfx_cancel()
	show_toast(str(r["msg"]))
	_open_panel("smith")


func _item_stat_text(item: Dictionary) -> String:
	var parts: Array[String] = []
	if int(item.get("attack", 0)) != 0:
		parts.append("攻 +%d" % int(item["attack"]))
	if int(item.get("defense", 0)) != 0:
		parts.append("防 +%d" % int(item["defense"]))
	if int(item.get("speed", 0)) != 0:
		parts.append("速 +%d" % int(item["speed"]))
	if bool(item.get("fire_vulnerable", false)):
		parts.append("惧火")
	if parts.is_empty():
		parts.append(str(item.get("description", "")))
	return "　".join(parts)


func _rarity_mark(rarity: String) -> String:
	match rarity:
		"legendary": return "　【传世】"
		"epic": return "　【珍品】"
		"rare": return "　【精良】"
		_: return ""


func _do_buy_equipment(entry: Dictionary) -> void:
	var r := _svc.buy_equipment(_city_id, entry)
	AudioManager.sfx_confirm() if r["ok"] else AudioManager.sfx_cancel()
	show_toast(str(r["msg"]))
	_open_panel("smith")


## ---------- 面板：官府 ----------

func _build_hall() -> void:
	_panel_title.text = "官  府"

	var morale := GameState.get_city_morale(_city_id)
	var defense := GameState.get_city_defense(_city_id)
	var cap_morale := _svc.morale_recruit_capacity(_city_id)

	_add_section("城池状况")
	_add_hint("民心 %d　城防 %d　等级 %d" % [morale, defense, int(_city.get("level", 1))], C_TEXT)
	_add_hint("征兵上限：%d 人（受民心约束）　|　每日名额：%d 人" % [
		cap_morale, _svc.remaining_quota(_city_id)], C_TEXT)
	_add_hint("民心决定兵源，是 Demo 阶段最紧的约束；城防影响守城战减伤。")

	_add_section("内  政")
	var gain_relieve := int(round(200.0 / 40.0))
	_add_row("开仓施赈（-金 200，民心 +%d → %d）" % [gain_relieve, mini(100, morale + gain_relieve)],
		func(): _do_relieve(),
		GameState.gold >= 200 and morale < 100,
		"每 3 点民心可多征 10 兵　|　当前民心 %d / 100" % morale)
	_add_row("修缮城防（-木 50 / -金 150，城防 +%d → %d）" % [
		4, defense + 4], func(): _do_repair(),
		GameState.wood >= 50 and GameState.gold >= 150,
		"城防越高，守城战我方减伤越多")

	_add_section("演武操练")
	_add_hint("进入演武场，可自由摆布阵型、以预设敌军试演，不消耗兵力、不写存档。")
	_add_row("进  入  演  武  场", func(): _open_drill(),
		true, "%d 套假想敌预设" % DataManager.get_drills().size())



func _do_relieve() -> void:
	var r := _svc.relieve_city(_city_id, 200)
	AudioManager.sfx_confirm() if r["ok"] else AudioManager.sfx_cancel()
	show_toast(str(r["msg"]))
	_open_panel("hall")


func _do_repair() -> void:
	var r := _svc.repair_city(_city_id, 50, 150)
	AudioManager.sfx_confirm() if r["ok"] else AudioManager.sfx_cancel()
	show_toast(str(r["msg"]))
	_open_panel("hall")


## ---------- 演练 ----------

## 打开演练选择：从官府进入时在面板内选；从底部按钮进入时用弹出列表
func _open_drill() -> void:
	AudioManager.sfx_click()
	_panel_root.visible = true
	_cur_panel = "drill"
	_clear_panel()
	_panel_title.text = "演  武  场"
	_add_section("选择假想敌")
	_add_hint("演练不消耗兵力、不给奖励，专为验证布阵与配兵思路。")

	for d in DataManager.get_drills():
		var did := str(d.get("id", ""))
		var diff := int(d.get("difficulty", 1))
		var names: Array[String] = []
		for u in d.get("enemy_units", []):
			var unit := DataManager.get_unit(str(u.get("unit_id", "")))
			if not unit.is_empty():
				names.append("%s×%d" % [str(unit.get("name", "?")), int(u.get("count", 0))])
		var sub := "%s　难度 %s\n%s" % [
			"、".join(names), "★".repeat(diff), str(d.get("description", "")),
		]
		_add_row("【%s】 建议等级 %d" % [str(d.get("name", did)), int(d.get("suggest_level", 1))],
			func(): _start_drill(did), true, sub)



func _start_drill(drill_id: String) -> void:
	var enc := _svc.drill_as_encounter(drill_id)
	if enc.is_empty():
		show_toast("演练配置缺失")
		return
	AudioManager.sfx_confirm()
	GameState.drill_mode = true
	GameState.current_encounter = enc
	# 记录演练前的位置：战斗结束后回到原地
	GameState.return_scene = "city"
	GameState.return_pos = _player.position
	EventBus.drill_started.emit(drill_id)
	SceneRouter.push_scene("formation")


## ---------- 菜单 / 离开 ----------

func _open_menu() -> void:
	AudioManager.sfx_click()
	_menu_wheel.open()


## 圆形主菜单的选项分发：任务中心只是其中一项
func _on_wheel_selected(action: String) -> void:
	match action:
		"quest":
			_quest_panel.open()
		"heroes":
			_hero_dex.open()
		"player":
			_attr_panel.open()
		"achieve":
			_ach_panel.open()
		"diplo":
			_diplomacy.open()
		"self_rule":
			# open("") 内部会回退到 GameState.current_city_id（当前所在城）
			_self_rule.open()
		"system":
			_settings.open(true)
		_:
			show_toast("待实装")


## 人物志点选 → 打开该武将详情
func _on_hero_picked(h: Dictionary) -> void:
	var fid := int(h.get("faction_id", 0))
	var faction: Dictionary = DataManager.get_faction6(fid) if fid > 0 else {}
	var fname := str(faction.get("name", "")) if not faction.is_empty() else ""
	var t := {
		"type": "hero",
		"name": str(h.get("name", "")),
		"title": fname,
		"data": { "role_id": int(h.get("id", 0)) },
	}
	_panel.open(t)


func _on_leave() -> void:
	AudioManager.sfx_click()
	EventBus.city_left.emit(_city_id)
	SceneRouter.back()


## ---------- 刷新辅助 ----------

## 重开当前面板（操作后刷新内容）
func _reopen() -> void:
	if _cur_panel.is_empty():
		return
	var key := _cur_panel
	_cur_panel = ""
	_open_panel(key)


func _on_inventory_changed() -> void:
	if _cur_panel in ["tavern", "market", "smith"]:
		_reopen()


func _on_party_changed() -> void:
	if _cur_panel == "tavern":
		_reopen()


## ---------- 提示 ----------

func show_toast(message: String) -> void:
	_toast.text = message
	_toast.modulate.a = 1.0
	var tween := create_tween()
	tween.tween_interval(2.5)
	tween.tween_property(_toast, "modulate:a", 0.0, 0.5)
