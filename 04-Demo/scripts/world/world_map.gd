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
@onready var _toast_label: Label = $UI/ToastLabel

var _menu: InteractionMenu
var _panel: CharacterPanel
var _trade: NpcTradePanel           ## NPC 背包交易面板
var _quest_panel: QuestPanel        ## 任务中心面板
var _event_popup: EventPopup        ## 随机事件弹窗
var _menu_wheel: MainMenuWheel      ## 圆形图标主菜单
var _hero_dex: HeroDex              ## 人物志浏览器
var _attr_panel: AttributePanel      ## 主角成长 / 属性加点面板
var _ach_panel: AchievementPanel
var _self_rule: SelfRulePanel     ## 成就面板
var _diplomacy: DiplomacyPanel       ## 外交面板（圆形菜单外交入口）
var _settings: SettingsPanel         ## 系统设置面板（音量 / 存档 / 返回主菜单）
var _panel_target: Dictionary = {}   ## 详情面板当前对象（对话结束后回到面板）
var _mentor_active := false           ## 正在为名士托付对话中（结束后统一交付+解锁）
var _mentor_target: Dictionary = {}   ## 当前名士 NPC 数据
var _toast_tween: Tween
var _busy := false          ## 正在对话 / 切场景 / 弹菜单确认中，暂停角色移动
## 大地图打开时刻与输入免疫期（毫秒）：用于屏蔽「打开那一次点击」的模拟触摸事件，
## 避免地图刚弹出就被同一次点击关掉。详见 _request_close_big_map()。
const MAP_INPUT_GUARD_MS := 320
var _map_opened_at_ms := 0
var _menu_target_id := ""
var _city_action_btn: Button = null   ## 右侧圆形「城池交互」按钮（代码创建）
var _city_target: Dictionary = {}      ## 当前可交互的城池/地点目标
var _city_target_pos: Vector2 = Vector2.ZERO
var _spar_popup: DuelPopup            ## 切磋单挑弹窗（复用战前单挑 UI）
var _spar_target_name := ""           ## 当前切磋对手名   ## 上一帧交互菜单显示的目标 id（节流用，避免每帧重建）


func _ready() -> void:
	AudioManager.play_bgm("res://assets/audio/bgm/world_map.ogg")

	# 用「当前区域矩形」作为玩家活动与缩放范围（而非全图尺寸），
	# 否则 zoom_min 按全图 21256×21826 算出来仅 ~0.095，
	# 缩到最小时区域只占屏幕一小块，看起来「地图显示不全」。
	var region_rect := RegionService.region_rect(GameState.current_region)
	if region_rect.size.x > 0.0 and region_rect.size.y > 0.0:
		_player.map_size = region_rect.size
		_player.region_offset = region_rect.position
		# 按「古州矩形集合」而非并集矩形做硬限制：
		# 并集会圈出虚空角落，玩家能走进去却什么都看不到 = 走出地图的观感。
		_player.walk_rects = RegionService.walkable_rects(GameState.current_region)
		_player.position = _player.position  # 触发边界 clamp
		# 通知地形绘制器当前区域窗口（用于区域级高清纹理 + 装饰物定位）
		_terrain.set_view_rect(region_rect)
	else:
		_player.map_size = _terrain.get_map_size()
		_player.region_offset = Vector2.ZERO
		_player.walk_rects = []

	# 区域窗口：把相机锁定到当前区域矩形（分区加载核心）
	_apply_region_camera()

	# 恢复战斗/进城前的位置（避免场景重载后回到出生点）
	if GameState.return_scene == "world":
		_player.position = GameState.return_pos
		# 旧存档 / 跨区域坐标可能已不在当前区域的地盘上，必须夹回来
		_player.sync_into_region()
		GameState.return_scene = ""
	else:
		# 全新进入大地图（新游戏首次）：随机选一座本区域城池附近出生，
		# 不再固定出生在建宁。
		_spawn_at_random_city()

	# 撞地图边界的反馈（C4：别让玩家以为是卡死）
	_player.bounds_blocked.connect(_on_bounds_blocked)

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

	# 接取任务后不再自动弹回人物详情面板
	EventBus.quest_accepted.connect(func(_id: String): _panel_target = {})

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
	EventBus.city_left.connect(func(_id: String): _busy = false)

	# 开场剧情：全新档（intro_seen=false）首次进入大地图时，延时一小段后自动播放；
	# 读档时 intro_seen 已按存档恢复为 true，不重放。
	if not GameState.intro_seen:
		var t := get_tree().create_timer(0.6)
		t.timeout.connect(func():
			if not GameState.intro_seen:
				_start_dialogue_by_id("intro"))
	# 第一章完成章末旁白：张角决战获胜返回时播放一次（mainline_service 记 pending 标记）
	if MainlineService.consume_ch1_end_pending():
		var t2 := get_tree().create_timer(0.8)
		t2.timeout.connect(func():
			_start_dialogue_by_id("mj_ch1_end"))
	EventBus.drill_finished.connect(func(_id: String, _r: Dictionary): _busy = false)
	EventBus.battle_ended.connect(func(_r: Dictionary): _busy = false)

	EventBus.toast.connect(show_toast)
	# 资源栏必须订阅「所有会显示的数值」对应的信号。
	# 历史 bug：这里只连了 gold/food/date，漏了 wood/troop，
	# 而 hud.update_resources() 明明会刷新木材与兵力 → 采木/募兵后
	# 大地图资源栏数值永远停在旧值（进一次城再回来才更新），表现为「数值不同步」。
	EventBus.gold_changed.connect(func(_v): _hud.update_resources())
	EventBus.food_changed.connect(func(_v): _hud.update_resources())
	EventBus.wood_changed.connect(func(_v): _hud.update_resources())
	EventBus.troop_changed.connect(func(_v): _hud.update_resources())
	EventBus.date_changed.connect(func(_y, _m, _d): _hud.update_resources())

	_spawn_city_markers()
	_hud.update_resources()
	_set_hint("用左侧摇杆移动，靠近人或城池即可交互")

	# 小地图点击 → 弹出放大地图（覆盖层，点任意处关闭）
	_minimap.expand_requested.connect(_show_big_map)


## 右上角动作按钮的统一外观（水墨描金风）。
## 放在代码里而不是 tscn 的 sub_resource：按钮数量少、且 world_map 已经在
## 代码里创建了一大批 UI，样式集中在一处更好维护。
## 【横屏适配】按钮只用 custom_minimum_size 定尺寸、由 HBoxContainer 右上锚定排布，
## 没有任何 1920 基准的绝对坐标，视口变宽时整体贴右边缘。
func _style_action_buttons() -> void:
	if _action_buttons == null:
		return
	var tint := Color(0.78, 0.64, 0.36, 1.0)   ## 描金主色 #C7A45C
	var ink := Color(0.09, 0.11, 0.15, 0.92)   ## 墨底 #171B26

	# 右侧动作按钮统一为「圆形」：56×56 + 圆角=半径 → 正圆，与中央圆形主菜单轮盘同一套语言。
	var normal := StyleBoxFlat.new()
	normal.bg_color = ink
	normal.border_color = Color(tint.r, tint.g, tint.b, 0.75)
	normal.set_border_width_all(2)
	normal.set_corner_radius_all(28)
	normal.content_margin_left = 4
	normal.content_margin_right = 4

	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(ink.r * 1.9, ink.g * 1.9, ink.b * 1.9, 0.96)
	hover.border_color = tint

	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(tint.r * 0.42, tint.g * 0.38, tint.b * 0.26, 1.0)
	pressed.border_color = Color(1.0, 0.92, 0.72, 1.0)

	for b in _action_buttons.get_children():
		if not (b is Button):
			continue
		# 圆形按钮：尺寸统一定为 56×56，corner_radius=28 即正圆；
		# ActionButtons 容器不裁剪，略高于 50px 状态栏也不会被切掉。
		b.custom_minimum_size = Vector2(56.0, 56.0)
		b.add_theme_stylebox_override("normal", normal)
		b.add_theme_stylebox_override("hover", hover)
		b.add_theme_stylebox_override("pressed", pressed)
		b.add_theme_font_size_override("font_size", 28)
		b.add_theme_color_override("font_color", Color(0.96, 0.90, 0.72, 1.0))
		b.add_theme_color_override("font_hover_color", Color(1.0, 0.96, 0.82, 1.0))
		b.add_theme_color_override("font_pressed_color", Color(0.12, 0.10, 0.07, 1.0))


## 是否有任意全屏/模态界面正在打开。
## 以前这里是 13 段「if xxx.is_open(): halt(); return」的复制粘贴，
## 漏掉一个（随机事件弹窗）就会出现「弹窗开着但人还在跑」的层级错乱。
## 收敛成一张表，新增面板只需往数组里加一项。
func _any_ui_open() -> bool:
	var panels: Array = [
		_dialogue, _panel, _trade, _quest_panel, _event_popup,
		_menu_wheel, _hero_dex, _attr_panel, _self_rule, _ach_panel,
		_diplomacy, _settings,
	]
	for p in panels:
		if p != null and p.has_method("is_open") and p.is_open():
			return true
	return false


var _last_cam_zoom := -1.0   ## 上一帧相机缩放，用于检测变化

func _process(_delta: float) -> void:
	# 缩放变化时重新计算区域相机 limit（避免缩放后露白或相机被锁死）
	var cur_zoom := _camera.zoom.x
	if absf(cur_zoom - _last_cam_zoom) > 0.0001:
		_apply_region_camera()
		_last_cam_zoom = cur_zoom

	# 小地图每帧刷新（玩家位置 / 朝向 / 镜头视野框）
	_minimap.update_view(_player.position, _player.facing, _camera)
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
## 改为 PRESET_CENTER_TOP 中心锚定：宽 520、上边距 26，与底部提示条完全镜像对称。
func _make_title_bar() -> PanelContainer:
	var bar := PanelContainer.new()
	bar.set_anchors_preset(Control.PRESET_CENTER_TOP)
	bar.offset_left = -260.0
	bar.offset_top = 26.0
	bar.offset_right = 260.0
	bar.offset_bottom = 64.0
	bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.08, 0.05, 0.82)
	sb.border_color = Color(0.78, 0.64, 0.36, 0.9)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 18.0
	sb.content_margin_right = 18.0
	bar.add_theme_stylebox_override("panel", sb)
	var lab := Label.new()
	lab.text = "天 下 地 图"
	lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lab.add_theme_font_size_override("font_size", 30)
	lab.add_theme_color_override("font_color", Color(0.98, 0.86, 0.54))
	lab.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	lab.add_theme_constant_override("shadow_offset_x", 1)
	lab.add_theme_constant_override("shadow_offset_y", 1)
	bar.add_child(lab)
	return bar


## 放大地图底部居中「点击关闭」提示条（对称居中的周边控制 UI）
## 【修复】旧代码 offset_top=0 / bottom=36 让提示条紧贴屏幕最底边，
## 而地图区域底部留了 70px 边距 —— 提示条悬在地图外缘之外的屏幕边缘上，
## 与顶部标题条（26px 边距）不对称。改为 bottom=-26，与标题条上下镜像。
func _make_close_hint() -> PanelContainer:
	var bar := PanelContainer.new()
	bar.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	bar.offset_left = -200.0
	bar.offset_top = -64.0
	bar.offset_right = 200.0
	bar.offset_bottom = -26.0
	bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.05, 0.04, 0.7)
	sb.set_corner_radius_all(9)
	sb.content_margin_left = 14.0
	sb.content_margin_right = 14.0
	bar.add_theme_stylebox_override("panel", sb)
	var lab := Label.new()
	lab.text = "点击任意处关闭地图"
	lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lab.add_theme_font_size_override("font_size", 20)
	lab.add_theme_color_override("font_color", Color(0.92, 0.88, 0.80))
	lab.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	lab.add_theme_constant_override("shadow_offset_x", 1)
	lab.add_theme_constant_override("shadow_offset_y", 1)
	bar.add_child(lab)
	return bar


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
		dim.set_anchors_preset(Control.PRESET_FULL_RECT)   ## 全屏遮罩同样不写死像素尺寸
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
		# —— 周边控制 UI：顶部标题条 + 底部关闭提示（居中对称）——
		_big_map_title = _make_title_bar()
		_big_map_close_hint = _make_close_hint()
		ui.add_child(_big_map_title)
		ui.add_child(_big_map_close_hint)
	# 关键：必须走 set_mode 触发 _recalc_geometry，否则视图仍是「局部」几何。
	# 注意：这里不要提前直接给 view_mode 赋值，否则 set_mode 会因「同值」提前 return。
	_big_map.set_mode(MiniMap.MODE_WORLD)
	_big_map.update_view(_player.position, _player.facing, _camera)
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

## 把相机锁定到当前游戏区域的矩形（世界坐标窗口）。
## 地形画整图，相机只显示当前区域窗口 —— 即「区域加载」的表现层。
func _apply_region_camera() -> void:
	var rect := RegionService.region_rect(GameState.current_region)
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	# 根据当前缩放动态收窄相机中心活动范围，使视口不超出区域矩形。
	# 允许视口边缘超出区域 10%（少量露白），换取相机能跟随玩家到区域边缘。
	var z := maxf(_camera.zoom.x, 0.001)
	var vp := _camera.get_viewport_rect().size
	var half_x := vp.x * 0.5 / z
	var half_y := vp.y * 0.5 / z
	var slack_x := half_x * 0.1
	var slack_y := half_y * 0.1
	_camera.limit_left = int(maxf(rect.position.x, rect.position.x + half_x - slack_x))
	_camera.limit_top = int(maxf(rect.position.y, rect.position.y + half_y - slack_y))
	_camera.limit_right = int(minf(rect.end.x, rect.end.x - half_x + slack_x))
	_camera.limit_bottom = int(minf(rect.end.y, rect.end.y - half_y + slack_y))
	# HUD 显示当前区域名（多区域适配）
	if _hud != null and _hud.has_method("update_region"):
		_hud.update_region(GameState.current_region)


## 每帧判定：玩家位置是否已落入某个邻接区域矩形 → 触发渐隐切区。
## 若尚未越界，把玩家夹回当前区域矩形内（贴墙时触发判定）。
func _check_region_bounds() -> void:
	var cur := GameState.current_region
	var rect := RegionService.region_rect(cur)
	if rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	var pos := _player.position
	var target := RegionService.resolve_crossing(cur, pos)
	if not target.is_empty() and target != cur:
		_goto_region(target, pos)
		return
	# 未越界：夹回当前区域（允许贴到边缘触发上面的判定）
	var c := Vector2(
		clampf(pos.x, rect.position.x, rect.end.x),
		clampf(pos.y, rect.position.y, rect.end.y))
	if c != pos:
		_player.position = c


## 撞到地图边界的反馈（C4）。
## 玩家推着摇杆撞墙却毫无动静时，第一反应是「游戏卡死」而不是「这里是地图边缘」，
## 所以必须给出明确提示；前方若接壤另一州，直接告诉他再走几步能进哪儿。
func _on_bounds_blocked(dir: Vector2) -> void:
	var probe := _player.position + dir.normalized() * 260.0
	var target := RegionService.resolve_crossing(GameState.current_region, probe)
	if not target.is_empty() and target != GameState.current_region:
		show_toast("再往前便是「%s」" % RegionService.region_name(target))
		return
	show_toast("前方已是无路之地")


## 切换区域：更新 GameState.current_region，把玩家位置推进到新区域内部，
## 经 SceneRouter 渐隐重载本场景（world）进入新区域窗口。
func _goto_region(target: String, pos: Vector2) -> void:
	if target.is_empty() or target == GameState.current_region:
		return
	GameState.current_region = target
	GameState.return_scene = "world"
	GameState.return_pos = RegionService.push_into_region(target, pos)
	if not GameState.unlocked_regions.has(target):
		GameState.unlocked_regions.append(target)
	_busy = true
	show_toast("进入「%s」" % RegionService.region_name(target))
	# SceneRouter.goto 会提交带渐隐的场景切换；本实例随后被卸载，
	# 因此调用后直接返回，不再访问本节点成员。
	SceneRouter.goto("world")


func _unhandled_input(event: InputEvent) -> void:
	# 返回键 / Esc：打开放大地图时优先关闭它（遮罩与地图一并隐藏）
	if event.is_action_pressed('ui_cancel'):
		if _big_map != null and _big_map.visible:
			_close_big_map()
			get_viewport().set_input_as_handled()


## 每帧找出「当前最该交互的对象」，让菜单贴着它显示
func _update_nearby_target() -> void:
	var best: Dictionary = {}
	var best_pos := Vector2.ZERO
	var best_dist := INF

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

	# 把「贴脸菜单是否已弹出」同步给 NPC 管理器：
	# 菜单弹出后要收起 NPC 头顶的「▲ 对话」与气泡，否则同一屏出现两套提示 = 重复显示。
	_npcs.menu_open = _menu.is_open()

	if best.is_empty():
		_menu.hide_menu()
		if _city_action_btn != null:
			_city_action_btn.hide()
		_menu_target_id = ""
		return

	# 城池 / 地点：不直接弹贴脸详情，改为屏幕右侧圆形交互按钮；
	# 玩家靠近并点击按钮后，才弹出「进入 / 查看」选项（满足“不直接弹出详情”需求）。
	var is_city := str(best.get("type", "")) != "npc"
	if is_city:
		if _menu.is_open():
			# 已由按钮弹出交互菜单，保持显示，不再处理按钮
			return
		_menu.hide_menu()
		_city_target = best
		_city_target_pos = best_pos
		if _city_action_btn != null:
			_city_action_btn.show()
		_menu_target_id = ""
		return

	# NPC：沿用贴脸菜单（人比建筑更需要即时交互）
	var key := "%s:%s" % [str(best.get("type", "")), str(best.get("id", ""))]
	if _menu.is_open() and key == _menu_target_id:
		return
	_menu_target_id = key
	if _city_action_btn != null:
		_city_action_btn.hide()
	_menu.show_for(best, best_pos)


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
const PLACE_RADIUS := {
	"city": 62.0, "capital": 78.0, "village": 46.0, "pass": 50.0,
	"ruin": 46.0, "landmark": 54.0,
}
const PLACE_RADIUS_FALLBACK := 58.0
const PLACE_LEVEL_STEP := 6.0          ## 城池等级每 +1，占地半径 +6
const PLACE_TOUCH_SLACK := 26.0        ## 边缘外的宽容余量：贴到城门口即可交互
const PLACE_OFFSCREEN_PENALTY := 1200.0  ## 屏幕外候选重罚（避免"弹远处的城"）
const PLACE_FACING_BONUS := 18.0       ## 正朝着走的地点加权（同距时按玩家意图选）


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
		_hide_all_place_hints()
		return {}

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
		_:
			show_toast("尚未实装：%s" % action)


func _start_dialogue(target: Dictionary) -> void:
	var data: Dictionary = target.get("data", {})
	var root := str(data.get("dialogue_root", ""))
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
	var data: Dictionary = target.get("data", {})
	var lines: Array[String] = []
	lines.append("【%s】%s" % [str(target.get("name", "")), str(target.get("title", ""))])
	var desc := str(data.get("description", ""))
	if not desc.is_empty():
		lines.append(desc)
	var lore := str(data.get("lore", ""))
	if not lore.is_empty():
		lines.append("— " + lore)
	# 武将额外显示能力
	var cid := str(data.get("hero_id", ""))
	if cid.is_empty():
		cid = str(data.get("character_id", ""))
	if not cid.is_empty():
		var ch := DataManager.get_record("characters", cid)
		if not ch.is_empty():
			# 四维按数据源自动适配（v6 官方表 vs legacy 自研表）
			var fs := CharacterService.four_stats(ch)
			var labels: Array = fs.get("labels", []) as Array
			var vals: Array = fs.get("values", []) as Array
			var segs: Array[String] = []
			for i in range(mini(labels.size(), vals.size())):
				segs.append("%s %d" % [str(labels[i]), int(vals[i])])
			lines.append("　".join(segs))
	show_toast("　".join(lines))


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


func _do_attack(target: Dictionary) -> void:
	show_toast("攻打 %s —— 需先集结部队。（待实装）" % str(target.get("name", "")))


# ------------------------------------------------------------------
# 城池标记
# ------------------------------------------------------------------

func _spawn_city_markers() -> void:
	var cities := DataManager.get_table("cities")
	if cities.is_empty():
		_create_placeholder_cities()
		return
	var cur := GameState.current_region
	for city in cities:
		# 分区加载：只生成当前游戏区域内的城池（RegionService.city_in_area）
		if not RegionService.city_in_area(cur, city):
			continue
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

	# 名称
	var label := Label.new()
	label.text = city_name
	label.add_theme_font_size_override("font_size", 20)
	label.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	label.add_theme_constant_override("shadow_offset_x", 1)
	label.add_theme_constant_override("shadow_offset_y", 1)
	label.position = Vector2(-40, 24)
	marker.add_child(label)

	_city_markers.add_child(marker)


# ------------------------------------------------------------------

func _on_npc_interacted(_npc: Dictionary) -> void:
	# 【需求 4】三位名士游历任务：靠近交互先听其托付（对话），结束后统一交付并解锁自立建国。
	# 替代原主菜单「自立」直入入口，玩家须游历天下依次寻得三人。
	if _npc.has("self_rule_mentor"):
		var flag := str(_npc.get("self_rule_mentor", ""))
		var nm := str(_npc.get("name", "名士"))
		if SelfRuleService.mentor_done(flag):
			EventBus.show_toast("%s 的托付已完成。" % nm)
			return
		# 首次相遇：播放托付对话，对话结束在 _on_dialogue_finished 内正式交付
		_mentor_active = true
		_mentor_target = _npc
		_busy = true
		_panel.close_silently()
		_dialogue.portrait_key = _portrait_key_of(_npc)
		_dialogue.talker_id = str(_npc.get("id", ""))
		_dialogue.start(str(_npc.get("dialogue_root", "")))
		return
	EventBus.show_toast("%s：……（暂未配置对话）" % str(_npc.get("name", "此人")))


func _on_dialogue_finished() -> void:
	_busy = false
	# 名士托付对话结束 → 正式交付并判定是否解锁自立建国
	if _mentor_active and not _mentor_target.is_empty():
		_mentor_active = false
		var m := _mentor_target
		_mentor_target = {}
		var flag := str(m.get("self_rule_mentor", ""))
		var nm := str(m.get("name", "名士"))
		SelfRuleService.complete_mentor(flag)
		var p := SelfRuleService.mentor_progress()
		if SelfRuleService.chain_unlocked():
			EventBus.show_toast("三位名士皆已托付于你，可自立建国！")
			_self_rule.open(GameState.current_city_id)
		else:
			EventBus.show_toast("完成 %s 的托付（%d/%d）。继续游历寻访其余名士。" % [nm, int(p["done"]), int(p["total"])])
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
			_quest_panel.open()
		"heroes":
			_hero_dex.open()
		"player":
			_attr_panel.open()
		"achieve":
			_ach_panel.open()
		"diplo":
			_diplomacy.open()
		"system":
			_settings.open(true)
		_:
			show_toast("待实装")


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
	_panel.open(t)


## 滚轮/捏合连续缩放（缩放按钮已移除，缩放只在小地图点开后可用）
func _on_toggle_zoom() -> void:
	AudioManager.sfx_click()
	_player.zoom_cycle()
	# 小地图跟随镜头：缩到最小即看天下，其余看周边
	var want_world := _player.is_zoomed_out()
	_minimap.set_mode(MiniMap.MODE_WORLD if want_world else MiniMap.MODE_LOCAL)


## 常驻指引（左上角，轻量提示）
func _set_hint(text: String) -> void:
	if _hud.has_method("set_hint"):
		_hud.set_hint(text)


func show_toast(message: String) -> void:
	_toast_label.text = message
	_toast_label.modulate.a = 1.0
	if _toast_tween and _toast_tween.is_valid():
		_toast_tween.kill()
	# 新建补间必须写在 if 之外：写在 if 内会因前一次补间已失效而永不创建，
	# 提示文字因此永不淡出（一直糊在屏幕上）。
	_toast_tween = create_tween()
	_toast_tween.tween_interval(2.6)
	_toast_tween.tween_property(_toast_label, "modulate:a", 0.0, 0.5)


func advance_dialogue() -> void:
	if _dialogue.is_open():
		_dialogue.advance()


## 右侧圆形「城池交互」按钮：靠近城池/地点时显示，点击后弹出「进入 / 查看」选项。
## 取代原贴脸直接弹详情的行为（需求：靠近不直接弹详情，点按钮才出选项）。
func _setup_city_action_button() -> void:
	var btn := Button.new()
	btn.name = "CityActionButton"
	btn.mouse_filter = Control.MOUSE_FILTER_STOP
	btn.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	btn.offset_left = -148.0
	btn.offset_right = -28.0
	btn.offset_top = -60.0
	btn.offset_bottom = 60.0
	btn.custom_minimum_size = Vector2(120.0, 120.0)
	btn.text = "交互"
	btn.visible = false
	var tint := Color(0.78, 0.64, 0.36, 1.0)
	var ink := Color(0.09, 0.11, 0.15, 0.92)
	var normal := StyleBoxFlat.new()
	normal.bg_color = ink
	normal.border_color = Color(tint.r, tint.g, tint.b, 0.85)
	normal.set_border_width_all(3)
	normal.set_corner_radius_all(60)
	normal.content_margin_left = 6.0
	normal.content_margin_right = 6.0
	normal.shadow_color = Color(0, 0, 0, 0.5)
	normal.shadow_size = 8
	normal.shadow_offset = Vector2(0, 3)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(ink.r * 1.9, ink.g * 1.9, ink.b * 1.9, 0.96)
	hover.border_color = tint
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(tint.r * 0.42, tint.g * 0.38, tint.b * 0.26, 1.0)
	pressed.border_color = Color(1.0, 0.92, 0.72, 1.0)
	btn.add_theme_stylebox_override("normal", normal)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("pressed", pressed)
	btn.add_theme_font_size_override("font_size", 30)
	btn.add_theme_color_override("font_color", Color(0.96, 0.90, 0.72, 1.0))
	btn.add_theme_color_override("font_hover_color", Color(1.0, 0.96, 0.82, 1.0))
	btn.add_theme_color_override("font_pressed_color", Color(0.12, 0.10, 0.07, 1.0))
	btn.pressed.connect(_on_city_action)
	$UI.add_child(btn)
	_city_action_btn = btn


## 点击右侧圆形交互按钮：弹出该城池/地点的「进入 / 查看」选项菜单。
func _on_city_action() -> void:
	AudioManager.sfx_click()
	if _city_target.is_empty():
		return
	_city_action_btn.hide()
	_menu.show_for(_city_target, _city_target_pos)


## 新游戏 / 首次进入大地图：随机选一座当前区域的城池附近作为出生点，
## 不再固定出生在建宁。记住出生点，使本次会话后续回大地图稳定在同一城。
func _spawn_at_random_city() -> void:
	var cur := GameState.current_region
	var cities: Array = DataManager.get_table("cities")
	var pool: Array = []
	for c in cities:
		if RegionService.city_in_area(cur, c):
			pool.append(c)
	if pool.is_empty():
		return   # 该区域无城池，沿用 tscn 默认位置
	var c: Dictionary = pool[randi() % pool.size()]
	var base := Vector2(float(c.get("map_x", 0.0)), float(c.get("map_y", 0.0)))
	# 城中随机偏移，落在城门口附近而非正中地标
	var off := Vector2(randf_range(-240.0, 240.0), randf_range(-240.0, 240.0))
	_player.position = base + off
	_player.sync_into_region()   # 夹回区域矩形内，避免落进虚空角落
	# 记出生点：后续回到大地图（进城 / 战斗返回）会恢复到这里，不再每次重新随机
	GameState.return_pos = _player.position
	GameState.return_scene = "world"
