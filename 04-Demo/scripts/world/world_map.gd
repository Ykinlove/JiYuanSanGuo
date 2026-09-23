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
@onready var _btn_zoom: Button = $UI/ActionButtons/BtnZoom
@onready var _action_buttons: HBoxContainer = $UI/ActionButtons
@onready var _city_markers: Node2D = $CityMarkers
@onready var _dialogue: DialogueUI = $UI/DialogueUI
@onready var _minimap: MiniMap = $UI/MiniMap
var _big_map: MiniMap  ## 点击小地图弹出的放大地图覆盖层
var _map_dim: ColorRect  ## 大地图背后的暗色遮罩（关闭时必须一并隐藏）
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
var _toast_tween: Tween
var _busy := false          ## 正在对话 / 切场景 / 弹菜单确认中，暂停角色移动
## 大地图打开时刻与输入免疫期（毫秒）：用于屏蔽「打开那一次点击」的模拟触摸事件，
## 避免地图刚弹出就被同一次点击关掉。详见 _request_close_big_map()。
const MAP_INPUT_GUARD_MS := 320
var _map_opened_at_ms := 0
var _menu_target_id := ""   ## 上一帧交互菜单显示的目标 id（节流用，避免每帧重建）


func _ready() -> void:
	AudioManager.play_bgm("res://assets/audio/bgm/world_map.ogg")

	var map_size := _terrain.get_map_size()
	_player.map_size = map_size

	# 区域窗口：把相机锁定到当前区域矩形（分区加载核心）
	_apply_region_camera()

	# 恢复战斗/进城前的位置（避免场景重载后回到出生点）
	if GameState.return_scene == "world":
		_player.position = GameState.return_pos
		GameState.return_scene = ""

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
	_btn_zoom.pressed.connect(_on_toggle_zoom)
	_style_action_buttons()
	_refresh_zoom_button()

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

	var normal := StyleBoxFlat.new()
	normal.bg_color = ink
	normal.border_color = Color(tint.r, tint.g, tint.b, 0.75)
	normal.set_border_width_all(2)
	normal.set_corner_radius_all(10)
	normal.content_margin_left = 14
	normal.content_margin_right = 14

	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(ink.r * 1.9, ink.g * 1.9, ink.b * 1.9, 0.96)
	hover.border_color = tint

	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(tint.r * 0.42, tint.g * 0.38, tint.b * 0.26, 1.0)
	pressed.border_color = Color(1.0, 0.92, 0.72, 1.0)

	for b in _action_buttons.get_children():
		if not (b is Button):
			continue
		b.add_theme_stylebox_override("normal", normal)
		b.add_theme_stylebox_override("hover", hover)
		b.add_theme_stylebox_override("pressed", pressed)
		b.add_theme_color_override("font_color", Color(0.96, 0.90, 0.72, 1.0))
		b.add_theme_color_override("font_hover_color", Color(1.0, 0.96, 0.82, 1.0))
		b.add_theme_color_override("font_pressed_color", Color(0.12, 0.10, 0.07, 1.0))
		# 触摸目标不小于 86px 高（≈ 9mm），避免手机上点不准
		b.custom_minimum_size = Vector2(170.0, 86.0)


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


func _process(_delta: float) -> void:
	# 小地图每帧刷新（玩家位置 / 朝向 / 镜头视野框）
	_minimap.update_view(_player.position, _player.facing, _camera)
	if _big_map != null and _big_map.visible:
		_big_map.update_view(_player.position, _player.facing, _camera)
		_player.halt()              # 放大地图打开时冻结移动
		return

	# 任一全屏界面开着时冻结移动（含随机事件弹窗，旧代码漏了它：
	# 弹窗开着时角色仍能走动，玩家一走就走出事件点，回来时事件已消失）。
	if _busy or _any_ui_open():
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


func _show_big_map() -> void:
	AudioManager.sfx_click()
	if _big_map == null:
		_big_map = MiniMap.new()
		# 放大版地图：铺满视口、四周留边（等价于 1920×1080 下 180,70 起、1560×940）。
		# 不要写死 1920×1080 —— stretch/aspect = expand 时非 16:9 机型的视口会更宽或更高，
		# 写死尺寸会让大图偏到左上角、遮不满屏幕，旁边露出地图背景 = 观感「错乱」。
		_big_map.expanded = true   ## 放大版：羊皮纸亮色高对比渲染
		_big_map.set_anchors_preset(Control.PRESET_FULL_RECT)
		_big_map.offset_left = 180.0
		_big_map.offset_top = 70.0
		_big_map.offset_right = -180.0
		_big_map.offset_bottom = -70.0
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
	# 关键：必须走 set_mode 触发 _recalc_geometry，否则视图仍是「局部」几何，
	# 天下大图只会画到地图左上角那块空区域（无城无路，看上去即黑屏）。
	# 注意：这里不要提前直接给 view_mode 赋值，否则 set_mode 会因「同值」提前 return。
	_big_map.set_mode(MiniMap.MODE_WORLD)
	_big_map.update_view(_player.position, _player.facing, _camera)
	_big_map.visible = true
	_map_dim.visible = true
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
	_camera.limit_left = int(rect.position.x)
	_camera.limit_top = int(rect.position.y)
	_camera.limit_right = int(rect.end.x)
	_camera.limit_bottom = int(rect.end.y)
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
		_menu_target_id = ""
		return

	# 目标没变时不再重复调 show_for：show_for 内部虽已做 same 判定，
	# 但每帧调用仍会反复走位置重算；一旦判定条件被打乱（例如 id 类型不一致）
	# 就会每帧重建一次按钮，表现为选项重复、甚至一次点击触发两次交互。
	var key := "%s:%s" % [str(best.get("type", "")), str(best.get("id", ""))]
	if _menu.is_open() and key == _menu_target_id:
		return
	_menu_target_id = key
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


func _find_nearest_place() -> Dictionary:
	var closest: Dictionary = {}
	var closest_pos := Vector2.ZERO
	var closest_dist := INF
	for marker in _city_markers.get_children():
		var d := _player.position.distance_to(marker.position)
		var hint := marker.get_node_or_null("Hint")
		var in_range := d < 130.0
		if hint and hint is CanvasItem:
			hint.visible = in_range and not _menu.is_open()
		if in_range and d < closest_dist:
			closest_dist = d
			closest_pos = marker.position
			closest = {
				"type": str(marker.get_meta("city_type", "city")),
				"id": str(marker.get_meta("city_id", "")),
				"name": str(marker.get_meta("city_name", "")),
				"title": str(marker.get_meta("city_title", "")),
				"tags": marker.get_meta("city_tags", []),
				"data": marker.get_meta("city_data", {}),
			}
	if closest.is_empty():
		return {}
	return { "target": closest, "pos": closest_pos, "dist": closest_dist }


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


func _do_spar(target: Dictionary) -> void:
	show_toast("切磋：与 %s 比武（待实装）" % str(target.get("name", "")))


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
	pass


func _on_dialogue_finished() -> void:
	_busy = false
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
		"self_rule":
			_self_rule.open(GameState.current_city_id)
		"achieve":
			_ach_panel.open()
		"city":
			_show_big_map()
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


## 缩放按钮：循环 最小 → 居中 → 最大 → 最小（单键走遍全范围）
## 滚轮/捏合可直接连续缩放，按钮只是快捷档位。
func _on_toggle_zoom() -> void:
	AudioManager.sfx_click()
	_player.zoom_cycle()
	# 小地图跟随镜头：缩到最小即看天下，其余看周边
	var want_world := _player.is_zoomed_out()
	_minimap.set_mode(MiniMap.MODE_WORLD if want_world else MiniMap.MODE_LOCAL)
	# 等缩放动画走完再刷新按钮文字
	await get_tree().create_timer(0.24).timeout
	_refresh_zoom_button()


func _refresh_zoom_button() -> void:
	if _btn_zoom == null:
		return
	# 按所处档位显示目标动作，比「全景/近景」二态更贴合连续缩放
	var r := _player.zoom_ratio()
	if r <= 0.08:
		_btn_zoom.text = "放大"
	elif r >= 0.92:
		_btn_zoom.text = "缩小"
	else:
		_btn_zoom.text = "缩放"


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
