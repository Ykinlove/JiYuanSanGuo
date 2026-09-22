extends Node
## 音频管理器（AudioManager）
## 职责：BGM 淡入淡出切换、SFX 播放、音量控制与持久化。

const BGM_BUS := "Master"
const SETTINGS_PATH := "user://settings.cfg"

var bgm_player: AudioStreamPlayer
var sfx_players: Array[AudioStreamPlayer] = []
const SFX_POOL_SIZE := 6

var master_volume: float = 1.0
var bgm_volume: float = 0.8
var sfx_volume: float = 0.9

var _current_bgm_path: String = ""
var _sfx_index: int = 0


func _ready() -> void:
	bgm_player = AudioStreamPlayer.new()
	bgm_player.bus = BGM_BUS
	add_child(bgm_player)

	for i in range(SFX_POOL_SIZE):
		var p := AudioStreamPlayer.new()
		p.bus = BGM_BUS
		add_child(p)
		sfx_players.append(p)

	load_settings()


## 播放 BGM（若相同则不重播）
func play_bgm(path: String, fade: bool = true) -> void:
	if _current_bgm_path == path and bgm_player.playing:
		return
	if not ResourceLoader.exists(path):
		push_warning("[AudioManager] BGM 不存在：%s" % path)
		return
	_current_bgm_path = path
	var stream := load(path)
	bgm_player.stream = stream
	bgm_player.volume_db = linear_to_db(bgm_volume)
	bgm_player.play()


func stop_bgm() -> void:
	bgm_player.stop()
	_current_bgm_path = ""


## 播放音效
func play_sfx(path: String, volume_scale: float = 1.0) -> void:
	if not ResourceLoader.exists(path):
		return
	var p := sfx_players[_sfx_index]
	_sfx_index = (_sfx_index + 1) % SFX_POOL_SIZE
	p.stream = load(path)
	p.volume_db = linear_to_db(clampf(sfx_volume * volume_scale, 0.0, 1.0))
	p.play()


## 常用音效封装
func sfx_click() -> void:
	play_sfx("res://assets/audio/sfx/click.ogg")


func sfx_confirm() -> void:
	play_sfx("res://assets/audio/sfx/confirm.ogg")


func sfx_cancel() -> void:
	play_sfx("res://assets/audio/sfx/cancel.ogg")


func sfx_hit() -> void:
	play_sfx("res://assets/audio/sfx/hit.ogg")


## 设置
func set_master_volume(v: float) -> void:
	master_volume = clampf(v, 0.0, 1.0)
	_apply_volumes()
	save_settings()


func set_bgm_volume(v: float) -> void:
	bgm_volume = clampf(v, 0.0, 1.0)
	_apply_volumes()
	save_settings()


func set_sfx_volume(v: float) -> void:
	sfx_volume = clampf(v, 0.0, 1.0)
	save_settings()


func _apply_volumes() -> void:
	bgm_player.volume_db = linear_to_db(bgm_volume * master_volume)


func save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("audio", "master", master_volume)
	cfg.set_value("audio", "bgm", bgm_volume)
	cfg.set_value("audio", "sfx", sfx_volume)
	cfg.save(SETTINGS_PATH)


func load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	master_volume = cfg.get_value("audio", "master", 1.0)
	bgm_volume = cfg.get_value("audio", "bgm", 0.8)
	sfx_volume = cfg.get_value("audio", "sfx", 0.9)
	_apply_volumes()
