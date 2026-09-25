extends Node
## 剧情导演（StoryDirector，autoload）
## ------------------------------------------------------------------
## 职责：把《剧本规划-三国全史篇》的时间轴数据变成运行时事件——
##   1. 监听任务完成 → MainlineService.on_quest_completed 推进章节（跳时间/置旁白标记）；
##   2. 监听日期变化 → 按当前章节播报史实锚点事件（storyline.json，toast 史官笔录）。
## 本节点不持有 UI：所有播报走 EventBus.toast，旁白由 world_map 消费 pending 标记播放。
## 数据：assets/data/storyline.json（chapters[].events[]，可改文案不动代码）。
## ------------------------------------------------------------------

const STORYLINE_PATH := "res://assets/data/storyline.json"

## 当前章节待播锚点（y*12+m -> [文本,...]）；重复播报由 GameState.story_fired 去重
## 【R1-13】去重戳入存档：读档当天已播的锚点不再重弹，新档自动清空
var _events_by_date: Dictionary = {}
var _chapter_titles: Dictionary = {}


func _ready() -> void:
	_load_storyline()
	EventBus.quest_completed.connect(_on_quest_completed)
	EventBus.date_changed.connect(_on_date_changed)


func _load_storyline() -> void:
	var txt := FileAccess.get_file_as_string(STORYLINE_PATH)
	if txt.is_empty():
		push_warning("[StoryDirector] storyline.json 缺失，锚点事件停用")
		return
	var parsed: Variant = JSON.parse_string(txt)
	if not (parsed is Dictionary):
		push_warning("[StoryDirector] storyline.json 解析失败")
		return
	var chapters: Array = parsed.get("chapters", [])
	for ch in chapters:
		if not (ch is Dictionary):
			continue
		_chapter_titles[int(ch.get("chapter", 0))] = str(ch.get("name", ""))
		for ev in ch.get("events", []):
			if not (ev is Dictionary):
				continue
			var key := int(ev.get("y", 0)) * 12 + int(ev.get("m", 0))
			if not _events_by_date.has(key):
				_events_by_date[key] = []
			_events_by_date[key].append(str(ev.get("text", "")))


func chapter_title(ch: int) -> String:
	return str(_chapter_titles.get(ch, MainlineService.chapter_title(ch)))


func _on_quest_completed(qid: String) -> void:
	var res := MainlineService.on_quest_completed(qid)
	if not bool(res.get("settled", false)):
		return
	var ch := int(res.get("chapter", 0))
	if bool(res.get("ending", false)):
		EventBus.show_toast("【史官】三分归晋之局已定，而你的名字，已留在了青史之间。")
	else:
		var nxt := mini(ch + 1, MainlineService.MAX_CHAPTER)
		EventBus.show_toast("【史官】%s 终。天下风云再起——新的篇章已然开启。" % chapter_title(ch))
		EventBus.show_toast("主线推进：%s（公元 %s）" % [chapter_title(nxt), GameState.get_date_text()])


func _on_date_changed(y: int, m: int, _d: int) -> void:
	var key: int = y * 12 + m
	if not _events_by_date.has(key):
		return
	var arr: Array = _events_by_date[key]
	for i in range(arr.size()):
		var stamp := "%d_%d" % [key, i]   ## 每个日期只经过一次，按 (日期,序号) 去重即可
		if stamp in GameState.story_fired:
			continue
		GameState.story_fired.append(stamp)
		var text := str(arr[i])
		if not text.is_empty():
			EventBus.show_toast("【史官·公元%d年%d月】%s" % [y, m, text])
