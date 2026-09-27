# 《纪元三国》v0.8.0 Demo · 技术岗代码审查报告（R1）

审查人：程基岩（engineering-lead） · 引擎 Godot 4.7.2（GL Compatibility） · 纯只读静态审查
范围：autoload / world / city / battle / services / ui / main 全部 .gd + 关键 .tscn / 资产 / 存档链路
方法：运行期/逻辑/性能/存档兼容静态推演（未跑引擎，编译期问题不报）。所有发现附「文件:行号」证据。
口径：不重复上报优化路线图已修病灶（C1-C4、P3-1~P3-6）与既定工程约定。

---

## 一、执行摘要（Top 5）

| # | 问题 | 一句话 |
|---|------|--------|
| 1 | **存档 int 键不归一化**：读档后外交系统整体失真 | JSON 读档把 Dictionary 的 int 键全变 str，`DiplomacyService`/`AIService` 全部用 int 键读写 → 关系值归零、结盟/宣战状态丢失、AI 兵力清零，且 int/str 双键并存持续污染存档 |
| 2 | **场景导航栈污染**：特定序列下战斗结束被送回"上一局的城" | `goto` 从不清 `_history`，读档/续档/新档三入口向脏栈 `push_scene("world")`，且 `push_scene` 先 append 后 goto（被拒绝时也污染） |
| 3 | **读档后随机出生**：玩家位置不入存档 | `to_dict()` 无 return_pos/return_scene，读档后 world_map 走 `_spawn_at_random_city()` 随机落点，与存档位置脱钩 |
| 4 | **采集点 daily_limit 失效** | `_handle_gather` 首次成功即置 `_triggered_ids`，配置「每日可采 N 次（N>1）」实际同日只能采 1 次 |
| 5 | **SaveManager._update_meta 空指针** | `FileAccess.open` 无判空直接 `store_string`，磁盘异常时保存即崩溃（同文件 save_game 有判空，此处漏了） |

已排除的担忧（简报曾关注，实测不成立）：
- `china_geo.png` 实为 1024×1024（简报的 21256×21826 是 terrain.json 世界坐标尺寸，非纹理像素）；
- 分块虚拟纹理机制已整体移除，改静态整图 `world_static.png`（但该图有新问题，见 R1-19）；
- 外交七手段概率公式「属性越高越难成功」**不是 bug**——D-08 定义的就是失败概率公式，代码 `randf() > prob` 行为正确（仅命名歧义，见 R1-17 备注）。

---

## 二、问题清单

严重度：高=破坏核心循环/数据错误；中=明显功能异常；中低=特定条件触发；低=体验/一致性/风格。

| ID | 文件:行 | 严重度 | 玩家现象 | 根因 | 修复方案 | 优先级 |
|----|---------|--------|----------|------|----------|--------|
| R1-01 | game_state.gd:715,718,719；diplomacy_service.gd:45,51,74,81；ai_service.gd:81,88 | 高 | 读档后外交面板关系全显示 0；已结盟/通商/联姻/宣战状态全部丢失（可重复结盟重复扣 1000 金）；AI 兵力清零重计；继续游玩后同一字典 int/str 双键并存，越存越脏 | `from_dict` 原样载入三个字典（`faction_relations`/`diplomacy`/`ai_state`），JSON 序列化把 int 键转成 str 键；服务层一律 `dict.get(faction_id)`（int）读写 | from_dict 对三字典按 `int(key)` 归一化重建（或全链统一 str 键+查询侧 str()）。旁证：self_rule_service.gd:182-186 已写双键兼容注释——作者知晓此坑但未修全 | P0 |
| R1-02 | scene_router.gd:67-69,73-76；save_menu.gd:93；main_menu.gd:41；create_hero.gd:883 | 中 | 复现序列：上一局进城 → 设置 → 「返回主菜单」（goto，栈残留 "city"）→ 读档 → 大地图 → 遭遇 → 打完仗 back() → 被送回**上一局那座城**。另有 push 被 `_is_transitioning` 拒绝时历史照样 append | `goto` 全程不清 `_history`；读档/续档/新档三入口统一 `push_scene("world")` 向脏栈追加；`push_scene` 先 append 再 goto | 在「返回主菜单」、读档成功、新开局三个时点 `_history.clear()`；push_scene 改为 goto 可执行后再 append | P0 |
| R1-03 | game_state.gd:600-671（to_dict 无位置字段）；world_map.gd:84-92,1366-1383 | 中 | 存档时在 A 城旁，读档后人站在当前区域**随机**城池附近（每次读档都可能不同），像"读档人物瞬移" | 玩家位置/return_scene 不入档；world_map._ready 见 return_scene≠"world" 即走 `_spawn_at_random_city()`（1375 行 randi 随机选城） | to_dict/from_dict 增加 `last_world_pos`（+return_scene="world"），读档恢复；随机出生仅限真·新档 | P1 |
| R1-04 | encounter_manager.gd:315-338（尤其 319 行） | 中 | 配置 `daily_limit: 5` 的采集点，采 1 次后当天就提示枯竭，次日才恢复 | `_handle_gather` 首次成功即 `_triggered_ids[enc_id]=true`（防每帧连采），`_gather_counts` 计数被短路，永远到不了上限 | daily_limit>1 时不置 `_triggered_ids`（用节流/位置离开判定防连采），仅计满后置 | P1 |
| R1-05 | save_manager.gd:139-141 | 中低 | 磁盘满/无权限时点保存 → 直接崩溃（空指针调 store_string），而非提示失败 | `_update_meta` 的 `FileAccess.open` 无判空；同文件 save_game:32-35 有判空，此处遗漏 | 判空 + push_error + 返回 false | P1 |
| R1-06 | game_state.gd:758-827（reset 缺项）；705-706（from_dict 载入） | 中低 | 重开新档后立刻去官府捐金，可能提示「今日功勋已满」 | reset() 未重置 `merit_today`/`merit_today_day`（上局值残留） | reset() 补 `merit_today=0; merit_today_day=-1` | P2 |
| R1-07 | faction_service.gd:291 | 中低 | 每月固定日号捐金被拒：1 月 5 日捐满，2 月 5 日仍提示「今日功勋已满」 | 惰性跨日重置只比 `GameState.day`，跨月/跨年同日号被当成同一天 | 改比 `GameState.total_days()`（year/month/day 三元组亦可） | P2 |
| R1-08 | city_scene.gd:1636；对照 game_state.gd:55 | 中低 | 装在**副武器槽（weapon2）**的装备不出现在铁匠铺强化列表（其它槽都正常） | 强化收集列表写死 `["weapon1","helmet","armor","treasure","mount"]`，漏 "weapon2" | 列表补 "weapon2" | P2 |
| R1-09 | encounter_manager.gd:308-311 | 中低 | 打不过的敌军想练级后再战——撤退/战败返回后这支敌军**永久消失**（encounter_resolved 已入档） | battle 类遭遇触发瞬间即写 `_triggered_ids`+`GameState.encounter_resolved`+`_hide`，与胜负无关 | 【待验证设计意图】若非有意，改为战斗胜利时才标记 resolved | P2 |
| R1-10 | battle_scene.gd:511-521 | 中低 | 空阵单挑（duel_only）胜局：未上阵的部队也被折损 50%——「单挑只论胜负不动兵力」口径被打破 | zero-summary 的 `ally_troops=0` 仍走 `apply_attrition(summary,total,0.5)` → keep=0.5 | 【待验证设计意图】duel_only 胜利链跳过 attrition 或 keep=1.0。行号出自先前通读，落修复前请复核 | P2 |
| R1-11 | battle_scene.gd:893-898,141-142 | 中低 | 撤退也按败北扣 25% 兵力；反复撤退重打同一遭遇时 battle_count 虚增 | `_on_retreat→force_end(false)` 走败北结算链；`battle_count` 在 `_setup_battle` 提前 +1 | 撤退单独轻惩罚（或不扣）；battle_count 移到结算时计数 | P2 |
| R1-12 | scenes/world/world_map.tscn:68；对照 world_clock.gd | 中低 | 进城/战斗期间游戏时间完全冻结：月度结算（义兵/外交维持/AI tick）停摆，长驻城内资源不随时间变化 | WorldClock 只挂在 world_map 场景 | 【待验证设计意图】若需统一，把 WorldClock 提升为 autoload 或城内场景也挂载 | P2 |
| R1-13 | story_director.gd:15,69-77 | 低 | 读档当天，当日史官锚点播报会再弹一次 | `_fired` 去重数组为内存态，不入存档 | _fired 关键 stamp 入档（或按 encounter_resolved 同款字典持久化） | P3 |
| R1-14 | audio_manager.gd:54（对照 111） | 低 | 设置里调低总音量后，切换场景的瞬间 BGM 音量突然弹大 | `play_bgm` 用 `linear_to_db(bgm_volume)` 漏乘 master_volume，与 `_apply_volumes` 口径不一致 | play_bgm 侧统一乘 master_volume | P3 |
| R1-15 | player_controller.gd:205-230 | 低 | 双指捏合缩放结束后接单指拖动，视野可能瞬间跳变一下 | `_pinch_last` 跨手势残留，单指阶段提前 return 未清理 | 手势结束/切换单指时清 `_pinch_last` | P3 |
| R1-16 | formation_calculator.gd:315-325,329-339 | 低 | 战前胜率预估系统性偏高，玩家按预估打会意外吃败仗 | `estimate_enemy_power` 敌方只算「兵力×品质」，无阵型/武将/装备加成；我方却带全加成进 Logistic | 敌方侧补武将/装备粗估，或预估公式双侧同口径 + 文案标注「粗估」 | P3 |
| R1-17 | diplomacy_service.gd:100-115,148-163,175-176,199,221-227；对照 02-策划文档/D-08:197,221,232,240,248,254,257 | 低 | 与文档偏差：结盟/联姻未校验魅力≥50/60；离间/造谣/破坏「被发现概率」恒为常量，缺「目标势力君主智力/300」项；造谣暴露缺名声-5；破坏暴露缺进入敌对状态 | 实现简化，未逐条落 D-08 公式 | 按 D-08 补齐门槛与暴露惩罚；另建议 `prob` 改名 `fail_prob`（现为失败概率，行为正确，命名有歧义） | P3 |
| R1-18 | hud.gd:96-99；scenes/world/world_map.tscn:139-175；对照 city_scene.gd:364 | 低 | 大地图顶栏只有金/粮/木/兵，看不到「铁」；进城才有——而强化/修缮都耗铁 | ResourceBar 无 IronBox，update_resources 也不刷铁 | 大地图资源栏补铁格子（或确认大地图刻意不显示） | P3 |
| R1-19 | assets/sprites/terrain/world_static.png（实测 4096×4206）；.import size_limit=0 | 低 | 部分移动 GPU 最大纹理 4096：4206 高的整图可能加载失败 → 大地图黑图/无地形（桌面无碍） | 整图高度超常见移动端纹理上限，导入未做尺寸限制 | 导入参数 `process/size_limit=4096`，或烘焙时裁到 ≤4096 | P2（发移动端前必改） |
| R1-20 | world_map.gd:572-585；region_service.gd:46-58 | 低（性能） | 大地图每帧 `_check_region_bounds` 触发 ~10 次 `guizhou_rect`，每次全量遍历 terrain 表——60fps 下持续 GC 压力与无谓 CPU | 矩形数据静态却每帧重查 JSON 表 | 场景加载时把 8 区域的古州 Rect2 缓存进成员字典，每帧只查内存 | P3 |
| R1-21 | save_manager.gd:23-42；formation_editor.gd:534；battle_scene.gd:907 | 低（性能） | 一场战斗触发**两次**全量 JSON 同步写盘（开战前 + 结算后），中端机存档瞬间可能掉帧 | `save_game` 主线程 stringify+写盘；开战/结算各 auto_save 一次 | 保留结算侧；开战侧改为内存快照；中期可挪 WorkerThreadPool（遵守既有纪律） | P3 |
| R1-22 | city_scene.gd:595-651 | 低（风格） | 无直接玩家现象 | 城内 `_process` 用 13 段复制粘贴 if 判冻结，world_map.gd:296-305 已收敛为 `_any_ui_open()` 一张表 | 对齐 world_map 的面板表驱动写法，防新增面板漏判 | P4 |

---

## 三、性能专项

结论先行：**无高危性能问题**。两处此前担忧实测排除：
1. 底图 `china_geo.png` 实为 1024×1024 无损纹理（.import：compress/mode=0、vram_texture=false），非巨型图；
2. 分块虚拟纹理机制已整体下线（terrain_painter.gd 改静态整图渲染），无逐块生成开销。

需关注的三项（均低优先）：
- **R1-20** 大地图每帧重复解析 terrain 表求区域矩形（缓存即可，量级：每帧 ~10 次表遍历）；
- **R1-21** 一场战斗两次同步全量 JSON 写盘（存档 payload 含 28 张表引用的全部 GameState，字符串化在主线程）；
- **R1-19** world_static.png 4096×4206：桌面 2D 加载无压力，但超出部分移动 GPU 的 4096 纹理上限（发移动端前用 size_limit 兜底）。

观察项（不立项）：battle_unit 每单位 7 个绘制子节点 × 全场部队，Compatibility 下可接受；`_any_ui_open()` 每帧 12 次 has_method/is_open 调用，量级可忽略。

## 四、存档专项

存档链路（SaveManager → JSON → GameState.to_dict/from_dict）主体健壮：`encounter_resolved` 防遭遇重生、`_migrate_equipment` 兼容旧字符串槽位、双 Schema 服务层兼容、 npc_stock_state 补货日、merit 日上限均已在。**核心风险集中在 R1-01**：

- **int 键字典读档失真（R1-01，P0）**——影响面：`faction_relations`（外交关系值）、`diplomacy`（结盟/通商/战争/联姻标记）、`ai_state`（势力 AI 兵力/资源）。三个字典的写入方（DiplomacyService/AIService/FactionService.join:187）全部用 int 键，读档后键变 str，等于**外交与势力 AI 子系统在读档后的会话里整体失忆**，且之后 int/str 双键并存写回存档，问题随游玩时长滚雪球。self_rule_service.gd:182-186 的兼容代码证明作者踩过并知晓该坑，修复应收口到 from_dict 一处，而不是各服务自查。
- **玩家位置不入档（R1-03，P1）**——与 R1-01 同属「to_dict/from_dict 覆盖不全」：return_pos/return_scene 只活在内存，读档后随机出生。
- **reset 漏项（R1-06，P2）**——`city_recruited_today` 有重置（783 行）而 `merit_today/merit_today_day` 无，同类字段不同命。
- **日锚点口径（R1-07，P2）**——`merit_today_day` 只比 day 字段，跨月同日误判；对比 npc_stock_state 用 `total_days()` 是正确范式，建议统一。
- **_update_meta 崩溃（R1-05，P1）**——存档路径上唯一未设防的 IO 点。
- **_fired 不入档（R1-13，P3）**——影响轻微（当日播报重弹一次）。

## 五、待验证清单（静态审查无法闭环，需人工/真机确认）

| # | 事项 | 验证方法 |
|---|------|----------|
| V1 | R1-09 战败即永久消失、R1-10 duel_only 胜局折损 50% 是否设计意图 | 对 D-06/D-07 战斗设计文档与路线图口径；策划拍板 |
| V2 | R1-12 WorldClock 仅挂 world_map、城内时间冻结是否设计意图 | 对 D-03 时间系统设计；观察月度结算是否预期「只在大地图走」 |
| V3 | R1-19 world_static 4096×4206 在低端安卓真机的表现 | QA 真机清单加一项：低配安卓进大地图看地形是否黑图 |
| V4 | city_scene.gd:1014-1016 酒馆统率显示直读 `hero.stats`，v6 heroes6 无 stats 字段时是否恒显示 50 | 用 v6 表武将进酒馆核对统率数值；建议改走 CharacterService.four_stats |
| V5 | R1-10 标注的 battle_scene.gd:511-521 行号出自先前通读记录（本次复核了 870-944 段），落修复前请按当前文件再核 | 修复 PR 前重读该函数 |
| V6 | `_on_encounter_triggered`（world_map.gd:1210-1219）await 0.5s 窗口内若紧邻第二个战斗遭遇点，`current_encounter` 会被后者覆盖（场景只切一次，进的可能不是看见的那场） | 编辑器里把两个 battle 遭遇点摆到 <触发半径 间距实测；概率极低，若复现再立项 |

## 六、修复顺序建议

1. **P0（发版阻塞）**：R1-01（存档键归一化）、R1-02（导航栈清理）——都在存档/路由收口处各改 ~10 行。
2. **P1**：R1-03（位置入档）、R1-04（采集限额）、R1-05（判空）、R1-19（移动端纹理上限）。
3. **P2**：R1-06/07（merit 两连）、R1-08（weapon2）、R1-09/10/11（战斗口径，先过策划）。
4. **P3/P4**：其余一致性与性能打磨。

—— 报告完（eng-lead · 程基岩）
