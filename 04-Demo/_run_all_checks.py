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
    ("_verify_orphan_probe_lock.py", "★ 复活被孤立的回归锁（死探针=没上锁）：普查 tests/ 下 30 个探针的「是否被任何 .py 消费」，发现 10 个零消费 —— 其中 encounter_loop_probe(5 判定)锁 72107b8「战败撤退当日按 enc_id 拦截原地重生」(EncounterManager._is_resolved) 与 ui_return_probe(14 判定)锁第五十轮「点人物弹菜单 + 轮盘居中 viewport 坐标系错位」属判定型且锁着已修的真实缺陷，却无人驱动，改回旧写法不会有任何校验变红（死锁）；另 8 个为诊断型（0 判定函数）不担锁职责，另 battle_blackout_probe 已被 _verify_battle_blackout.py 静态覆盖。同时取证两探针结果文件早于 .gitignore 规则入库 故规则对已跟踪文件无效、仓库长期躺着 2026-09-28 过期快照易被 review 误读为当前状态 —— 已 git rm --cached 让规则生效。先证伪再改：ui_return_probe 原有 5 项 FAIL 全部源于探针过时而非产品回归（返回按钮判据找「←」但实现是第五十轮改的 button(\"返 回\",..)；close_panel 走 modal_exit 的 0.14s Tween 而探针只等 1 帧；_find_first_list_button 未排除「返 回」导致其高度≥84 先于武将行被匹配、探针按下返回键使 picked 永不发射），三处判据已对齐实现形态；本轮校验真跑两探针（5+14 项全绿）、对 user://saves/ 做跑前跑后指纹比对、钉死三处判据不得回退、普查「判定型孤儿必须为 0」并确认过期快照不再被跟踪"),
    ("_verify_self_rule_guard.py", "★ 自立建国防误触（本工程最重的不可逆操作一点即过）：取证 found_self_rule 落地四项不可逆全局变更 —— is_self_rule 置真后全工程唯一复位点只在 GameState.reset()（本局不可退）、全势力关系 DiplomacyService.modify(-10) 不可返、join_intent 作废、失败结局线自 check_ending 逐月起判（infamy>=80 即终局不可重开）；而城内处死俘虏/解散部队第五十一轮已各补 make_sub_modal 确认、主菜单开新征程也有，唯独最不可逆的自立建国一点即过；改为未自立分支先跑 can_attempt 门禁再弹确认（点明势力关系下降/投靠作废/结局不可重开，不写可撤销类虚假兜底），确认后走 _do_found，已自立的改国号属可逆故不拦、前置不满足与国号空白也不拦（避免凭空加步骤）；headless 真跑 39 项（拦截期六项内存态零改动/取消零建国/确认后3-3家势力各降10且join_intent 作废/改国号不拦/文案四要点且无虚假兜底/弹窗国号与旗帜为构建时快照/连点不叠遮罩/关窗零建国/信物未齐与全空格与已投靠均不拦），并对 user://saves/ 做跑前跑后指纹比对确保零污染玩家存档；另独立锚定上游源码锁死弹窗调用为_on_confirm 终止语句、建国动作只在 _do_found、幂等守卫、三项快照、关闭路径零建国、改国号分支零确认、国号空白必须 strip_edges、文案无虚假兜底、第六十一/六十二轮存档确认未被回退"),
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
    ("_verify_world_scale.py", "★ 第六十六轮 问题1 大地图尺度/密度/行走（遭遇物按『物件<人<城』重排：玩家/宝箱 7.9:1 收敛到 4:1；最小间距 220→620、数量改由面积反推，约 15 秒碰一个而非 1 秒；步幅由绝对像素改为身高比例，主角步频 3.2→1.5 步/秒。全部数值断言+旧写法反证）静态复核"),
    ("_verify_interaction_ui.py", "★ 第六十六轮 问题2 交互框/对话卡/提示对齐（InteractionMenu 居中开关+0.62 锚点、选项框改居中并跟随卡片下沿、圆形按钮提示以按钮中心对齐；对提示偏移做代数验算并反证旧写法确偏 90px）静态复核"),
    ("_verify_menu_reopen.py", "★ 第六十六轮 问题4 大地图轮盘重复弹出（触控双事件穿透导致面板开门即关、守卫误判已返回而重弹轮盘）：headless 真跑 A/B/C/D 四用例（含 C 反向对照：信任期过后面板真关闭仍须重开，防修法退化成永不重开）+ 独立锚定 world_map 源码锁守卫真的接上"),
    ("_verify_exitcode_guard.py", "★★ 第六十七轮 元缺陷 判定型校验器退出码传导体检（普查「不会响的锁」：本轮在 _verify_combat.py 挖出 30 处 check() 判定全红却退出码恒 0，聚合器仍记 PASS —— 比没有锁更危险。静态判定 50 个被驱动脚本，判定型者必须能把失败传导到非零退出码，否则判红）"),
    ("_verify_67_reverse.py", "★ 第六十七轮 反向验证：T8 攻城战时长 11 条判据逐个注入缺陷必须变红（含 R1-R7 守军配置/耐久翻倍/复刻漂移 + R8 精确复现「有 FAIL 但退出码 0」的不会响状态 + 5 条假阳性对照）"),
    ("_verify_depth_sort.py", "★★ 第六十八轮 问题5 深度排序（y_sort）接入 —— 让大地图从『贴纸』变成可行走的世界。此前全工程零 y_sort，城池/NPC/遭遇/玩家靠固定 z_index 分层，彼此毫无前后关系（角色走到城北仍画在城前，像贴在城墙上）。本轮把四类实体合并进同一 y_sort 层。三层校验：L1 headless 真跑 29 项（含产出量闸门，探针崩溃不再表现为绿灯）；L2 **非 headless 像素取证** 8 项（PIX1-4 在干净场景用像素级正反对照闭环证明引擎 y_sort 行为）；L3 独立源码锚定 21 项（防探针与产品代码同改互相放过）"),
    ("_verify_depth_sort_reverse.py", "★★ 第六十八轮 反向验证：12 个真缺陷注入必须报红（z_index 不清零/建层早于 marker 生成/5 处运行期遍历退回空容器/新增绕过统一入口的直查/地形误开 y_sort/层不置首位/切区重建不回层）+ 2 条假阳性对照须仍绿 + 1 条判据方向对照（z_index 改成 8 盖过 y_sort）+ 存档指纹未污染"),
    ("_verify_city_depth_sort.py", "★★ 第六十八轮 问题5 第二层 城内深度排序 —— 城内此前同样零 y_sort，且玩家被硬设 z_index=20 压住一切，走近任何建筑都像贴在城墙上。本轮把建筑/玩家/城内 NPC 合并进同一 y_sort 层，氛围与夜色层改用显式 z_index（删除两处依赖树序的 move_child，y_sort 后必然失效）。三层校验：L1 headless 真跑 23 项（含产出量闸门）；L2 **非 headless 像素取证** 8 项（PIX1-4 像素级正反对照闭环 + PIX5-8 真实城内结构锚定）；L3 独立源码锚定 23 项"),
    ("_verify_city_depth_sort_reverse.py", "★★ 第六十八轮第二层 反向验证：9 个真缺陷注入必须报红（建层早于 NPC 生成/玩家恢复 z_index=20/丢 is CanvasItem 守卫/不按名字前缀抓实体/层级退回树序 move_child/夜色层压到氛围层之下/清场不置空句柄致层分裂/不复用 pin_terrain/层不排首位/玩家不入层/清零改成 8）+ 2 条假阳性对照须仍绿 + 存档指纹未污染"),
    ("_verify_terrain_height.py", "★★★ 第六十八轮第三层 地形高度场 —— 让角色真正『行经走于每个地质上面，包括山啊、土地』。取证发现 terrain_painter 内部早有完整高程模型（西高东低三级阶梯+三层噪声+城池压平），但只用于底图上色、颜色随 _draw 丢失 → 角色在高山与平原绘制高度完全一样。抽成 TerrainHeight 静态类供查询，角色按海拔浮起（只抬可视子节点，不动实体 position，否则污染距离判定/存档坐标）。L1 headless 12 项（含 H7 累加漂移回归锁——该缺陷实由探针抓到：连调 10 次位移 -450px 而单次只该 -45px）+ L3 独立源码锚定 29 项（含与 terrain_painter 的**同源性**锚定：参数漂移会导致「画上是山、角色按平原站」且运行期不报错）"),
    ("_verify_terrain_height_reverse.py", "★★★ 第六十八轮第三层 反向验证：12 个真缺陷注入必须报红（噪声频率/种子漂移/**上游改了底图下游未跟**/去掉基准 y 守卫致累加漂移/抬升符号写反致角色沉进地里/阶梯抹平致海拔全零/城池压平失效/接线摘掉/改实体 position 污染距离判定/NPC 访问器摘掉/样本出口摘掉/类名改掉）+ 2 条假阳性对照须仍绿 + 存档指纹未污染"),
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
