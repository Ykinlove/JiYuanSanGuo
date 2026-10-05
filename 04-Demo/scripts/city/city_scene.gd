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
@onready var _interior: Node2D = $WorldView/SubViewport/Interior
@onready var _walk_joy: GameJoystick = $WalkUI/Joy
@onready var _panel_layer: Control = %PanelLayer
@onready var _panel_title: Label = %PanelTitle
@onready var _panel_body: ScrollContainer = %PanelBody
@onready var _panel_content: VBoxContainer = %PanelContent
@onready var _panel_footer: HBoxContainer = %PanelFooter
@onready var _panel_root: Control = %PanelRoot
@onready var _btn_panel_close: Button = %PanelClose

var _svc := CityService.new()
var _city: Dictionary = {}
var _city_id: String = ""
var _cur_panel: String = ""          ## tavern / barracks / market / smith / hall
var _place_buttons: Dictionary = {}  ## building_key -> Button
var _prison_confirm: Control = null  ## 【第五十一轮】处死俘虏二次确认弹层（防重复弹出）
var _pending_execute_id: String = "" ## 【第五十一轮】待处死的俘虏 id
var _disband_confirm: Control = null  ## 【第五十一轮】解散部队二次确认弹层（防重复弹出）
var _pending_disband_index: int = -1  ## 【第五十一轮】待解散的部队下标，-1 表示无

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
## 广场游荡巢点：官府前与市场/铁匠铺之间的开阔地带
## 【第十四轮 密度提升】由 7 个扩到 16 个，散布广场（间距 ≥180），
## 避免空城补位 NPC 因 idx % size 循环复用而堆叠在同一锚点。
const CITY_NPC_HOME_SPOTS: Array[Vector2] = [
	Vector2(820, 700), Vector2(1080, 700), Vector2(1340, 700), Vector2(1600, 700),
	Vector2(760, 880), Vector2(1020, 880), Vector2(1280, 880), Vector2(1540, 880), Vector2(1800, 880),
	Vector2(860, 1060), Vector2(1120, 1060), Vector2(1380, 1060), Vector2(1640, 1060),
	Vector2(940, 1240), Vector2(1200, 1240), Vector2(1460, 1240),
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
const INTERACT_RADIUS := 260.0     ## 走到多近显示「进入/交谈」按钮（用户反馈 210 仍偏紧）
const GATE_ZONE_Y := 1400.0        ## 走到此处出现「出城」

## 【第十四轮 城内氛围·密度】空城补位的「闲散居民」：不可交易，只用 NPC_SMALLTALK 搭话。
## npc_type 取 resident/elder/youth/hero 轮流 —— DialogueUI 按 npc_type 取 NPC_SMALLTALK 搭话，
## 而 InteractionMenu 只给 merchant/blacksmith 出「交易」选项，所以这几类天然「只交谈、不交易」。
const CITY_RESIDENT_COUNT := 5
const CITY_RESIDENT_TYPES := ["resident", "elder", "youth", "hero"]
const CITY_RESIDENT_TITLES := {
	"resident": "城中居民", "elder": "城中老者",
	"youth": "城中后生", "hero": "路过的游侠",
}

## 城内氛围（纯程序化 CPU 粒子，零新美术资源；Compatibility 下 GPUParticles 静默失效）
const CITY_ATMOS_DUST_AMOUNT := 26      ## 地面扬尘粒子数
const CITY_ATMOS_DUST_ALPHA := 0.16     ## 扬尘透明度
const CITY_ATMOS_LAMP_AMOUNT := 8       ## 每座开放建筑门口的灯火粒子数
const CITY_ATMOS_LAMP_ALPHA := 0.30     ## 灯火透明度（构建初值；每帧按夜色重写）
## 【四十轮·灯火夜亮】白天是灶膛余烟（几乎看不见），入夜点灯笼（暖橙透亮）
const CITY_ATMOS_LAMP_ALPHA_DAY := 0.10
const CITY_ATMOS_LAMP_ALPHA_NIGHT := 0.62
### 【第六十八轮起】夜色压暗：冷蓝薄雾铺满城内世界，压在**全部实体之上**
##   （原注释「只压建筑与地面，不压玩家/NPC」已随 y_sort 接入作废 —— 实体整体成
##   为一个排序单元，无法把压暗层夹在建筑与角色之间；而真实夜晚环境光笼罩一切，
##   「角色亮着、脚下发暗」本身也是贴图感。alpha 仅 0.14×夜色因子，观感损失极小）
const CITY_NIGHT_VEIL_COLOR := Color(0.16, 0.22, 0.42)
const CITY_NIGHT_VEIL_ALPHA := 0.14
## 【第六十八轮·城内层级】接入 y_sort 后，实体整体成为一个排序单元，
## 氛围/夜色/雨雪**再也无法用 add_child 顺序插进实体内部**，层级一律走显式 z：
##   Ground(-100) < ActorLayer(0) < Atmos(80) < NightVeil(90) < WeatherFx(100)
## 单一事实源在此，下面的 z 全部引用它，勿在别处写字面量。
const CITY_ATMOS_Z := 80
const CITY_VEIL_Z := 90
const CITY_WEATHER_Z := 100
## 相机待机微动（叠加在 cam.offset，不破坏硬跟随）
const CITY_CAM_SWAY_AMP_X := 6.0
const CITY_CAM_SWAY_AMP_Y := 4.0
const CITY_CAM_SWAY_FREQ_X := 0.55
const CITY_CAM_SWAY_FREQ_Y := 0.42

var _world: Node2D
var _player: PlayerController
var _joy: GameJoystick
var _enter_btn: Button
var _near_key := ""
var _at_gate := false
var _quest_panel: QuestPanel         ## 任务中心面板
var _panel: CharacterPanel           ## 人物/武将详情面板
var _menu_wheel: MainMenuWheel       ## 圆形图标主菜单
## 【2026-09-28 用户反馈】从轮盘打开的面板关闭后回到轮盘（同 world_map，轮询 visible）
var _wheel_return_panel: Control = null
var _hero_dex: HeroDex               ## 人物志浏览器
var _attr_panel: AttributePanel
var _backpack: BackpackPanel          ## 背包面板（圆形菜单背包入口，与大地图一致）       ## 主角成长 / 属性加点面板
## 【本轮】商城面板（市场面板「打开商城」进入；与大地图轮盘入口共用 EconomyPanel）
var _economy: EconomyPanel
var _ach_panel: AchievementPanel      ## 成就面板
var _diplomacy: DiplomacyPanel        ## 外交面板（圆形菜单外交入口，与大地图一致）
var _self_rule: SelfRulePanel         ## 自立面板（圆形菜单自立入口，与大地图一致）
var _dialogue: DialogueUI             ## 城内对话界面（代码构建，与大地图同一脚本）
var _trade: NpcTradePanel             ## 城内 NPC 背包交易面板
var _menu: InteractionMenu            ## 贴脸交互菜单（圆圈按钮弹出：交谈/交易，与大地图同款）
var _near_npc_pos := Vector2.ZERO     ## 当前最近 NPC 的世界坐标（交互菜单贴着它弹）
var _city_action_btn: Button = null    ## 右下角圆形「城池交互」按钮（与大地图同款）
var _action_hint: Label = null         ## 交互按钮上方的动作提示（进入 X / 交谈 / 出城）
var _menu_btn: Button = null           ## 顶栏右上角圆形菜单按钮（与大地图同款）
var _action_mode: String = ""          ## 当前交互按钮行为：gate / npc / building:<key> / 空
var _city_npcs: Array[Dictionary] = []  ## 本城 NPC：{data, node}
var _near_npc: Dictionary = {}          ## 当前靠近的城内 NPC
var _settings: SettingsPanel            ## 系统设置面板（音量 / 存档 / 返回主菜单）

## 城内氛围运行时句柄
var _atmos: Node2D = null               ## 粒子氛围容器（扬尘 + 灯火）
var _city_cam: Camera2D = null          ## 城内相机引用（用于待机微动）
var _city_cam_t := 0.0                  ## 微动相位累加
## 【四十轮】灯火句柄（每帧按夜色重写 alpha）/ 夜色压暗层 / 跨场景雨雪层
var _lamps: Array = []
var _night_veil: ColorRect = null
var _weather_fx: Node2D = null
var _weather_audio: AudioStreamPlayer = null
var _weather_screen := Vector2.ZERO     ## 雨雪层覆盖尺寸（世界单位），跟随视野用
## 【第六十八轮·城内深度排序】实体层：建筑 + 玩家 + 城内 NPC 全部搬进来开 y_sort
var _actor_layer: Node2D = null


func _ready() -> void:
	_city_id = GameState.current_city_id
	_city = DataManager.get_city(_city_id)

	AudioManager.play_bgm("res://assets/audio/bgm/city.res")

	# 【精美】城内自有面板滚动区同套描金细滚动条（与 make_modal 面板一致）
	UITheme.style_scrollbar(_panel_body)

	_build_place_buttons()
	_refresh_header()
	_build_interior()

	# 恢复演练前在城内的位置
	if GameState.return_scene == "city":
		_player.position = GameState.return_pos
		GameState.return_scene = ""

	_btn_panel_close.pressed.connect(_close_panel)

	# 【重构】城内交互与大地图统一：右下圆形交互钮 + 顶栏右上圆形菜单钮，
	# 删掉原先在底部的「离开 / 菜单」按钮与中央贴脸的「进入 / 出城」按钮。
	_setup_city_action_button()
	_setup_menu_button()

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

	# 人物志 → 详情 → 「返回列表」回到人物志（不整页关闭）
	_panel.back_requested.connect(func():
		if _hero_dex != null:
			_hero_dex.open())

	# 主角成长 / 属性加点面板（代码创建）
	_attr_panel = AttributePanel.new()
	_attr_panel.name = "AttributePanel"
	add_child(_attr_panel)

	# 背包面板（采集资源 / 装备武器查看，代码创建）
	_backpack = BackpackPanel.new()
	_backpack.name = "BackpackPanel"
	add_child(_backpack)

	# 【本轮】商城面板（与大地图轮盘「商城」入口共用同一个类）
	_economy = EconomyPanel.new()
	_economy.name = "EconomyPanel"
	add_child(_economy)

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

	# 【2026-09-28 用户反馈】各面板标题行「返 回」按钮 → 关面板并回到轮盘菜单。
	# 显式按钮路径不依赖 _process 轮询（轮询只兜底 ✕/点遮罩关闭的情形）。
	for p: Control in [_quest_panel, _hero_dex, _attr_panel, _ach_panel,
			_backpack, _diplomacy, _settings, _self_rule]:
		if p.has_signal("menu_return_requested"):
			p.menu_return_requested.connect(_reopen_menu_wheel)

	# 城内对话界面（与大地图同一 DialogueUI 脚本，代码构建）
	_dialogue = DialogueUI.create()
	_dialogue.name = "DialogueUI"
	# 城内顶栏高 190（城名 + 城况 + 资源条，用户反馈原 150 太窄），对话卡下移避让 ——
	# 旧版沿用大地图的 60，对话卡直接盖住顶栏（用户反馈「人物语言挡住顶栏内容」）。
	_dialogue.top_margin = 204.0
	_dialogue.dialogue_finished.connect(_on_dialogue_finished)
	add_child(_dialogue)

	# 城内 NPC 背包交易面板（代码创建）
	_trade = NpcTradePanel.new()
	_trade.name = "NpcTradePanel"
	add_child(_trade)

	# 城内贴脸交互菜单（与大地图同款 InteractionMenu）：
	# 圆形交互钮点按 → 在 NPC 头顶弹「交谈 / 交易」选项（数据驱动 items）。
	# 【2026-09-24 用户拍板】删掉原「交易」独立按钮——城内交互统一走圆圈弹菜单。
	_menu = InteractionMenu.new()
	_menu.name = "InteractionMenu"
	add_child(_menu)
	# 【2026-09-28 小遗留修复】城内世界在 SubViewport、菜单投影依赖根 Control 设计坐标系，
	# 不能像大地图那样挂 CanvasLayer（否则横向错位）。此处按设计空间裁切：菜单依视口反算
	# 「可见设计带」夹取，aspect=expand 宽屏下不再被裁底（大地图走 $UI CanvasLayer 不需要）。
	_menu.set_design_space_clamp(true)
	_menu.action_chosen.connect(_on_menu_action)

	# toast 由全局 ToastLayer autoload 统一消费（B2/B4/B11 一揽子修复），本地不再重复连接
	# 对话 open_shop 动作 → 打开 NPC 随身货单（R2-05a，城内 NPC 对话通用）
	# 【H1】一律方法绑定连接（捕获 self 的 lambda 连到 autoload 后不会随场景释放断连，
	# 每次进出城叠一层僵尸 handler 对已释放实例刷报错）；方法连接随实例释放自动断开
	EventBus.npc_shop_requested.connect(_on_npc_shop_requested)

	# 两段式投靠第二步：带着投靠意向进城即触发面见主公（旧版挂在 open_shop
	# 信号上——不找商人开货单就永远不弹，投靠闭环实际不可达）
	_check_join_pledge.call_deferred()
	EventBus.gold_changed.connect(_refresh_header)
	EventBus.food_changed.connect(_refresh_header)
	EventBus.wood_changed.connect(_refresh_header)
	EventBus.iron_changed.connect(_refresh_header)
	EventBus.troop_changed.connect(_refresh_header)
	EventBus.inventory_changed.connect(_on_inventory_changed)
	EventBus.party_changed.connect(_on_party_changed)

	# 【第五十二轮】UI 面板登记表在此一次性填好，供 _any_ui_open() 每帧零分配查询。
	# 注意 _dialogue / _trade 都在本 _ready 里 create() 出来（非 @onready），
	# 必须在它们创建之后登记，否则会漏判「对话开着但人还在跑」。
	# 判定集合与优化前**逐项一致**（含 _menu_wheel、不含 _menu）：本次只做性能改造，
	# 不顺手改「菜单弹出时能否走动」这类玩法语义——那是另一个需要单独确认的决策。
	_ui_panels = [
		_quest_panel, _menu_wheel, _hero_dex, _panel, _attr_panel,
		_ach_panel, _diplomacy, _self_rule, _settings, _dialogue, _trade,
		_backpack, _economy,
	]


## 【H1】对话 open_shop 动作落点（方法绑定，替代捕获 self 的 lambda）
func _on_npc_shop_requested(npc: Dictionary) -> void:
	_trade.open(npc)


## 【两段式投靠】若玩家已表明投靠意向且本城正是该势力都城，
## 弹出「面见主公」弹窗：献上投名状（金钱 500）即正式加入，也可暂缓/放弃。
func _check_join_pledge() -> void:
	var fid := GameState.join_intent
	if fid <= 0 or GameState.affiliation != 0:
		return
	var cap_id := FactionService.capital_city_id(fid)
	if _city_id != cap_id:
		return
	var lord_name := "主公"
	var lord_id := FactionService.faction_lord_id(fid)
	if lord_id > 0:
		var lord := DataManager.get_hero6(lord_id)
		if not lord.is_empty():
			lord_name = str(lord.get("name", lord_name))

	var dim := ColorRect.new()
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.color = UITheme.SCRIM
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(860, 0)
	card.add_theme_stylebox_override("panel", UITheme.card_style())
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dim.add_child(center)
	center.add_child(card)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 16)
	card.add_child(box)
	box.add_child(UITheme.label("面见 %s 主公 · %s" % [FactionService._faction_name(fid), lord_name],
		UITheme.FS_TITLE, UITheme.GOLD))
	var desc := UITheme.label(
		"你向「%s」表明了投靠之意，一路赶来都城求见。%s端坐堂上打量你良久：\n\n「乱世用人之际，某正缺你这样的人物。只是空口无凭——献上投名状（金钱 %d），此后同荣辱、共进退，你可想好了？」"
		% [FactionService._faction_name(fid), lord_name, FactionService.JOIN_PLEDGE_GOLD],
		UITheme.FS_BODY, UITheme.TEXT)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(desc)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 18)
	btn_row.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(btn_row)

	var ok := UITheme.button("献上投名状（金钱 %d）" % FactionService.JOIN_PLEDGE_GOLD,
		UITheme.FS_BODY, Vector2(360, 84))
	ok.pressed.connect(func():
		var r := FactionService.pledge_at_capital(_city)
		EventBus.toast.emit(str(r.get("msg", "")))
		dim.queue_free()
		if bool(r.get("ok", false)):
			AudioManager.sfx_confirm())
	btn_row.add_child(ok)

	var later := UITheme.button("暂不加入", UITheme.FS_BODY, Vector2(200, 84))
	later.pressed.connect(func():
		dim.queue_free())
	btn_row.add_child(later)

	var giveup := UITheme.button("放弃投靠", UITheme.FS_NOTE, Vector2(160, UITheme.TOUCH_H))   ## 【触控铁律】60→84
	giveup.pressed.connect(func():
		FactionService.cancel_join_intent()
		EventBus.toast.emit("你打消了投靠的念头。")
		dim.queue_free())
	box.add_child(giveup)


func _unhandled_input(event: InputEvent) -> void:
	# 安卓返回键 / Esc：优先关闭面板
	if event.is_action_pressed("ui_cancel"):
		if _menu_wheel != null and _menu_wheel.is_open():
			_menu_wheel.close()
			get_viewport().set_input_as_handled()
		elif _menu != null and _menu.is_open():
			_menu.hide_menu()
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
		elif _backpack != null and _backpack.is_open():
			_backpack.close_panel()
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
	{ "key": "hall",     "name": "官  府", "desc": "内政建设\n政务民情", "field": "hall" },
]


func _build_place_buttons() -> void:
	for child in _place_grid.get_children():
		child.queue_free()
	_place_buttons.clear()

	var buildings: Array = _city.get("buildings", [])
	var is_city := str(_city.get("type", "city")) == "city"

	for p in PLACES:
		# 开放判定：城池才开放全部；村寨/关隘按 buildings 字段
		var field := str(p["field"])
		var open := true
		if not is_city:
			open = (field in buildings) or (field == "hall")
		else:
			# 城池：官府常开，其余看 buildings 字段（缺省视为开放）
			if field != "hall" and not buildings.is_empty():
				open = field in buildings

		# 【未开放直接不显示】旧版显示置灰按钮 +「（未开放）」角标，
		# 用户拍板：没开放的功能点没有存在意义，直接从入口里删掉。
		if not open:
			continue

		var btn := Button.new()
		btn.custom_minimum_size = Vector2(346, 200)
		btn.add_theme_font_size_override("font_size", 34)
		btn.text = "%s\n%s" % [str(p["name"]), str(p["desc"])]
		var key := str(p["key"])
		btn.pressed.connect(func(): _open_panel(key))
		_place_grid.add_child(btn)
		_place_buttons[key] = btn


## ---------- 城内行走场景 ----------

## 建筑地基：已停用 —— 旧地基在建筑门前画出一块空棕色平台，观感像「贴图前留空」。
## 建筑贴图本身已含门槛与台阶，直接落地即可。
func _building_pads() -> Array:
	return []


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

	# 旧节点全清（重新进城时用）。
	# 【第六十八轮】ActorLayer 也一并清掉并在第 7 步重建 —— 否则会出现
	# 「新建的 ActorLayer 与旧层同名，Godot 自动改名成 @ActorLayer@2」的
	# 静默分裂：探针按名字取层取到空的那个，所有实体都判定为「不在层内」。
	# queue_free 是延迟的，故同时把句柄置空，避免半途复用已释放节点。
	_actor_layer = null
	for child in _interior.get_children():
		child.queue_free()

	# 1. 地面（城墙 / 道路 / 建筑地基）
	var ground := CityGround.new()
	ground.name = "Ground"
	ground.ground_size = INTERIOR_SIZE
	ground.pads = _building_pads()
	_interior.add_child(ground)

	# 2. 建筑实体（门口装饰小人已删：不可交互的摆设只会让玩家误以为能对话）
	# 【未开放建筑直接删除】旧版给未开放建筑画一栋灰房子 +「未开放」字样，
	# 用户拍板：不能进的交互地没有存在意义，直接从城里消失（连同阻挡矩形，
	# 空出的地皮可以行走，城内布局随 buildings 字段自然疏密）。
	var blocks: Array = []
	for spot in BUILDING_SPOTS:
		var key: String = str(spot["key"])
		if not _building_open(key):
			continue
		var bpos: Vector2 = spot["pos"]
		var b := CityInteriorArt.build(key, str(spot["name"]), true)
		b.position = bpos
		_interior.add_child(b)
		# 【建筑阻挡】主体矩形（贴图宽 400 × 高约 230，取主体下半段）——
		# 主角不能从建筑贴图上直接走过去；门口 y=bpos 附近留一格进出空间
		blocks.append(Rect2(bpos + Vector2(-185, -185), Vector2(370, 185)))

	# 3. 城门出城点：保留位置标记（一根描金路标），不再摆「守卒」假人

	# 4. 玩家（自建，不依赖大地图场景；河流无阻挡，室内自由行走）
	_player = PlayerController.new()
	_player.name = "Player"
	_player.map_size = INTERIOR_SIZE
	_player.auto_zoom = false
	_player.block_rects = blocks
	_player.position = Vector2(1200.0, INTERIOR_SIZE.y - 330.0)
	# 【第六十八轮·移除】原为 z_index = 20（硬压在所有建筑之上）——
	# 那正是「像贴图游戏」的根源：主角从任何方向走近建筑都永远画在屋顶前面，
	# 视觉上是「贴在墙上」而不是「走在墙后」。现由 y_sort 按 y 坐标决定前后。

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
	# 【2026-09-24 用户反馈修复】城内地图小、移动快，平滑跟随（speed 6）滞后明显，
	# 主角视觉上「走出当前视角外」。改为硬跟随：相机永远锁定主角屏中，绝不出屏。
	cam.position_smoothing_enabled = false
	_player.add_child(cam)

	_interior.add_child(_player)
	cam.zoom = Vector2.ONE * 1.05
	cam.limit_left = 0
	cam.limit_top = 0
	cam.limit_right = int(INTERIOR_SIZE.x)
	cam.limit_bottom = int(INTERIOR_SIZE.y)
	cam.make_current()
	# 交互菜单的世界→屏幕换算需要城内相机（菜单贴着 NPC 弹出）
	if _menu != null:
		_menu.set_camera(cam)

	# 5. 本城 NPC（在城中活动，随机游荡）
	_spawn_city_npcs()

	# 6. 城内氛围（扬尘 + 灯火粒子 + 相机微动），见 _build_city_atmos()
	_city_cam = cam
	_build_city_atmos()

	# 7. 【第六十八轮·城内深度排序】必须放在**最后**：
	#    上面 2/4/5 步已把建筑、玩家、NPC 全部挂进 _interior，
	#    此时建层才能把它们一网打尽。放在 _spawn_city_npcs() 之前的话，
	#    NPC 会全部留在层外 —— 而这种失败**不报任何错**，只是「NPC 不参与排序」。
	_setup_depth_sort()


## 【第六十八轮·城内深度排序】让城内也按 y 坐标决定遮挡。
##
## 【改的是什么】此前城内所有东西都挂在 _interior 下靠**添加顺序**决定前后，
## 玩家还被硬设 z_index=20 压在一切之上。结果是主角从北侧走近任何建筑时
## 永远画在屋顶前面 —— 视觉上像**贴在城墙上**而不是**走在城墙后面**。
## 现在建筑 / 玩家 / 城内 NPC 全部进入 ActorLayer（y_sort_enabled=true），
## 「谁在谁前面」由 y 坐标决定，走位与遮挡的关系第一次成立。
##
## 【为什么必须最后一个建】见调用点注释：建筑/玩家/NPC 都必须在层建好之后才存在。
##
## 【层级用显式 z_index 而非 add_child 顺序】y_sort 之后，实体整体成为一个
## 排序单元，夜色压暗层与氛围粒子**再也无法用 move_child 插进「建筑之上、
## 玩家之下」**——它们只可能整体在层之上或之下。故改为显式 z 分层：
##   Ground(z=-100) < ActorLayer(z=0) < Atmos(80) < NightVeil(90) < WeatherFx(100)
## 顺带说明一处**刻意的产品取舍**：原注释写「夜色只压建筑与地面，不压玩家/NPC」，
## 那是 z_index 分层的遗留执念 —— 真实夜晚里环境光笼罩一切，「角色头顶亮着、
## 脚下发暗」本身就是一种贴图感。夜 veil 的 alpha 只有 0.14（再乘夜色因子），
## 压全屏在观感上几乎无损，换来的是正确的整体氛围。
func _setup_depth_sort() -> void:
	# 地面压底：全城一张底图，不参与 y_sort（否则每帧对全表排序纯属浪费）
	var ground := _interior.get_node_or_null(NodePath("Ground")) as Node2D
	DepthSort.pin_terrain(ground, -100)

	# 建筑 + 玩家 + 城内 NPC 都直接挂在 _interior 下（没有中间容器），
	# 所以逐个点名搬：建筑名统一是 "B_<key>"，NPC 名统一是 "CityNPC_<id>"。
	var to_move: Array[Node] = []
	for child in _interior.get_children():
		if child == ground or child == _atmos or child == _night_veil:
			continue
		if child == _weather_fx or child == _player:
			continue
		var nm := str(child.name)
		if nm.begins_with("B_") or nm.begins_with("CityNPC_"):
			to_move.append(child)
	# 玩家走**实体**路径（搬本体）—— 它同时也是容器（挂着 Visual/Camera2D），
	# 若按容器处理搬子节点，玩家本人就留在层外，永远压不住任何东西。
	if _player != null:
		to_move.append(_player)

	if to_move.is_empty():
		push_warning("[CityScene] 无实体可搬入深度排序层，跳过建层")
		return

	var layer := Node2D.new()
	layer.name = "ActorLayer"
	layer.y_sort_enabled = true
	_interior.add_child(layer)
	_interior.move_child(layer, 0)   # 排首位：避免被同 z 兄弟按插入顺序压住
	for n in to_move:
		# 【地雷·同大地图】子节点未必是 CanvasItem（Player 下的 Visual 是 Node2D，
		#  但 WalkAnim 是纯 Node），对非 CanvasItem 写 z_index 会抛错并**中断整个
		#  循环** —— 后续实体全没搬进去，而错误只在运行时日志里，编译期完全无感。
		if n is CanvasItem:
			(n as CanvasItem).z_index = 0
		_interior.remove_child(n)
		layer.add_child(n)
	_actor_layer = layer

	# 【第六十八轮第四层·接地投影】给玩家与城内 NPC 挂上落在地面的影子。
	# 城内同样有深度排序带来的遮挡，若角色脚下无影 → 观感是「贴图漂在街上」。
	# 影子挂在 _interior 下、z 压在地面之上实体层之下，
	# **不进 ActorLayer** —— 进了会被 y_sort 按 y 排到别的实体后面去。
	_setup_ground_shadows()


func _setup_ground_shadows() -> void:
	# 影子挂在 **_interior（地面容器）** 下，绝不挂 actor.get_parent()：
	# 接入 y_sort 后实体的父节点是 ActorLayer，挂过去会被卷进 y_sort ——
	# 走远后影子跑到别的实体后面，且 z=-50 触犯「层内 z 必须为 0」。
	if _player != null:
		GroundShadow.attach(_player, UITheme.WORLD_UNIT_HEIGHT, _interior)
	for entry in _city_npcs:
		var node = entry.get("node") as Node2D
		if node != null:
			GroundShadow.attach(node, UITheme.WORLD_UNIT_HEIGHT, _interior)


## 城内氛围：地面扬尘 + 建筑门口灯火，纯 CPU 粒子（GPUParticles 在 Compatibility 下静默失效）。
## 插在背景层（Ground / 建筑）与玩家之间，既有纵深又不会盖住主角与 NPC。
## 零生图、零新美术资源——用粒子把"空旷的城内"做得有空气感。
func _build_city_atmos() -> void:
	_atmos = Node2D.new()
	_atmos.name = "Atmos"
	_lamps.clear()          ## 重进城时旧灯火句柄必须清空，否则对已释放节点写 color
	# 【第六十八轮】层级改用**显式 z_index**。
	# 原实现在这里 `_interior.move_child(_atmos, _player.get_index())` —— 把粒子层
	# 插到玩家之前，靠「建筑 → 粒子 → 玩家 → NPC」的**树序**制造纵深。
	# 接入 y_sort 后实体整体成为一个排序单元，这行插序**必然失效**：
	# 玩家已被搬进 ActorLayer，`_player.get_index()` 返回的是**层内索引**，
	# 拿它去 move_child 会把粒子层塞到完全无关的位置，且不报任何错。
	# 粒子 alpha 本就很低（扬尘 0.16），统一放在实体之上不再遮人。
	_atmos.z_index = CITY_ATMOS_Z
	_interior.add_child(_atmos)

	# 1. 地面扬尘：低空暖色微尘，缓慢上浮，制造"城内空气在流动"的纵深
	var dust := CPUParticles2D.new()
	dust.name = "GroundDust"
	dust.emitting = true
	dust.amount = CITY_ATMOS_DUST_AMOUNT
	dust.lifetime = 3.2
	dust.direction = Vector2(0.0, -1.0)
	dust.spread = 36.0
	dust.initial_velocity_min = 4.0
	dust.initial_velocity_max = 16.0
	dust.gravity = Vector2(0.0, -2.0)
	dust.scale_amount_min = 0.30
	dust.scale_amount_max = 0.90
	dust.color = Color(0.82, 0.74, 0.56, CITY_ATMOS_DUST_ALPHA)
	dust.position = Vector2(INTERIOR_SIZE.x * 0.5, INTERIOR_SIZE.y - 140.0)
	dust.emission_shape = 2   # CPUParticles2D.EMISSION_SHAPE_BOX
	dust.emission_rect_extents = Vector2(INTERIOR_SIZE.x * 0.5, 70.0)
	_atmos.add_child(dust)

	# 2. 建筑门口灯火：暖橙微光缓慢升起、左右轻摆，像灯笼与灶火（仅已开放建筑）
	for spot in BUILDING_SPOTS:
		if not _building_open(str(spot["key"])):
			continue
		var lamp := CPUParticles2D.new()
		lamp.name = "Lamp_%s" % str(spot["key"])
		lamp.emitting = true
		lamp.amount = CITY_ATMOS_LAMP_AMOUNT
		lamp.lifetime = 2.4
		lamp.direction = Vector2(0.0, -1.0)
		lamp.spread = 20.0
		lamp.initial_velocity_min = 3.0
		lamp.initial_velocity_max = 10.0
		lamp.gravity = Vector2(0.0, -3.0)
		lamp.scale_amount_min = 0.50
		lamp.scale_amount_max = 1.40
		lamp.color = Color(1.0, 0.74, 0.36, CITY_ATMOS_LAMP_ALPHA)
		lamp.position = Vector2(spot["pos"].x, spot["pos"].y - 150.0)
		lamp.emission_shape = 2   # CPUParticles2D.EMISSION_SHAPE_BOX
		lamp.emission_rect_extents = Vector2(55.0, 26.0)
		_atmos.add_child(lamp)
		_lamps.append(lamp)

	# 3. 【四十轮】夜色压暗 + 灯火夜亮 + 跨场景雨雪：见 _build_city_night_weather()
	_build_city_night_weather()


## 【四十轮·跨场景天气 / 灯火夜亮】（【第六十八轮】层级改显式 z_index，见 CITY_*_Z）
##   · 夜色压暗：冷蓝薄雾铺满城内世界，【现压在全部实体之上】——
##     原为「只压建筑与地面」，接入 y_sort 后实体成为整体排序单元，无法再夹层。
##   · 灯火夜亮：门口那批暖橙粒子按「进入城里的时辰」（GameState.day_fraction，
##     进城时时钟已暂停，故冻结在入城那一刻）在 0.10 ↔ 0.62 之间连续变化。
##   · 雨雪：与大地图同一场雨/雪（事实在 GameState），跟着主角视野走。
func _build_city_night_weather() -> void:
	# 夜色压暗层（【第六十八轮】改显式 z_index：见 _setup_depth_sort() 的层级说明。
	# 原实现 `_interior.move_child(_night_veil, _atmos.get_index())` 依赖树序，
	# y_sort 接入后实体被搬进子层，_atmos.get_index() 仍有效但语义已变，
	# 统一交给 z_index 表达层级，不再混用两套机制）
	_night_veil = ColorRect.new()
	_night_veil.name = "NightVeil"
	_night_veil.color = CITY_NIGHT_VEIL_COLOR
	_night_veil.size = INTERIOR_SIZE
	_night_veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_night_veil.z_index = CITY_VEIL_Z
	_interior.add_child(_night_veil)

	# 雨雪层（headless 下恒 null，见 WeatherFx 顶部坑注）
	var zoom := 1.0
	if _city_cam != null:
		zoom = maxf(0.05, _city_cam.zoom.x)
	var screen := _interior.get_viewport_rect().size / zoom
	_weather_screen = screen
	_weather_fx = WeatherFx.build_precip(WeatherFx.current(), screen, 0.75)
	if _weather_fx != null:
		# 【第六十八轮】雨雪在最前（雨要落在所有东西前面），显式 z 不依赖树序
		_weather_fx.z_index = CITY_WEATHER_Z
		_interior.add_child(_weather_fx)
	if WeatherFx.current() == WeatherFx.RAIN:
		var a := AudioStreamPlayer.new()
		a.name = "WeatherRain"
		a.stream = WeatherFx.make_rain_stream()
		a.bus = "BGM"
		a.volume_db = WeatherFx.RAIN_DB_CITY
		add_child(a)
		a.play()
		_weather_audio = a
	_update_city_night()


## 每帧：夜色与灯火（时辰是入城那一刻的冻结值，城内不再流动）
func _update_city_night() -> void:
	var nf := WeatherFx.night_factor_now()
	if _night_veil != null and is_instance_valid(_night_veil):
		_night_veil.color = Color(
			CITY_NIGHT_VEIL_COLOR.r, CITY_NIGHT_VEIL_COLOR.g, CITY_NIGHT_VEIL_COLOR.b,
			CITY_NIGHT_VEIL_ALPHA * nf)
		_night_veil.visible = nf >= 0.02
	if _lamps.is_empty():
		return
	var a := lerpf(CITY_ATMOS_LAMP_ALPHA_DAY, CITY_ATMOS_LAMP_ALPHA_NIGHT, nf)
	for l in _lamps:
		if not is_instance_valid(l):
			continue
		l.color = Color(1.0, 0.74, 0.36, a)
		l.visible = a >= 0.02


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
		# 【第十四轮 城内氛围·密度】空城补位：除每座开放建筑 1 个功能 NPC 外，
		# 再补若干闲散居民（不可交易，只用 NPC_SMALLTALK 搭话），让广场「有人气」。
		for r in CITY_RESIDENT_COUNT:
			var rtype: String = CITY_RESIDENT_TYPES[r % CITY_RESIDENT_TYPES.size()]
			_spawn_one_city_npc(_npc_resident(rtype, idx), idx)
			idx += 1


## 生成一个城内游荡 NPC 节点并登记进 _city_npcs
func _spawn_one_city_npc(npc: Dictionary, idx: int) -> void:
	var node := CityNpc.new()
	node.name = "CityNPC_" + str(npc.get("id", idx))
	node.wander_radius = 200.0
	node.position = CITY_NPC_HOME_SPOTS[idx % CITY_NPC_HOME_SPOTS.size()]
	node.set_meta("npc", npc)
	# 形象：优先立绘贴图（assets/sprites/npcs/<id>.png），再按身份回退
	# civ_<npc_type>.png（闲散居民无专属图），最后才几何兜底
	var art := CityInteriorArt.build_npc(
		str(npc.get("name", "居民")), str(npc.get("id", "")),
		str(npc.get("npc_type", "")))
	node.add_child(art)
	# 【行走动画】游荡的 NPC 也是单张立绘，不踏步就是"贴图在地上滑"。
	# 只驱动 "Body"（人物本体），投影与名牌不受影响。
	var wa := WalkAnim.attach(node, art.get_node_or_null("Body") as Node2D)
	if wa != null:
		# 【第六十六轮】报身高，让步幅按身高取（城内 NPC 身高见 CityInteriorArt.NPC_WORLD_HEIGHT）
		wa.body_height = CityInteriorArt.NPC_WORLD_HEIGHT
		wa.bob_amp = 2.2        ## NPC 世界身高 56px，幅度按身高缩放
		wa.lean_deg = 4.0
		wa.dir_lean_deg = 2.5
		wa.squash = 0.035
		# 【双腿/影子】几何小人装真腿（前摆抬脚/后蹬落地）；单图立绘动不了
		# 画在图里的腿，改接影子联动——抬脚影子缩小、落地恢复，同样有落地感
		if not bool(art.get_meta("has_portrait", false)):
			wa.leg_len = 9.0
			wa.leg_swing_deg = 24.0
			wa.leg_color = Color(0.20, 0.17, 0.14)
			wa.add_legs(art.get_node_or_null("Body") as Node2D, 22.0, 6.0)
		else:
			wa.shadow_node = art.get_node_or_null("Shadow") as Node2D
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


## 【第十四轮 城内氛围·密度】构造一个「闲散居民」（不可交易，只用 NPC_SMALLTALK 搭话）。
## npc_type 取 resident/elder/youth/hero 轮流 —— DialogueUI 按 npc_type 取 NPC_SMALLTALK 搭话，
## InteractionMenu 只给 merchant/blacksmith 出「交易」，所以闲散居民天然「只交谈、不交易」。
func _npc_resident(rtype: String, seq: int) -> Dictionary:
	return {
		"id": "gen_resident_%d" % seq,
		"name": str(CITY_RESIDENT_TITLES.get(rtype, "城中居民")),
		"npc_type": rtype,
		"city_id": _city_id,
		"role_id": -1,
		"tags": ["resident"],
		"title": str(CITY_RESIDENT_TITLES.get(rtype, "城中居民")),
	}


## 【R1-22】城内面板开合表驱动判定（对齐 world_map._any_ui_open）：
## 新增面板只需入表，不再复制粘贴 if 段，防漏判冻结
func _any_ui_open() -> bool:
	# 【第五十二轮】改用 _ui_panels 成员表 + 去反射，理由同 world_map：
	# 本函数在 _process 里每帧调 2~3 次，旧写法每帧新建 12 元素数组，
	# 且对每个面板做 has_method 反射（全工程均已实现 is_open()，恒为真）。
	for p in _ui_panels:
		if p != null and p.is_open():
			return true
	return false


## 参与「UI 是否打开」判定的面板登记表（_ready 时填好，勿每帧重建）
var _ui_panels: Array = []


## 运行期动态创建的面板补登记（create() 路径的对话/面板不在 @onready 里）
func _register_panel(p: Node) -> void:
	if p != null and not _ui_panels.has(p):
		_ui_panels.append(p)


## 每帧：喂摇杆输入 + 判定「附近建筑 / 已到城门」
func _process(_delta: float) -> void:
	# 【四十轮】灯火夜亮（时辰冻结在入城那一刻）+ 雨雪层跟着主角视野走
	_update_city_night()
	# 【第六十八轮第四层】接地投影跟随。放在最前面（含 `_player == null`
	# 的提前 return 之前）：城内 NPC 是**持续游荡**的，影子若不每帧跟上，
	# 就会与本体分离留在原地 —— 这是「投影反而暴露浮空」的另一种形态。
	GroundShadow.follow(_player)
	for entry in _city_npcs:
		GroundShadow.follow(entry.get("node") as Node2D)
	if _player != null and _weather_fx != null and is_instance_valid(_weather_fx):
		_weather_fx.position = _player.position - _weather_screen * 0.5
	if _player == null:
		return
	# 【城内氛围】相机待机微动：叠加在硬跟随之上，世界更"活"。
	# cam.offset 是相机自身偏移，不影响"相机锁定主角"的跟随逻辑，故硬跟随不被破坏。
	if _city_cam != null:
		_city_cam_t += _delta
		_city_cam.offset = Vector2(
			sin(_city_cam_t * CITY_CAM_SWAY_FREQ_X) * CITY_CAM_SWAY_AMP_X,
			cos(_city_cam_t * CITY_CAM_SWAY_FREQ_Y) * CITY_CAM_SWAY_AMP_Y)
	# 【2026-09-28 用户反馈】轮盘打开的面板关闭后 → 回到轮盘菜单（与大地图一致）。
	# 放在 _any_ui_open() 提前 return 之前。
	# 【误弹修复】仅在「面板已关 且 当前没有任何界面打开」时才回菜单：
	# hero_dex 选人时会先关列表再开详情（面板→面板切换），此时不能弹菜单。
	if _wheel_return_panel != null:
		if not is_instance_valid(_wheel_return_panel) or not _wheel_return_panel.visible:
			if not _panel_root.visible and not _any_ui_open():
				_wheel_return_panel = null
				_menu_wheel.open()
	# 任意面板打开时冻结移动，避免误触移动（主容器直接查 visible，其余走 is_open 表）
	if _panel_root.visible or _any_ui_open():
		_player.set_move_input(Vector2.ZERO)
		_hide_action_button()
		return
	_player.set_move_input(_walk_joy.output)
	_update_nearby()


## 【重构·与大地图统一】右下角圆形「城池交互」按钮：
## 常驻显示、靠近建筑/人物/城门时高亮并提示动作，点按才执行对应交互。
## 摇杆所在的 UI 容器。交互按钮必须挂在它下面：与摇杆同一坐标系，
## 才不会在宽屏机型上错位、越出可视区。取不到时退回自身（仍是设计空间）。
func _walk_ui_parent() -> Control:
	if _walk_joy != null and _walk_joy.get_parent() is Control:
		return _walk_joy.get_parent() as Control
	return self


func _setup_city_action_button() -> void:
	# 交互按钮挂到摇杆的同一个父容器（$WalkUI），与摇杆同一坐标系；
	# 具体坐标一律交给 _layout_city_action_btn()（屏幕右缘 + 摇杆中心），
	# 这里的初值只是占位，别在这儿调位置。
	var ui_layer := _walk_ui_parent()
	var btn := Button.new()
	btn.name = "CityActionButton"
	btn.mouse_filter = Control.MOUSE_FILTER_STOP
	btn.offset_left = 1700.0
	btn.offset_right = 1840.0
	btn.offset_top = 750.0
	btn.offset_bottom = 890.0
	btn.custom_minimum_size = Vector2(140.0, 140.0)
	btn.text = ""
	btn.visible = false
	var tint := Color(0.78, 0.64, 0.36, 1.0)
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.09, 0.11, 0.15, 0.28)   # 空心：只留淡墨底衬
	normal.border_color = Color(0.96, 0.92, 0.80, 0.60)  # 暖白描边（同摇杆底座观感）
	normal.set_border_width_all(5)
	normal.set_corner_radius_all(70)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.09, 0.11, 0.15, 0.50)
	hover.border_color = Color(1.0, 0.96, 0.85, 0.85)
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(tint.r * 0.42, tint.g * 0.38, tint.b * 0.26, 0.72)
	pressed.border_color = Color(1.0, 0.92, 0.72, 1.0)
	btn.add_theme_stylebox_override("normal", normal)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("pressed", pressed)
	btn.add_theme_font_size_override("font_size", 30)
	btn.pressed.connect(_on_city_action)
	ui_layer.add_child(btn)
	_city_action_btn = btn

	# 提示标签（按钮正上方，与按钮同坐标系，右端对齐）
	var hint := Label.new()
	hint.name = "ActionHint"
	hint.offset_left = 1520.0
	hint.offset_right = 1840.0
	hint.offset_top = 690.0
	hint.offset_bottom = 740.0
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 24)
	hint.add_theme_color_override("font_color", Color(0.96, 0.90, 0.72, 1.0))
	hint.visible = false
	ui_layer.add_child(hint)
	_action_hint = hint
	_layout_city_action_btn()
	# 尺寸/朝向变化（分屏、旋屏、窗口拉伸）后按新的可见区重排一次
	var vp := get_viewport()
	if vp != null:
		vp.size_changed.connect(_layout_city_action_btn)


## 交互按钮定位：横向贴**屏幕真实右缘**，纵向对齐**摇杆实际中心**。
## 【2026-09-29 用户反馈】「交互按钮还是超出屏幕之外 / 跟摇杆对不齐」的真因：
##   ① 右缘写死 1920 —— 但 expand 拉伸下屏幕可能是 2400 宽，右边多出的空间
##      全在 1920 之外，按钮于是孤零零浮在屏幕中间（看着就像「跑到外面」）；
##   ② 早先一版用「居中裁切」反算可见区（UITheme.visible_rect），把区域算小，
##      宽屏推到中间、竖屏还顶到摇杆上方 —— 已改为 screen_rect。
## 现在：x = 屏幕宽 - 边距 - 尺寸（边距与摇杆左边距 54 镜像）；
##       y = 摇杆矩形中心 ± 尺寸/2，两钮严格同一水平线。
func _layout_city_action_btn() -> void:
	if _city_action_btn == null:
		return
	var sz := 140.0
	var margin := 54.0   ## 与摇杆左边距 54 镜像，左右对称
	var screen := UITheme.screen_rect(self)
	# 纵向基准：读摇杆**实际**矩形取中心，不写死 820（摇杆挪位也会自动跟随）
	var cy := screen.size.y - 260.0
	if _walk_joy != null and _walk_joy is Control:
		var jr := (_walk_joy as Control).get_rect()
		cy = jr.position.y + jr.size.y * 0.5
	var x := screen.size.x - margin - sz
	_city_action_btn.offset_left = x
	_city_action_btn.offset_right = x + sz
	_city_action_btn.offset_top = cy - sz * 0.5
	_city_action_btn.offset_bottom = cy + sz * 0.5
	if _action_hint != null:
		# 【第六十六轮·对齐修复】原写法是「提示右端对齐按钮右缘」：
		#   提示宽 320、右端 = x+sz → 提示中心 = x+sz-160
		#   按钮中心 = x+sz/2 = x+70（sz=140）
		#   两者相差 90px，于是「可交谈」几个字明显偏在按钮左边，看着没对上。
		# 改为以**按钮中心**为中心左右各 160，提示与按钮同轴。
		var hint_w := 320.0
		var btn_cx := x + sz * 0.5
		_action_hint.offset_right = btn_cx + hint_w * 0.5
		_action_hint.offset_left = btn_cx - hint_w * 0.5
		_action_hint.offset_bottom = cy - sz * 0.5 - 12.0
		_action_hint.offset_top = cy - sz * 0.5 - 62.0


## 顶栏右上角圆形菜单按钮（与大地图 ActionButtons 同款语言）
func _setup_menu_button() -> void:
	var btn := Button.new()
	btn.name = "MenuButton"
	btn.text = "≡"
	btn.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	# 【R3-04】菜单钮 60×60 → 84×84（触控 ≥84px 铁律），锚定右上、向左下生长
	btn.offset_left = -140.0
	btn.offset_right = -56.0
	btn.offset_top = 15.0
	btn.offset_bottom = 99.0
	btn.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	btn.grow_vertical = Control.GROW_DIRECTION_BEGIN
	btn.custom_minimum_size = Vector2(84.0, 84.0)
	var tint := Color(0.78, 0.64, 0.36, 1.0)
	var ink := Color(0.09, 0.11, 0.15, 0.92)
	var normal := StyleBoxFlat.new()
	normal.bg_color = ink
	normal.border_color = Color(tint.r, tint.g, tint.b, 0.75)
	normal.set_border_width_all(2)
	normal.set_corner_radius_all(42)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(ink.r * 1.9, ink.g * 1.9, ink.b * 1.9, 0.96)
	hover.border_color = tint
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(tint.r * 0.42, tint.g * 0.38, tint.b * 0.26, 1.0)
	pressed.border_color = Color(1.0, 0.92, 0.72, 1.0)
	btn.add_theme_stylebox_override("normal", normal)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("pressed", pressed)
	btn.add_theme_font_size_override("font_size", 34)
	btn.add_theme_color_override("font_color", Color(0.96, 0.90, 0.72, 1.0))
	btn.pressed.connect(_open_menu)
	add_child(btn)
	_menu_btn = btn


## 设置交互按钮上方的动作提示
func _set_action_hint(text: String) -> void:
	if _action_hint == null:
		return
	if text.is_empty():
		_action_hint.visible = false
	else:
		_action_hint.text = text
		_action_hint.visible = true


## 冻结移动时统一隐藏交互相关按钮与菜单（避免叠加在模态面板之上）
func _hide_action_button() -> void:
	if _city_action_btn != null:
		_city_action_btn.visible = false
	if _menu != null:
		_menu.hide_menu()
	_set_action_hint("")


## 点击右下角圆形交互按钮：按当前目标执行对应交互
func _on_city_action() -> void:
	if _interact_on_cooldown():
		return
	AudioManager.sfx_click()
	if _action_mode == "gate":
		_on_leave()
		return
	if _action_mode == "npc":
		_open_npc_menu()
		return
	if _action_mode.begins_with("building:"):
		_open_panel(_action_mode.get_slice(":", 1))
		return
	show_toast("附近没有可交互的目标，走近建筑或人物再试")


func _update_nearby() -> void:
	var p := _player.position

	# 城门（走到下方即出现「出城」）
	var at_gate := p.y >= GATE_ZONE_Y
	_at_gate = at_gate

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
	var npc_pos := Vector2.ZERO
	var npc_best: float = INTERACT_RADIUS
	for entry in _city_npcs:
		var node: Node2D = entry.get("node")
		var d := p.distance_to(node.position)
		if d < npc_best:
			npc_best = d
			near_npc = entry.get("data")
			npc_label = str(near_npc.get("name", ""))
			npc_pos = node.position

	# 决定圆形交互按钮的行为与提示（与大地图一致：靠近才点亮，点按才执行）
	if at_gate:
		_action_mode = "gate"
		_set_action_hint("出  城")
	elif not near_npc.is_empty() and npc_best <= best:
		_near_npc = near_npc
		_near_npc_pos = npc_pos
		_near_key = ""
		_action_mode = "npc"
		_set_action_hint("与 %s 交谈" % npc_label)
	else:
		_near_npc = {}
		if not near_key.is_empty():
			_action_mode = "building:" + near_key
			_set_action_hint("进入 %s" % near_label)
		else:
			_action_mode = ""
			_set_action_hint("")

	_city_action_btn.visible = not _action_mode.is_empty()

	# 交互菜单开着但目标已离开/切换 → 自动收起（与大地图行为一致）
	if _menu != null and _menu.is_open():
		var mt := _menu.get_target()
		if _action_mode != "npc" \
				or str(mt.get("id", "")) != str(_near_npc.get("id", "")):
			_menu.hide_menu()


## 【重复触发免疫】对话刚关闭的瞬间，手指连点/双击容易落在立即恢复显示的
## 「交谈/交易」按钮上，把同一段对话再开一遍（用户反馈「选完选项再次靠近
## 依然重复触发」）。对话关闭后 350ms 内忽略交互入口。
var _interact_cooldown_until := 0

func _on_dialogue_finished() -> void:
	_interact_cooldown_until = Time.get_ticks_msec() + 350


func _interact_on_cooldown() -> bool:
	return Time.get_ticks_msec() < _interact_cooldown_until


func _on_walk_enter() -> void:
	if _interact_on_cooldown():
		return
	# 靠近的是城内 NPC → 对话（接取/提交任务都在对话里）
	if not _near_npc.is_empty():
		AudioManager.sfx_click()
		# 【NPC 记忆性 2026-09-29】不再一律播初见节点：任务在身就问进度、做完了就催交差，
		# 交完这一轮才回到常规对话。节点缺失时 DialogueService 会自动退回初见，行为不变。
		var root := DialogueService.entry_node(_near_npc)
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


## 圆形交互钮点按 NPC → 弹贴脸交互菜单（交谈/交易，按 npc_type 出选项）。
## 【2026-09-24 用户拍板】城内交互统一走「圆圈触发选项再选择」，删独立交易按钮。
func _open_npc_menu() -> void:
	if _near_npc.is_empty():
		return
	AudioManager.sfx_click()
	var npc_type := str(_near_npc.get("npc_type", ""))
	var items: Array = ["talk", "trade"] \
		if npc_type in ["merchant", "blacksmith"] else ["talk"]
	var target := {
		"type": "npc",
		"id": str(_near_npc.get("id", "")),
		"name": str(_near_npc.get("name", "")),
		"tags": [npc_type],
		"items": items,          # 城内显式出选项（不走大地图 rules 匹配）
		"data": _near_npc,
	}
	_menu.show_for(target, _near_npc_pos)


## 交互菜单选项回调（与大地图 _on_menu_action 同构，动作子集）
func _on_menu_action(action: String, target: Dictionary) -> void:
	var data: Dictionary = target.get("data", {})
	match action:
		"talk":
			_menu.hide_menu()
			_near_npc = data
			_on_walk_enter()
		"trade":
			_menu.hide_menu()
			if data.is_empty():
				return
			AudioManager.sfx_click()
			_trade.open(data)
		_:
			show_toast("尚未实装：%s" % action)


## ---------- 面板：通用 ----------

func _open_panel(key: String) -> void:
	if _cur_panel == key and _panel_root.visible:
		return
	# 【四十一轮】面板开合音（卷轴抽开）；触发它的按钮音由 UITheme.button 工厂统一出
	AudioManager.ui_panel_open()
	_cur_panel = key
	_panel_root.visible = true
	_clear_panel()
	_panel_body.scroll_vertical = 0   ## 【M1】重建后复位滚动，防上次位置残留

	match key:
		"tavern":   _build_tavern()
		"barracks": _build_barracks()
		"market":   _build_market()
		"smith":    _build_smith()
		"hall":     _build_hall()


func _close_panel() -> void:
	AudioManager.ui_panel_close()   ## 【四十一轮】合拢音（原 sfx_cancel 与"关闭"语义不符）
	_panel_root.visible = false
	_cur_panel = ""
	_clear_panel()
	_refresh_header()


func _clear_panel() -> void:
	for c in _panel_content.get_children():
		# 先摘除再释放：queue_free 帧末才生效，旧按钮本帧仍可被点第二次
		# （否则同帧双击旧按钮双扣账——与 npc_trade_panel._clear_list 同病灶）
		_panel_content.remove_child(c)
		c.queue_free()
	for c in _panel_footer.get_children():
		if str(c.name) != "PanelClose":
			_panel_footer.remove_child(c)
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
		AudioManager.play_sfx("res://assets/audio/sfx/recruit_ok.ogg")
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
	AudioManager.play_sfx("res://assets/audio/sfx/recruit_ok.ogg")
	_reopen()


## 处死俘虏：二次确认拦截（误触即永久丢将 + 恶名不可逆）
## 【第五十一轮】此前点一下直接 remove_prisoner，俘虏永久消失、恶名不可回退，
## 而按钮就在列表里、连点两下就没了。改为弹 make_sub_modal 确认（同 save_menu
## 的「确认删除」组件），文案把代价写明，让玩家看清代价再决定。
func _do_prisoner_execute(hero_id: String) -> void:
	var p := GameState.get_prisoner(hero_id)
	if p.is_empty():
		_reopen()
		return
	if _prison_confirm != null and is_instance_valid(_prison_confirm):
		return
	var hero := DataManager.get_hero_resolved(hero_id)
	var hname := str(hero.get("name", hero_id)) if not hero.is_empty() else hero_id
	_pending_execute_id = hero_id
	var m := UITheme.make_sub_modal(self, "处 死 俘 虏？",
		_close_prison_confirm, Vector2(800, 460))
	_prison_confirm = m["dim"]
	var body: VBoxContainer = m["body"]
	var tip := UITheme.label(
		"处死 %s 后，%s 将永久消失，无法找回；你的恶名将 +%d，同样不可回退。" % [
			hname, hname, PrisonerService.execute_infamy_gain()],
		UITheme.FS_BODY, UITheme.TEXT)
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(tip)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 28)
	var cancel := UITheme.button("再想想", UITheme.FS_BODY, Vector2(240, 84))
	cancel.pressed.connect(func():
		AudioManager.sfx_click()
		_close_prison_confirm())
	var ok := UITheme.button("狠心处死", UITheme.FS_BODY, Vector2(240, 84))
	ok.pressed.connect(func():
		AudioManager.sfx_confirm()
		var pid := _pending_execute_id
		_close_prison_confirm()
		if not pid.is_empty():
			_confirm_prisoner_execute(pid))
	row.add_child(cancel)
	row.add_child(ok)
	body.add_child(row)


## 确认后真正执行（与原 _do_prisoner_execute 的执行体一致）
func _confirm_prisoner_execute(hero_id: String) -> void:
	# 防御：弹窗期间若俘虏已被其他路径移除（如读档），直接刷新不重复结算
	if GameState.get_prisoner(hero_id).is_empty():
		_reopen()
		return
	var hero := DataManager.get_hero_resolved(hero_id)
	var hname := str(hero.get("name", hero_id)) if not hero.is_empty() else hero_id
	GameState.remove_prisoner(hero_id)
	var gain := PrisonerService.execute_infamy_gain()
	GameState.add_infamy(gain)
	show_toast("已处死 %s，恶名 +%d" % [hname, gain])
	# 【第五十一轮】此处是「成功」路径，旧代码播 sfx_cancel（取消音）语义相反，
	# 玩家执行了不可逆操作却听到否定反馈，误导决策。改用确认音。
	AudioManager.sfx_confirm()
	_reopen()


func _close_prison_confirm() -> void:
	if _prison_confirm != null and is_instance_valid(_prison_confirm):
		_prison_confirm.queue_free()
	_prison_confirm = null
	_pending_execute_id = ""


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
		AudioManager.play_sfx("res://assets/audio/sfx/recruit_ok.ogg")
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


## 解散是不可逆操作（兵力直接消失、无法找回），与「处死俘虏」同级。
## 【第五十一轮】此前点一下就直接解散，手滑/误触即永久损失，
## 现补二次确认，文案写明代价（沿用 _do_prisoner_execute 的弹窗模式）。
func _do_disband(troop_index: int) -> void:
	if troop_index < 0 or troop_index >= GameState.troops.size():
		return
	if _disband_confirm != null and is_instance_valid(_disband_confirm):
		return
	var t: Dictionary = GameState.troops[troop_index]
	var unit := DataManager.get_unit(str(t.get("unit_id", "")))
	var n := int(t.get("count", 0))
	var uname := str(unit.get("name", "?"))
	_pending_disband_index = troop_index
	var m := UITheme.make_sub_modal(self, "解 散 部 队？",
		_close_disband_confirm, Vector2(800, 440))
	_disband_confirm = m["dim"]
	var body: VBoxContainer = m["body"]
	var tip := UITheme.label(
		"解散后 %s ×%d 将永久消失，无法找回；该部队占用的带兵武将也会变为空闲。" % [
			uname, n],
		UITheme.FS_BODY, UITheme.TEXT)
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(tip)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 28)
	var cancel := UITheme.button("再想想", UITheme.FS_BODY, Vector2(240, 84))
	cancel.pressed.connect(func():
		AudioManager.sfx_click()
		_close_disband_confirm())
	var ok := UITheme.button("确认解散", UITheme.FS_BODY, Vector2(240, 84))
	ok.pressed.connect(func():
		AudioManager.sfx_confirm()
		var idx := _pending_disband_index
		_close_disband_confirm()
		if idx >= 0:
			_confirm_disband(idx))
	row.add_child(cancel)
	row.add_child(ok)
	body.add_child(row)


## 确认后真正解散（防御：弹窗期间部队可能已被其他路径移除）
func _confirm_disband(troop_index: int) -> void:
	if troop_index < 0 or troop_index >= GameState.troops.size():
		_open_panel("barracks")
		return
	var t: Dictionary = GameState.troops[troop_index]
	var unit := DataManager.get_unit(str(t.get("unit_id", "")))
	var n := int(t.get("count", 0))
	GameState.remove_troop(troop_index)
	AudioManager.sfx_confirm()
	show_toast("已解散 %s ×%d" % [str(unit.get("name", "?")), n])
	_open_panel("barracks")


func _close_disband_confirm() -> void:
	if _disband_confirm != null and is_instance_valid(_disband_confirm):
		_disband_confirm.queue_free()
	_disband_confirm = null
	_pending_disband_index = -1


## ---------- 面板：市场 ----------

func _build_market() -> void:
	_panel_title.text = "市  场"
	var level := int(_city.get("level", 1))
	var quota := _svc.remaining_trade_quota(_city_id)

	_add_section("买  进")
	# 【跑商】旧模型下全天下物资同价（只按城池等级缩放），且卖出恒为买入价 ×0.55，
	# 于是不管在哪买哪卖都亏，跑商根本无从谈起。现在买入价随各城「商业值 + 特产」浮动，
	# 城与城之间有了真实价差；行尾标注此地价相对天下均价的高低，玩家据此决定在此进货还是出货。
	_add_hint("物资价随各城商业、特产浮动，贱买贵卖可获利。今日此城还可进货 %d 批。" % quota)
	for g in DataManager.get_market_goods():
		var goods: Dictionary = g
		var is_res := str(goods.get("kind", "")) == "resource"
		if is_res:
			var res := str(goods.get("resource", ""))
			var pack := int(goods.get("pack", 10))
			var base := int(goods.get("price", 0))
			var price := _svc.resource_buy_price(_city_id, res, base)
			var tag: Dictionary = _svc.price_tag(_city_id, res, base)
			var g2: Dictionary = goods
			_add_row("%s ×%d（%s）" % [str(goods.get("name", res)), pack, str(tag.get("text", ""))],
				func(): _do_buy_resource(res, pack, price, g2),
				GameState.gold >= price and quota > 0,
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
		# 【M-1 修复】原只查旧 items.json：255 种 items6 物品（战利品主力）
		# 查不到就直接跳过，永远卖不掉。改走统一解析链——
		# resolve_item6（items6 数字 id / 旧 id 映射）→ 旧 items.json → 都无才跳过
		var item3 := CharacterService.resolve_item6(sid)
		if item3.is_empty():
			item3 = DataManager.get_item(sid)
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
	# 收货价走跑商模型（该城的物资买入价 × 回收比例），不同城给的价不一样：
	# 在缺货的城出货才划算，商埠收货价另高一档。
	_add_section("售出物资")
	_add_resource_sell_rows("food", "粮草", 100, 200)
	_add_resource_sell_rows("wood", "木材", 50, 150)
	_add_resource_sell_rows("iron", "铁矿", 20, 160)

	# 【本轮】集市/商城/观览不再内联摆行，改开 EconomyPanel ——
	# 与大地图轮盘「商城」入口共用同一个类，摆行逻辑只有一份。
	_add_row("打  开  商  城", _open_economy, true, "集市 · 珍玩阁 · 观览")


func _open_economy() -> void:
	_economy.open()


## 【本轮·搬迁说明】原先的 _build_market_exchange / _build_market_mall /
## _build_market_ad / _tier_label / _do_exchange / _do_buy_mall / _do_watch_ad
## 已整体移入 `scripts/ui/economy_panel.gd`（EconomyPanel）。
## 【为什么不留一份兼容实现】它们与商城面板逐行重复，是「同一规则两处改」的标准场景；
## 而这些函数都是本文件内的私有方法（无 `static`、无外部调用者），
## 删干净后由 _compile_check 证明没有残留引用。

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
	# 必须传「基础价」：resource_sell_price 内部自己会再算一遍该城的买入价，
	# 传 resource_buy_price 的返回值会把城池/商业/特产系数乘两遍，售价虚高。
	var sp := _svc.resource_sell_price(_city_id, res, base_price)
	var tag: Dictionary = _svc.price_tag(_city_id, res, base_price)
	_add_row("售 %s ×%d（+金 %d，此地%s）" % [name, pack, sp, str(tag.get("text", ""))],
		func(): _do_sell_resource(res, pack, sp))


func _do_buy_resource(res: String, pack: int, price: int, _g: Dictionary) -> void:
	var r := _svc.buy_resource(_city_id, res, pack, price)
	if r["ok"]:
		AudioManager.play_sfx("res://assets/audio/sfx/coin_trade.ogg")
	else:
		AudioManager.sfx_cancel()
	show_toast(str(r["msg"]))
	_open_panel("market")


func _do_sell_resource(res: String, pack: int, price: int) -> void:
	var r := _svc.sell_resource(_city_id, res, pack, price)
	if r["ok"]:
		AudioManager.play_sfx("res://assets/audio/sfx/coin_trade.ogg")
	else:
		AudioManager.sfx_cancel()
	show_toast(str(r["msg"]))
	_open_panel("market")


func _do_buy_item(item_id: String, count: int, price: int) -> void:
	var r := _svc.buy_item(_city_id, item_id, count, price)
	if r["ok"]:
		AudioManager.play_sfx("res://assets/audio/sfx/coin_trade.ogg")
	else:
		AudioManager.sfx_cancel()
	show_toast(str(r["msg"]))
	_open_panel("market")


func _do_sell_item(item_id: String, count: int, price: int) -> void:
	var r := _svc.sell_item(_city_id, item_id, count, price)
	if r["ok"]:
		AudioManager.play_sfx("res://assets/audio/sfx/coin_trade.ogg")
	else:
		AudioManager.sfx_cancel()
	show_toast(str(r["msg"]))
	_open_panel("market")


## ---------- 面板：铁匠铺 ----------

func _build_smith() -> void:
	_panel_title.text = "铁匠铺"
	var level := int(_city.get("level", 1))
	_add_hint("打造装备需城池等级达标。装备属性详见物品说明。")

	_build_smith_enhance()
	_build_smith_craft()

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
	for slot in ["weapon1", "weapon2", "helmet", "armor", "treasure", "mount"]:
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
			var exp_gold := EnhanceService.expected_gold_from(0)
			var nom_gold := EnhanceService.nominal_gold_to_max()
			if exp_gold > 0 and nom_gold > 0:
				_add_hint("期望账：0→满级标价合计 %d 金，计失败返工实花约 %d 金（%.1f 倍），请按期望规划预算。" % [
					nom_gold, exp_gold, float(exp_gold) / float(nom_gold)])
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
	if bool(r.get("ok", false)):
		# 强化成败专用音：成功=磬「叮」，失败=闷金属+下行（替换通用确认/命中音）
		if bool(r.get("success", false)):
			AudioManager.play_sfx("res://assets/audio/sfx/enhance_ok.ogg")
		else:
			AudioManager.play_sfx("res://assets/audio/sfx/enhance_fail.ogg")
	else:
		AudioManager.sfx_cancel()
	show_toast(str(r["msg"]))
	_open_panel("smith")


## ---------- 铁匠铺·锻造区（第七十五轮新增） ----------
##
## 【为什么放在铁匠铺而不是新开面板】items6 的 113 件配方全部走这里，
## 与强化区共用「已拥有的东西」这一语境；新开面板要额外写 tscn/gd、
## 接 _any_ui_open 红线清单、加无头探针，成本翻倍而玩家认知路径更长。
##
## 配方材料不进本区展示（那是背包的事），副标题只报「缺哪几种 + 差多少」，
## 否则 113 行 × 每行 3~4 种材料会把面板撑到几千像素，滚到天荒地老。
func _build_smith_craft() -> void:
	var lim := CraftService.daily_limit()
	var left := CraftService.left_today()
	if left < 0:
		_add_hint("锻造不设次数。工费只买手艺，材料须自备。")
	else:
		_add_hint("锻造工费：材料自备，另付工费。今日 %d/%d。" % [CraftService.used_today(), lim])
	var rows := CraftService.craftable_list()
	if rows.is_empty():
		_add_hint("暂无图纸。")
		return
	# 113 件配方按大类分节，只列「材料齐 + 钱够」的前若干件可做项 + 全部不可做项的提示。
	# 做法：先列可做（玩家当下能推进的），再折叠成一行提示「另有 N 件待备料」。
	var doable: Array = []
	var locked: Array = []
	for r in rows:
		if bool(r["ok"]):
			doable.append(r)
		else:
			locked.append(r)
	if not locked.is_empty():
		_add_hint("另有 %d 件待备料（材料齐后自动出现）。" % locked.size())
	if doable.is_empty():
		_add_hint("眼下无一件可开炉。去市场买些材料再来。")
		return
	var cur_cat := -1
	for r in doable:
		var cat := int(r.get("cat", 0))
		if cat != cur_cat:
			cur_cat = cat
			_add_section(_craft_cat_name(cat))
		var mat_txt := _craft_material_text(r)
		var gate := CraftService.can_craft(int(r["item_id"]))
		var sub := "工费 %d 金　%s" % [int(r["gold"]), mat_txt]
		if not bool(gate.get("ok", false)):
			sub += "　[%s]" % str(gate["reason"])
		var iid := int(r["item_id"])
		var label := str(r["name"])
		var q := str(r.get("quality", ""))
		if not q.is_empty() and q != "未知":
			label += "　【%s】" % q
		_add_row(label, func(): _do_craft(iid), bool(gate["ok"]), sub)


func _craft_cat_name(cat: int) -> String:
	match cat:
		2: return "锻造·头盔"
		3: return "锻造·食物"
		4: return "锻造·护甲"
		5: return "锻造·武器"
		6: return "锻造·宝物"
		7: return "锻造·坐骑"
		1: return "锻造·材料"
		8: return "锻造·工具"
	return "锻造"


## 配方副标题：只说缺什么，不列全部材料。
## 「缺」用 C_ALERT 语义（附在文字里），齐的就不占篇幅。
func _craft_material_text(r: Dictionary) -> String:
	var parts: Array[String] = []
	for m in r.get("materials", []):
		var md: Dictionary = m
		var short := int(md.get("short", 0))
		if short > 0:
			parts.append("%s 缺%d" % [str(md.get("name", "?")), short])
	if parts.is_empty():
		return "材料齐备"
	if parts.size() > 3:
		return "、".join(parts.slice(0, 3)) + " 等%d种" % parts.size()
	return "、".join(parts)


func _do_craft(item_id6: int) -> void:
	var r := CraftService.craft(item_id6)
	if bool(r.get("ok", false)):
		AudioManager.play_sfx("res://assets/audio/sfx/enhance_ok.ogg")
	else:
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

	## 【2026-09-24 用户拍板】演武场入口整体下线：城内按钮已删，官府面板入口同步移除。
	## drill 数据/服务代码保留（不触发即无副作用），需要时把这里接回来即可。



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
	AudioManager.ui_panel_open()
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


## 【2026-09-28 用户反馈】面板「返 回」按钮统一入口：重开轮盘菜单
func _reopen_menu_wheel() -> void:
	_wheel_return_panel = null
	_menu_wheel.open()


## 圆形主菜单的选项分发：任务中心只是其中一项
func _on_wheel_selected(action: String) -> void:
	match action:
		"quest":
			_wheel_return_panel = _quest_panel
			_quest_panel.open()
		"heroes":
			_wheel_return_panel = _hero_dex
			_hero_dex.open()
		"player":
			_wheel_return_panel = _attr_panel
			_attr_panel.open()
		"achieve":
			_wheel_return_panel = _ach_panel
			_ach_panel.open()
		"bag":
			_wheel_return_panel = _backpack
			_backpack.open()
		"diplo":
			_wheel_return_panel = _diplomacy
			_diplomacy.open()
		"self_rule":
			# open("") 内部会回退到 GameState.current_city_id（当前所在城）
			_wheel_return_panel = _self_rule
			_self_rule.open()
		"system":
			_wheel_return_panel = _settings
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
	_panel.open(t, true, false)   # 从人物志进入：显示「返回列表」；城内无人接动作信号，纯查阅（M2）


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

## 统一提示出口（2026-09-27）：转发全局 ToastLayer（横排自适应 + 3~5 秒），
## 不再用本场景的 ToastLabel —— 竖排 bug 的根因之一就是各场景各养一套 toast。
func show_toast(message: String) -> void:
	EventBus.show_toast(message)
