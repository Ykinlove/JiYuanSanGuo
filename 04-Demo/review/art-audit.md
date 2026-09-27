# R3 美术审查报告 · 《纪元三国》Demo v0.8.0

审查人：林绘澄（art-lead）· 2026-09-24
范围：地形底图 / 遭遇与角色立绘 / 战场背景 / UI 体系 / 性能开销。**纯只读审查，未改动任何工程文件**。
方法：关键脚本逐读（ui_theme / terrain_painter / minimap / world_map / encounter_manager / city_marker_art / dialogue_ui / character_panel / hud / main_menu_wheel / battle_scene / npc_manager）+ 831 张 png 全量尺寸统计（Pillow）+ 17 张代表资产逐像素 alpha 检测 + 多模态目检 20 张。

---

## 执行摘要

**总体判断：UI 体系是这个 Demo 美术侧的强项，风险集中在「大地图底图策略」与「NPC 立绘批量质量」两端。**

做得好的（保持，勿动）：
- `ui_theme.gd` 单一规范源落地扎实：character_panel / dialogue_ui / hud / main_menu_wheel 全部走语义色 + 字号表 + 容器工厂，无一处自建 const C_XXX；面板 1040×780 统一、圆角/边距/行样式全套复用。
- 「外壳色归 UITheme、数据可视化色留在数据里」的边界意识正确：minimap 地形色/势力色、轮盘六入口功能色都留在了各自绘制域，并写了注释说明为什么不进调色板——这个边界建议写进美术圣经固化为条款。
- 遭遇立绘 18 张（128×128 透明底）实测**零白边零白晕**，几何菱形回退链完整；battle_bg 5 张水墨古战场与描金 UI 同调，质量高。

三大风险（本报告三条高优主线）：
1. **【性能+表现】大地图底图策略倒挂**：china_geo.png 实际仅 **1024×1024**（21256×21826 是世界坐标，不是纹理尺寸——任务书口径在此纠偏），却拉伸铺满全图并**在一切缩放级别优先使用**；而细节好 4 倍的 world_static.png（4096×4206，解压 ≈69MB）在 `_ready` **无条件加载后从未被绘制**（被 china_geo 短路），白吃 69MB 内存。近景 zoom=1.0 时 1 纹素≈21 屏幕像素，马赛克是必然。
2. **【风格】NPC 立绘 749 张两批风格混用 + 8/8 白雾残留**：写实水彩批（npc_elder 等）与扁平二次元批（300.png、protagonist 等）同库混载；逐像素检测全部存在白底抠图残留（white_halo 800~2100 px），暗色面板上显灰白毛边。
3. **【规范】触控目标系统性低于 84px 铁律**：右上动作按钮 56×56、模态关闭键 64×64、二级弹层关闭键 56×52。

**三类权衡取舍结论（原型阶段）**：
- 优先级排序：**风格统一（脏边/混风格=第一印象损伤，且管线级修一次管全部）≥ 性能开销（只做架构级+零成本项，巨图策略现在改一行顶将来改十行）> 视觉表现力（只做成本≈0 的描边/渐晕/分层；立绘放大、2048 底图等大改全部缓行）**。
- 明确不做：3D/实时光影、逐 NPC 手修、全城池专属图、动态虚拟纹理（已废弃的分块机制不复活）。

---

## 一、风格统一专项

### 1.1 视觉语言批次盘点（实测 6 种风格共存）

| 批次 | 资产 | 与「水墨描金暗色」关系 |
|---|---|---|
| 暗调写实国风插画 | encounters/18 张、npc_elder、npc_blacksmith 等 | **契合**（同暗调，纹理笔触与水墨兼容） |
| 扁平二次元国风 | npcs 数字批（300 等 746 张）、player/portrait 10 张 | **契合**（描金装饰元素常见，如 portrait_male_01） |
| 水墨古战场 | battle_bg 5 张 | **高度契合**（暗金低饱和，天然衬描金 UI） |
| 亮水墨描金 | ui/bg_main_menu.png | **契合但亮**（作背景+暗面板叠加是成立的做法） |
| 写实卫星 | terrain/china_geo.png | **异质**（照片质感，无笔墨；用户已拍板留作远景，需「水墨化叠色」过渡） |
| 像素/等距 | city_icons 5 张、map/scene_* 6 张、units 14 张 | **异质**（128 小尺寸下可容忍，放大即穿帮） |

**结论**：批次本身不是问题，**同屏混用**才是。当前唯一实锤同屏冲突点：对话/详情面板的立绘栏可能并排出现写实水彩 NPC 与扁平二次元 NPC（npcs 目录两批混存，`dialogue_ui._load_portrait_tex` 按 id 直取，无风格路由）。

**R3-07 方案（需用户拍板二选一）**：
- A（推荐，零资产成本）：按功能域划风格——主线命名 NPC（npc_*）=写实水彩批，数字批=随机路人；在 npcs.json 加 `art_style` 字段，详情面板/对话立绘统一垫「墨色衬底 + 描金细框」（inner_style 已有），用容器统一弱化批差。
- B（资产成本）：后续 AI 生成补齐时统一 prompt 到单一风格，旧图逐步替换——原型期不建议。

### 1.2 NPC 立绘白雾残留（实测数据）

逐像素检测（17 张样本）：encounters 6/6、portraits 3/3、units/icons 3/3 **全部干净**（white_halo=0）；**npcs 8/8 全部带白雾**：300.png=1028px、protagonist.png=797px、npc_elder=1497px（另有 3.6% 边缘白描边）、npc_meng_huo=2129px。成因：白底图抠底后半透明像素 RGB 仍携带白色（spill），未经 erode/despill 净化。暗底 #171B26 上呈灰白毛边——对话面板立绘栏（INK/CARD 底）首当其冲。

**R3-01 方案（高优，管线一次修全部）**：在 `_encounter_art_process.py` 同级新增/追加处理步骤，对 `03-美术资源/AI源图/npcs/_done` 全量 746 张执行：① alpha 通道 1px erode（收缩裁掉白边源）；② despill：`0<a<200` 的像素，RGB 向最近实心像素色回拉（或简单地 `rgb *= (1 - (1-a)*0.6)` 预乘净化）；③ 重导出覆盖 `assets/sprites/npcs/`。单张成本毫秒级，全批一次性。

### 1.3 UI 规范符合性（按铁律基线逐条）

| 铁律 | 实测 | 判定 |
|---|---|---|
| 面板统一 1040×780 | make_modal 全走 CITY_PANEL_SIZE | ✅ |
| 水墨描金暗色 | 全 UI 面板走 UITheme 语义色 | ✅ |
| 字号三级表 | make_modal 标题硬编码 **44px**（逃逸表外）；world_map 标题条 30、提示 20、marker 名 20/18/17 碎字号 | ⚠️ |
| 触控目标 ≥84px | 动作按钮 **56×56**、CLOSE_SIZE **64×64**、sub_modal close **56×52**；达标项：轮盘 170/112、放大地图缩放钮 96×84、城内交互钮 140×140 | ❌ |

**R3-04 方案（高优）**：`ui_theme.gd` 中 `CLOSE_SIZE = Vector2(84,84)`、sub_modal close 改 `(84,84)`；`world_map._style_action_buttons` 56×56→**84×84**（corner_radius 42，字号 28→30）。三处改动，零风险。
**R3-10 方案（低优）**：44px 入表为 `FS_TITLE_DISPLAY := 44`（注释：大标题位）；世界内文字收敛两档常量 `FS_MARKER_NAME=20 / FS_MARKER_NOTE=17` 放 ui_theme 或 world 级常量文件。

### 1.4 内联色散布

`world_map.gd` 四处自建色值：`_style_action_buttons`（tint=0.78,0.64,0.36=GOLD_LINE、ink=INK）、`_make_title_bar`（0.78,0.64,0.36+0.98,0.86,0.54）、`_make_close_hint`、`_setup_city_action_button`（0.96,0.92,0.80 暖白描边为**新色**，表外）。值大多与 UITheme 一致，但脱离规范源=将来调色必漏。
**R3-09 方案（中优）**：四处改引 `UITheme.GOLD_LINE / INK / GOLD / TEXT`；暖白描边新增 `UITheme.BONE := Color(0.96,0.92,0.80)` 入表。
city_marker_art 九色世界物件调色板、minimap 地形/势力色——**豁免**（世界物件/数据可视化，非 UI 外壳），建议在美术圣经记条款即可。

### 1.5 其余风格项

- **R3-06（并入 1.2 管线）**、**R3-13 阴影语言**：遭遇立绘脚下=菱形底衬（encounter_manager `_make_diamond`）、城池 marker=椭圆（city_marker_art `_add_shadow`）、NPC=无影。统一为椭圆（遭遇处复用 ellipse 生成，半透黑 0.18→0.20 一致）。
- **R3-17 轮盘功能色**：quest（0.93,0.80,0.45）与 achieve（0.95,0.80,0.45）几乎同金，七入口视觉不可分。achieve 改 `UITheme.WARN` 邻近但偏橙或引入表外一次性功能色（0.72,0.86,0.98 系 REL_FRIEND 蓝复用即可）。
- **R3-15 panel_paper.png 孤立资产**：全工程零引用，且为亮色羊皮纸（522×900）。二选一：删除（-576KB）；或作为放大地图羊皮纸底图启用（现放大版是代码画的纯色 0.84,0.78,0.63，换这张图质感立升，1 行 set_terrain_tex 之外的 draw 改动，成本≈0——倾向后者，但需用户拍板）。
- **R3-16 bg_main_menu.png 右下 AI 伪影**：右下角约 (820,650) 起有一浅灰矩形块。主菜单 UI 若不覆盖该区域则可见。方案：管线裁剪右下 15% 或补一小块云雾笔刷覆盖，成本一次性。

---

## 二、视觉表现力专项

### 2.1 大地图底图：马赛克根因与分层方案（本报告最重要的单条）

实测链路：`terrain_painter._draw()` → china_geo（1024²）拉伸到 21256×21826 世界矩形，**任何缩放级别都用它**（world_static 仅 china_geo 缺失时才绘制）。zoom 范围实测 `zoom_min≈0.095（全图）→ 1.0（近景）→ 上限≈1.6`：

| zoom | 1 纹素（china_geo 1024）≈屏幕像素 | 1 纹素（world_static 4096）≈屏幕像素 |
|---|---|---|
| 0.095 全图 | 1.87 | 0.47（超采样，浪费） |
| 1.0 近景 | **20.8 → 马赛克** | 5.2 → 细颗粒 |
| 1.6 上限 | 33 | 8.3 |

两条纹理在全程都是「放大采样」，mipmap 无济于事（mipmap 只救缩小），**唯一解法是分层 + 提细节**。分块虚拟纹理机制已按用户要求废弃，不复活。

**R3-02 方案（高优，纯代码，成本≈0）**——利用 `_cam_view`（已在 `set_camera_view` 每帧记录）取当前 zoom，`_draw()` 改为三层：
```
① china_geo 全图铺底（现状保留，远景即它）
② world_static 叠画：alpha = clamp((zoom - 0.25) / 0.15, 0, 1)
   draw_texture_rect(_static_tex, Rect2(ZERO, size), false) 加 modulate alpha 渐入
③ 程序化噪声细节 tile：_make_procedural_terrain_tex("plain", 256) 以
   draw_texture_rect(tex, Rect2(ZERO, size), true) 平铺（tile=true 自动重复），
   alpha≈0.22 —— 噪声以屏幕级频率重复，近景立刻有"地表颗粒"而非糊块
```
每帧多 2 个 draw call；无加载开销（world_static 本来就已经在内存里——见 R3-03）。近景观感从「21 倍马赛克」变为「5 倍细颗粒 + 噪声纹理」，一次代码改动拿到 80% 收益。

### 2.2 遭遇/NPC 立绘屏上表现力

实测：遭遇立绘世界高 54px、NPC 56px；zoom 1.0 屏上 54~56px，**放大上限 1.6 也只有 86~90px**——128/768 高的素材细节大量闲置，且大地图行走时立绘偏小、辨识度弱，尤其暗调立绘贴暗调地形。

**R3-05 方案（高优，成本≈0）**：
- **描金外发光描边**：`_spawn_one`（encounter_manager）与 npc_manager 生成 sprite 时，垫一张同 texture 的轮廓 sprite：`scale ×1.08`、`modulate = UITheme.GOLD_DIM`、位于本体之后——即任务示例的「金色轮廓 sprite 垫底」法；128px 小图上 8% 轮廓≈1~2px 描金边，与描金 UI 呼应，暗地形上轮廓立现。GL Compatibility 下无 shader 成本。
- **交互放大**：`nearest_interactable` 已算出最近遭遇，把该 node 的 sprite `scale` 补间到 ×1.25（Tween 0.15s），离开复位——「要交互的对象长大一点」是最便宜的可读性。
- 不做：逐帧发光动画、shader 外描边（Compatibility 下性价比低）。

### 2.3 战场背景叠加

battle_scene `_setup_background()`：modulate 0.85 压亮 + GroundLine 调淡 0.35，**无渐晕/遮罩**，四角亮度与中央一致，单位与底部操作条浮在等亮背景上。
**R3-08 方案（中优）**：背景 TextureRect 之上加两个 ColorRect（顶部/底部各高 160px，黑 alpha 0.28→0 用 GradientTexture2D 或 8 条 20px 渐变带——Compatibility 最省写法与 hud 渐隐段同款），中央战场自然聚焦，UI 四角可读性+1。成本 2 节点。

**R3-12（低优）**：5 张 bg 随机池与遭遇类型无关（张角 BOSS 可能配田园战场）。encounters.json 加可选 `battle_bg: 4` 字段，battle_scene 读到则锁图、否则随机。

### 2.4 小地图/放大地图底图分辨率

放大版控件 ≈1440px 显示全图 → 1 纹素=1.4px（可接受）；**左上角小缩略图局部模式**窗口 ≈2900 世界宽 → 仅采样 ≈140 纹素拉到 ~300px 控件 → 2.1px/纹素，明显糊。
**R3-11（低优，中期）**：离线把 china_geo 重采样/重生成 **2048×2048** 版（`03-美术资源` 管线加一步，信息量 ×4），`_get_minimap_tex` 改用 2048 版专供小地图；大地图继续用现有 1024（远景 1.87px/纹素无感）。2048² RGBA=16MB 内存，可接受。

### 2.5 专属城图覆盖

map/ 专属图 6 张 vs 110 城。`character_panel` 详情页与 marker 共用 `map/<id>.png`，无图时回退类型图标——回退链健康。
**R3-18（低优）**：优先给都城+州治（is_capital 或 level≥4，实测 cities.json 50 城）补专属图，60 村落保持类型图标即可。与文策渊对齐名单后进下一轮 AI 批次。

---

## 三、性能开销专项

### 3.1 纹理内存盘点（解压后 RGBA8 口径，实测尺寸计算）

| 资产 | 实测尺寸 | 解压内存 | 导入预设现状 | 问题 |
|---|---|---|---|---|
| china_geo.png | 1024×1024 | 4MB | mode=0 无损 / 无 mipmap / size_limit=0 | 无损压缩对照片式图无意义 |
| world_static.png | 4096×4206 | **≈69MB** | 同上 | **无条件加载但被短路，0 命中** |
| battle_bg ×5 | 1536×1024 | ≈6.3MB×5 | 同上 | 每场只 load 1 张 ✅，但 5 张迟早全进缓存 |
| npcs ×749 | ~350×768 | ≈1.1MB/张 | 同上 | 包体 ≈170MB；显存按需+ResourceLoader 永久缓存 |
| encounters/icons/units 等 128² | 128×128 | 64KB/张 | 同上 | 无风险 |

**R3-03（高优）**：`terrain_painter._load_static_tex()` 从 `_ready` 移到首次需要时（R3-02 方案② 首次 zoom≥0.25 时，或 china_geo 缺失回退时）——一行 lazy 化。若采纳 R3-02，则它转为「近景层按需加载」，合理性自动成立。
**R3-19（中优，导入预设矩阵）**：一次性批量改 .import——
- china_geo / world_static / battle_bg：`compress/mode=2`（VRAM 压缩：GL Compatibility 桌面走 S3TC、移动走 ETC2/ASTC，project.godot 已开 etc2_astc ✅）。world_static 69MB→≈17MB；photos 类图无压缩伪影顾虑。
- npcs 全批：追加 `process/size_limit=512`。依据：屏上立绘极限 = 详情面板 470px 高 < 512；768→512 省 56% 显存与包体，对话栏 218px / 世界 90px 全部无损观感。**包体收益 ≈170MB→≈75MB**，对手机包是量级改善。
- 128² 小图保持不动（本来就小）。

### 3.2 每帧开销

- **R3-14（低优）**：放大地图打开时 `_minimap.visible=false`，但 `world_map._process` 仍每帧 `_minimap.update_view()` → 内部无条件 `queue_redraw()`（不可见也重绘画布）。`update_view` 首行加 `if not visible: return`（放大版 _big_map 保持原逻辑）。一行改动，白赚。
- minimap 可见时每帧全量重绘（底图采样 + 110 城 + 河流道路折线）：Compatibility 2D 批处理下约几十 draw call，原型可接受，不动。
- encounter_manager `_process` 每帧双循环 ~140 节点求距离：纯 CPU 数值，非美术域——转交 eng-lead 评估半帧分摊/事件驱动，本报告仅登记。
- DrawCall 静态评估：TerrainPainter 单次 `_draw` ≈1 底图 + ~20 区域多边形 + 河流×3 层 + 道路×2 层 ≈150 命令，静态缓存几何（`_poly_cache` 已做）仅在重绘时执行 ✅；常驻节点（110 marker×3 + 遭遇 ~115×3 + NPC）≈800 节点，2D 视口剔除可扛。**结论：GL Compatibility 下无 DrawCall 高危点**，优先级让位给纹理内存。

### 3.3 资产管线卫生

- npcs/_raw 子目录在工程 assets 内（749 张之外还有原始图）：确认是否被打包（res:// 下即进包）。若仅作回溯用，建议移出 assets/ 或加 `.gdignore`——**转 eng-lead 确认打包白名单后执行，本报告只标记**。
- 03-美术源图 目录为空（0 png），826 张源图在 03-美术资源/，管线 `_done` 流转清晰 ✅。

---

## 四、修改清单

| 编号 | 类别 | 优先级 | 现状 | 方案 | 涉及文件 |
|---|---|---|---|---|---|
| R3-01 | 风格统一 | **高** | NPC 立绘 8/8 白雾（800~2100px halo） | 管线加 1px erode + despill 步骤，746 张批处理后重导出 | tools 管线脚本、assets/sprites/npcs/ |
| R3-02 | 性能开销+表现力 | **高** | 近景 1024 底图马赛克（1 纹素≈21px）；world_static 加载即休眠 | `_draw` 三层：china_geo 底 + world_static 按 zoom 渐入（阈值 0.25~0.4）+ 256 噪声 tile 叠加 α0.22 | scripts/world/terrain_painter.gd |
| R3-03 | 性能开销 | **高** | world_static 69MB 无条件加载、0 使用 | lazy load（首次近景/回退时） | terrain_painter.gd `_load_static_tex` |
| R3-04 | 风格统一(规范) | **高** | 触控目标 56/64/52 < 84px 铁律 | CLOSE_SIZE→84、sub_modal close→84、动作按钮 56→84(r=42) | ui_theme.gd、world_map.gd |
| R3-05 | 视觉表现力 | **高** | 立绘屏上仅 54px、暗贴暗、无轮廓 | 垫金色轮廓 sprite（scale1.08×GOLD_DIM）+ 交互对象 scale×1.25 补间 | encounter_manager.gd、npc_manager.gd |
| R3-06 | 性能开销 | 中 | npcs 768 高全量导入，包体≈170MB | 全批 size_limit=512（包体≈75MB、显存-56%） | npcs/*.import（脚本批量） |
| R3-07 | 风格统一 | 中 | 写实水彩/扁平二次元两批 NPC 混载同屏 | **用户拍板**：A=功能域划风格+统一墨底衬/描金框；B=后续统一 prompt | npcs.json（art_style 字段）、character_panel.gd、dialogue_ui.gd |
| R3-08 | 视觉表现力 | 中 | battle_bg 无渐晕，四角与中央等亮 | 顶/底 160px 黑渐变带各一（同 hud 渐隐写法） | battle_scene.gd |
| R3-09 | 风格统一 | 中 | world_map 四处内联色脱离规范源 | 改引 UITheme 语义色；暖白描边入表为 BONE | world_map.gd、ui_theme.gd |
| R3-10 | 风格统一 | 低 | 标题 44px 硬编码逃逸字号表；世界文字 17/18/20 碎 | FS_TITLE_DISPLAY=44 入表；世界文字两档常量 | ui_theme.gd、world_map.gd、encounter/npc_manager.gd |
| R3-11 | 视觉表现力 | 低 | 小地图局部模式 ≈140 纹素拉 300px，糊 | 离线出 2048 版 china_geo 专供 minimap | 03-美术资源 管线、terrain_painter.gd `_get_minimap_tex` |
| R3-12 | 视觉表现力 | 低 | 战场背景与遭遇类型无关联 | encounters.json 加 `battle_bg` 字段，读到则锁定 | encounters.json、battle_scene.gd |
| R3-13 | 风格统一 | 低 | 遭遇菱形底衬/城池椭圆影/NPC 无影 | 遭遇改椭圆（复用 city_marker_art 椭圆生成），三处统一 α | encounter_manager.gd |
| R3-14 | 性能开销 | 低 | 放大地图打开时隐藏的小地图仍每帧重绘 | `update_view` 首行 `if not visible: return` | minimap.gd（或 world_map 调用处） |
| R3-15 | 风格统一 | 低 | panel_paper 零引用孤立 + 亮色与铁律相反 | **用户拍板**：删除，或启用为放大地图羊皮纸底（推荐后者，成本≈0） | assets/sprites/ui/、minimap.gd `_draw_panel_bg` |
| R3-16 | 风格统一 | 低 | bg_main_menu 右下 AI 伪影矩形 | 管线裁剪/云雾覆盖右下角 | 03-美术资源 管线、ui/bg_main_menu.png |
| R3-17 | 风格统一 | 低 | 轮盘 quest/achieve 功能色同金不可分 | achieve 改 REL_FRIEND 系蓝或 WARN 橙 | main_menu_wheel.gd |
| R3-18 | 视觉表现力 | 低 | 专属城图 6/110 | 优先都城+州治（50 城）补批，60 村落维持类型图标 | 03-美术资源、assets/sprites/map/ |
| R3-19 | 性能开销 | 中 | 全部纹理 mode=0 无损、照片类图压缩浪费 | china_geo/world_static/battle_bg 改 mode=2（VRAM），world_static ≈69→17MB | 三组 .import（导入面板批量） |
| R3-20 | 性能开销 | 低 | npcs/_raw 疑似随包 | 确认打包白名单，移出或 .gdignore（转 eng-lead 确认） | assets/sprites/npcs/_raw |

**待用户拍板项**：R3-07（风格域划界）、R3-15（删或用 panel_paper）。
**跨岗移交**：R3-20→eng-lead；encounter 每帧扫描优化→eng-lead 参考。
**建议执行顺序**（原型阶段、全部不含美术重制）：R3-01 → R3-02/03 → R3-04 → R3-05 → R3-19/06 → 其余按优先级。

---

*附：本报告全部尺寸/内存数字来自 Pillow 实测（831 png 全扫 + 17 张逐像素 alpha 检测），脚本与中间产物均在系统临时目录，未触碰工程目录。多模态目检样本：china_geo、world_static、battle_bg_1、encounters×6、npcs×5、portrait×1、city_icons、scene_17、hall、bg_main_menu、panel_paper、units、menu_icons。*
