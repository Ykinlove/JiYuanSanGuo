extends Node
## 战斗黑屏诊断探针（临时取证，定位后可转正式回归断言）
## 运行：godot --headless --path <工程> res://tests/battle_blackout_probe.tscn
##
## 【取证目标】玩家反馈「进入战斗页面后黑屏」。可能的黑屏源：
##   ① SceneRouter 全局转场黑幕 _overlay 没淡出
##   ② 战斗场景自己的开场黑幕 SceneCurtain 没淡出
##   ③ 战斗相机 position/zoom 异常，取景落在背景之外
##   ④ 背景 ColorRect / Sprite 被隐藏或全黑
## 本探针把上述四项的实际状态全部打印，不猜。

var _lines: Array[String] = []


## 递归收集所有"全屏 ColorRect 且颜色偏暗"的遮罩：黑屏的真凶往往就是其中之一
## 忘了关 / 忘了淡出 / 建了没回收。
func _collect_full_rect(n: Node, out: Array) -> void:
	if n is ColorRect and n.name != "Background":
		# 背景本体不算遮挡层：把它计入会让"叠加残亮"恒为 0，指标完全失真
		var cr := n as ColorRect
		var r := cr.get_rect()
		# 实际不透明度 = color.a × modulate.a（淡入淡出多半动的是 modulate）
		var eff_a := cr.color.a * cr.modulate.a
		if r.size.x >= 1000.0 and r.size.y >= 600.0 and eff_a > 0.05:
			out.append({
				"name": cr.get_path(), "color": cr.color, "alpha": eff_a,
				# 【必须查 is_visible_in_tree】子节点自身 visible=true 但父节点隐藏时
				# 实际并不可见；只看 cr.visible 会把"常驻但被隐藏的弹窗"误判成黑屏元凶。
				"visible": cr.is_visible_in_tree(),
			})
	for c in n.get_children():
		_collect_full_rect(c, out)


func _say(t: String) -> void:
	print(t)
	_lines.append(t)


func _ready() -> void:
	_say("================ 战斗黑屏诊断 ================")

	# 【真实数据】此前直接 instantiate 时 troops 为空 → 战场空荡荡，
	# 与玩家实际遭遇战完全不同（_build_battle_set 根本没 spawn 部队）。
	# 这里按 garrison_units_of 的真实结构灌入，才能复现玩家所见。
	GameState.troops = [
		{"unit_id": "infantry", "count": 60, "hero_id": "", "exp": 0},
		{"unit_id": "spearman", "count": 40, "hero_id": "", "exp": 0},
		{"unit_id": "archer", "count": 30, "hero_id": "", "exp": 0},
	]
	GameState.party = [{"hero_id": "181", "level": 3, "exp": 0, "intimacy": 20}]
	GameState.current_encounter = {
		"id": "diag_1",
		"name": "诊断遭遇",
		"type": "battle",
		"enemy_units": [
			{"unit_id": "infantry", "count": 50},
			{"unit_id": "spearman", "count": 35},
			{"unit_id": "archer", "count": 25},
		],
		"rewards": {"gold": [100, 200], "fame": 10},
	}

	var scene := load("res://scenes/battle/battle_scene.tscn") as PackedScene
	var bs := scene.instantiate()
	add_child(bs)

	# 给足帧数：开场黑幕淡出 0.45s（≈27 帧），跑 90 帧绰绰有余
	for _i in range(90):
		await get_tree().process_frame

	# ① 战斗场景自己的开场黑幕
	_say("")
	_say("-- ① 开场黑幕 SceneCurtain --")
	_say("    bs._curtain = %s" % ("null（已淡出并回收）" if bs._curtain == null else str(bs._curtain)))
	var cur := bs.get_node_or_null("UI/SceneCurtain")
	if cur == null:
		_say("    UI/SceneCurtain 节点：不存在（已 queue_free）✅")
	else:
		_say("    UI/SceneCurtain 仍在！color=%s  visible=%s  ⚠️黑幕未消失" % [
			str(cur.color), str(cur.visible)])

	# ② SceneRouter 全局转场黑幕
	_say("")
	_say("-- ② 全局转场黑幕 SceneRouter._overlay --")
	var ov = SceneRouter._overlay
	if ov == null:
		_say("    _overlay = null")
	else:
		_say("    _overlay.color = %s（a=%0.3f，>0 即压黑）" % [str(ov.color), ov.color.a])
		_say("    is_transitioning = %s" % str(SceneRouter.is_transitioning()))

	# ③ 战斗相机
	_say("")
	_say("-- ③ 战斗相机 --")
	var cam := bs.get_node_or_null("BattleCam")
	if cam == null:
		var found: Camera2D = null
		for ch in bs.get_children():
			if ch is Camera2D:
				found = ch
				break
		cam = found
	if cam == null:
		_say("    未找到相机")
	else:
		_say("    相机 %s  pos=%s  zoom=%s  offset=%s  enabled=%s" % [
			str(cam.name), str(cam.position), str(cam.zoom), str(cam.offset), str(cam.enabled)])

	# ④ 背景与根节点
	_say("")
	_say("-- ④ 背景 / 根节点 --")
	var bg := bs.get_node_or_null("Background")
	_say("    Background = %s" % ("缺失" if bg == null else "visible=%s color=%s" % [
		str(bg.visible), str(bg.color)]))
	_say("    根节点 %s visible=%s modulate=%s" % [
		str(bs.name), str(bs.visible), str(bs.modulate)])
	var bgsp := bs.get_node_or_null("BackgroundSprite")
	if bgsp != null:
		_say("    BackgroundSprite visible=%s texture=%s modulate=%s" % [
			str(bgsp.visible), str(bgsp.texture != null), str(bgsp.modulate)])

	# ⑤ 视口实际尺寸（相机取景范围是否覆盖背景 0~1920 x 0~1080）
	_say("")
	_say("-- ⑤ 视口 --")
	var vp := get_viewport()
	_say("    viewport size = %s" % str(vp.get_visible_rect().size))
	_say("    canvas transform = %s" % str(vp.canvas_transform))

	# ⑥ 主角与单位是否真的建出来（黑屏也可能是"什么都没画"）
	_say("")
	_say("-- ⑥ 战场内容 --")
	var ally := bs.get_node_or_null("AllyUnits")
	var enemy := bs.get_node_or_null("EnemyUnits")
	_say("    AllyUnits 子节点 %d，EnemyUnits 子节点 %d" % [
		ally.get_child_count() if ally != null else -1,
		enemy.get_child_count() if enemy != null else -1])
	var pl := bs.get_node_or_null("Player")
	_say("    Player 子节点 %d，pos=%s" % [
		pl.get_child_count() if pl != null else -1, str(pl.position) if pl != null else "-"])
	if pl != null:
		for c in pl.get_children():
			_say("       └ %s" % str(c.name))
	var port := bs.get_node_or_null("Player/Body/Portrait")
	_say("    主角立绘 Portrait：%s" % (
		"已接入 ✅ texture=%s scale=%s" % [
			str(port.texture != null), str(port.scale)] if port != null else "未接入（回退几何体）"))
	_say("    phase = %s" % str(bs._phase))

	# ⑥b 【关键】准备阶段（玩家刚进战斗看到的那一屏）到底压了几层黑？
	#     玩家口中的"黑屏"就发生在这一刻，必须逐层点名。
	_say("")
	_say("-- ⑥b 准备阶段的全屏遮挡（实际可见性） --")
	var dims0 := []
	_collect_full_rect(bs, dims0)
	if dims0.is_empty():
		_say("    无全屏遮挡 ✅")
	for d in dims0:
		_say("    %s  可见=%s  color=%s  实际a=%0.2f" % [
			str(d.get("name")), str(d.get("visible")), str(d.get("color")),
			float(d.get("alpha"))])
	# 战场背景（深绿 0.16,0.22,0.16，亮度取 r 通道 0.16）被各层遮挡后还剩多少
	var remain := 1.0
	for d in dims0:
		if bool(d.get("visible")):
			remain *= (1.0 - float(d.get("alpha")))
	_say("    → 战场背景残亮 = 0.16 × %0.3f = %0.3f" % [remain, 0.16 * remain])
	_say("    → 判定：残亮 < 0.06 即接近纯黑（玩家会说黑屏）")

	# ⑦ 走真实链路：点「即刻开战」后跑满战斗（玩家必经路径，前面只停在准备阶段）
	_say("")
	_say("-- ⑦ 开战后 --")
	bs._begin_battle()
	for _i in range(600):
		await get_tree().process_frame
	_say("    phase = %s" % str(bs._phase))
	_say("    玩家 HP = %0.1f / %0.1f" % [bs._player_hp, bs._player_hp_max])
	_say("    time_scale = %0.2f（≠1 说明慢镜卡住）" % Engine.time_scale)
	_say("    AllyUnits 子节点 %d，EnemyUnits 子节点 %d" % [
		ally.get_child_count() if ally != null else -1,
		enemy.get_child_count() if enemy != null else -1])
	_say("    prepare_overlay = %s（应为 null，否则挡屏）" % str(bs._prepare_overlay))
	# 再检查一次黑幕类遮挡
	var dims := []
	_collect_full_rect(bs, dims)
	for d in dims:
		_say("    全屏遮罩 %s：color=%s visible=%s" % [
			str(d.get("name")), str(d.get("color")), str(d.get("visible"))])

	_say("")
	_say("DIAG_DONE")

	var f := FileAccess.open("res://battle_blackout_diag.txt", FileAccess.WRITE)
	if f != null:
		for ln in _lines:
			f.store_line(ln)
		f.close()
	get_tree().quit()
