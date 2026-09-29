extends Node2D
class_name DamageNumber
## 伤害飘字（DamageNumber）
## ------------------------------------------------------------------
## 【为什么需要它】战斗此前只有血条在缩，玩家看不到"这一下打了多少"、
## 也分不清是谁挨了打 —— 观感就是双方站桩对砍、数字在后台悄悄变化。
## 飘字是成本最低、提升最明显的打击反馈。
##
## 用法：DamageNumber.pop(父节点, 世界坐标, 文本, 样式)
##   父节点用受击单位所在图层（同一坐标系），飘字才会跟着战场走。
##
## 三个动作叠出"弹出来"的感觉：
##   ① 先放大到 1.25 再收回 1.0（弹出）
##   ② 持续上浮（读 CombatFeelService.damage_number_rise）
##   ③ 后半程淡出（读 damage_number_life）
## 生命周期结束自动 queue_free，调用方不用管回收。
## ------------------------------------------------------------------

## 样式：敌军挨打（暖白）/ 我方挨打（红）/ 克制暴击（金）/ 提示（灰白）
const COLOR_ENEMY := Color(1.00, 0.94, 0.78, 1.0)
const COLOR_ALLY := Color(1.00, 0.45, 0.38, 1.0)
const COLOR_CRIT := Color(1.00, 0.84, 0.32, 1.0)
const COLOR_INFO := Color(0.92, 0.92, 0.95, 1.0)


## 弹出一个飘字。crit=true 用金色放大字号；ally_hurt=true 用红色（我方挨打）。
static func pop(parent: Node, at: Vector2, text: String,
		crit: bool = false, ally_hurt: bool = false) -> void:
	if parent == null or not is_instance_valid(parent):
		return
	var life := CombatFeelService.damage_number_life()
	var rise := CombatFeelService.damage_number_rise()
	var font := CombatFeelService.damage_number_font_crit() if crit \
		else CombatFeelService.damage_number_font()

	var col := COLOR_CRIT if crit else (COLOR_ALLY if ally_hurt else COLOR_ENEMY)

	var n := Node2D.new()
	n.name = "DamageNumber"
	n.position = at
	# 战场里部队密集，飘字必须压在最上层，否则会被方阵底座盖住
	n.z_index = 200
	n.z_as_relative = false

	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", font)
	lbl.add_theme_color_override("font_color", col)
	# 描边（深墨）：战场背景深浅不一，纯色字容易糊在背景里
	lbl.add_theme_color_override("font_shadow_color", Color(0.05, 0.04, 0.03, 0.9))
	lbl.add_theme_constant_override("shadow_offset_x", 2)
	lbl.add_theme_constant_override("shadow_offset_y", 2)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.size = Vector2(160.0, float(font) * 1.6)
	lbl.position = Vector2(-80.0, -float(font) * 0.8)
	n.add_child(lbl)
	parent.add_child(n)

	var tw := n.create_tween()
	tw.set_parallel(true)
	# ① 弹出：先冲过头再收回，比匀速放大有"蹦出来"的劲
	tw.tween_property(n, "scale", Vector2(1.28, 1.28), life * 0.22)
	tw.tween_property(n, "position:y", at.y - rise, life)
	tw.chain().tween_property(n, "scale", Vector2(1.0, 1.0), life * 0.25)
	# ② 淡出：前半程保持不透明，后半程才化开（保证数字看得清）
	var fade := n.create_tween()
	fade.tween_interval(life * 0.45)
	fade.tween_property(n, "modulate:a", 0.0, life * 0.55)
	fade.tween_callback(n.queue_free)


## 便捷：整数伤害（自动归零以下为 0）
static func pop_damage(parent: Node, at: Vector2, amount: float,
		crit: bool = false, ally_hurt: bool = false) -> void:
	pop(parent, at, "%d" % maxi(0, int(round(amount))), crit, ally_hurt)
