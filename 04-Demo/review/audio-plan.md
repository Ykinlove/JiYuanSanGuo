# 《纪元三国》Demo v0.8.0 音频落地规划

> 产出：阮和鸣（audio-lead / 音频与声效设计师） · 任务 R4 · 2026-09-24
> 依据：只读审计 `04-Demo` 工程代码与配置；工程内当前 **0 个真实音频文件**（assets/ 下仅 data/icons/sprites），全部声音为 `audio_manager.gd` 运行时正弦合成占位音。
> 结论先行：**接口层（play_bgm / play_sfx / 三通道设置）已可用，无需改调用点即可接入真实资产；但代码层有 6 处缺陷需先修，BGM 全局只有 3 个挂点（主菜单/创角/结算全部漏铺）**。

---

## 一、现状问题清单

### 1.1 代码层缺陷（按危害排序，均给修复建议，交工程侧执行）

| # | 问题 | 位置 | 危害与修复建议 |
|---|------|------|----------------|
| P1 | **BGM_BUS 常量 = "Master"**，1 个 BGM player + 6 个 SFX player（`SFX_POOL_SIZE=6`）全部挂 Master | `scripts/autoload/audio_manager.gd:7,33,38` | 三通道音量全靠代码乘法模拟（71、111 行），物理上无法分轨。修复：建 BGM/SFX 双子 bus（见 §4），`BGM_BUS` 改 "BGM"，SFX player 的 bus 改 "SFX" |
| P2 | **play_bgm 的 fade 参数从未使用**：签名 `fade: bool = true`，函数体直接 `bgm_player.play()` 硬切 | `audio_manager.gd:46-55` | 三个调用点全部走默认 true，形同虚设；进战斗时战鼓 BGM 瞬间砸入。修复：用 Tween 对 volume_db 做 0.6~0.8s 淡出旧曲/淡入新曲 |
| P3 | **play_bgm 漏乘 master_volume**：切歌时 `volume_db = linear_to_db(bgm_volume)`，而 `_apply_volumes` 是 `linear_to_db(bgm_volume * master_volume)` | `audio_manager.gd:54` vs `:111` | 玩家调低主音量后每切一次场景 BGM 会跳响一次。真实 bug，一行修复 |
| P4 | **stop_bgm 是孤儿函数**，全工程零调用；且主菜单/创角场景不调 play_bgm → 从大地图/城内退回主菜单时，旧 BGM **无人叫停、持续循环** | `audio_manager.gd:58-60`；`scripts/main/main_menu.gd`（无 play_bgm） | "返回主菜单后 city.ogg 还在响"是玩家必然踩到的实际 bug。修复：main_menu `_ready()` 显式 `play_bgm(main_menu 曲)` 或 `stop_bgm()` |
| P5 | **set_sfx_volume 不即时生效**：只写变量不 apply，下次 play_sfx 才用新值；BGM 侧 `_apply_volumes` 即时 | `audio_manager.gd:105-107` vs `:110-112` | 设置页拖"战斗音效"滑块无听觉反馈，与 BGM 滑块行为不一致 |
| P6 | **SFX 池环形轮转硬顶替**：第 7 个音顶掉第 1 个仍在播的音 | `audio_manager.gd:64-72` | 战斗连打时 hit 相互截断。Demo 可接受（占位音仅 0.12s），换真实 hit（0.3~0.5s）后必须加"同 stream 不顶替"判定或扩池 |
| P7 | event_popup 选项点击**连响两次 confirm**（resolve 前后各一次） | `scripts/ui/event_popup.gd:89,94` | 同一点击两声，删 89 行即可 |
| P8 | `_sfx_kind` 按文件名只有 click/confirm/cancel/hit/other 五类 | `audio_manager.gd:161-165` | 新增 SFX 文件（treasure.ogg 等）占位期全归 "other"，占位多样性不足——不阻塞，真实资产到位后自动失效 |
| 澄清 | **PLACEHOLDER_MIX_RATE=22050 对 BGM 音质影响 ≈ 0** | `audio_manager.gd:13` | 占位 BGM 内容是 110/165Hz 纯音，奈奎斯特上限 11kHz 绰绰有余；真实 ogg 走原始采样率不受此常量影响。**此项不建议工程侧"顺手改"，无收益** |

### 1.2 占位音的真实体验伤害（哪些地方"有占位音比没声音更糟"）

| 场景 | 现状 | 伤害 |
|------|------|------|
| boot→主菜单→创角 | **全程静音**（`scripts/main/boot.gd` 无音频；main_menu.gd / create_hero.gd 均无 play_bgm 挂点），仅按钮点按有占位 click | 首印象前 30-60s 完全死寂。这不是占位音的锅，是 **BGM 挂点缺失**，属 P0 补挂点 |
| 大地图（全国无缝行走） | 110+165Hz 低音嗡鸣 4s 循环 + 1Hz 呼吸起伏 | 长时间行走产生持续性烦躁，**比静音更糟**；嗡鸣与 UI 高频 confirm 双音（660→990Hz，电话拨号质感）叠加，疲劳极快 |
| 城内（市集/铁匠/酒馆/兵营密集操作） | 同上嗡鸣 + 大量 confirm/cancel 双音来回跳（city_scene.gd 内 40+ 处调用） | 每 1-2s 一声上行/下行电子双音，10 分钟即听觉疲劳 |
| 战斗 | hit=160Hz 正弦+50% 白噪 0.12s，攻击冷却 0.32s（`battle_scene.gd:698`） | 连续输出≈每 0.32s 一声"沙嗒"，1-2 分钟后如电钻；**且 `_on_attack` 在按键瞬间发声（:699），距离过远未命中也已响（:707-708）——挥空也有打击音**，音画不符 |
| 大招释放 | 复用 confirm 音（`battle_scene.gd:732`） | "释放大招！"时刻响一声确认弹窗音，情绪完全错位，是全游戏最伤的一处语义错配 |
| 铁匠强化失败 | `sfx_confirm if success else sfx_hit`（`city_scene.gd:1682`） | 失败反馈用战斗打击音，语义错配 |
| 遭遇（采集/宝箱/商队/奇遇） | `encounter_manager.gd` 全程无任何音频调用 | 手动触发的四大遭遇链路零反馈，大地图玩法核心循环无声 |

---

## 二、场景-BGM 规划表（Demo 收敛：5 首 + 1 首可选）

统一调色板：**水墨三国 = 古琴/箫/笛做主线，鼓/梆子/木鱼做骨架，琵琶/扬琴点缀，锣/唢呐只在高点**。忌电子合成质感与西式管弦全奏。

| # | 文件（路径） | 覆盖场景 | 情绪关键词 | 曲风与乐器建议 | 时长 | 循环方式 | 优先级 | 挂点 |
|---|--------------|----------|-----------|----------------|------|----------|--------|------|
| 1 | `bgm/main_menu.ogg` | 主菜单 + 创角（共用或同主题变奏） | 苍茫开卷·历史厚重 | 古琴独奏起手→箫进入→低鼓心跳铺底；BPM 55-65 | 60-90s | 前奏 + 主体循环段（ABA'），循环点落在乐句收束 | **P0** | `main_menu.gd:_ready()` 新增；`create_hero.gd:_ready()` 复用同曲 |
| 2 | `bgm/world_map.ogg` | 大地图（全国无缝行走） | 苍茫行军·征途 | 笛主旋律 + 行进小鼓 + 长音弦底；BPM 85-100 | 90-120s | 双段 AB 循环，尾→首无缝（复用现有调用 `world_map.gd:68`） | **P0** | 已有 |
| 3 | `bgm/city.ogg` | 城内五场所（衙署/市集/铁匠/酒馆/兵营） | 市井烟火·安定 | 琵琶轮指 + 扬琴点缀 + 梆子/木鱼律动；BPM 90-105 | 60-90s | 单段循环，循环点在过门（复用 `city_scene.gd:117`） | **P0** | 已有 |
| 4 | `bgm/battle.ogg` | 战斗全程（含布阵 formation_editor） | 紧张压迫·鼓动 | 战鼓套底 + 急板琵琶 + 唢呐低鸣；BPM 120-140 | 60-90s | 主循环；Demo 单段即可，完全体加战况段落（复用 `battle_scene.gd:90`） | **P0** | 已有 |
| 5 | `bgm/victory.ogg` | 战斗结算胜利（可复用于单挑胜） | 昂扬·短胜利曲 | 锣起 + 唢呐/号角短乐句 + 鼓收 | 8-15s | **不循环**（one-shot） | P1 | `battle_scene.gd:883` `battle_ended` 结算处新增（败北可静音或低锣，不单配曲） |
| 6（可选） | `bgm/duel.ogg` | 单挑（duel_popup） | 一对一斗智斗勇 | 急速斗鼓 + 琵琶对答句式 | 40-60s | 循环 | P2 | 完全体再挂；之前复用 battle |

配套决策：
- **对话（dialogue_ui）不独立配曲**：保持所在场景 BGM 连续。`play_bgm` 对同路径不重播（`audio_manager.gd:47`）已天然支持，无需改代码。
- boot 场景保持静音（<2s），无必要配曲。
- 结算=胜利曲 one-shot 叠在场景 BGM 上播（走 SFX bus 或临时压低 BGM -6dB，见 §4）。

## 三、SFX 事件表（Demo 收敛：16 个）

现有挂点 4 个（click/confirm/cancel/hit）全部保留；新增 12 个按玩家操作链补齐。**按钮悬停（hover）明确砍除**：手机横屏触屏为主（`project.godot:47` emulate_touch_from_mouse），悬停无交互意义。

| # | 事件名（=文件名） | 触发代码位置 | 音色方向（水墨调色板） | 优先级 |
|---|-------------------|--------------|------------------------|--------|
| 1 | `sfx/ui_click` | 已挂：`audio_manager.gd:76`（全 UI 按钮） | 短促木鱼/梆子"嗒"，30-60ms | **P0** |
| 2 | `sfx/ui_confirm` | 已挂：`audio_manager.gd:80` | 古琴/琵琶拨弦上行双音，120-200ms | **P0** |
| 3 | `sfx/ui_cancel` | 已挂：`audio_manager.gd:84` | 拂袖低扫弦/闷拨下行，150-250ms | **P0** |
| 4 | `sfx/battle_hit` | 已挂：`battle_scene.gd:699`，**建议改挂到命中判定后（:707 reach 判断通过后）** | 兵刃相击金属声 + 闷鼓，80-150ms；完全体做 3 变体轮换 | **P0** |
| 5 | `sfx/battle_skill` | `battle_scene.gd:732`（替换现 confirm） | 唢呐扬起 + 大鼓重击，400-600ms | **P0** |
| 6 | `sfx/encounter_battle` | `encounter_manager.gd:311`（`encounter_triggered.emit` 前） | 急促号角/战鼓三连，600-900ms | **P0** |
| 7 | `sfx/battle_win` | `battle_scene.gd:883`（`battle_ended` win 分支新增） | 锣 + 号角短乐句，1.5-2.5s | **P0** |
| 8 | `sfx/coin_trade` | `npc_trade_panel.gd:263-271`；`city_scene.gd:1215-1220` | 铜钱碰撞叮当，200-300ms | P1 |
| 9 | `sfx/gather_ok` | `encounter_manager.gd:337`（采集成功 toast 处） | 竹叶/水声 + 小铃，300-400ms | P1 |
| 10 | `sfx/treasure_open` | `encounter_manager.gd:341` `_handle_treasure` | 木质箱开 + 金属碰 + 琶音，500-800ms | P1 |
| 11 | `sfx/recruit_ok` | `city_scene.gd:1563-1584` 招募/招降类 r.ok 分支 | 铜铃 + 古琴上行，500-700ms | P1 |
| 12 | `sfx/enhance_ok` | `city_scene.gd:1682`（成功分支，替换 confirm） | 淬火"锵" + 余韵，300-500ms | P1 |
| 13 | `sfx/enhance_fail` | `city_scene.gd:1682`（失败分支，**替换误用的 sfx_hit**） | 闷响 + 金属坠地，300-400ms | P1 |
| 14 | `sfx/duel_round` | `duel_popup.gd:154`（替换现 confirm） | 兵刃 + 短促人声喝声，250-400ms | P1 |
| 15 | `sfx/battle_lose` | `battle_scene.gd:883`（win=false 分支新增） | 低沉锣 + 弦乐下坠，1.5-2s | P2 |
| 16 | `sfx/quest_done` | 任务完成结算点（Demo 可先挂 `event_popup.gd:94` 结果确认处） | 编钟/磬三连，600-900ms | P2 |

补充说明：
- `city_enter`（进城开门声）、`stat_up`（加点）合并入二/三批的可选池，Demo 16 个为上限，**不再扩充**。
- 军令（charge/hold，`battle_scene.gd:744,752`）、闪避（:718）、解散（city_scene.gd:1468）、撤退（:896）继续复用 click/cancel，不单开文件——避免"每个按钮一种音"的碎片化。
- 事件命名 = 资源路径小写下划线，与 EventBus 信号风格一致。

## 四、混音与实现策略

### 4.1 Audio Bus 布局（用 Godot 内建，Demo 不需要 FMOD/Wwise）

规模 5-6 BGM + 16 SFX，AudioManager 单例 + 双子 bus 完全够用：

```
Master（-6dB headroom，玩家主音量）
├── BGM（玩家 BGM 音量；可挂低通——将来做暂停"闷化"）
└── SFX（玩家 SFX 音量；完全体可再拆 UI/Combat，Demo 不必）
```

建立步骤（交工程侧，约 30 行改动）：
1. Godot 编辑器 → Audio 面板 → 新建 BGM、SFX bus → Save Bus Layout 到 `res://default_bus_layout.tres`（当前 project.godot 无任何 [audio] 配置节，只有默认 Master）。
2. `audio_manager.gd:7` `BGM_BUS` 改 `"BGM"`；`audio_manager.gd:38` SFX player 的 bus 改 `"SFX"`。
3. 三个 set_*_volume 改走 `AudioServer.set_bus_volume_db(AudioServer.get_bus_index(name), linear_to_db(v))`，删除手写乘法（`:71` 与 `:111`），master 天然级联——顺带修掉 P3 漏乘与 P5 不即时两个 bug。
4. `settings_panel.gd:36-41` 三滑块语义不变。

### 4.2 音量基准（写进资产交付规格）

| 通道 | 基准 |
|------|------|
| BGM 母带 | **-14 LUFS** 集成响度；运行时 BGM bus -10 ~ -12dB |
| SFX 单发峰值 | **-6 dBFS**（战斗 hit 可到 -4）；UI click 类 -12 ~ -10dB，不抢戏 |
| 对照现状 | 占位音 amp 0.16-0.40 ≈ -17 ~ -8 dBFS，量级尚可；真实资产必须统一响度归一，杜绝"接进来忽大忽小" |
| 编码 | ogg vorbis q6-7；BGM 44.1kHz 立体声，SFX 44.1kHz 单声道（省内存） |

### 4.3 移动端注意（手机横屏，`project.godot:43` orientation=4）

- **后台/灭屏静音**：audio_manager 挂 `_notification`，在 `NOTIFICATION_APPLICATION_PAUSED` / `NOTIFICATION_WM_WINDOW_FOCUS_OUT` 时 `AudioServer.set_bus_mute(0, true)`，恢复时解除。
- **iOS 静音键**：默认遵循静音键行为；需在 export 时核对 playback category 设置（本次只读未展开 export_presets.cfg，**存疑项，交工程侧导出核对**）。
- 同发语音预算：手机端 8-12 voices 足够；SFX 池 6 + BGM 1 = 7，在预算内，无需扩。

### 4.4 循环点处理（第一批落地的头号坑）

- **Godot 4.7 的 ogg 循环要在导入面板开**（AudioStreamOggVorbis import 设置 loop=true）。占位音的 `LOOP_FORWARD`（`audio_manager.gd:237-239`）只覆盖占位音；**真实 ogg 若忘开 loop，每首 BGM 放完一次即永久静默**——写进每批验收标准。
- 循环点必须落在乐句边界；外购/生成曲要求交付"无缝循环版"，AI 生成曲循环处需手工淡接或选整曲循环型。
- SFX 一律不循环；victory.ogg 为 one-shot。

## 五、落地路线（从零到有的可执行路径）

### 第一批 · 最小集（建议 1-2 天）
- **代码修**（与资产无关，可先行，交程基岩）：§1.1 的 P1(bus 拆分)、P2(fade)、P3(漏乘)、P4(stop_bgm 挂点)、P5(SFX 即时)、P7(双响)；battle_hit 移到命中后；hit 语义替换（skill/enhance）。
- **资产**：BGM 2 首（main_menu、battle）+ SFX 8 个（ui_click、ui_confirm、ui_cancel、battle_hit、battle_skill、encounter_battle、battle_win、coin_trade）。
- **验收**（怎么听）：① 主菜单→创角→大地图→战斗全程无静音段，主菜单有曲；② 战斗连打 30s，hit 不互相截断、大招有声且非确认音；③ 场景切换 BGM 1s 内平滑过渡（fade 生效）；④ 设置页三滑块独立生效（SFX 调 0 只剩 BGM）、调完切场景 BGM 音量不跳变；⑤ 每首 BGM 连播 2 遍无中断（loop 开关核对）。

### 第二批 · 铺满场景
- **资产**：BGM 2 首（world_map、city）+ SFX 6 个（gather_ok、treasure_open、battle_lose、recruit_ok、enhance_ok、enhance_fail、duel_round → 计 7 个，duel_round 可挪三批）；main_menu/create_hero 补挂 play_bgm。
- **验收**：城内连续操作 10 分钟无"电话拨号音"疲劳点；采集→宝箱→招募→交易→强化全链路每步有反馈音且成败音色可分辨。

### 第三批 · 完全体
- **资产**：BGM victory.ogg（+ 可选 duel.ogg）+ SFX battle_lose、quest_done；battle_hit 做 3 变体轮换（play_sfx 加变体后缀随机轮询，防"复读机感"）。
- **验收**：全场景 BGM 无死角；战斗 5 分钟内同一音效无可感知重复；结算胜利曲 one-shot 正确且压住场景 BGM。

### 资产来源建议（含版权边界）
| 来源 | 适配度 | 风险提示 |
|------|--------|----------|
| Kenney.nl（CC0） | UI 通用 click/confirm 可直接用 | 无国风质感，需处理或只做临时底 |
| Sonniss GDC Bundle（CC0） | 量大，金属/打击类可筛 | 中式乐器样本少，需耐心筛 |
| freesound.org | CC0/CC-BY 混合 | CC-BY 需署名，建议只取 CC0 并逐条记录 |
| 爱给网等国内素材站 | 国风样本多 | **版权状态混乱，商用风险高，不建议用于任何将来可能上架的版本** |
| AI 生成（Suno 等） | BGM 情绪贴合度高、成本低 | ① 商用授权取决于平台订阅条款，**内测 Demo 可用、上架前必须复核**；② 生成曲循环点需手工处理；③ 同一 batch 音色漂移，建议逐首锁定 |

- 落地纪律：每个文件在 `assets/audio/CREDITS.md` 登记来源 + License + 日期，供后续合规审查。
- 阶段策略：**先用 AI 生成曲 + CC0 UI 音打通全链路（第一批），验证听感与验收后，再决定完全体是否采购/委托定制**——用户拍板点：听觉方向（纯民族器乐 vs 民乐+轻电子混合）请在第二批前定调。

### 风险与待审批项
1. 【待用户拍板】整体听觉方向：A. 纯民族器乐（更"水墨"，素材难找） B. 民乐为主+氛围合成垫底（素材好找、成本低的折中）。
2. 【待工程确认】export_presets.cfg 的 iOS 音频类别设置（§4.3 存疑项）。
3. 【待工程排期】§1.1 六项代码修 + bus 建立，规格已给全，建议先于第一批资产落地。
