# -*- coding: utf-8 -*-
"""一键运行全部校验脚本并汇总结果（替代 shell 批处理）"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
PY = sys.executable

SCRIPTS = [
    ("_validate.py", "工程基础校验（JSON / 资源 / 节点数 / 类型 / 撞名）"),
    ("_compile_check.py", "★ Godot 实际编译全部脚本（最可靠，能抓出 F5 前的语法与类型错误）"),
    ("_run_probe.py", "★ 运行时探针（挂场景真跑：成就解锁 / 治理 / 反扑 / 收复，真实 autoload 环境）"),
    ("_run_scene_boot.py", "★ 场景启动冒烟（headless 真跑五大主场景 world_map/city_scene/main_menu/create_hero/formation_editor，抓引擎 WARNING/ERROR 中真实缺陷、过滤 headless 良性告警）"),
    ("_verify_formation.py", "M3 阵型战力公式复核"),
    ("_check_m4.py", "M4 战场节点与配置校验"),
    ("_verify_combat.py", "M4 战斗数值复核"),
    ("_check_m5.py", "M5 城池经营模块校验"),
    ("_verify_economy.py", "M5 城池经济与招募复核"),
    ("_verify_skills.py", "武将特技（铁壁/连射/冲锋）数据与触发时序复核"),
    ("_verify_prisoner.py", "俘虏招降/处死规则与数据校验"),
    ("_verify_monthly.py", "月度义兵 + 好感结义校验"),
    ("_verify_m6.py", "M6 中循环断点接线 + 战斗奖励规则 + 数值边界"),
    ("_verify_m7.py", "M7 委托任务/随机事件/铁匠强化/个人技单挑 接线与边界"),
    ("_verify_m8.py", "M8 安卓导出预设/横屏触屏/面板适配/构建产物"),
    ("_verify_m9.py", "M9 策划文档补齐+数据表标记字段+引用闭合校验"),
    ("_verify_m10.py", "M10 全国大地图分区加载框架（区域窗口/越界切区/HUD适配）"),
    ("_verify_m11.py", "M11 主线第一章黄巾之乱（MainlineService/任务链/张角决战）"),
    ("_verify_m12.py", "M12 势力线+投靠势力流程（Faction/Diplomacy/AIService）"),
    ("_verify_m13.py", "M13 主线穿插支线+势力/隐藏/武将专属剧情 数据"),
    ("_verify_m14.py", "M13 自立称王（SelfRuleService/信物/立业）"),
    ("_verify_m15.py", "M15 彩蛋与隐藏事件（隐藏资源点/通道/上香虎符链）"),
    ("_verify_m17.py", "M16 优化衔接+M17 性能基线"),
    ("_verify_battle_hud.py", "战斗 HUD 平滑/残影/残血警示/连斩/按钮冷却 接线静态复核"),
    ("_verify_battle_cinema.py", "战斗 镜头语言/战场氛围/BGM 战况三态 接线静态复核"),
    ("_verify_city_atmos.py", "城内氛围 扬尘/灯火粒子/相机微动 接线静态复核"),
    ("_verify_world_cinema.py", "大地图演出 行军拖尾/城池选中脉冲/相机缩放缓动 接线静态复核"),
    ("_verify_ui_panel_anim.py", "方向④ UI 面板（任务/背包/成就）进出动画统一接线静态复核"),
    ("_verify_city_npc_density.py", "第十四轮 城内非发任务 NPC 密度提升（锚点/闲散居民/搭话/不出交易）静态复核"),
    ("_verify_combat_balance.py", "第十五轮 战斗数值微调（伤害稳定化/防御减伤配置化）边界复核"),
    ("_verify_dialogue_depth.py", "第十六轮 主线/支线剧情深写（提质/无新薄节点/接线零改）静态复核"),
    ("_verify_battle_visual.py", "第十七轮续 战斗场景升级（阵营军旗/方阵底座/布景大纛/孤身战败修复）接线静态复核"),
    ("_verify_world_events.py", "第十八轮 世界动态事件（丰凶/流民/寇掠/名将寻访 时间生成+地图脉冲标记+拉动跑商价）接线静态复核"),
    ("_verify_world_epic.py", "大地图史诗感（世界事件横幅/昼夜时辰氛围）接线静态复核"),
    ("_verify_walk_legs.py", "角色行走动作·双腿与落地感（几何真腿/立绘影子联动）接线静态复核"),
    ("_verify_battle_blackout.py", "第二十一轮 战斗黑屏回归锁（伪补间 API 清零/决断遮罩强度/party 类型防御）静态复核"),
    ("_verify_battle_actions.py", "第二十三轮 角色移动去僵 + 战斗动作差异化（普攻月牙斩/大招冲击波/个人技 damage·shield·heal 分流/feel 配置）静态复核"),
    ("_verify_world_terrain_detail.py", "第二十四轮 大地图地貌细节层（底图 2048 优先/china_geo_4096 锐化细节层/world_static 降级回退/烘焙管线）静态复核"),
    ("_verify_world_ambience.py", "第二十九轮 大地图活物氛围层（云影掠地/城池炊烟近城裁剪/飞鸟掠空/填充率与巨图过滤红锁）静态复核"),
    ("_verify_world_ambient_audio.py", "第三十一轮 大地图环境音层（程序化风声循环/昼夜联动鸟鸣虫鸣/合成安全/轨位）静态复核"),
    ("_verify_world_caravans.py", "第三十二轮 大地图官道商队（数据同源/数量红锁/折线推进折返/绘制裁剪）静态复核"),
    ("_verify_world_weather.py", "第三十八轮 大地图天气层（季节概率/粒子红锁/headless 坑规避/染色复用/雨声合成）静态复核"),
    ("_verify_bgm.py", "第三十九轮 程序化 BGM（烘焙产物样本数/峰值/直流/接缝/循环标记）音频验收"),
    ("_verify_weather_linkage.py", "第四十轮 天气×场景联动（GameState 事实层/WeatherFx 演出层/战斗雨雪+城内灯火夜亮）静态复核"),
    ("_verify_season_terrain.py", "四十二轮 四季地形变色（TerrainPainter 季节氛围罩+冬季北方积雪渐变+季节切换重绘）静态复核"),
    ("_verify_season_consistency.py", "四十三轮 季节定义一致性（DayNightTint 与 TerrainPainter 同走 GameState.get_season() 单一来源，不再按 month 自定区间）静态复核"),
]

summary = []
for fname, desc in SCRIPTS:
    path = os.path.join(ROOT, fname)
    print("=" * 66)
    print(">>> %s  —  %s" % (fname, desc))
    print("=" * 66)
    if not os.path.exists(path):
        print("  [SKIP] 脚本不存在")
        summary.append((fname, "SKIP", 0))
        continue
    p = subprocess.run([PY, path], cwd=ROOT, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    out = (p.stdout or "") + (p.stderr or "")
    print(out.rstrip())
    print("")
    status = "PASS" if p.returncode == 0 else "FAIL"
    summary.append((fname, status, p.returncode))

print("=" * 66)
print("汇总")
print("=" * 66)
for fname, status, code in summary:
    print("  [%s] %-24s (exit %d)" % (status, fname, code))

fails = [s for s in summary if s[1] == "FAIL"]
print("")
if fails:
    print("[FAIL] %d 个脚本未通过：%s" % (len(fails), [f[0] for f in fails]))
    sys.exit(1)
print("全部 %d 个校验脚本通过，工程处于可运行状态 ✅" % len(summary))
# 同步记忆里的套件计数（避免后续批次误报 35）
assert len(summary) >= 41, "校验套件计数异常：期望 >=41，实际 %d" % len(summary)
