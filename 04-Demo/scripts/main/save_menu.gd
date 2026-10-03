extends Control
class_name SaveMenu
## 存档菜单（SaveMenu）
## 职责：展示存档槽列表，支持存/读/删。
## 入口：主菜单「读取存档」、游戏内系统面板「保存/读取存档」。
## SceneRouter.goto 不传参，故用静态字段传递「模式 + 返回场景」，由 open_as 统一设置。

## load / save（进入场景时读取，随后复位）
static var pending_mode: String = "load"
## 返回目标场景 key
static var pending_return: String = "main_menu"
## 【第六十二轮·防误触】进入本界面时**是否存在进行中的对局**。
## 由 open_as 依据调用来源写入：主菜单入口=false，游戏内系统面板入口=true。
## 读档要靠它判断「当前未保存进度是否会被丢弃」——pending_return 也能推断，
## 但那是**表现层字段**（返回哪个场景），拿它承载「有没有对局」是耦合，
## 独立字段更直白，也避免以后改返回逻辑时连带改坏判据。
static var pending_in_game: bool = false

@onready var _slot_list: VBoxContainer = %SlotList
@onready var _btn_back: Button = %BtnBack
@onready var _title: Label = %TitleLabel

var _mode: String = "load"   ## load / save

## 删除确认弹窗（B10，与大地图/城内同一套 sub-modal 视觉）
var _del_confirm: Control = null
var _pending_del_slot: int = -1
## 【第六十一轮·防误触】覆盖确认弹窗。
## 原缺口：删除有二次确认，但**覆盖已存在的存档一点即过**——
## 而覆盖的代价（丢掉一整局进度）与删档等价，同屏两个按钮却一个拦一个放行。
var _ovr_confirm: Control = null
var _pending_ovr_slot: int = -1
## 覆盖确认时展示的旧档摘要（存疑信息快照，避免确认态与列表行出现两个版本）
var _ovr_old_name := ""
var _ovr_old_level := 0
var _ovr_old_date := ""
## 【第六十二轮·防误触】读档确认弹窗。
## 取证：自动存档只在 create_hero（创角）与 battle_scene（战斗结算）两处写；
## `grep SaveManager. scripts/world|city|ui` 零命中 —— 跑商、招兵、占地、推进
## 月份全部只存于内存。而 GameState.from_dict() 会用 79 个字段**全量覆盖**内存态。
## 于是「战斗后跑商赚 3000 金 → 点读取存档」= 一整段进度无声蒸发，零确认。
## 同屏反证：settings_panel 的「返回主菜单」明确提示"未保存的进度将丢失"并弹确认，
## 一屏之隔的「读取存档」同样丢进度却一点即过 —— 行为不对称。
var _ld_confirm: Control = null
var _pending_ld_slot: int = -1
## 读档目标档摘要（同样是入参快照，确认态不重查）
var _ld_target_name := ""
var _ld_target_level := 0
var _ld_target_date := ""
## 进入本界面时是否有进行中对局（读档确认的前提条件）
var _in_game := false


## 以指定模式打开存档菜单（供主菜单 / 游戏内系统面板调用）
## in_game=true 表示「当前有进行中的对局」—— 游戏内读档会丢弃未保存进度，
## 需要二次确认；主菜单进来时无对局，不该平白加一步。
static func open_as(mode: String, return_scene: String = "main_menu",
		in_game: bool = false) -> void:
	pending_mode = mode
	pending_return = return_scene
	pending_in_game = in_game
	SceneRouter.goto("save_menu")


func _ready() -> void:
	var back_target := pending_return
	_mode = pending_mode
	_in_game = pending_in_game
	pending_mode = "load"
	pending_return = "main_menu"
	pending_in_game = false

	_btn_back.pressed.connect(func():
		AudioManager.sfx_click()
		SceneRouter.goto(back_target)
	)
	_title.text = "读取存档" if _mode == "load" else "保存存档"
	_refresh()


func _refresh() -> void:
	for child in _slot_list.get_children():
		child.queue_free()

	var slots := SaveManager.get_save_slots()
	for info in slots:
		# 保存模式下不展示自动存档槽（自动存档由系统写入）
		if _mode == "save" and info["is_auto"]:
			continue
		_slot_list.add_child(_make_slot_row(info))


func _make_slot_row(info: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, 96)
	row.add_theme_constant_override("separation", 20)

	var slot_no: int = info["slot"]
	var label_text := "自动存档" if info["is_auto"] else "存档 %d" % slot_no

	var name_btn := Button.new()
	name_btn.custom_minimum_size = Vector2(760, 96)
	name_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_btn.add_theme_font_size_override("font_size", 26)
	if info["exists"]:
		name_btn.text = "%s　·　%s　Lv.%d　·　%s" % [
			label_text, info["player_name"], info["level"], info["date_text"]
		]
	else:
		name_btn.text = "%s　·　空" % label_text
		name_btn.disabled = _mode == "load"
	# 存已有档 → 走覆盖二次确认（不可逆），故把info 快照传下去供弹窗展示
	name_btn.pressed.connect(func(): _on_slot_pressed(slot_no, info["exists"], info))
	row.add_child(name_btn)

	if info["exists"] and not info["is_auto"]:
		var del_btn := Button.new()
		del_btn.custom_minimum_size = Vector2(140, 96)
		del_btn.add_theme_font_size_override("font_size", 24)
		del_btn.text = "删除"
		del_btn.pressed.connect(func(): _show_del_confirm(slot_no))
		row.add_child(del_btn)

	return row


## 删除确认弹窗（B10：误触即永久丢档，二次确认拦截）
func _show_del_confirm(slot_no: int) -> void:
	if _del_confirm != null:
		return
	_pending_del_slot = slot_no
	var m := UITheme.make_sub_modal(self, "删除存档？",
		_close_del_confirm, Vector2(760, 440))
	_del_confirm = m["dim"]
	var body: VBoxContainer = m["body"]
	var tip := UITheme.label(
		"该存档将被永久删除，删除后无法找回。确定删除吗？",
		UITheme.FS_BODY, UITheme.TEXT)
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(tip)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 28)
	var cancel := UITheme.button("再想想", UITheme.FS_BODY, Vector2(240, 84))
	cancel.pressed.connect(func():
		AudioManager.sfx_click()
		_close_del_confirm())
	var ok := UITheme.button("确认删除", UITheme.FS_BODY, Vector2(240, 84))
	ok.pressed.connect(func():
		AudioManager.sfx_confirm()
		var slot := _pending_del_slot
		_close_del_confirm()
		if slot >= 0:
			SaveManager.delete_save(slot)
			_refresh())
	row.add_child(cancel)
	row.add_child(ok)
	body.add_child(row)


func _close_del_confirm() -> void:
	if _del_confirm != null and is_instance_valid(_del_confirm):
		_del_confirm.queue_free()
	_del_confirm = null
	_pending_del_slot = -1


func _on_slot_pressed(slot: int, exists: bool, info: Dictionary = {}) -> void:
	AudioManager.sfx_confirm()
	if _mode == "load":
		# 【第六十二轮·防误触】游戏内读档会丢弃**当前未保存的进度**：
		# 自动存档只在创角与战斗结算写，跑商/招兵/占地/推进月份全在内存里，
		# 而 from_dict 会用 79 个字段全量覆盖。点一下读档，这段进度就没了。
		# 与同屏「返回主菜单」的确认提示对齐；主菜单进来无对局，不加这一步。
		if exists and _in_game:
			_show_load_confirm(slot, info)
			return
		_do_load(slot)
		return
	# 【第六十一轮·防误触】保存模式：覆盖已存在的档必须二次确认。
	# 覆盖不可逆（旧进度永久丢失），代价与删档等价 —— 删除有拦截而覆盖没有，
	# 是同屏两个按钮行为不一致的真实缺口。空槽直达，不平白加步骤。
	if exists:
		_show_overwrite_confirm(slot, info)
		return
	if SaveManager.save_game(slot):
		_refresh()


## 执行读档并进入世界（第61 轮J1 要求 load 分支先于 exists 判断 return，
## 故实际读档动作抽到这里，确认/直读两条路径共用，避免逻辑分叉）
func _do_load(slot: int) -> void:
	if SaveManager.load_game(slot):
		SceneRouter.goto_fresh("world")   # 入世入口：清空菜单残留历史（R1-02）


## 【第六十一轮】覆盖已存在存档的二次确认。
## 与 _show_del_confirm 同一套sub-modal 视觉；文案里的旧档信息取**入参快照**，
## 不在确认态重查 SaveManager —— 否则列表刷新后同一弹窗会显示两个版本的旧档信息。
func _show_overwrite_confirm(slot_no: int, info: Dictionary = {}) -> void:
	if _ovr_confirm != null:
		return
	_pending_ovr_slot = slot_no
	_ovr_old_name = str(info.get("player_name", "未知角色"))
	_ovr_old_level = int(info.get("level", 1))
	_ovr_old_date = str(info.get("date_text", ""))

	var m := UITheme.make_sub_modal(self, "覆盖存档？",
		_close_overwrite_confirm, Vector2(760, 520))
	_ovr_confirm = m["dim"]
	var body: VBoxContainer = m["body"]

	var tip := UITheme.label(
		"存档 %d 已有进度：%s　Lv.%d　%s。\n覆盖后旧进度永久丢失，无法找回。"
		% [slot_no, _ovr_old_name, _ovr_old_level, _ovr_old_date],
		UITheme.FS_BODY, UITheme.TEXT)
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(tip)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 28)
	# 撤销放左（拇指高频区留给撤销），与删档确认一致
	var cancel := UITheme.button("再想想", UITheme.FS_BODY, Vector2(240, 84))
	cancel.pressed.connect(func():
		AudioManager.sfx_click()
		_close_overwrite_confirm())
	var ok := UITheme.button("确认覆盖", UITheme.FS_BODY, Vector2(240, 84))
	ok.pressed.connect(func():
		AudioManager.sfx_confirm()
		var slot := _pending_ovr_slot
		_close_overwrite_confirm()
		if slot >= 0 and SaveManager.save_game(slot):
			_refresh())
	row.add_child(cancel)
	row.add_child(ok)
	body.add_child(row)


func _close_overwrite_confirm() -> void:
	if _ovr_confirm != null and is_instance_valid(_ovr_confirm):
		_ovr_confirm.queue_free()
	_ovr_confirm = null
	_pending_ovr_slot = -1


## 【第六十二轮】游戏内读档的二次确认。
## 与覆盖确认同一套 sub-modal 视觉。文案要点明**丢的是什么**：
##   - 当前未保存的进度会消失（跑商/招兵/占地/月份推进都只在内存里）；
##   - 会回到哪个档（角色/等级/公元年月，取入参快照）。
## 「自动存档已保留」这句话不能写 —— 自动档只在创角与战斗结算写，
## 拿它当兜底承诺等于骗玩家（settings_panel 的返回主菜单提示就这么写的，
## 但那里场景是「回主菜单后可再继续读自动档」，语境不同；此处读档会直接覆盖内存态）。
func _show_load_confirm(slot_no: int, info: Dictionary = {}) -> void:
	if _ld_confirm != null:
		return
	_pending_ld_slot = slot_no
	_ld_target_name = str(info.get("player_name", "未知角色"))
	_ld_target_level = int(info.get("level", 1))
	_ld_target_date = str(info.get("date_text", ""))

	var m := UITheme.make_sub_modal(self, "读取存档？",
		_close_load_confirm, Vector2(760, 560))
	_ld_confirm = m["dim"]
	var body: VBoxContainer = m["body"]

	var tip := UITheme.label(
		"当前未保存的进度将全部丢失，包括跑商所得、招募兵力、\n"
		+ "攻城略地与时间推进——这些尚未写入任何存档。\n\n"
		+ "即将读取：存档 %d　%s　Lv.%d　%s"
		% [slot_no, _ld_target_name, _ld_target_level, _ld_target_date],
		UITheme.FS_BODY, UITheme.TEXT)
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(tip)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 28)
	# 撤销放左（与覆盖/删除确认一致）
	var cancel := UITheme.button("再想想", UITheme.FS_BODY, Vector2(240, 84))
	cancel.pressed.connect(func():
		AudioManager.sfx_click()
		_close_load_confirm())
	var ok := UITheme.button("确认读取", UITheme.FS_BODY, Vector2(240, 84))
	ok.pressed.connect(func():
		AudioManager.sfx_confirm()
		var slot := _pending_ld_slot
		_close_load_confirm()
		if slot >= 0:
			_do_load(slot))
	row.add_child(cancel)
	row.add_child(ok)
	body.add_child(row)


func _close_load_confirm() -> void:
	if _ld_confirm != null and is_instance_valid(_ld_confirm):
		_ld_confirm.queue_free()
	_ld_confirm = null
	_pending_ld_slot = -1
