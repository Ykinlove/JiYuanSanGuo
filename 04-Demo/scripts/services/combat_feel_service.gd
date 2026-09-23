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
