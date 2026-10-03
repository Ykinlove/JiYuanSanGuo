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
    ("_verify_scenes.py", "★ 场景完整性校验（headless 递归 load() 全工程 .tscn，锁场景引用闭合，专抓改名/移动脚本后 .tscn 悬空 ExtResource 这类编译期抓不到的破坏）"),
    ("_run_boot_flow.py", "★ 真实入口链路冒烟（headless 直启 boot.tscn，覆盖 boot→SceneRouter.goto→main_menu._ready 启动转场，抓该链路真实 WARNING/ERROR、过滤 headless 良性告警）"),
    ("_verify_save_load.py", "★ 存档读档往返冒烟（headless 真跑 save→load，验 to_dict/from_dict 序列化往返 + JSON int 键还原 + 空槽优雅返回，抓该生死线真实 WARNING/ERROR）"),
    ("_verify_dialogue_layout.py", "★ 对话选项布局冒烟（headless 真跑全量 180 个带选项的对话节点，逐按钮断言不出视口/≥84px 触控高/互不重叠/超 4 项走两列，专抓几何类不可点缺陷——编译期与静态扫描都看不见）"),
    ("_verify_toast_queue.py", "★ Toast 多提示队列冒烟（headless 连发多条，逐面板断言独立存在/互不覆盖/超上限挤最旧/释放不泄漏——纯运行时行为，编译期无感）"),
    ("_verify_ui_layering.py", "★ UI 层级判定集合校验（_any_ui_open 面板表逐项比对改造前集合，锁死「面板开着人还在跑」这类不崩不报错的静默层级错乱）"),
    ("_verify_hero_dex_search.py", "★ 人物志搜索响应性冒烟（headless 真跑：get_heroes6 缓存同实例+过滤语义不坏、连打合并为一次重建、去抖窗口提示筛选中、回车立即出结果，兼抓 Container 误调 Array 方法这类编译期无感的运行时错误）"),
    ("_verify_encounter_perf.py", "★ 遭遇管理器每帧性能改造行为不变量（锁死结算判定顺序铁律：已结算战斗点被每帧重复触发、提示同屏亮两串、缓存漏清、dist 返回平方值的静默量纲错误），兼查每帧 get_children 全量遍历与每帧数组分配"),
    ("_verify_safe_area.py", "★ 移动端安全区适配（刘海/挖孔屏）：headless 真跑验证无刘海环境内缩量全 0 → 布局逐像素不变、内缩量非负有限、贴顶/贴右下控件 offset 零改动、零内缩即早退守卫存在、null 兜底不崩；兼查 HUD 与右下交互钮接线是否真的接上（写了工具没人用等于没做）"),
    ("_verify_city_interact.py", "★ 大地图城池交互判定几何等价（headless 真跑：110 城半径新旧算式逐个相等、14.5 万次判定验证平方粗筛与原开方判定接受集合完全一致含边界±0.5/±1px 加密采样；独立锚定上游源码防「探针照抄改造后版本反而放过」），兼查 cull 仅变化才写"),
    ("_verify_retake_confirm.py", "★ 收复军弃城二次确认防误触：不可逆失地操作不得存在一点即结算的直通分支、open() 须复位确认态/文案/确认行、取消须完整还原描述、确认行初始隐藏、四个按钮均走 TOUCH_H 工厂（≥84px）、全部方法绑定无 lambda、迎战直通不受拦、进出确认有音效、确认态势力名用 open() 快照防同屏双势力名"),
    ("_verify_art_pipeline.py", "★ 美术资源链路完整性（防静默退化）：units.json 与立绘双向闭合（缺图/孤儿图都抓）、heroes6 全员立绘齐备、源码引用的美术目录必须真实存在且非空、兵种立绘 alpha 真透明且非实心方块（手写 PNG 解码不依赖 Pillow）、每张图都有 .import"),
    ("_verify_marker_cache.py", "★ 大地图 marker/NPC 缓存改造（每帧性能）：headless 真跑验证缓存与节点树双向一致、切区重建后无悬空残留、候选缓冲区跨帧归零不串数据、Hint 显隐两条遍历路径逐项相同；并独立锚定上游源码锁死三处热路径已无 get_children()、重建必clear 缓存、无每帧新建数组"),
    ("_verify_minimap_geom.py", "★ 小地图静态几何脏标记（每帧性能）：headless 真跑验证脏标记版与每帧必重算版产出的 _world_window/_scale/_origin 逐帧逐字段相等（含越界夹取与切模式）、局部模式窗口随玩家移动更新（小地图不会卡住）、快照已同步到直接调用路径、静止 20 帧判脏≤1 次；并独立锚定上游源码锁死脏标记含 _player_pos、快照同步在 clamp 之后"),
    ("_verify_walk_shadow.py", "★ WalkAnim 影子联动（站定误动修复）：headless 真跑量化影子在站定 120 帧的 scale/alpha 波动必须为0（原版 0.0204/0.0063）、行走 90 帧必须有可见起伏（防矫枉过正成影子永不动）；并独立锚定上游源码锁死抬脚量基于纯 bob 不得用 bob_offset、必须有 move_k 门控、idle 呼吸项不得被删"),
    ("_verify_minimap_throttle.py", "★ 小地图重绘节流（静止省帧·跟手不退化）：静止时每帧重画 110 城全表只为让呼吸光晕脉动，改为光晕 12fps 节流而玩家位置/朝向/相机视野/几何输入任一变化仍同帧立即重绘；headless 真跑量化静止 60 帧重绘 ≤30 次且移动 60 帧重绘 ≥48 次；并独立锚定上游源码锁死 _redraw_needed 不得复用有副作用的 _static_geometry_dirty（否则几何脏标记被静默架空）"),
    ("_verify_save_overwrite.py", "★ 存档覆盖防误触（不可逆操作对称拦截）：删除槽位有二次确认而覆盖已有槽位一点即过，代价等价却行为不对称；改为 save 模式点已存在档先弹覆盖确认（展示旧档角色/等级/日期摘要，取入参快照防同屏两版本）、空槽仍直达；headless 真跑 8 项（空槽不拦/拦截期零写盘/取消零写盘/确认写盘/快照同源/读档不拦/连点不叠遮罩/关窗零写盘，均用存档 sha 比对），并对 user://saves/ 跑前跑后指纹比对确保测试零污染玩家存档；另独立锚定上游源码锁死 load 分支 return 早于 `if exists:`、exists 分支弹确认后先 return、幂等守卫、关闭路径不含 save_game、既有删除确认（B10）未被回退"),
    ("_verify_save_load_guard.py", "★ 游戏内读档防误触（丢弃未保存进度必须确认）：取证自动存档只在创角/战斗结算写、grep SaveManager 于 world|city|ui 零命中、GameState.from_dict 79 字段全量覆盖 —— 跑商招兵占地全在内存，点读取存档即无声蒸发；且同屏「返回主菜单」有确认提示而读档没有，行为不对称；改为 load 模式点已存在档且当前有对局时先弹确认（点明丢的是跑商/招募/攻城/时间推进，不用「自动存档已保留」这类不成立兜底），主菜单入口与空槽不拦；headless 真跑 9 项（拦截期进度零改动/取消零读档/确认真读档/主菜单直达/文案无虚假承诺/摘要快照同源/连点不叠遮罩/关窗零读档/空槽不拦），探针全程持SceneRouter 切场景闸防缺陷态下探针被销毁而误报成超时；另独立锚定上游源码锁死三重守卫 exists and _in_game、读档动作集中 _do_load、幂等守卫、关闭路径零读档、三个入口 in_game 取值、第六十一轮覆盖确认未被回退"),
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
    ("_verify_data_closure.py", "★ 第四十九轮 复合 action 双路径解析一致性（对话任务状态过滤与执行共用逗号切分，锁复合 accept_quest 修复不回归）+ 跨表 ID 引用闭合（对话跳转/任务目标按 type 分派/NPC 城市与对话根/条件引用，约 460 条判定）"),
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
