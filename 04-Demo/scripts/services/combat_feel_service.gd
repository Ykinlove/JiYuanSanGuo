class_name CombatFeelService
extends RefCounted
## 战斗打击感规则层（CombatFeelService）· M16 系统优化
## 职责：统一读取 combat.json 的 feel 段（顿帧 hitstop / 震屏 shake / 命中减速 time_scale），
##       供战斗场景做即时反馈。全部 static 纯函数——场景/UI 不内联手感数值。
##
## 设计：手感分三档（light 普攻·单挑 / heavy 个人技·克制 / ultimate 大招·军团技）。
##       顿帧通过 Engine.time_scale 短暂降速实现，震屏通过相机 offset 实现；
##       两者在 Compatibility(GLES3) 下均无额外渲染开销，低端机安全（M17）。

## 打击档位
const KIND_LIGHT := "light"
const KIND_HEAVY := "heavy"
const KIND_ULTIMATE := "ultimate"

## combat.json 中手感段键名
const CFG_SECTION := "feel"

## 兜底默认（combat.json 缺失/字段缺失时仍可用）
const _FALLBACK := {
	"time_scale_on_hit": 0.05,
	"hitstop_light": 0.045,
	"hitstop_heavy": 0.085,
	"hitstop_ultimate": 0.13,
	"shake_light": 4.0,
	"shake_heavy": 7.0,
	"shake_ultimate": 12.0,
	"bar_smooth_hp": 9.0,
	"bar_smooth_morale": 6.0,
	"bar_smooth_rage": 7.0,
	"bar_smooth_enemy": 5.0,
	"ghost_hold": 0.35,
	"ghost_catchup": 7.0,
	"low_hp_ratio": 0.3,
	"low_hp_hz_min": 1.6,
	"low_hp_hz_max": 3.2,
	"low_hp_alpha_min": 0.06,
	"low_hp_alpha_max": 0.2,
	"combo_window": 2.2,
	"combo_min": 2,
	"combo_font": 54,
	"combo_pop_scale": 1.35,
	"cam_zoom_begin": 1.05,
	"cam_zoom_skill": 1.10,
	"cam_zoom_kill": 1.14,
	"cam_punch_in": 0.12,
	"cam_punch_out": 0.30,
	"cam_kill_slow": 0.55,
	"cam_kill_slow_time": 0.12,
	"atmos_dust_amount": 26,
	"atmos_dust_alpha": 0.16,
	"atmos_fog_alpha": 0.10,
	"bgm_prepare": "res://assets/audio/bgm/formation.ogg",
	"bgm_fight": "res://assets/audio/bgm/battle.ogg",
	"bgm_win": "res://assets/audio/bgm/victory.ogg",
}


static func _section() -> Dictionary:
	var rec := DataManager.get_record("combat", "root")
	if rec.is_empty():
		return {}
	return rec.get(CFG_SECTION, {})


static func _num(key: String) -> float:
	return float(_section().get(key, _FALLBACK.get(key, 0.0)))


## 命中瞬间的时间缩放（越小顿感越强）
static func time_scale_on_hit() -> float:
	return clampf(_num("time_scale_on_hit"), 0.0, 1.0)


## 各档顿帧时长（秒；0 表示不顿帧）
static func hitstop(kind: String) -> float:
	match kind:
		KIND_HEAVY:
			return maxf(0.0, _num("hitstop_heavy"))
		KIND_ULTIMATE:
			return maxf(0.0, _num("hitstop_ultimate"))
		_:
			return maxf(0.0, _num("hitstop_light"))


# ------------------------------------------------------------------
# 战斗演出（2026-09-30 用户反馈「战斗页面太生硬死板」）
# 顿帧/震屏只解决"手感"，但玩家**看不见**发生了什么：
#   · 打出去多少伤害 —— 没有飘字，只能盯血条猜
#   · 谁在出手       —— 攻击是瞬时扣血，双方站桩对砍
#   · 部队怎么没的   —— 阵亡是 visible=false，啪一下消失
# 这一段提供上述演出的全部参数，数值一律留在 combat.json。
# ------------------------------------------------------------------

## 伤害飘字：上浮距离（像素）/ 存活时长（秒）/ 字号 / 暴击字号
static func damage_number_rise() -> float:
	return maxf(0.0, _num("damage_number_rise"))


static func damage_number_life() -> float:
	return maxf(0.05, _num("damage_number_life"))


static func damage_number_font() -> int:
	return int(_num("damage_number_font"))


static func damage_number_font_crit() -> int:
	return int(_num("damage_number_font_crit"))


## 出手前突：速度（像素/秒）与衰减系数（越大收得越快）
static func lunge_speed() -> float:
	return maxf(0.0, _num("lunge_speed"))


static func lunge_decay() -> float:
	return maxf(0.1, _num("lunge_decay"))


## 受击击退：速度（像素/秒）与衰减系数
static func knock_speed() -> float:
	return maxf(0.0, _num("knock_speed"))


static func knock_decay() -> float:
	return maxf(0.1, _num("knock_decay"))


## 主角挥砍：前突距离（像素）与「递出去 / 收回来」的时长（秒）。
## 【为什么是"前突再收回"而不是冲量】冲量衰减到 0 就停在那儿，
## 连点攻击会让主角一路飘进敌阵；前突必须回中，才能反复使用。
static func swing_distance() -> float:
	return maxf(0.0, _num("swing_distance"))


static func swing_out() -> float:
	return maxf(0.02, _num("swing_out"))


static func swing_back() -> float:
	return maxf(0.02, _num("swing_back"))


## 阵亡消散：时长（秒）与下沉距离（像素）
static func death_fade() -> float:
	return maxf(0.08, _num("death_fade"))


static func death_sink() -> float:
	return maxf(0.0, _num("death_sink"))


## 大招全屏闪：峰值透明度与淡出时长（秒）
static func ult_flash_peak() -> float:
	return clampf(_num("ult_flash_peak"), 0.0, 1.0)


static func ult_flash_life() -> float:
	return maxf(0.05, _num("ult_flash_life"))


# ------------------------------------------------------------------
# HUD 平滑（2026-09-30 第二轮战斗优化）
# 血条此前是「value = 当前值」瞬间跳格，扣血/涨怒都像啪一下切过去。
# 改成每帧指数逼近目标值后，血条才有"流动"；再叠残影条与残血警示，
# 让玩家在混战中也读得清自己还剩多少血。
# ------------------------------------------------------------------

## 血条逼近速率（越大越快）：hp / morale / rage / enemy
static func bar_smooth(kind: String) -> float:
	return maxf(0.5, _num("bar_smooth_%s" % kind))


## 指数逼近：cur 向 target 靠拢 1-e^(-k·dt) 的比例。
## 【为什么不用 lerp(cur,target,0.2)】那种写法跟帧率绑死：120Hz 下收敛
## 快一倍、掉到 20Hz 又慢得像没动。这里的结果只跟真实经过的时间有关，
## 掉帧时血条依然按同样的"秒速"流动。
static func approach(cur: float, target: float, delta: float, k: float) -> float:
	return lerpf(cur, target, 1.0 - exp(-k * delta))


## 掉血后残影条停留多久才开始收（秒）
static func ghost_hold() -> float:
	return maxf(0.0, _num("ghost_hold"))


## 残影条收拢速率
static func ghost_catchup() -> float:
	return maxf(0.5, _num("ghost_catchup"))


## 主角血量低于此比例即进入残血警示
static func low_hp_ratio() -> float:
	return clampf(_num("low_hp_ratio"), 0.0, 1.0)


## 残血脉冲频率区间（Hz）
static func low_hp_hz_min() -> float:
	return maxf(0.2, _num("low_hp_hz_min"))


static func low_hp_hz_max() -> float:
	return maxf(0.2, _num("low_hp_hz_max"))


## 残血脉冲透明度区间
static func low_hp_alpha_min() -> float:
	return clampf(_num("low_hp_alpha_min"), 0.0, 1.0)


static func low_hp_alpha_max() -> float:
	return clampf(_num("low_hp_alpha_max"), 0.0, 1.0)


## 连斩：中断窗口（秒）/ 至少几连才显示 / 字号 / 弹出缩放
static func combo_window() -> float:
	return maxf(0.3, _num("combo_window"))


static func combo_min() -> int:
	return maxi(2, int(_num("combo_min")))


static func combo_font() -> int:
	return maxi(12, int(_num("combo_font")))


static func combo_pop_scale() -> float:
	return maxf(1.05, _num("combo_pop_scale"))


## 各档震屏振幅（像素）
static func shake(kind: String) -> float:
	match kind:
		KIND_HEAVY:
			return maxf(0.0, _num("shake_heavy"))
		KIND_ULTIMATE:
			return maxf(0.0, _num("shake_ultimate"))
		_:
			return maxf(0.0, _num("shake_light"))


## 一次性取用某档全部反馈参数
static func feedback(kind: String) -> Dictionary:
	return {
		"hitstop": hitstop(kind),
		"shake": shake(kind),
		"time_scale": time_scale_on_hit(),
	}


# ------------------------------------------------------------------
# 镜头语言 + 战场氛围 + BGM 战况三态（2026-09-30 第四轮续）
# 固定竞技场不连续跟随（保持全战场可读），改用『推近特写』制造电影感。
# ------------------------------------------------------------------

## 推近倍率：开战一紧 / 大招 / 击杀特写
static func cam_zoom(kind: String) -> float:
	match kind:
		"skill":
			return maxf(1.0, _num("cam_zoom_skill"))
		"kill":
			return maxf(1.0, _num("cam_zoom_kill"))
		_:
			return maxf(1.0, _num("cam_zoom_begin"))


## 推近 / 回正时长（秒）
static func cam_punch_in() -> float:
	return maxf(0.03, _num("cam_punch_in"))


static func cam_punch_out() -> float:
	return maxf(0.05, _num("cam_punch_out"))


## 击杀特写短慢镜：time_scale 与持续时长（秒）。复用 _hitstop_end_ms 机制还原。
static func cam_kill_slow() -> float:
	return clampf(_num("cam_kill_slow"), 0.0, 1.0)


static func cam_kill_slow_time() -> float:
	return maxf(0.05, _num("cam_kill_slow_time"))


## 战场氛围：地面扬尘粒子数 / 扬尘透明度 / 远景烟雾透明度
static func atmos_dust_amount() -> int:
	return maxi(0, int(_num("atmos_dust_amount")))


static func atmos_dust_alpha() -> float:
	return clampf(_num("atmos_dust_alpha"), 0.0, 1.0)


static func atmos_fog_alpha() -> float:
	return clampf(_num("atmos_fog_alpha"), 0.0, 1.0)


## BGM 战况三态路径（铺垫/交战/胜利）；空串表示沿用当前曲
static func bgm_prepare() -> String:
	return str(_section().get("bgm_prepare", _FALLBACK.get("bgm_prepare", "")))


static func bgm_fight() -> String:
	return str(_section().get("bgm_fight", _FALLBACK.get("bgm_fight", "")))


static func bgm_win() -> String:
	return str(_section().get("bgm_win", _FALLBACK.get("bgm_win", "")))
