extends Node2D
## 大地图（WorldMap）
## 职责：地形绘制、主角行走、相机跟随、城池/遭遇/NPC 交互、进入城镇、对话调度。
## 整合 TerrainPainter / EncounterManager / NPCManager / PlayerController /
##      DialogueUI / InteractionMenu。
##
## 【交互模型】靠近对象 → 贴着对象弹出交互菜单 → 选项即能力。
## 菜单数据驱动，配置在 assets/data/interaction_menu.json。
##
## 【分区加载】本场景是覆盖全国的单地图。M10 起按 GameState.current_region 做「区域窗口」：
##   相机锁定当前区域矩形；只生成该区域城池/遭遇；走到边界越出邻接区域矩形 → 渐隐切区。
##   区域规则见 RegionService（02-策划文档/D-04）。

@onready var _player: PlayerController = $Player
@onready var _camera: Camera2D = $Player/Camera2D
@onready var _terrain: TerrainPainter = $Terrain
@onready var _encounters: EncounterManager = $Encounters
@onready var _npcs: NPCManager = $NPCs
@onready var _hud: WorldHUD = $UI/HUD
@onready var _joystick: GameJoystick = $UI/VirtualJoystick
@onready var _btn_menu: Button = $UI/ActionButtons/BtnMenu
@onready var _action_buttons: HBoxContainer = $UI/ActionButtons
@onready var _city_markers: Node2D = $CityMarkers
@onready var _dialogue: DialogueUI = $UI/DialogueUI
@onready var _minimap: MiniMap = $UI/MiniMap
var _big_map: MiniMap  ## 点击小地图弹出的放大地图覆盖层
var _map_dim: ColorRect  ## 大地图背后的暗色遮罩（关闭时必须一并隐藏）
var _big_map_title: PanelContainer  ## 放大地图顶部标题条（周边控制 UI）
var _big_map_close_hint: PanelContainer  ## 放大地图底部关闭提示条（周边控制 UI）

var _menu: InteractionMenu
var _panel: CharacterPanel
var _trade: NpcTradePanel           ## NPC 背包交易面板
var _quest_panel: QuestPanel        ## 任务中心面板
var _event_popup: EventPopup        ## 随机事件弹窗
var _world_event_markers: Node2D = null  ## 世界动态事件标记层（脉冲标记，点击弹出选项）
var _menu_wheel: MainMenuWheel      ## 圆形图标主菜单
## 【2026-09-28 用户反馈】从轮盘打开的面板关闭后，要回到轮盘菜单而不是光秃秃的大地图。
## 记下「本次从轮盘打开的面板」，_process 里每帧查它是否已关；已关则重开轮盘。
## 用轮询而不是 closed 信号：quest_panel 没有 closed 信号，且各面板关闭路径不止一条；
## 面板都遵守 visible 开关，轮询统一可靠。hero_dex 点选详情时保持自身可见，不会误触发。
var _wheel_return_panel: Control = null
var _hero_dex: HeroDex              ## 人物志浏览器
var _attr_panel: AttributePanel      ## 主角成长 / 属性加点面板
var _ach_panel: AchievementPanel
var _backpack: BackpackPanel          ## 背包面板（圆形菜单背包入口，与城内一致）
var _self_rule: SelfRulePanel     ## 成就面板
var _diplomacy: DiplomacyPanel       ## 外交面板（圆形菜单外交入口）
var _settings: SettingsPanel         ## 系统设置面板（音量 / 存档 / 返回主菜单）
var _panel_target: Dictionary = {}   ## 详情面板当前对象（对话结束后回到面板）
var _mentor_active := false           ## 正在为名士托付对话中（【霸王立志篇】改为任务驱动，仅保留对话态标记）
var _busy := false          ## 正在对话 / 切场景 / 弹菜单确认中，暂停角色移动
## 剧情旁白排队（章末/章初/结局演出）：_busy 时先入队，dialogue_finished 后接播
var _narration_queue: Array[String] = []
## 大地图打开时刻与输入免疫期（毫秒）：用于屏蔽「打开那一次点击」的模拟触摸事件，
## 避免地图刚弹出就被同一次点击关掉。详见 _request_close_big_map()。
const MAP_INPUT_GUARD_MS := 320
## 大地图演出（方向②）· 零生图 CPU 粒子 + 选中脉冲
const WORLD_MARCH_DUST_AMOUNT := 14      ## 行军拖尾粒子数
const WORLD_MARCH_DUST_ALPHA := 0.22     ## 行军尘土透明度
const SELECT_PULSE_AMOUNT := 10          ## 城池选中脉冲粒子数
const SELECT_PULSE_ALPHA := 0.34         ## 城池选中脉冲透明度
const SELECT_PULSE_MIN := 0.45           ## 脉冲呼吸最低透明度
const SELECT_PULSE_PERIOD := 0.9         ## 脉冲呼吸半周期（秒）
var _map_opened_at_ms := 0
var _menu_target_id := ""
var _city_action_btn: Button = null   ## 右侧圆形「城池交互」按钮（代码创建）
var _city_target: Dictionary = {}      ## 当前可交互的城池/地点目标
var _city_target_pos: Vector2 = Vector2.ZERO
var _enc_target_node: Node2D = null    ## 当前可手动触发的非战斗遭遇节点（采集/宝箱/商队/奇遇）
var _hl_node: Node2D = null            ## 【R3-05】当前放大高亮的交互对象 node
var _hl_tween: Tween = null            ## 【R3-05】放大/复位补间
## 大地图演出（方向②）运行时句柄
var _march_dust: CPUParticles2D = null   ## 行军拖尾（挂 _player 脚下，随移动飘散）
var _sel_pulse: CPUParticles2D = null    ## 城池选中脉冲（挂选中 marker 脚下）
var _sel_pulse_marker: Node2D = null     ## 当前脉冲所属 marker
var _sel_pulse_tween: Tween = null       ## 脉冲呼吸缓动
## 遭遇类型中文名（交互菜单副标题用）
const ENC_TYPE_CN := {
	"gather": "采集点", "treasure": "宝箱", "merchant": "行商", "event": "奇遇",
}
var _spar_popup: DuelPopup            ## 切磋单挑弹窗（复用战前单挑 UI）
var _spar_target_name := ""           ## 当前切磋对手名
var _govern_panel: CityGovernPanel = null   ## 治下城池治理面板（#66，按需创建，关闭即释放）
var _retake_popup: RetakePopup = null       ## 收复军来袭弹窗（#67，按需创建）
## 【#67】本月已问过「迎战/弃城」的城池：city_id -> 游戏月序，避免走近一次弹一次
var _retake_prompted: Dictionary = {}   ## 上一帧交互菜单显示的目标 id（节流用，避免每帧重建）


func _ready() -> void:
	AudioManager.play_bgm("res://assets/audio/bgm/world_map.res")

	# 【第五十二轮】UI 面板登记表在此一次性填好，供 _any_ui_open() 每帧零分配查询
	_ui_panels = [
		_dialogue, _panel, _trade, _quest_panel, _event_popup,
		_menu_wheel, _hero_dex, _attr_panel, _self_rule, _ach_panel,
		_diplomacy, _settings, _backpack,
	]

	# 【全国连续地图】玩家活动范围=整张天下地图，区域只是「内容刷新粒度」
	# 而不是空气墙 —— 区域接缝处不再出现「前方已是无路之地」，
	# 也不再为了换区域把整场景渐隐重载（黑屏过渡）。
	var world := _terrain.get_map_size()
	_player.map_size = world
	_player.region_offset = Vector2.ZERO
	_player.walk_rects = [Rect2(Vector2.ZERO, world)]
	# 通知地形绘制器当前区域窗口（用于区域级高清纹理 + 装饰物定位）
	_terrain.set_view_rect(Rect2(Vector2.ZERO, world))

	# 相机锁定到全图范围（全国连续行走后相机永远跟随玩家）
	_apply_region_camera()

	# 恢复战斗/进城前的位置（避免场景重载后回到出生点）
	if GameState.return_scene == "world":
		_player.position = GameState.return_pos
		# 旧存档 / 跨区域坐标可能已不在当前区域的地盘上，必须夹回来
		_player.sync_into_region()
		GameState.last_world_pos = _player.position
		GameState.return_scene = ""
	elif GameState.last_world_pos != Vector2.ZERO:
		# 【R1-03】读档：恢复存档瞬间在大地图上的位置（旧档无此数据 → 走随机出生）
		_player.position = GameState.last_world_pos
		_player.sync_into_region()
	else:
		# 全新进入大地图（新游戏首次）：随机选一座本区域城池附近出生，
		# 不再固定出生在建宁。
		_spawn_at_random_city()

	# 撞地图边界的反馈（C4：别让玩家以为是卡死）
	_player.bounds_blocked.connect(_on_bounds_blocked)

	# 静态地图：地形为离线烘焙整图，无需开局预热/后台分块生成（见 terrain_painter.gd）。

	# 交互菜单（代码创建，避免往 tscn 里堆节点）
	_menu = InteractionMenu.new()
	_menu.name = "InteractionMenu"
	$UI.add_child(_menu)
	_menu.set_camera(_camera)
	_menu.action_chosen.connect(_on_menu_action)

	# 人物/城池详情面板（代码创建）
	_panel = CharacterPanel.new()
	_panel.name = "CharacterPanel"
	$UI.add_child(_panel)
	_panel.action_requested.connect(_on_menu_action)
	_panel.closed.connect(func(): _panel_target = {})
	# 人物志 → 详情 → 「返回列表」回到人物志（不整页关闭）
	_panel.back_requested.connect(func():
		if _hero_dex != null:
			_hero_dex.open())

	# NPC 背包交易面板（代码创建）
	_trade = NpcTradePanel.new()
	_trade.name = "NpcTradePanel"
	$UI.add_child(_trade)

	# 任务中心面板（代码创建）
	_quest_panel = QuestPanel.new()
	_quest_panel.name = "QuestPanel"
	$UI.add_child(_quest_panel)

	# 随机事件弹窗（代码创建）
	_event_popup = EventPopup.create()
	_event_popup.name = "EventPopup"
	$UI.add_child(_event_popup)

	# 世界动态事件标记层（与城池标记同坐标系，脉冲提示"沙盘活起来"）
	_world_event_markers = Node2D.new()
	_world_event_markers.name = "WorldEventMarkers"
	_city_markers.get_parent().add_child(_world_event_markers)
	EventBus.day_passed.connect(_on_world_day)
	_event_popup.popup_closed.connect(_on_event_popup_closed)
	_refresh_world_event_markers()
	call_deferred("_show_world_event_news")

	# 【大地图史诗感 2026-09-30】世界事件横幅 + 昼夜时辰氛围（纯演出层，零新资源）
	# ① 横幅：破城/失地/名将来投/阵擒名将 → 全屏金字横幅（独立 CanvasLayer）
	var banner := WorldEventBanner.new()
	banner.name = "WorldEventBanner"
	add_child(banner)
	# ② 氛围：全屏色温层压在 $UI 最底层（index 0）——只染地图世界，不盖 HUD/面板
	var tint := DayNightTint.new()
	tint.name = "DayNightTint"
	tint.clock = $WorldClock
	$UI.add_child(tint)
	$UI.move_child(tint, 0)

	# ③ 【身临其境 2026-10-01】世界活物氛围层：云影掠地 / 城池炊烟 / 飞鸟掠空
	# （零新资源；云影压 Terrain 之上 CityMarkers 之下，炊烟只挂相机附近城市）
	var ambience := WorldAmbience.new()
	ambience.name = "WorldAmbience"
	add_child(ambience)
	ambience.setup(_camera)

	# ③.5 【三十二轮 2026-10-01】官道商队：沿 terrain.json 官道往返的小队伍
	# （与小地图/地形官道同源数据；程序化小人+货车，上限 3 队）
	var caravans := WorldCaravans.new()
	caravans.name = "WorldCaravans"
	add_child(caravans)
	caravans.setup(_camera)

	# 【三十四轮×5】城池图标放大后挤城区自适应收缩（call_deferred 确保全部 marker 已建）
	call_deferred("_fit_marker_scales")

	# ④ 【三十一轮 2026-10-01】环境音层：风声循环 + 昼夜联动鸟鸣/虫鸣
	# （零外部素材全程序化合成；走 BGM bus 随背景音量缩放）
	var amb_audio := WorldAmbientAudio.new()
	amb_audio.name = "WorldAmbientAudio"
	add_child(amb_audio)
	amb_audio.setup($WorldClock)

	# ⑤ 【三十八轮 2026-10-02】天气层：季节概率雨/雪 + 阴天染色复用 DayNightTint
	# 因子 + 程序化雨声联动静鸟鸣（零新素材、零新增全屏混合层）
	var weather := WorldWeather.new()
	weather.name = "WorldWeather"
	add_child(weather)
	weather.setup(_camera, tint, amb_audio)

	# 圆形图标主菜单（代码创建）
	_menu_wheel = MainMenuWheel.new()
	_menu_wheel.name = "MainMenuWheel"
	$UI.add_child(_menu_wheel)
	_menu_wheel.selected.connect(_on_wheel_selected)

	# 人物志浏览器（代码创建）
	_hero_dex = HeroDex.new()
	_hero_dex.name = "HeroDex"
	$UI.add_child(_hero_dex)
	_hero_dex.picked.connect(_on_hero_picked)

	# 主角成长 / 属性加点面板（代码创建）
	_attr_panel = AttributePanel.new()
	_attr_panel.name = "AttributePanel"
	$UI.add_child(_attr_panel)

	# 背包面板（采集资源 / 装备武器查看，代码创建）
	_backpack = BackpackPanel.new()
	_backpack.name = "BackpackPanel"
	$UI.add_child(_backpack)

	# 成就面板（代码创建）
	_ach_panel = AchievementPanel.new()
	_self_rule = SelfRulePanel.new()
	_self_rule.name = "SelfRulePanel"
	$UI.add_child(_self_rule)
	_ach_panel.name = "AchievementPanel"
	$UI.add_child(_ach_panel)

	# 外交面板（代码创建）
	_diplomacy = DiplomacyPanel.new()
	_diplomacy.name = "DiplomacyPanel"
	$UI.add_child(_diplomacy)

	# 系统设置面板（代码创建）
	_settings = SettingsPanel.new()
	_settings.name = "SettingsPanel"
	$UI.add_child(_settings)

	# 【2026-09-28 用户反馈】各面板标题行「返 回」按钮 → 关面板并回到轮盘菜单。
	# 显式按钮路径不依赖 _process 轮询（轮询只兜底 ✕/点遮罩关闭的情形）。
	for p: Control in [_quest_panel, _hero_dex, _attr_panel, _ach_panel,
			_backpack, _diplomacy, _settings, _self_rule]:
		if p.has_signal("menu_return_requested"):
			p.menu_return_requested.connect(_reopen_menu_wheel)

	# 接取任务后不再自动弹回人物详情面板
	# 【H1】autoload 信号一律方法绑定连接：捕获 self 的 lambda 不会随场景释放断连，
	# 每次进城/回图叠一层僵尸 handler，之后每次触发都对已释放实例刷报错
	EventBus.quest_accepted.connect(_on_quest_accepted)

	_joystick.changed.connect(_on_joystick_changed)
	_btn_menu.pressed.connect(_on_open_menu)
	_style_action_buttons()
	_setup_city_action_button()

	# 切磋单挑弹窗：与武将/NPC 过招，纯切磋不动兵力（复用 DuelPopup UI）
	_spar_popup = DuelPopup.create()
	_spar_popup.name = "SparPopup"
	$UI.add_child(_spar_popup)
	_spar_popup.duel_finished.connect(_on_spar_finished)

	_dialogue.dialogue_finished.connect(_on_dialogue_finished)
	_npcs.npc_interacted.connect(_on_npc_interacted)
	_encounters.encounter_triggered.connect(_on_encounter_triggered)
	# 从子场景返回时复位忙碌标记（用既有信号，不新增）
	EventBus.city_left.connect(_on_city_left)

	# 开场剧情：全新档（intro_seen=false）首次进入大地图时，延时一小段后自动播放；
	# 读档时 intro_seen 已按存档恢复为 true，不重放。
	if not GameState.intro_seen:
		var t := get_tree().create_timer(0.6)
		t.timeout.connect(func():
			# 【freed 防护】0.6s 内场景可能已被释放（读档直跳等），先验自身再播
			if not is_instance_valid(self) or not is_inside_tree():
				return
			if not GameState.intro_seen:
				_start_dialogue_by_id("intro"))
	# 第一章完成章末旁白：张角决战获胜返回时播放一次（mainline_service 记 pending 标记）
	if MainlineService.consume_ch1_end_pending():
		_queue_narration("mj_ch1_end", 0.8)
	# 【剧本全篇】二~七章的章末/章初旁白 + 终章结局演出：
	# MainlineService 通用推进（on_quest_completed）会置 pending 标记，这里统一消费。
	# 缺对话节点时静默跳过（dialogue_ui.start 内部已兜底关卡）。
	# 旁白走 _narration_queue 排队：章末(0.8s)/章初(1.4s)/结局(1.6s)若撞上
	# 玩家仍在播放前一段旁白（_busy），排队等 dialogue_finished 再播，绝不丢弃。
	var end_ch := MainlineService.consume_chapter_end_pending()
	if end_ch > 0:
		_queue_narration("mj_ch%d_end" % end_ch, 0.8)
	var intro_ch := MainlineService.consume_chapter_intro_pending()
	if intro_ch > 0:
		_queue_narration("mj_ch%d_start" % intro_ch, 1.4)
	if MainlineService.consume_ending_pending():
		# 【多结局分流 2026-09-28】按玩家终局状态选对应结局节点（称帝/汉室/霸业/归隐/默认）
		_queue_narration(MainlineService.ending_node_id(), 1.6)
	EventBus.drill_finished.connect(_on_async_done)
	# 战斗结束改走 _on_battle_ended：攻城战获胜时占领城池（#64），内部同样复位 _busy
	EventBus.battle_ended.connect(_on_battle_ended)
	# 【#67】原属势力收复军到期：玩家在场就地开战，不在场只发告警（赶回来再问）
	EventBus.city_retake_incoming.connect(_on_retake_incoming)
	# 城池归属变化（AI 攻城/玩家占领）→ 重绘势力配色底盘（方法绑定，场景释放自动断连）
	EventBus.world_territory_changed.connect(_rebuild_city_markers)

	# 【审计回归】初始城池标记 + 操作指引 + 小地图接线：这三样历史上被误并入
	# _on_res_changed（每次资源/日期信号都会无清场叠加 110 个 marker、重复连接
	# expand_requested），归位到 _ready 只执行一次
	_spawn_city_markers()
	_build_world_atmos()	# 方向②：行军拖尾粒子挂到 _player
	_set_hint("用左侧摇杆移动，靠近人或城池即可交互")
	_minimap.expand_requested.connect(_show_big_map)
	# 【地貌同步】等 terrain 的远景全图预热（call_deferred）完成后注入小地图
	call_deferred("_sync_minimap_terrain")

	# toast 由全局 ToastLayer autoload 统一消费（B2/B4/B11 一揽子修复），本地不再重复连接
	# 对话 open_shop 动作 → 打开 NPC 随身货单（R2-05a，与交互菜单「交易」同面板）
	EventBus.npc_shop_requested.connect(_on_npc_shop_requested)
	# 资源栏必须订阅「所有会显示的数值」对应的信号。
	# 历史 bug：这里只连了 gold/food/date，漏了 wood/troop，
	# 而 hud.update_resources() 明明会刷新木材与兵力 → 采木/募兵后
	# 大地图资源栏数值永远停在旧值（进一次城再回来才更新），表现为「数值不同步」。
	EventBus.gold_changed.connect(_on_res_changed)
	EventBus.food_changed.connect(_on_res_changed)
	EventBus.wood_changed.connect(_on_res_changed)
	EventBus.troop_changed.connect(_on_res_changed)
	EventBus.date_changed.connect(_on_res_changed)


## 【H1】以下均为方法绑定落点（对象释放自动断连），替代捕获 self 的 lambda
func _on_quest_accepted(_id: String) -> void:
	_panel_target = {}


func _on_city_left(_id: String) -> void:
	_busy = false


## drill_finished(id, r) 与 battle_ended(r) 共用：任一结束即解除忙碌
func _on_async_done(_a, _b = null) -> void:
	_busy = false


func _on_npc_shop_requested(npc: Dictionary) -> void:
	_trade.open(npc)


## gold/food/wood/troop(1 参) 与 date(3 参) 共用刷新
func _on_res_changed(_a = null, _b = null, _c = null) -> void:
	_hud.update_resources()


## 把 terrain_painter 的远景全图纹理注入小地图（小地图底图 = 大地图真实地貌）。
## 【后台就绪重试】程序化远景已改为后台线程生成：首帧可能尚未算完（返回 null），
## 记一个 1s 后的重试点，_process 里补注入；AI 全景图存在时首次即成功，无重试。
var _minimap_sync_next_ms := 0

func _sync_minimap_terrain() -> void:
	if _minimap == null or _terrain == null:
		return
	var tex := _terrain._get_minimap_tex()
	if tex != null:
		_minimap.set_terrain_tex(tex)
	else:
		_minimap_sync_next_ms = Time.get_ticks_msec() + 1000


## 右上角动作按钮的统一外观（水墨描金风）。
## 放在代码里而不是 tscn 的 sub_resource：按钮数量少、且 world_map 已经在
## 代码里创建了一大批 UI，样式集中在一处更好维护。
## 【横屏适配】按钮只用 custom_minimum_size 定尺寸、由 HBoxContainer 右上锚定排布，
## 没有任何 1920 基准的绝对坐标，视口变宽时整体贴右边缘。
func _style_action_buttons() -> void:
	if _action_buttons == null:
		return
	var tint := UITheme.GOLD_LINE              ## 描金主色 #C7A45C（R3-09 归表）
	var ink := Color(UITheme.INK, 0.92)        ## 墨底 #171B26（R3-09 归表）

	# 右侧动作按钮统一为「圆形」：128×128 + 圆角=半径(64) → 正圆，与中央圆形主菜单轮盘同一套语言。
	var normal := StyleBoxFlat.new()
	normal.bg_color = ink
	normal.border_color = Color(tint.r, tint.g, tint.b, 0.75)
	normal.set_border_width_all(2)
	normal.set_corner_radius_all(64)
	normal.content_margin_left = 4
	normal.content_margin_right = 4

	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(ink.r * 1.9, ink.g * 1.9, ink.b * 1.9, 0.96)
	hover.border_color = tint

	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(tint.r * 0.42, tint.g * 0.38, tint.b * 0.26, 1.0)
	pressed.border_color = UITheme.BONE   ## R3-09：原内联 (1.0,0.92,0.72) 归表为暖白

	for b in _action_buttons.get_children():
		if not (b is Button):
			continue
		# 圆形按钮：尺寸统一定为 128×128（【R3-04】触控 ≥84px 铁律；2026-09-29 用户
		# 反馈「菜单按钮跟日期重叠、还太小」→ 放大并下移到地图顶部之下，见 tscn ActionButtons）。
		# corner_radius=64 即正圆；ActionButtons 容器不裁剪，按钮底缘略越出容器矩形也正常显示。
		b.custom_minimum_size = Vector2(128.0, 128.0)
		b.add_theme_stylebox_override("normal", normal)
		b.add_theme_stylebox_override("hover", hover)
		b.add_theme_stylebox_override("pressed", pressed)
		b.add_theme_font_size_override("font_size", 40)
		b.add_theme_color_override("font_color", UITheme.BONE)            ## R3-09 归表
		b.add_theme_color_override("font_hover_color", UITheme.BONE.lightened(0.12))
		b.add_theme_color_override("font_pressed_color", UITheme.INK_DEEP)


## 是否有任意全屏/模态界面正在打开。
## 以前这里是 13 段「if xxx.is_open(): halt(); return」的复制粘贴，
## 漏掉一个（随机事件弹窗）就会出现「弹窗开着但人还在跑」的层级错乱。
## 收敛成一张表，新增面板只需往数组里加一项。
##
## 【第五十二轮】改为**成员常量数组 + 去反射**：
## ① 本函数在 _process 里每帧调 2~3 次，旧写法每次都新建一个 13 元素
##    Array _literal_（堆分配 + 拷贝），纯属每帧白白制造垃圾；
## ② `p.has_method("is_open")` 每帧对每个面板做一次反射查询——而全工程
##    13 个面板**全部**实现了 is_open()（已 grep 确认），这个检查恒为真，
##    只是在每帧重复问 Godot「这个对象有这个方法吗」。直接调即可。
## 成员常量在 _ready 后不再重建；若某面板是运行期动态创建的，
## 由 _register_panel() 补登记。
func _any_ui_open() -> bool:
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


var _last_cam_zoom := -1.0   ## 上一帧相机缩放，用于检测变化

func _process(_delta: float) -> void:
	# 【2026-09-28 用户反馈】轮盘打开的面板关闭后 → 回到轮盘菜单。
	# 必须放在 _any_ui_open() 提前 return 之前，否则面板开着时永远轮询不到。
	# 【误弹修复】仅在「面板已关 且 当前没有任何界面打开」时才回菜单：
	# hero_dex 选人时会先关列表再开详情（面板→面板切换），此时不能弹菜单。
	if _wheel_return_panel != null:
		if not is_instance_valid(_wheel_return_panel) or not _wheel_return_panel.visible:
			if not _busy and not _any_ui_open():
				_wheel_return_panel = null
				_menu_wheel.open()
	# 【R1-03】实时记录玩家大地图位置（存档时由此恢复，ZERO=尚无有效位置）
	GameState.last_world_pos = _player.position
	# 小地图底图延迟注入（程序化远景后台生成完毕后补一次）
	if _minimap_sync_next_ms > 0 and Time.get_ticks_msec() >= _minimap_sync_next_ms:
		_minimap_sync_next_ms = 0
		_sync_minimap_terrain()
	# 缩放变化时重新计算区域相机 limit（避免缩放后露白或相机被锁死）
	var cur_zoom := _camera.zoom.x
	if absf(cur_zoom - _last_cam_zoom) > 0.0001:
		_apply_region_camera()
		_last_cam_zoom = cur_zoom

	# 【方向②】行军拖尾：玩家移动时脚下扬起尘烟（粒子留原地，形成行军路径）
	if _march_dust != null and is_instance_valid(_march_dust) and _player != null:
		_march_dust.emitting = _player.is_moving

	# 【三十四轮×5 性能红锁】城池图标 768px / NPC 420px 后，屏外元素必须裁剪
	# （110 城×768px 全进管线 = 填充率爆炸，实测 FPS 30→9）
	_cull_offscreen()

	# 小地图每帧刷新（玩家位置 / 朝向 / 镜头视野框）
	_minimap.update_view(_player.position, _player.facing, _camera)
	# 地形近景细节层 LOD：相机可视矩形 + zoom 一起喂给 painter
	# （【R3-02】zoom 缺传会导致 _cam_zoom 恒 1.0、细节层远观常开——噪声糊满全图）
	_terrain.set_camera_view(_camera_view_rect(), cur_zoom)
	if _big_map != null and _big_map.visible:
		_big_map.update_view(_player.position, _player.facing, _camera)
		if _city_action_btn != null:
			_city_action_btn.hide()
		_player.halt()              # 放大地图打开时冻结移动
		return

	# 任一全屏界面开着时冻结移动（含随机事件弹窗，旧代码漏了它：
	# 弹窗开着时角色仍能走动，玩家一走就走出事件点，回来时事件已消失）。
	if _busy or _any_ui_open():
		if _city_action_btn != null:
			_city_action_btn.hide()
		_player.halt()
		return

	_player.set_move_input(_joystick.output)
	_update_nearby_target()
	# 分区加载：检测是否走到区域边界的邻接区域（越界渐隐切区）
	_check_region_bounds()


## 放大地图覆盖层（懒创建；点任意处关闭）
## 关闭放大版地图：地图与暗色遮罩必须一起隐藏，否则遮罩残留会「半黑屏」且移动已解冻。
## 打开时藏起了左上角小缩略图，关闭时必须还原，否则小地图永久消失。
func _close_big_map() -> void:
	if _big_map != null:
		_big_map.visible = false
		# 复位成局部模式：这样下次打开时 set_mode(MODE_WORLD) 是一次「真切换」，
		# 会重新执行 _recalc_geometry()。否则同值早退，大图会沿用上一次的过期
		# 映射矩阵（表现为内容错位/整片空白，像「地图没了」）。
		_big_map.set_mode(MiniMap.MODE_LOCAL)
	if _map_dim != null:
		_map_dim.visible = false
	if _big_map_title != null:
		_big_map_title.visible = false
	if _big_map_close_hint != null:
		_big_map_close_hint.visible = false
	if _minimap != null:
		_minimap.visible = true


## 关闭请求的统一入口（带输入免疫期）。
## 【为什么需要】项目开了 pointing/emulate_touch_from_mouse：
## 手机/桌面模拟下一次点击会同时投递「鼠标按下」和「模拟触摸按下」两个事件。
## 前者打开大地图 → 全屏遮罩当帧就显示出来；后者紧接着落在遮罩上 →
## 立刻把刚打开的地图关掉。玩家看到的正是「点一下地图，地图闪一下就不见了」。
## 因此打开后的 320ms 内忽略一切关闭请求。
func _request_close_big_map() -> void:
	if Time.get_ticks_msec() - _map_opened_at_ms < MAP_INPUT_GUARD_MS:
		return
	_close_big_map()


## 放大地图顶部居中标题条（对称居中的周边控制 UI）
## 【修复】旧代码用 PRESET_TOP_WIDE（anchor 0→1 横跨全屏）却写了 offset_left=-320/
## offset_right=+320，于是标题条从屏幕左边缘外 320px 一直铺到右边缘外 320px，
## 两个圆角边框被推出屏幕外 —— 表现为「顶部横条排版错乱、边框不见了」。
## 改为 PRESET_CENTER_TOP 中心锚定：宽 640、上边距 64。
## 【2026-09-24 用户反馈】旧 top=26 与顶部 HUD 资源条（0..53px）重叠，
## 「天下地图」字样挡住了顶栏内容；且 520 宽偏窄。现移到 HUD 下方（64..106）并加宽。
func _make_title_bar() -> PanelContainer:
	var bar := PanelContainer.new()
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE   ## 纯展示条，不吞点击（点标题条区域也能操作/关闭地图）
	bar.set_anchors_preset(Control.PRESET_CENTER_TOP)
	bar.offset_left = -320.0
	bar.offset_top = 64.0
	bar.offset_right = 320.0
	bar.offset_bottom = 106.0
	bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(UITheme.CARD_DEEP, 0.82)   ## R3-09：原内联 (0.09,0.08,0.05) 归表
	sb.border_color = Color(UITheme.GOLD_LINE, 0.9)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 18.0
	sb.content_margin_right = 18.0
	bar.add_theme_stylebox_override("panel", sb)
	var lab := Label.new()
	lab.text = "天 下 地 图"
	lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lab.add_theme_font_size_override("font_size", 30)
	lab.add_theme_color_override("font_color", UITheme.GOLD)
	lab.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	lab.add_theme_constant_override("shadow_offset_x", 1)
	lab.add_theme_constant_override("shadow_offset_y", 1)
	bar.add_child(lab)
	return bar


## 放大地图底部居中「操作提示」条（对称居中的周边控制 UI）
## 【2026-09-24】放大地图已支持拖动/缩放（minimap 内置手势 + 右上角按钮），
## 提示文案从「点击任意处关闭」改为完整操作说明。
func _make_close_hint() -> PanelContainer:
	var bar := PanelContainer.new()
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE   ## 纯展示条，不吞点击
	bar.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	bar.offset_left = -280.0
	bar.offset_top = -64.0
	bar.offset_right = 280.0
	bar.offset_bottom = -26.0
	bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(UITheme.INK_DEEP, 0.70)   ## R3-09：原内联 (0.05,0.05,0.04) 归表
	sb.set_corner_radius_all(9)
	sb.content_margin_left = 14.0
	sb.content_margin_right = 14.0
	bar.add_theme_stylebox_override("panel", sb)
	var lab := Label.new()
	lab.text = "拖动查看地图 · ＋/－ 缩放 · 轻点地图关闭"
	lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lab.add_theme_font_size_override("font_size", UITheme.FS_MARKER_NOTE)
	lab.add_theme_color_override("font_color", UITheme.TEXT)   ## R3-09 归表
	lab.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	lab.add_theme_constant_override("shadow_offset_x", 1)
	lab.add_theme_constant_override("shadow_offset_y", 1)
	bar.add_child(lab)
	return bar


## 放大地图右上角缩放控制（＋ / － / 复位）。
## 挂在 _big_map 内部：随地图一起显隐，位置锚在地图右上角内侧
## （避开顶部标题条与右下角关闭提示，也不与拖动手势冲突）。
func _make_big_map_zoom_controls() -> VBoxContainer:
	var box := VBoxContainer.new()
	box.name = "ZoomBox"
	box.add_theme_constant_override("separation", 14)
	box.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	box.offset_left = -122.0
	box.offset_right = -26.0
	box.offset_top = 22.0
	box.grow_vertical = Control.GROW_DIRECTION_END
	var defs := [
		["＋", func(): _big_map.zoom_in()],
		["－", func(): _big_map.zoom_out()],
		["◎", func(): _big_map.reset_view()],
	]
	for d in defs:
		var b := Button.new()
		b.text = str(d[0])
		b.custom_minimum_size = Vector2(96, 84)   ## 触控目标 ≥84px
		b.add_theme_font_size_override("font_size", 34)
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.09, 0.08, 0.05, 0.88)
		sb.border_color = Color(UITheme.GOLD_LINE, 0.95)
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(12)
		b.add_theme_stylebox_override("normal", sb)
		var sb_h := sb.duplicate() as StyleBoxFlat
		sb_h.bg_color = Color(0.26, 0.22, 0.13, 0.95)
		b.add_theme_stylebox_override("hover", sb_h)
		b.add_theme_stylebox_override("pressed", sb_h)
		b.add_theme_color_override("font_color", UITheme.GOLD)
		b.add_theme_color_override("font_pressed_color", Color(1.0, 0.95, 0.8))
		var cb: Callable = d[1]
		b.pressed.connect(cb)
		box.add_child(b)
	return box


func _show_big_map() -> void:
	AudioManager.sfx_click()
	if _big_map == null:
		_big_map = MiniMap.new()
		# 【固定尺寸弹窗】放大地图不再全屏铺满，改为居中弹出的固定比例面板
		# （约屏幕 3/4 大小），与所有菜单/交易面板统一规范，避免忽大忽小。
		_big_map.expanded = true   ## 放大版：羊皮纸亮色高对比渲染
		_big_map.set_anchors_preset(Control.PRESET_CENTER)
		# 宽高取视口的 75%，上下各留约 12.5% 边距，视觉居中且不贴边
		_big_map.offset_left = -get_viewport().get_visible_rect().size.x * 0.375
		_big_map.offset_top = -get_viewport().get_visible_rect().size.y * 0.375
		_big_map.offset_right = get_viewport().get_visible_rect().size.x * 0.375
		_big_map.offset_bottom = get_viewport().get_visible_rect().size.y * 0.375
		var dim := ColorRect.new()
		dim.color = Color(0.03, 0.03, 0.04, 0.72)
		dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)   ## 全屏遮罩同样不写死像素尺寸
		dim.mouse_filter = Control.MOUSE_FILTER_STOP
		dim.gui_input.connect(func(e: InputEvent):
			if (e is InputEventMouseButton and (e as InputEventMouseButton).pressed) \
			or (e is InputEventScreenTouch and (e as InputEventScreenTouch).pressed):
				_request_close_big_map())
		_big_map.expand_requested.connect(_request_close_big_map)
		var ui: CanvasLayer = $UI
		ui.add_child(dim)
		ui.add_child(_big_map)
		_map_dim = dim
		dim.name = "MapDim"
		# —— 周边控制 UI：顶部标题条 + 底部操作提示（居中对称）——
		_big_map_title = _make_title_bar()
		_big_map_close_hint = _make_close_hint()
		ui.add_child(_big_map_title)
		ui.add_child(_big_map_close_hint)
		# —— 缩放控制（＋/－/复位）：挂在放大地图内部右上角，随地图显隐 ——
		_big_map.add_child(_make_big_map_zoom_controls())
	# 关键：必须走 set_mode 触发 _recalc_geometry，否则视图仍是「局部」几何。
	# 注意：这里不要提前直接给 view_mode 赋值，否则 set_mode 会因「同值」提前 return。
	_big_map.set_mode(MiniMap.MODE_WORLD)
	# 每次打开复位到整图视野：上一次拖走/放大后的窗口不再残留
	# （与 set_mode 的「复位成局部」同理由 —— 保证打开状态确定）。
	_big_map.reset_view()
	_big_map.update_view(_player.position, _player.facing, _camera)
	# 【地貌同步】放大地图也用大地图地貌纹理作底图
	if _terrain != null:
		_big_map.set_terrain_tex(_terrain._get_minimap_tex())
	_big_map.visible = true
	_map_dim.visible = true
	if _big_map_title != null:
		_big_map_title.visible = true
	if _big_map_close_hint != null:
		_big_map_close_hint.visible = true
	# 打开全国大地图时，藏起左上角小缩略图，避免两者重叠透叠影响观感。
	# 必须每次打开都执行 —— 旧代码写在 if _big_map == null 里，第二次打开就漏了，
	# 小地图会盖在大地图上，看起来像「元素重复显示」。
	if _minimap != null:
		_minimap.visible = false
	_map_opened_at_ms = Time.get_ticks_msec()
	# 盖在最后，保证在最上层
	_big_map.get_parent().move_child(_big_map, _big_map.get_parent().get_child_count() - 1)
	# 打开瞬间停一步（后续帧由 _process 冻结）
	_player.halt()


# ------------------------------------------------------------------
# 分区加载（Region Window）
# ------------------------------------------------------------------

## 把相机锁定到整张天下地图（全国连续行走后，相机永远跟随玩家，
## 只在世界边缘收住 —— 不再按区域窗口钳制，玩家走到哪镜头跟到哪）。
## 【视角跟随修复】Camera2D 的 limit 约束的是「视口边缘」能到达的世界坐标，
## 不是相机中心。旧代码把「中心活动范围」当 limit 写：
## limit_left = rect.x + half*0.9 → 视口左缘被强行推进区域内部 ~1800px，
## 玩家出生/行走在区域边缘（城池多贴边）时相机被钳在区域中部，
## 主角直接消失在屏幕外 —— 表现为「视角固定在小地图那个白框里，
## 人必须走进框里才看得见」。正确写法：limit 就是全图矩形。
func _apply_region_camera() -> void:
	var world := _terrain.get_map_size()
	if world.x <= 0.0 or world.y <= 0.0:
		return
	_camera.limit_left = 0
	_camera.limit_top = 0
	_camera.limit_right = int(world.x)
	_camera.limit_bottom = int(world.y)
	# HUD 显示当前区域名（多区域适配）
	if _hud != null and _hud.has_method("update_region"):
		_hud.update_region(GameState.current_region)


## 每帧判定：玩家位置落在哪个古州矩形 → 原地切换所属游戏区域。
## 【无缝切区】不再 SceneRouter 渐隐重载（黑屏过渡），只更新区域归属与
## 遭遇物分布；城池标记/NPC 全国常驻，无需重建。
func _check_region_bounds() -> void:
	var target := _resolve_game_region_at(_player.position)
	if not target.is_empty() and target != GameState.current_region:
		_enter_region_in_place(target)


## 位置命中哪个古州矩形 → 返回其所属游戏区域 id；都不命中返回 ""（保持现状）。
func _resolve_game_region_at(pos: Vector2) -> String:
	for gr_node in RegionService.GAME_REGIONS:
		var gr := str(gr_node)
		for code_node in (RegionService.GAME_REGIONS[gr_node] as Array):
			if RegionService.guizhou_rect(str(code_node)).has_point(pos):
				return gr
	return ""


## 原地进入新区域：更新归属、解锁、HUD 与遭遇分布，不重载场景。
func _enter_region_in_place(target: String) -> void:
	if target.is_empty() or target == GameState.current_region:
		return
	GameState.current_region = target
	if not GameState.unlocked_regions.has(target):
		GameState.unlocked_regions.append(target)
	show_toast("进入「%s」" % RegionService.region_name(target))
	if _hud != null and _hud.has_method("update_region"):
		_hud.update_region(target)
	# 【城池重建·关键】城池 marker 只在场景加载时按"当时的区域"生成过一次。
	# 全国无缝行走后场景不再重载，走出初始州就进入一片没有 marker 的无城之地
	# —— 用户观感是「所有城池在大地图中都消失了」（小地图直接读全量表所以照常显示）。
	_rebuild_city_markers()
	if _encounters != null and _encounters.has_method("reload_region"):
		_encounters.reload_region()


## 按当前区域重建城池标记（原地切区专用）。
## 旧 marker 先 remove_child 再 queue_free：同帧内 _find_nearest_place 等
## 遍历者不会再摸到过期节点（queue_free 是帧末释放，直接挂着的旧城会残留一帧）。
func _rebuild_city_markers() -> void:
	for c in _city_markers.get_children():
		_city_markers.remove_child(c)
		c.queue_free()
	_spawn_city_markers()


## 撞到地图边界的反馈（C4）。
## 全国连续行走后，只有天下最外缘会撞墙；若前方接壤的区域尚未走过，
## 提示再走几步能进哪儿。
func _on_bounds_blocked(dir: Vector2) -> void:
	var probe := _player.position + dir.normalized() * 260.0
	var target := _resolve_game_region_at(probe)
	if not target.is_empty() and target != GameState.current_region:
		show_toast("再往前便是「%s」" % RegionService.region_name(target))
		return
	show_toast("前方已是天下边界")


func _unhandled_input(event: InputEvent) -> void:
	# 返回键 / Esc：打开放大地图时优先关闭它（遮罩与地图一并隐藏）
	if event.is_action_pressed('ui_cancel'):
		if _big_map != null and _big_map.visible:
			_close_big_map()
			get_viewport().set_input_as_handled()


## 每帧找出「当前最该交互的对象」，让菜单贴着它显示
func _update_nearby_target() -> void:
	# 常驻按钮：被弹窗/大地图隐藏后每帧拉回（交互菜单开着时除外）
	if _city_action_btn != null and not _menu.is_open():
		_city_action_btn.show()
	var best: Dictionary = {}
	var best_pos := Vector2.ZERO
	var best_dist := INF
	_enc_target_node = null

	# 1) NPC 优先（人比建筑更需要即时交互）
	var npc := _npcs.get_nearby_npc()
	if not npc.is_empty():
		best = {
			"type": "npc",
			"id": str(npc.get("id", "")),
			"name": str(npc.get("name", "")),
			"title": _npc_title(npc),
			"tags": npc.get("tags", []),
			"data": npc,
		}
		best_pos = _npcs.get_nearby_npc_pos()
		best_dist = 0.0

	# 2) 城池/地点
	if best.is_empty():
		var city_hit := _find_nearest_place()
		if not city_hit.is_empty():
			best = city_hit["target"]
			best_pos = city_hit["pos"]
			best_dist = city_hit["dist"]

	# 3) 非战斗遭遇（采集/宝箱/商队/奇遇）：走近亮「▲ 可交互」，
	#    点交互按钮弹菜单手动触发（2026-09-24 用户拍板：不再走近自动结算）
	if best.is_empty():
		var enc := _encounters.nearest_interactable(_player.global_position)
		if not enc.is_empty():
			var edef: Dictionary = enc["def"]
			var enode: Node2D = enc["node"]
			best = {
				"type": "encounter",
				"id": str(enc["id"]),
				"name": str(edef.get("name", "遭遇")),
				"title": str(ENC_TYPE_CN.get(str(edef.get("type", "")), "遭遇")),
				"tags": [],
				"data": edef,
			}
			best_pos = enode.global_position
			best_dist = float(enc["dist"])
			_enc_target_node = enode

	# 把「贴脸菜单是否已弹出」同步给 NPC 管理器：
	# 菜单弹出后要收起 NPC 头顶的「▲ 对话」与气泡，否则同一屏出现两套提示 = 重复显示。
	_npcs.menu_open = _menu.is_open()

	if best.is_empty():
		_menu.hide_menu()
		_city_target = {}
		_city_target_pos = Vector2.ZERO
		_menu_target_id = ""
		if _city_action_btn != null:
			_city_action_btn.text = ""   ## 动词随目标走：无目标复位为空心圆环
		_set_highlight(null)   ## 【R3-05】无可交互对象：放大复位
		_update_select_pulse(null)   ## 方向②：清城池选中脉冲
		return   # 按钮常驻：无目标时保持显示，点击给提示

	# 【统一交互按钮】城池/地点/NPC 都走右下角圆形按钮：点按才弹交互菜单。
	# 旧设计 NPC 走贴脸自动菜单、城池走右侧按钮 —— 两套交互并存，
	# 手机上贴脸菜单位置飘忽且会挡住视线；固定拇指位（摇杆对端）更符合直觉。
	var key := "%s:%s" % [str(best.get("type", "")), str(best.get("id", ""))]
	if _menu.is_open():
		if key == _menu_target_id:
			return   # 菜单已因该目标打开：保持现状（按钮保持隐藏）
		_menu.hide_menu()   # 走近了另一个目标：收起旧菜单，按钮切到新目标
	_city_target = best
	_city_target_pos = best_pos
	_menu_target_id = key
	# 【2026-09-28 用户反馈】非战斗遭遇不再弹交互菜单：按钮文字直接变成动作
	# （采集/垂钓/交流/开箱），点按直接触发；城池/NPC 仍走菜单（选项多）。
	if _city_action_btn != null:
		_city_action_btn.text = _encounter_verb(best) if str(best.get("type", "")) == "encounter" else ""
	# 【R3-05】交互放大：可交互对象（NPC/遭遇）整体 ×1.25 补间，城池不动
	var hl: Node2D = null
	if str(best.get("type", "")) == "encounter":
		hl = _enc_target_node
	elif str(best.get("type", "")) == "npc":
		hl = _npcs.get_node_or_null("NPC_" + str(best.get("id", ""))) as Node2D
	_set_highlight(hl)
	# 【方向②】城池选中脉冲：城池此前无任何选中视觉反馈（只有 Hint 文字），
	# 脚下挂一圈暖光涌动提示「可进入」。NPC/遭遇走 _set_highlight 放大，不在此列。
	# 【方向②】城池选中脉冲：best 是 Dictionary（来自 _find_nearest_place 的 target），
	# 不能用 `best as Node2D`（非法 cast），须用 city id 取 marker 节点。
	if str(best.get("type", "")) == "city":
		var cid := str(best.get("id", ""))
		var marker: Node2D = _city_markers.get_node_or_null("Marker_" + cid) as Node2D
		_update_select_pulse(marker)
	else:
		_update_select_pulse(null)
	if _city_action_btn != null:
		_city_action_btn.show()


## 遭遇类型 → 按钮动词（垂钓是 gather 的特例：quest_event == "fish"）
func _encounter_verb(target: Dictionary) -> String:
	var def: Dictionary = target.get("data", {})
	match str(def.get("type", "")):
		"gather":
			return "垂钓" if str(def.get("quest_event", "")) == "fish" else "采集"
		"treasure":
			return "开箱"
		"merchant":
			return "交流"
		"event":
			return "查看"
	return "交互"


## 【R3-05】交互对象放大高亮：目标 ×1.25（0.15s 补间），离开复位 ×1.0。
## 作用于整个 Node2D（含金轮廓/提示），不改 position，不影响交互判定距离。
func _set_highlight(node: Node2D) -> void:
	if node == _hl_node:
		return
	if not is_instance_valid(_hl_node):
		_hl_node = null
	if _hl_tween != null and _hl_tween.is_valid():
		_hl_tween.kill()
	_hl_tween = create_tween().set_parallel(true)
	if _hl_node != null:
		_hl_tween.tween_property(_hl_node, "scale", Vector2.ONE, 0.15)
	_hl_node = node
	if _hl_node != null:
		_hl_tween.tween_property(_hl_node, "scale", Vector2(1.25, 1.25), 0.15)


## 大地图演出（方向②）：行军拖尾（玩家脚下尘土）+ 城池选中脉冲（脚下暖光涌动）。
## 零生图、零新美术资源，与战斗/城内扬尘风格统一。粒子留原地→玩家移动时脚下尘烟连成路径。
func _build_world_atmos() -> void:
	if _player == null:
		return
	_march_dust = CPUParticles2D.new()
	_march_dust.name = "MarchDust"
	_march_dust.emitting = false
	_march_dust.amount = WORLD_MARCH_DUST_AMOUNT
	_march_dust.lifetime = 0.7
	_march_dust.direction = Vector2(0.0, -1.0)
	_march_dust.spread = 42.0
	_march_dust.initial_velocity_min = 6.0
	_march_dust.initial_velocity_max = 22.0
	_march_dust.gravity = Vector2(0.0, -2.0)
	_march_dust.scale_amount_min = 0.30
	_march_dust.scale_amount_max = 0.85
	_march_dust.color = Color(0.78, 0.70, 0.54, WORLD_MARCH_DUST_ALPHA)
	_march_dust.position = Vector2(0.0, 24.0)
	_march_dust.emission_shape = 2   # CPUParticles2D.EMISSION_SHAPE_BOX
	_march_dust.emission_rect_extents = Vector2(36.0, 22.0)
	_player.add_child(_march_dust)

## 城池选中脉冲：选中目标为城池时，在其脚下挂一圈暖光涌动 CPU 粒子（呼吸透明度），
## 提示「此城可进入」。不碰 marker 的 scale（放大由 _set_highlight 管，且城池不参与放大），
## 也不影响交互判定距离。marker 随 _rebuild_city_markers 销毁时，子节点一并释放。
func _update_select_pulse(marker: Node2D) -> void:
	if _sel_pulse_marker != null and not is_instance_valid(_sel_pulse_marker):
		_sel_pulse_marker = null
		_sel_pulse = null
	if marker == _sel_pulse_marker:
		return
	if _sel_pulse != null and is_instance_valid(_sel_pulse):
		_sel_pulse.queue_free()
		_sel_pulse = null
	if _sel_pulse_tween != null and _sel_pulse_tween.is_valid():
		_sel_pulse_tween.kill()
	_sel_pulse_marker = marker
	if marker == null or not is_instance_valid(marker):
		return
	var pulse := CPUParticles2D.new()
	pulse.name = "SelectPulse"
	pulse.emitting = true
	pulse.amount = SELECT_PULSE_AMOUNT
	pulse.lifetime = 1.1
	pulse.direction = Vector2(0.0, -1.0)
	pulse.spread = 30.0
	pulse.initial_velocity_min = 4.0
	pulse.initial_velocity_max = 14.0
	pulse.gravity = Vector2(0.0, -3.0)
	pulse.scale_amount_min = 0.45
	pulse.scale_amount_max = 1.10
	pulse.color = Color(1.0, 0.82, 0.46, SELECT_PULSE_ALPHA)
	pulse.position = Vector2(0.0, 18.0)
	pulse.emission_shape = 2   # CPUParticles2D.EMISSION_SHAPE_BOX
	pulse.emission_rect_extents = Vector2(52.0, 18.0)
	marker.add_child(pulse)
	_sel_pulse = pulse
	# 呼吸：透明度在 [MIN, 1.0] 间循环，制造"脉冲"提示
	_sel_pulse_tween = create_tween().set_loops()
	_sel_pulse_tween.tween_property(pulse, "modulate:a", SELECT_PULSE_MIN, SELECT_PULSE_PERIOD)
	_sel_pulse_tween.tween_property(pulse, "modulate:a", 1.0, SELECT_PULSE_PERIOD)


func _npc_title(npc: Dictionary) -> String:
	var t := str(npc.get("title", ""))
	if not t.is_empty():
		return t
	match str(npc.get("npc_type", "")):
		"elder": return "长者"
		"official": return "官吏"
		"merchant": return "商人"
		"hero": return "武将"
		"youth": return "少年"
	return ""


# ------------------------------------------------------------------
# 地点交互判定（C1）
# ------------------------------------------------------------------
## 【为什么不能只算「中心点距离」】
## 城池在世界里是有占地的：都城图标约 150px 宽，小村寨不到 70px。
## 旧写法 `d < 130.0` 一刀切，于是——
##   · 都城：玩家明明站在城墙根下（中心点距离 140）却弹不出菜单；
##   · 村寨：隔着一条街（130）菜单就糊上来了，且常常是隔壁那个更大的城被选中。
## 现在改为：**到城池「边缘」的距离** = 中心点距离 − 该地点的占地半径，
## 再叠加「屏幕内优先 / 朝着走优先」两级排序，杜绝误选。

## 各类地点的世界占地半径（与 CityMarkerArt 的图标尺度对齐）
## 【三十五轮微调】×2.5：交互半径随档
const PLACE_RADIUS := {
	"city": 155.0, "capital": 195.0, "village": 115.0, "pass": 125.0,
	"ruin": 115.0, "landmark": 135.0,
}
const PLACE_RADIUS_FALLBACK := 145.0
const PLACE_LEVEL_STEP := 15.0         ## 城池等级每 +1，占地半径 +15
const PLACE_TOUCH_SLACK := 180.0       ## 边缘外的宽容余量（随档联动）
const PLACE_OFFSCREEN_PENALTY := 1200.0  ## 屏幕外候选重罚（避免"弹远处的城"）
const PLACE_FACING_BONUS := 18.0       ## 正朝着走的地点加权（同距时按玩家意图选）
## 【#67】收复军来袭时判定「玩家算不算赶回来了」的距离阈值：
## 比交互触发半径（PLACE_TOUCH_SLACK 72）宽得多 —— 兵临城下隔着一段就该问，
## 否则玩家几乎不可能恰好站在城门口才会被提示，观感就是「莫名其妙丢城」。
const RETAKE_PROMPT_RANGE := 1050.0   ## 【三十四轮×5】随交互半径联动


## 某地点在世界中的占地半径
func _place_radius(marker: Node2D) -> float:
	var t := str(marker.get_meta("city_type", "city"))
	var r := float(PLACE_RADIUS.get(t, PLACE_RADIUS_FALLBACK))
	var data: Dictionary = marker.get_meta("city_data", {})
	if t == "city":
		r += PLACE_LEVEL_STEP * maxi(int(marker.get_meta("city_level", 1)), 1)
		if bool(data.get("is_capital", false)):
			r = maxf(r, float(PLACE_RADIUS["capital"]))
	return r


## 当前镜头在世界坐标下的可视矩形（用于剔除屏幕外的误判候选）
func _camera_view_rect() -> Rect2:
	var z := maxf(_camera.zoom.x, 0.001)
	var half := get_viewport_rect().size * 0.5 / z
	var c := _camera.global_position
	return Rect2(c - half, half * 2.0)


## 把当前镜头离心的内容全部隐藏 Hint
func _hide_all_place_hints() -> void:
	for marker in _city_markers.get_children():
		var hint := marker.get_node_or_null("Hint")
		if hint and hint is CanvasItem:
			hint.visible = false


## 找出当前最该交互的地点：
## 先看「有没有进入半径」，再按 score 排序（屏幕内 > 朝着走 > 离边缘更近）。
func _find_nearest_place() -> Dictionary:
	# 【天下视图禁用交互】缩到最小（天下全景）时只看地图，不触发任何城池/NPC 交互，
	# 避免玩家在全景模式下误触「进入/查看详情」。
	# 全景下必须把所有提示收起 —— 否则从近景切到全景后 "▲ 进入" 会残留在屏幕上。
	if _player.is_zoomed_out():
		# 全景下只收起「▲ 进入」提示（提示太多眼花），
		# 但**不再禁用交互**——交互菜单靠右下按钮显式点按，全景下无误触问题；
		# 旧逻辑直接 return {}，全景走近城池点按钮永远「无目标」，用户观感即
		# 「在地图行走有些交互不上」。
		_hide_all_place_hints()

	var view := _camera_view_rect()
	var best_node: Node2D = null
	var best: Dictionary = {}
	var best_pos := Vector2.ZERO
	var best_dist := INF
	var best_score := INF

	var candidates: Array = []
	for marker in _city_markers.get_children():
		if not (marker is Node2D):
			continue
		# 显式用 global_position：marker 挂在 CityMarkers 下，
		# 以世界坐标做距离判定，即便将来给该节点加 transform 也不会算错。
		var d := _player.global_position.distance_to(marker.global_position)
		var edge := d - _place_radius(marker)
		if edge > PLACE_TOUCH_SLACK:
			continue
		var score := maxf(edge, 0.0)
		if not view.has_point(marker.global_position):
			# 屏幕外：玩家根本看不见它，却被引想去交互 —— 明确排除
			score += PLACE_OFFSCREEN_PENALTY
		elif d > 1.0:
			# 屏幕内才考虑行走意图：朝着哪个城走就优先哪个
			var dir: Vector2 = (marker.global_position - _player.global_position).normalized()
			score -= PLACE_FACING_BONUS * maxf(0.0, dir.dot(_player.facing))
		candidates.append({ "node": marker, "pos": marker.global_position, "dist": d, "score": score })
		if score < best_score or (absf(score - best_score) < 1.0 and d < best_dist):
			best_score = score
			best_dist = d
			best_node = marker
			best_pos = marker.global_position

	# 提示只在「最终选中的那个地点」上方显示。
	# 旧写法对每个进入范围的地点都开 Hint，两个城挨着时会同时冒出两串「▲ 进入」。
	for c in candidates:
		var hint := (c["node"] as Node2D).get_node_or_null("Hint")
		if hint and hint is CanvasItem:
			hint.visible = (c["node"] == best_node) and not _menu.is_open()

	if best_node == null:
		return {}
	best = {
		"type": str(best_node.get_meta("city_type", "city")),
		"id": str(best_node.get_meta("city_id", "")),
		"name": str(best_node.get_meta("city_name", "")),
		"title": str(best_node.get_meta("city_title", "")),
		"tags": best_node.get_meta("city_tags", []),
		"data": best_node.get_meta("city_data", {}),
	}
	# 【#66】己方城池改出「治理」菜单（不再显示攻取自己的城）：
	# 选项列表走 interaction_menu.json 的 owned_city_items，不在代码里硬编码。
	if GameState.captured_cities.has(str(best.get("id", ""))):
		var owned: Array = DataManager.get_record("interaction_menu", "root").get("owned_city_items", [])
		if not owned.is_empty():
			best["items"] = owned
	# 【#67】兵临城下的己方城：走近了就自动问「迎战 / 弃城」，不必等下个月结算
	_maybe_prompt_retake(str(best.get("id", "")))
	return { "target": best, "pos": best_pos, "dist": best_dist }


func _on_joystick_changed(_value: Vector2) -> void:
	pass


# ------------------------------------------------------------------
# 行动分发：菜单选项 → 具体行为
# ------------------------------------------------------------------

func _on_menu_action(action: String, target: Dictionary) -> void:
	match action:
		"talk", "info":
			# 按用户设计：靠近后的「对话 / 查看详情」都进独立面板，
			# 在面板里再选对话 / 交易 / 送礼 / 结交
			_open_detail(target)
		"talk_to":
			# 面板内的「对话」按钮 → 正式对话，结束后回到面板
			_start_dialogue(target)
		"info_detail":
			_show_info(target)
		"trade":
			_open_trade(target)
		"recruit":
			_do_recruit(target)
		"gift":
			_do_gift(target)
		"spar":
			_do_spar(target)
		"quest":
			_start_dialogue(target)
		"enter":
			_enter_place(target)
		"explore":
			_do_explore(target)
		"cross":
			_do_cross(target)
		"attack":
			_do_attack(target)
		"govern":
			_open_govern(target)
		"interact":
			# 非战斗遭遇手动触发（采集/宝箱/商队/奇遇）
			_do_encounter(target)
		_:
			show_toast("尚未实装：%s" % action)


## 手动触发非战斗遭遇（encounter_manager 的采集/宝箱/商队/事件结算入口）
func _do_encounter(_target: Dictionary) -> void:
	if _enc_target_node == null or not is_instance_valid(_enc_target_node):
		show_toast("目标已消失。")
		return
	var node := _enc_target_node
	_enc_target_node = null
	_encounters.trigger_encounter(node)


func _start_dialogue(target: Dictionary) -> void:
	var data: Dictionary = target.get("data", {})
	# 【NPC 记忆性 2026-09-29】按任务状态分流：进行中问进度 / 达成催交差 / 否则初见。
	var root := DialogueService.entry_node(data)
	if root.is_empty():
		show_toast("他没什么想说的。")
		return
	_panel.close_silently()
	_panel_target = target
	_busy = true
	# 立绘 key：NPC 用字符串 id，武将用 heroes6 的数字 id（role_id）
	_dialogue.portrait_key = _portrait_key_of(data)
	_dialogue.talker_id = str(data.get("id", ""))
	_dialogue.start(root)


## 直接按对话 id 打开（开场剧情/剧情演出用，无 target 实体）。
## 空闲时由 _ready 的开场判定或剧情调度调用；结束回调 _on_dialogue_finished 复位 _busy。
func _start_dialogue_by_id(d_id: String) -> void:
	if _busy:
		return
	_panel.close_silently()
	_panel_target = {}
	_busy = true
	_dialogue.portrait_key = ""   # 旁白无立绘，回退首字占位
	_dialogue.talker_id = ""      # 旁白/剧情演出不计 NPC 交谈
	_dialogue.start(d_id)


## 延时播放剧情旁白；若到点仍在播放其它对话（_busy），入队等播完接播。
func _queue_narration(d_id: String, delay: float) -> void:
	var t := get_tree().create_timer(delay)
	t.timeout.connect(func():
		# 【freed 防护】延时期间场景可能已被释放（切场景/读档），先验自身再播
		if not is_instance_valid(self) or not is_inside_tree():
			return
		if _busy:
			_narration_queue.append(d_id)
		else:
			_start_dialogue_by_id(d_id))


## 取对话立绘用的资源 key。武将走 role_id（数字 id），NPC 走 id。
## 都没有则回退到谈话人名字（DialogueUI 内部会再试一次）。
func _portrait_key_of(data: Dictionary) -> String:
	var rid := str(data.get("role_id", ""))
	if not rid.is_empty() and rid != "0":
		return rid
	return str(data.get("id", ""))


func _open_detail(target: Dictionary) -> void:
	_panel_target = target
	_menu.hide_menu()
	_panel.open(target)


func _show_info(target: Dictionary) -> void:
	# 【B15】详情改走 CharacterPanel 面板（可停留回看），不再拼串走 7.6s 即逝 toast。
	# target 与 _open_detail 同构（name/title/data.description/lore/hero_id），
	# 面板内 _refresh_npc / _refresh_place 已含四维与描述展示。
	_panel_target = target
	_menu.hide_menu()
	_panel.open(target)


func _open_trade(target: Dictionary) -> void:
	var data: Dictionary = target.get("data", {})
	if not str(data.get("shop_table", "")).is_empty() or not data.is_empty():
		# NPC 背包交易：打开交易面板（货单来自 npc_stock.json，按 NPC 身份匹配）
		_menu.hide_menu()
		_panel.close_silently()
		_trade.open(data)
	else:
		show_toast("%s：「我没什么可卖的。」" % str(target.get("name", "")))


func _do_recruit(target: Dictionary) -> void:
	var data: Dictionary = target.get("data", {})
	var hero_id := str(data.get("hero_id", ""))
	if hero_id.is_empty():
		hero_id = str(data.get("character_id", ""))
	if hero_id.is_empty():
		show_toast("此人暂不可招募。")
		return

	# 找到招募池里对应的条目（含难度/额外金钱等门槛）
	var entry := CharacterService.find_recruit_entry(hero_id)
	if entry.is_empty():
		show_toast("%s：「我暂不打算出山。」" % str(target.get("name", "")))
		return

	# 走 CityService 的统一规则（门槛校验 + 扣钱 + 入队 + 信号广播）
	var svc := CityService.new()
	var check := svc.can_recruit_hero(entry)
	if not bool(check.get("ok", false)):
		show_toast(str(check.get("reason", "无法招募")))
		return
	var r := svc.recruit_hero(entry)
	show_toast(str(r.get("msg", "")))


func _do_gift(target: Dictionary) -> void:
	show_toast("送礼界面待实装（可赠之物见 items.json 的 gift 类）")


## 切磋：复用战前单挑 UI（三择相克），只论名声胜负，不动兵力。
func _do_spar(target: Dictionary) -> void:
	var hero := _spar_hero_of(target)
	if hero.is_empty():
		show_toast("%s 不愿与你动手。" % str(target.get("name", "此人")))
		return
	var champs := DuelService.champions()
	if champs.is_empty():
		show_toast("你尚无法出阵。")
		return
	_spar_target_name = str(hero.get("name", ""))
	_busy = true
	_spar_popup.open(champs[0], hero)


## 解析切磋对手：role_id（heroes6 数字 id）优先，其次 hero_id/character_id（legacy）
func _spar_hero_of(target: Dictionary) -> Dictionary:
	var data: Dictionary = target.get("data", {})
	var rid := int(data.get("role_id", 0))
	if rid > 0:
		var h := DataManager.get_hero6(rid)
		if not h.is_empty():
			return {
				"id": str(rid), "name": str(h.get("name", "")),
				"force": clampi(int(h.get("force", 50)), 1, 100),
			}
	var hid := str(data.get("hero_id", ""))
	if hid.is_empty():
		hid = str(data.get("character_id", ""))
	if not hid.is_empty():
		var h2 := DataManager.get_hero_resolved(hid)
		if not h2.is_empty():
			return {
				"id": hid, "name": str(h2.get("name", "")),
				"force": clampi(int(h2.get("force", 50)), 1, 100),
			}
	return {}


## 切磋结算：仅名声奖励，不影响兵力与存档部队
func _on_spar_finished(outcome: String) -> void:
	_busy = false
	match outcome:
		"win":
			GameState.add_fame(1)
			show_toast("切磋获胜！你与 %s 惺惺相惜（名声 +1）" % _spar_target_name)
		"lose":
			show_toast("切磋落败，%s 拱手道：「承让。」" % _spar_target_name)
		_:
			show_toast("与 %s 打成平手，各自收招。" % _spar_target_name)


func _enter_place(target: Dictionary) -> void:
	if str(target.get("id", "")).is_empty():
		return
	_panel.close_silently()
	_busy = true
	# 记录进城前的位置：出城后回到城门口原地
	GameState.return_scene = "world"
	GameState.return_pos = _player.position
	GameState.current_city_id = str(target.get("id", ""))
	# 抵达类任务记账：城池可在 cities.json 用 visit_target 声明任务地点 id
	var city_rec: Dictionary = DataManager.get_record("cities", GameState.current_city_id)
	# 造访记录（成就 travel_10 依赖）：首次到访某城时记账
	GameState.visited_cities[GameState.current_city_id] = true
	var visit_target := str(city_rec.get("visit_target", ""))
	if not visit_target.is_empty():
		QuestService.record_event("reach", visit_target)
	AchievementService.check_all()
	EventBus.city_entered.emit(GameState.current_city_id)
	SceneRouter.push_scene("city")


func _do_explore(target: Dictionary) -> void:
	show_toast("探索 %s……（待实装）" % str(target.get("name", "")))


func _do_cross(target: Dictionary) -> void:
	show_toast("渡口 %s —— 需水军相助。（待实装）" % str(target.get("name", "")))


## 攻城（#64）：原为此处占位桩（只弹「待实装」），现接上真正的攻城流程。
## 规则判定与守军编制全部走 CityService（数据驱动），本层只负责组装遭遇并发兵。
func _do_attack(target: Dictionary) -> void:
	var cid := str(target.get("id", ""))
	var city := DataManager.get_city(cid)
	if city.is_empty():
		city = target
	var svc := CityService.new()
	var chk := svc.can_siege(city)
	if not bool(chk.get("ok", false)):
		show_toast(str(chk.get("reason", "此时不可攻打。")))
		return
	var defense := int(city.get("defense", 10))
	# 组装成一场「攻城战」遭遇：复用遭遇战 → 布阵 → 战斗的既有链路
	GameState.current_encounter = {
		"id": "siege_%s" % cid,
		"name": "攻打%s" % str(city.get("name", "此地")),
		"type": "battle",
		"enemy_units": svc.garrison_units(city),
		"siege_city_id": cid,
		"rewards": svc.siege_rewards(city),
		"description": "守军 %d 人据城而守，城防 %d。" % [
			_garrison_total(svc.garrison_units(city)), defense],
	}
	# 记下战斗前位置：打完回原地而不是出生点
	GameState.return_scene = "world"
	GameState.return_pos = _player.position
	_busy = true
	SceneRouter.push_scene("formation")


func _garrison_total(units: Array) -> int:
	var n := 0
	for u in units:
		if u is Dictionary:
			n += int(u.get("count", 0))
	return n


## 治理面板入口（#66）：己方城池的「治理」菜单项
func _open_govern(target: Dictionary) -> void:
	var cid := str(target.get("id", ""))
	if cid.is_empty():
		cid = str(target.get("data", {}).get("id", ""))
	if not GameState.captured_cities.has(cid):
		show_toast("此地不在你治下。")
		return
	if _govern_panel != null and is_instance_valid(_govern_panel):
		_govern_panel.queue_free()
	_govern_panel = CityGovernPanel.new()
	_govern_panel.name = "CityGovernPanel"
	$UI.add_child(_govern_panel)
	_govern_panel.open(cid)


## 守城战（#67）：原属势力兵临城下，玩家据城一战。
## 敌军规模由 CityService 按「收复军 - 城墙守军抵扣」算好，本层只负责组装遭遇。
func _do_defend(city_id: String) -> void:
	var city := DataManager.get_city(city_id)
	if city.is_empty():
		return
	var claim: Dictionary = GameState.city_claims.get(city_id, {})
	var fid := int(claim.get("faction", 0))
	var info := CityService.retake_battle_units(city)
	if GameState.get_total_troops() <= 0:
		show_toast("麾下无兵，无力守城。")
		return
	GameState.current_encounter = {
		"id": "defend_%s" % city_id,
		"name": "守卫%s" % str(city.get("name", "此地")),
		"type": "battle",
		"enemy_units": info.get("units", []),
		"defend_city_id": city_id,
		"rewards": {
			"gold": [int(CityService.retake_settings().get("reward_gold", 300)), int(CityService.retake_settings().get("reward_gold", 300))],
			"fame": int(CityService.retake_settings().get("reward_fame", 12)),
		},
		"description": "%s 起兵 %d 人来夺，城中守军已挫其锋 %d 人，须击退余众 %d 人。" % [
			FactionService.faction_name(fid), int(info.get("raw", 0)),
			int(info.get("wall", 0)), int(info.get("army", 0))],
	}
	GameState.return_scene = "world"
	GameState.return_pos = _player.position
	_busy = true
	SceneRouter.push_scene("formation")


## 【#67】收复军到期：玩家就在该城附近 → 就地开打（迎战/弃城二选一）；
## 不在场 → 只发告警，等他赶回来（走近时 _maybe_prompt_retake 会再问一次）。
func _on_retake_incoming(city_id: String, faction_id: int) -> void:
	if not GameState.captured_cities.has(city_id):
		return   # 已经丢了的城不再打扰玩家
	_city_under_threat(city_id, faction_id)
	var near := _is_player_near_city(city_id)
	if not near:
		var city := DataManager.get_city(city_id)
		show_toast("%s 起兵来夺 %s！速回救援。" % [
			FactionService.faction_name(faction_id), str(city.get("name", city_id))])
		return
	_prompt_retake(city_id, faction_id)


## 玩家是否在该城附近（能赶上这一战）
func _is_player_near_city(city_id: String) -> bool:
	if GameState.current_city_id == city_id:
		return true
	var marker := _city_markers.get_node_or_null("Marker_" + city_id)
	if marker == null or not (marker is Node2D):
		return false
	return _player.global_position.distance_to((marker as Node2D).global_position) \
		<= RETAKE_PROMPT_RANGE


## 走近「兵临城下」的己方城 → 自动问一次「迎战 / 弃城」（每月最多问一次）
func _maybe_prompt_retake(city_id: String) -> void:
	if city_id.is_empty() or not GameState.captured_cities.has(city_id):
		return
	var claim: Dictionary = GameState.city_claims.get(city_id, {})
	if claim.is_empty():
		return
	if GameState.month_index() < int(claim.get("due", 0)):
		return   # 还没到兵期
	if int(_retake_prompted.get(city_id, -1)) == GameState.month_index():
		return
	if _retake_popup != null and is_instance_valid(_retake_popup):
		return
	_prompt_retake(city_id, int(claim.get("faction", 0)))


func _prompt_retake(city_id: String, faction_id: int) -> void:
	_retake_prompted[city_id] = GameState.month_index()
	var city := DataManager.get_city(city_id)
	var info := CityService.retake_battle_units(city)
	if _retake_popup != null and is_instance_valid(_retake_popup):
		_retake_popup.queue_free()
	_retake_popup = RetakePopup.new()
	_retake_popup.name = "RetakePopup"
	$UI.add_child(_retake_popup)
	_retake_popup.decided.connect(_on_retake_decided)
	_retake_popup.open(city_id, str(city.get("name", city_id)),
		FactionService.faction_name(faction_id),
		int(info.get("raw", 0)), int(info.get("wall", 0)))


func _on_retake_decided(city_id: String, fight: bool) -> void:
	_retake_popup = null
	var claim: Dictionary = GameState.city_claims.get(city_id, {})
	var fid := int(claim.get("faction", 0))
	if not fight:
		# 弃城：直接失地，归还原属势力
		GameState.lose_city(city_id, fid)
		var city := DataManager.get_city(city_id)
		show_toast("弃守 %s，此地复归 %s。" % [
			str(city.get("name", city_id)), FactionService.faction_name(fid)])
		return
	_do_defend(city_id)


## 城池告急的视觉/文案提示（当前只走 toast，留作后续接入醒目告警的钩子）
func _city_under_threat(_city_id: String, _faction_id: int) -> void:
	pass


## 战斗结束（#64/#65/#67 三合一结算）：
##   攻城胜 → 占领；攻城败 → 守军反扑（额外减员 + 辎重 + 该城戒备）
##   守城胜 → 击退收复军（领赏 + 进入冷却）；守城败 → 城池失守
func _on_battle_ended(result: Dictionary) -> void:
	_busy = false
	var enc: Dictionary = GameState.current_encounter
	if enc.is_empty():
		return
	var win := bool(result.get("win", false))
	var cid := str(enc.get("siege_city_id", ""))
	if not cid.is_empty():
		# 不在此处清 current_encounter：战利结算(BattleRewardService)与俘虏判定
		# 仍要读它，清空交给 battle_scene._on_result_ok（玩家点确认后）统一处理。
		if not win:
			# 【#65】守军反扑：攻城不是「打输就没事」，败兵会被掩杀
			var city := DataManager.get_city(cid)
			show_toast(CityService.apply_siege_defeat(city))
			return
		# 接管方：已投靠则归该势力，否则归玩家势力（888888）。
		# 口径统一走 MainlineService.player_faction_id()：旧写法用 1，但势力表无 id=1，
		# 城池归属会显示成「无名势力」。
		var fid := MainlineService.player_faction_id()
		GameState.capture_city(cid, fid)
		var city2 := DataManager.get_city(cid)
		show_toast("已攻下 %s！此地归入你麾下。" % str(city2.get("name", cid)))
		return

	var did := str(enc.get("defend_city_id", ""))
	if did.is_empty():
		return
	var claim: Dictionary = GameState.city_claims.get(did, {})
	var fid2 := int(claim.get("faction", 0))
	var city3 := DataManager.get_city(did)
	if win:
		# 击退收复军：清排期 + 进冷却（原属势力短期内不再图谋）
		GameState.city_claims.erase(did)
		GameState.city_retake_cooldown[did] = GameState.month_index() \
			+ int(CityService.retake_settings().get("cooldown_months", 6))
		GameState.city_alert.erase(did)
		show_toast("击退 %s 的收复军，%s 仍在你手。" % [
			FactionService.faction_name(fid2), str(city3.get("name", did))])
	else:
		GameState.lose_city(did, fid2)
		show_toast("%s 守城失利，已为 %s 所夺。" % [
			str(city3.get("name", did)), FactionService.faction_name(fid2)])


# ------------------------------------------------------------------
# 城池标记
# ------------------------------------------------------------------

func _spawn_city_markers() -> void:
	var cities := DataManager.get_table("cities")
	if cities.is_empty():
		_create_placeholder_cities()
		return
	## 【全国常驻】全国无缝行走后场景不再重载，城池标记一律按整表生成。
	## 旧写法按当前游戏区域过滤（RegionService.city_in_area），玩家走出初始州
	## 就进入一片无 marker 的「无城之地」——小地图读全量表照常显示，大地图却空，
	## 观感就是「城池全消失了」。110 城全建：绘制由视口裁剪，
	## 交互仍走距离判定（_update_nearby_target），远处城池不会被误触。
	for city in cities:
		_create_marker(city)


func _create_placeholder_cities() -> void:
	_create_marker({ "id": "city_jianning", "name": "建宁", "type": "city",
		"map_x": 700, "map_y": 400 })
	_create_marker({ "id": "city_yongchang", "name": "永昌", "type": "city",
		"map_x": 400, "map_y": 620 })
	_create_marker({ "id": "city_yunnan", "name": "云南", "type": "city",
		"map_x": 980, "map_y": 700 })
	_create_marker({ "id": "village_axiang", "name": "阿乡寨", "type": "village",
		"map_x": 560, "map_y": 260 })


## 城池标记：按类型给出不同造型（不再是统一方框）
func _create_marker(city: Dictionary) -> void:
	var city_id := str(city.get("id", ""))
	var city_name := str(city.get("name", "城"))
	var city_type := str(city.get("type", "city"))
	var pos := Vector2(float(city.get("map_x", 0)), float(city.get("map_y", 0)))

	var marker := Node2D.new()
	marker.name = "Marker_" + city_id
	marker.position = pos
	marker.set_meta("city_id", city_id)
	marker.set_meta("city_name", city_name)
	marker.set_meta("city_type", city_type)
	marker.set_meta("city_title", str(city.get("title", "")))
	marker.set_meta("city_level", int(city.get("level", 1)))
	marker.set_meta("city_tags", city.get("tags", []))
	marker.set_meta("city_data", city)

	CityMarkerArt.build(marker, city)

	# 名称。【2026-09-28 用户反馈】20px 在大地图上太小，放大到 34 并按宽居中；
	# 【三十五轮微调】×2.5：图标 384px → 城名 55 号
	var label := Label.new()
	label.text = city_name
	label.add_theme_font_size_override("font_size", 55)
	label.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	label.custom_minimum_size = Vector2(280, 0)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.position = Vector2(-140, 65)
	marker.add_child(label)

	_city_markers.add_child(marker)


# ------------------------------------------------------------------

## 【三十四轮×5 性能红锁】视口裁剪：城池 marker 与世界 NPC 屏外隐藏。
## 图标 768px/NPC 420px 后屏外元素也进渲染管线 → 填充率爆炸；grow 余量
## 取图标半径 400+400，保证缓慢拉远时不突兀消失。
func _cull_offscreen() -> void:
	if _camera == null or not is_instance_valid(_camera):
		return
	var center := _camera.get_screen_center_position()
	var half := get_viewport_rect().size * 0.5 / maxf(_camera.zoom.x, 0.001)
	var view := Rect2(center - half, half * 2.0).grow(900.0)
	# 【三十四轮 zoom LOD】zoom 低于近景 0.78 后按比例缩城图标——视野广时
	# 可见城数暴涨（华北 10+ 城×768px），填充率爆炸；近景保持全尺寸。
	var zoom := _camera.zoom.x
	var lod := 1.0
	if zoom < 0.78:
		lod = clampf((zoom - 0.1) / 0.68, 0.22, 1.0)
	if _city_markers != null:
		for m in _city_markers.get_children():
			var nd := m as Node2D
			if nd == null:
				continue
			nd.visible = view.has_point(nd.position)
			var base: float = nd.get_meta("fit_scale", 1.0)
			nd.scale = Vector2.ONE * (base * lod)
	var npcs := get_node_or_null("NPCs")
	if npcs != null:
		for nd2 in npcs.get_children():
			if nd2 is Node2D:
				(nd2 as Node2D).visible = view.has_point((nd2 as Node2D).position)


## 【三十四轮×5】图标放大后，最近邻过近的城整组收缩（防 598px 城距全叠）：
## 每城取最近邻距离，不足「city 图标直径×1.1」时按比例缩 marker（含城名），
## 收缩下限 0.35；绝大多数城 s=1 不受影响。全部 marker 建完后执行。
func _fit_marker_scales() -> void:
	if _city_markers == null:
		return
	var diam := 3.0 * 128.0  ## city 档图标直径（TYPE_ICON_SCALE["city"]×128）
	var n := _city_markers.get_child_count()
	for i in range(n):
		var m := _city_markers.get_child(i) as Node2D
		if m == null:
			continue
		var d_min := 1e12
		for j in range(n):
			if i == j:
				continue
			var o := _city_markers.get_child(j) as Node2D
			if o != null:
				d_min = minf(d_min, m.position.distance_to(o.position))
		var s := clampf(d_min / (diam * 1.1), 0.35, 1.0)
		m.set_meta("fit_scale", s)   ## 供 _cull_offscreen 的 zoom LOD 乘算
		if s < 0.999:
			m.scale = Vector2(s, s)


func _on_npc_interacted(_npc: Dictionary) -> void:
	# 【霸王立志篇】三名士托付改为任务驱动：对话里给「接下托付」选项（accept_quest:bw_xx），
	# 完成托付由任务奖励 unlock（sr_* -> SelfRuleService.grant_by_flag）驱动，三齐自动解锁自立。
	# 此处只负责播对话；已完成托付的名士给 toast 免玩家反复听讲。
	if _npc.has("self_rule_mentor"):
		var flag := str(_npc.get("self_rule_mentor", ""))
		var nm := str(_npc.get("name", "名士"))
		if SelfRuleService.mentor_done(flag):
			EventBus.show_toast("%s 的托付已完成。" % nm)
			return
		# 托付对话（对话内含任务接取选项，交付走对话「提交任务」按钮）
		_mentor_active = true
		_busy = true
		_panel.close_silently()
		_dialogue.portrait_key = _portrait_key_of(_npc)
		_dialogue.talker_id = str(_npc.get("id", ""))
		_dialogue.start(str(_npc.get("dialogue_root", "")))
		return
	EventBus.show_toast("%s：……（暂未配置对话）" % str(_npc.get("name", "此人")))


func _on_dialogue_finished() -> void:
	_busy = false
	# 【重复触发免疫】对话刚关的瞬间手指连点容易落到右下交互按钮上，
	# 把同一个 NPC 的交互菜单立刻又弹出来（用户反馈「选完选项再次靠近
	# 依然重复触发交互选项」）。350ms 内忽略交互按钮。
	_interact_cooldown_until = Time.get_ticks_msec() + 350
	# 旁白队列：前一段剧情旁白播完，自动接播排队的下一段（章末→章初→结局）
	if not _narration_queue.is_empty():
		_start_dialogue_by_id(_narration_queue.pop_front())
		return
	# 【霸王立志篇】名士托付交付已改由任务系统驱动（unlock sr_* -> complete_mentor），
	# 对话结束不再自动写托付标记；仅清对话态标记。
	if _mentor_active:
		_mentor_active = false
		var p := SelfRuleService.mentor_progress()
		EventBus.show_toast("名士托付进行中（%d/%d）——完成托付任务方可解锁自立。" %
			[int(p["done"]), int(p["total"])])
		return
	# 对话结束 → 回到人物详情面板（用户设计：在面板里继续选交易/送礼/结交）
	if not _panel_target.is_empty():
		_panel.open(_panel_target)


func _on_encounter_triggered(encounter: Dictionary) -> void:
	var type := str(encounter.get("type", "battle"))
	if type == "battle":
		GameState.current_encounter = encounter
		# 记录战斗前的位置：战斗结束后回到原地，而不是出生点
		GameState.return_scene = "world"
		GameState.return_pos = _player.position
		_busy = true
		await get_tree().create_timer(0.5).timeout
		# 【freed 防护】0.5s 内场景可能已被释放（切场景/读档），恢复执行前先验自身
		if not is_instance_valid(self) or not is_inside_tree():
			return
		SceneRouter.push_scene("formation")
	elif type == "merchant":
		# 路上商队：直接打开随身货单（货单 npc_stock.json 的 merchant 组）
		_trade.open({
			"id": "enc_merchant",
			"npc_type": "merchant",
			"name": str(encounter.get("name", "行商")),
		})
	elif type == "event":
		# 随机事件：弹窗选择，结算走 WorldEventService
		_event_popup.open(encounter)



func _on_open_menu() -> void:
	AudioManager.sfx_click()
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
			# 【M3 修复】轮盘加了「自立」入口后补分支：open() 自带任务链
			# 未解锁 toast，大地图/城内行为一致（此前全工程唯一入口是
			# 城内死分支——ENTRIES 里根本没有 self_rule 项）
			_wheel_return_panel = _self_rule
			_self_rule.open()
		"system":
			_wheel_return_panel = _settings
			_settings.open(true)
		_:
			show_toast("待实装")


## 【2026-09-28 用户反馈】面板「返 回」按钮统一入口：重开轮盘菜单
func _reopen_menu_wheel() -> void:
	_wheel_return_panel = null
	_menu_wheel.open()


## 人物志点选 → 打开该武将详情（heroes6 的 role_id 走 v6 表）
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
	_panel.open(t, true)   # 从人物志进入：显示「返回列表」


## 滚轮/捏合连续缩放（缩放按钮已移除，缩放只在小地图点开后可用）
func _on_toggle_zoom() -> void:
	AudioManager.sfx_click()
	# 缩放缓动（set_zoom 内部 0.18s tween）期间实时 zoom 仍在过渡，
	# 此刻读 is_zoomed_out() 会误判档位；用「切换前状态的反相」推断目标档，
	# 与缓动解耦，小地图模式随切换目标即时切换。
	var will_be_world := not _player.is_zoomed_out()
	_player.zoom_cycle()
	_minimap.set_mode(MiniMap.MODE_WORLD if will_be_world else MiniMap.MODE_LOCAL)


## 常驻指引（左上角，轻量提示）
func _set_hint(text: String) -> void:
	if _hud.has_method("set_hint"):
		_hud.set_hint(text)


## 统一提示出口（2026-09-27）：不再用本场景的 ToastLabel 就地显示，
## 一律转发全局 ToastLayer —— 那边是横排自适应宽度 + 3~5 秒自适应时长，
## 四处场景各养一套 toast 迟早样式漂移（竖排 bug 就是这么来的）。
## tscn 里的 ToastLabel 节点保留但不再使用（删节点要动整棵子树，风险大于收益）。
func show_toast(message: String) -> void:
	EventBus.show_toast(message)


func advance_dialogue() -> void:
	if _dialogue.is_open():
		_dialogue.advance()


## 右侧圆形「城池交互」按钮：靠近城池/地点时显示，点击后弹出「进入 / 查看」选项。
## 取代原贴脸直接弹详情的行为（需求：靠近不直接弹详情，点按钮才出选项）。
## 右下角圆形交互按钮：移动摇杆（左下）的对端，手机拇指自然触位。
## 靠近城池/地点/NPC 时出现，点按才弹交互菜单（进入/查看/交谈…）。
func _setup_city_action_button() -> void:
	var btn := Button.new()
	btn.name = "CityActionButton"
	btn.mouse_filter = Control.MOUSE_FILTER_STOP
	btn.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	# 【内移】旧位 46px 贴边太近（用户反馈「太靠边」）：右缘留 110px、底缘留 96px
	btn.offset_left = -250.0
	btn.offset_right = -110.0
	btn.offset_top = -236.0
	btn.offset_bottom = -96.0
	btn.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	btn.grow_vertical = Control.GROW_DIRECTION_BEGIN
	btn.custom_minimum_size = Vector2(140.0, 140.0)
	# 【样式重做】空心圆环：不写「交互」二字（用户要求与移动摇杆同风格 ——
	# 摇杆底座就是半透明圆环），内部仅淡墨底衬保证任何地表上都可辨识。
	btn.text = ""
	# 【常驻按钮】像主流手游一样固定在右下角（摇杆对端），
	# 无目标时点了给提示，有目标时直接弹菜单 —— 不再「时有时无」让玩家找不到。
	btn.visible = true
	var tint := UITheme.GOLD_LINE   ## （R3-09 归表）
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(UITheme.INK, 0.28)   # 空心：只留淡墨底衬（R3-09 归表）
	normal.border_color = Color(UITheme.BONE, 0.60)  # 暖白描边（同摇杆底座观感，R3-09 入表 BONE）
	normal.set_border_width_all(5)
	normal.set_corner_radius_all(70)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(UITheme.INK, 0.50)
	hover.border_color = Color(UITheme.BONE, 0.85)
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(tint.r * 0.42, tint.g * 0.38, tint.b * 0.26, 0.72)
	pressed.border_color = UITheme.BONE   ## R3-09：原内联 (1.0,0.92,0.72) 归表为暖白
	btn.add_theme_stylebox_override("normal", normal)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("pressed", pressed)
	btn.add_theme_font_size_override("font_size", 30)
	btn.pressed.connect(_on_city_action)
	$UI.add_child(btn)
	_city_action_btn = btn
	# 【第五十四轮·移动端安全区】刘海/挖孔屏上右下角会被系统手势条与挖孔遮挡，
	# 按钮会变成「看得见一半、点不到」。按安全区内缩整体左移上移。
	# 无刘海机（桌面/平板）返回全 0，位置与改造前逐像素一致。
	UITheme.apply_safe_bottom_right(btn, self)


## 【重复触发免疫】对话/详情面板关闭后 350ms 内忽略右下交互按钮（见 _on_dialogue_finished）
var _interact_cooldown_until := 0

## 点击右下角圆形交互按钮：弹出当前目标（城池/地点/NPC）的交互选项菜单。
## 无目标时提示（按钮常驻，不再是「靠近才出现」）。
## 【2026-09-28 用户反馈】非战斗遭遇（采集/垂钓/商队/宝箱/奇遇）不再弹菜单：
## 按钮文字已是动作动词，点按直接触发结算。
func _on_city_action() -> void:
	if Time.get_ticks_msec() < _interact_cooldown_until:
		return
	AudioManager.sfx_click()
	if _city_target.is_empty():
		show_toast("附近没有可交互的目标，走近城池或人物再试")
		return
	if str(_city_target.get("type", "")) == "encounter":
		_do_encounter(_city_target)
		return
	_city_action_btn.hide()
	_menu.show_for(_city_target, _city_target_pos)


## 新游戏 / 首次进入大地图：随机选一座当前区域的城池附近作为出生点，
## 不再固定出生在建宁。记住出生点，使本次会话后续回大地图稳定在同一城。
func _spawn_at_random_city() -> void:
	var cur := GameState.current_region
	var cities: Array = DataManager.get_table("cities")
	var pool: Array = []
	for city in cities:
		if RegionService.city_in_area(cur, city):
			pool.append(city)
	if pool.is_empty():
		return   # 该区域无城池，沿用 tscn 默认位置
	var city: Dictionary = pool[randi() % pool.size()]
	var base := Vector2(float(city.get("map_x", 0.0)), float(city.get("map_y", 0.0)))
	# 城中随机偏移，落在城门口附近而非正中地标
	var off := Vector2(randf_range(-240.0, 240.0), randf_range(-240.0, 240.0))
	_player.position = base + off
	_player.sync_into_region()   # 夹回区域矩形内，避免落进虚空角落
	# 记出生点：后续回到大地图（进城 / 战斗返回）会恢复到这里，不再每次重新随机
	GameState.return_pos = _player.position
	GameState.return_scene = "world"


## ---------- 世界动态事件（标记 / 弹窗 / 播报） ----------

## 每天推进 / 弹窗关闭后：刷新标记并按序播报待弹出事件
func _on_world_day(_y: int, _m: int, _d: int) -> void:
	_refresh_world_event_markers()
	_show_world_event_news()


func _on_event_popup_closed() -> void:
	_refresh_world_event_markers()
	_show_world_event_news()


func _refresh_world_event_markers() -> void:
	if _world_event_markers == null:
		return
	for c in _world_event_markers.get_children():
		_world_event_markers.remove_child(c)
		c.queue_free()
	for ev in WorldEventService.active_world_events():
		_add_world_event_marker(ev)


func _add_world_event_marker(ev: Dictionary) -> void:
	var btn := Button.new()
	btn.name = "WE_" + str(ev.get("uid", ""))
	btn.custom_minimum_size = Vector2(84, 84)
	btn.position = Vector2(float(ev.get("map_x", 0)), float(ev.get("map_y", 0))) - Vector2(42, 42)
	btn.text = str(ev.get("glyph", "！"))
	btn.mouse_filter = Control.MOUSE_FILTER_STOP
	var col := _we_color(str(ev.get("type", "")))
	var st := StyleBoxFlat.new()
	st.bg_color = col
	st.border_color = Color(1, 1, 1, 0.85)
	st.set_corner_radius_all(12)
	btn.add_theme_stylebox_override("normal", st)
	var st_h := StyleBoxFlat.new()
	st_h.bg_color = col.lightened(0.18)
	st_h.border_color = Color(1, 1, 1, 1.0)
	st_h.set_corner_radius_all(12)
	btn.add_theme_stylebox_override("hover", st_h)
	btn.add_theme_color_override("font_color", Color(1, 1, 1, 1))
	btn.add_theme_font_size_override("font_size", 40)
	btn.pressed.connect(_on_world_event_pressed.bind(ev))
	_world_event_markers.add_child(btn)
	# 脉冲：提示此处有动态事件可交互（缩放呼吸，不碰坐标）
	var tw := create_tween().set_loops(true)
	tw.tween_property(btn, "scale", Vector2(1.12, 1.12), 0.7)
	tw.tween_property(btn, "scale", Vector2(1.0, 1.0), 0.7)


func _we_color(t: String) -> Color:
	match t:
		"harvest": return Color(0.30, 0.70, 0.35)
		"famine": return Color(0.80, 0.45, 0.20)
		"refugees": return Color(0.45, 0.55, 0.80)
		"bandit": return Color(0.80, 0.30, 0.30)
		"hero_seek": return Color(0.85, 0.70, 0.20)
		"tribute": return Color(0.55, 0.45, 0.75)
		"plague": return Color(0.55, 0.55, 0.55)
		"rebellion": return Color(0.75, 0.35, 0.45)
		"omen": return Color(0.40, 0.40, 0.60)
		"market_boom": return Color(0.30, 0.60, 0.65)
		_: return Color(0.6, 0.6, 0.6)


func _on_world_event_pressed(ev: Dictionary) -> void:
	if _any_ui_open():
		return
	_event_popup.open(ev)


## 按序弹出待播报的世界事件（进入大地图 / 每天推进 / 上一弹窗关闭后触发）
func _show_world_event_news() -> void:
	if _world_event_markers == null:
		return
	if _any_ui_open():
		return
	if GameState.world_event_pending.is_empty():
		return
	var ev: Dictionary = GameState.world_event_pending.pop_front()
	var found := false
	for a in WorldEventService.active_world_events():
		if str(a.get("uid", "")) == str(ev.get("uid", "")):
			found = true
			ev = a
	if not found:
		return
	_event_popup.open(ev)
