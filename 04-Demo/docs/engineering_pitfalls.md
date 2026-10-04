# 纪元三国 · 工程陷阱库

> 这是 **MEMORY.md 的下沉明细**。MEMORY.md 只留「不读会立刻犯错」的硬约束；
> 完整的踩坑细节、代码标识符、判据写法全部在这里，需要时按标题检索。
>
> 创建于第六十八轮（2026-10-03）。原 MEMORY.md 达 21KB 会话时被截断，
> 故按「高频硬约束 → 按需明细」两层拆分。

---

## 一、GDScript 语法陷阱

### Parse Error 常见源
- `for x in [...]` 漏 `in`（Parse Error）
- `var x := a and b` —— 动态属性组合（Parse Error）
- `.get()` / 索引 / `[]` 的结果不能 `:=` 推断
- **带类型标注的变量不能赋 null**：`var x: Array = null` → Parse Error，
  用「未初始化为空数组」表示无缓存
- `for x in [...]` 里的 `x` 漏 `in` 是 Parse Error，不是运行时报错

### 类型方法误用
- **Container 不是数组**：`is_empty()` / `size()` / `has()` 属 Array/Dictionary。
  判 Control/Container 空必须用 `get_child_count()`，否则运行时报
  `Nonexistent function 'is_empty' in base 'VBoxContainer'`。
  **编译期完全无感，只有真跑才现形** —— 这是本工程最贵的坑之一。
- `String` 无 `size()`，用 `length()`
- 不支持嵌套切片 `body[a:][:120]`（Parse Error）
- `float` 无 `is_equal_approx()`（那是 Vector2 的）
- 模块级计数器在函数内 `+=` → UnboundLocalError，用 `CNT=[0]` 间接引用
- `get_node_or_null` 只收 NodePath，而 `Node.name` 是 StringName
  → `NodePath(str(x))`

### 伪装成「挂死」的错误
headless 下 Parse Error **只表现为挂死/超时**，不打印明确错误。
排查法：先直接跑引擎 + `grep "SCRIPT ERROR|Parse Error"`，别猜逻辑。
此类探针须 `run_in_background=true`（工具 120s 超时同症状）+ `get_tree().quit(code)`。

### 协程两种伪装
- 调协程漏 `await` → 脚本加载失败、进程永不退出
- `"t" + await _check_x()` 而它 `-> bool` → Invalid operands
- **判定函数统一返回 String**（Python 侧用 `== "true"` 判断）
- 写完先跑 `--check-only`

### 中文注释经 shell heredoc 会变乱码（第六十八轮·本轮踩 2 次）
`python - <<'EOF'` 传入的中文在某些终端编码下会变成 U+FFFD 替换字符（`�`）。
**症状**：改完文件后注释里出现 `��何分支` 这种残缺字，且**编译能过、运行正常**，
只有肉眼看注释才发现 —— 极易漏过。

**正确做法**（按优先级）：
1. 改中文注释用 **Edit 工具**，不走 shell 传输。
2. 若必须用 heredoc：**写盘后立刻普查**
   ```python
   s.count('\ufffd')   # 必须为 0
   ```
   全工程普查脚本：
   ```python
   for root,dirs,files in os.walk('.'):
       dirs[:] = [d for d in dirs if d not in ('.godot','.git')]
       for fn in files:
           if fn.endswith(('.gd','.tscn','.json','.py','.md')):
               s=open(os.path.join(root,fn),encoding='utf-8',errors='replace').read()
               if s.count('\ufffd'): print("乱码:",fn)
   ```
3. 乱码修掉后**还要检查是否连带缺字**（删 U+FFFD 会留下残句，如「的世界」→「的界」）。

### 搜索盲区
grep 调用点须同搜无括号形式：`call_deferred("_f")` 不被 `grep '_f()'` 命中。

---

## 二、无头探针铁律

### autoload 不加载
**`--headless --script` 不加载 autoload**。依赖 `GameState` / `DataManager` 的脚本
**加载期编译失败**，类对象方法全空，报
`Nonexistent function 'x' in base 'GDScript'`。
SceneTree 型探针只能碰零 autoload 依赖模块：
- 可：`CityInteriorArt`
- 不可：`CityMarkerArt`、`BattleUnit`

**修法在探针侧**（直接验资源 + 复算公式），**不改生产代码**。

### 平台层陷阱
- **`taskkill` 输出是 GBK** → `subprocess.run(text=True)` 按 UTF-8 解码抛
  `UnicodeDecodeError`，且发生在读取线程里 → **整个校验崩掉**。
  必须 `encoding="gbk", errors="replace"`。
- **Windows 上 Godot 被 timeout 杀后留僵尸进程**（实测 6 个），
  持有 `.godot/` 与存档写锁 → 存档指纹判据误报「探针污染玩家存档」。
  校验器跑探针前先 `kill_stale_godot()`，且存档基线必须在清理**之后**取。

### 协程与产出量
- **含 await 的检查须逐个 await**：for/裸调并发、共享夹具被后一个
  `queue_free` → "previously freed"；漏 await 则空跑却输出 PASS。
- 校验器必须加**产出量闸门**（按钮数/实体数），光看节点数不够。
- 探针根节点用 `Control` 不用 `Node`：待测 Control 靠锚点定位，
  父级非 Control 时锚点无参照、坐标失真。
- **headless 视口是 1920×1920**（无窗口时高度退化为宽度），不是项目配置的 1080。
  任何"是否出屏"判断必须相对 `get_viewport_rect().size`。

### 探针内禁用 `%` 格式化
`_fail("..%s.." % x)` 参数不匹配会中断、结果文件不落盘、进程挂死
→ 缺陷表现为「超时」而非「明确 FAIL」。**全用字符串拼接**（`%` 优先级高于 `+`）。

### 先审副作用链
交互切场景 / 改 autoload / 写盘会 free 探针节点 → 后续判定全灭，
且被误读成别的判定挂了。
- 有副作用的命题交**源码锚定层**，探针只做无副作用子集
- 切场景类探针持 `SceneRouter._is_transitioning=true` 闸
- **探针须对「缺陷态」有防御**

### 落盘纪律
真写磁盘时，收尾要枚举原子写全部产物（`X` / `.bak` / `.tmp` / 索引），
并加「跑前跑后目录指纹一致」硬判据。仅还原主文件＝污染玩家存档。
判据串须与其他字段值可区分（裸 `contains("3")` 会被「天下 3 家势力」巧合命中）。

### 不硬编码上游常量
`world_map.gd` 无 `class_name`，常量（`PLACE_RADIUS` / `PLACE_TOUCH_SLACK` /
`PLACE_LEVEL_STEP`）应从源文件抠取。否则上游调数值、校验留过期副本
=「测的和跑的不是一个东西」。

**「新旧两套算式都在探针里」是陷阱**：照抄改造后版本则上游改错反而放过。
必须补**独立锚定层**直接核对上游源码。由 `_verify_city_interact.py` 的 A2/B2 实现。

**各文件探针签名不同，别跨文件复用**：`tests/probe_runner.gd` 的
`_check(tag: String, cond: bool)` 只有 **2 个参数**（无 detail 形参），
与其他探针不同。

---

## 三、校验方法论（血泪）

### 反向验证必做
新校验上线前必须**把被测逻辑改坏**，确认校验真的会报红。
绿灯必须证明过自己是有效的。配**假阳性对照**（改一处无关内容，锁必须仍绿），
否则说明判据过于宽泛（靠"文件里有这个字"蒙对）。

### 注入器的自检闸
- 先在原文把全部锚点 `count(o)==1` 预检，全中才一次性写盘；
  预检失败即中止＝校验跑原版＝**制造假绿灯**
- 锚点用**最小唯一单行**（尽量单行）；不要用多行大块锚点（缩进层级极易写错）
- 连续 2 次锚点失败时**不要重复换行尾处理**（已踩过），应改为打印 `repr()` 看真实缩进
- heredoc 会吞 `\n` 成字面量 → 换行用字符拼装
- 注入器是临时文件，验完必删

**`assert` 在写盘前中止 → 文件未被破坏 → 校验跑的是原版 →
这是一次假绿灯的制造过程。**

### 注入不得污染判据输入
判据若扫全工程 `.py`，注入脚本里就不能留被注入对象的完整名字字面量
（否则注入脚本自己成了"消费者"，用例 100% 漏放）。用运行时拼接。

**且样本必须真落在判据的扫描范围内**（如判据只扫 `*_probe.gd`，
样本就得保留该后缀）—— 两处任一错，用例都表现为「100% 漏放」，
与「判据写错」症状相同，**须先查样本是否入范围**。

### 判据要断言语义而非字面形式
- 锚「表达式/赋值」不锚「标识符出现」：同标识符多次出现时 `in` 等于随机抽样
  （删 `shadow_node.modulate.a` 赋值仍子串命中；只判 `var idle` 被「留声明废语义」骗过）
- 用 `re.search(r"…\s*=")` 并数赋值次数
- 只认字面数字的正则会在值改成表达式后假红
  → 用 `_positive_expr(rhs)` 断言语义（仍拒绝 0/负/缺失）

### 判据形态须对齐实现形态
先 Read 真实实现（内联 / 调用 / 委托）。按钮改名、关闭改补间、筛选变宽
会让探针静默恒假（表现为 FAIL 非报错，最易误当产品回归）。
要区分同函数内不同语义段。

### 校验器自造假绿灯的四类根因
1. falsy 空容器跳过分支（先 `check(bool(x))`）
2. 只查存在不查内容（`isdir` 空目录仍真 → 加「元素数>0」）
3. 死代码阈值常量（上线前 grep）
4. PNG 透明须实测 alpha，看 ct=6 会漏

### 判定型探针须被 .py 消费
无人消费的 `_check` 探针＝**不会响的锁**。定期普查 `tests/*_probe.gd`。
判定型 = 有 `_check` / `_fails += 1` / 哨兵 / 非零退出码；
诊断型（0 判定函数）不担锁职责。

### 退出码必须传导（第六十七轮血泪）
判定型校验器若只打印「失败项」然后正常收尾，**退出码恒为 0**，
而 `_run_all_checks.py` 用 `returncode == 0` 判 PASS
→ **这把锁永远不会响，比没有锁更危险**。
`_verify_exitcode_guard.py` 普查全部被驱动脚本守住这条。
Python 侧还要注意 `import sys` 是否存在。

### 行尾不统一（本仓现状）
`ui_theme.gd` / `hud.gd` 是 CRLF，`encounter_manager.gd` 是纯 LF。
做临时注入 / 批量改写前**必须先探测行尾**（`raw.count(b"\r\n") > 0`），
写盘用 `newline=""`；否则 `assert` 在写盘前中止＝假绿灯。
注入器写文件会改换行符（autocrlf=true，sha256 对不上 HEAD 但 `git diff` 空
→ 判污染用**归一化比对**）。

### 批次删除防护钩子
本工程累计删除数超阈值（实测 50）会拦下 `os.remove`。
反复注入一律用 `os.replace(x, x + ".bak"/".rvbak"/".stale")` 改名，
这些后缀需进 `.gitignore`。

**`os.replace` 不能跨盘**（E:→C: 报 WinError 17），跨盘要 `shutil.move`。

### 基线取证须串在同一条命令
`cp orig && godot && cp fixed` 必须在同一条命令内，后台任务内不得穿插编辑；
否则探针读到修复版却输出「原版 OK」。

**有效性看进程退出码**（FAIL→`quit(1)`→EXIT=1），不看文本有无 FAIL。

### 其他
- 事实性数字先 grep 实测再落笔（散落多文件，一处写错＝三处污染）
- 静态校验按源码字面切段 → 新增同字面结构会切坏，须反写绕开
- `_verify_*.py` 放 04-Demo 根目录且 `ROOT = dirname(abspath(__file__))`
  （用 `dirname(dirname())` 会错位到上级目录，聚合脚本会 FAIL）
- 探针/烘焙脚本须**自包含**（内嵌 GDScript 写 tests/ 临时文件），否则删了探针就跑不了
- `git ls-files` 传纯文件名（cwd 为子目录时仓库根相对路径恒解析失败
  →「是否被跟踪」判据变死锁）
- 前置门禁先于不可逆确认：`can_attempt` 不过不弹窗；空白判定用 `strip_edges().is_empty()`
- 批量替换后数配对数量自检
- 扫 substr 的判据会误命中自己写的注释行（排除 `#` 开头行）
- **`_verify_*.py` 新增后必须放 04-Demo 根目录**，且加入 `_run_all_checks.py` 的 `SCRIPTS`

---

## 三·补 判据设计的四条教训（第六十八轮·新增）

### 1. 复刻式校验必须随产品算法同步重写
`_verify_world_scale.py` 第六十六轮复刻「步幅 = 身高比例 × 身高」。
第六十八轮产品改成「步幅 = 速度 ÷ 目标步频」后，**校验器仍按旧式计算** ——
它测的是一个产品已不存在的模型。复刻式判据不是文档，**它是产品的一部分**。

### 2. 校验器硬编码上游常量副本 = 自己制造假绿灯
同一文件曾硬编码 `REF_SPEED = 300.0`（上游 `walk_anim.gd` 实际是 400.0），
于是校验器算出 2.08 步频，并据此**把正确的实现判红**。
**后果比假绿灯更隐蔽**：它不仅漏，还会主动报错。
必须从源文件抠取（`walk_anim.gd` 无 `class_name`，`const_floats()` 正则提取）。

### 3. 「取证到 X」不等于「校验 X 的值」
反向验证 R3/R6 暴露：城内/世界 NPC 判据写的是
`check("城内 NPC 报身高", "wa.body_height = ..." in city)` ——
只验证了**接线**（有没有把身高传下去），没验证**数值**。
把 `NPC_WORLD_HEIGHT` 退回 56 / 210，校验器**全绿**。
凡是「取到 X」后面紧跟的判据，都要问一句：**我锁的是它的值，还是它存在？**

### 4. 判据的方向可能与用户诉求相反
旧判据「城池与玩家同量级（0.6~1.6）」在旧基准 425 下意味着
「城墙 ≈ 人高」—— 而这正是用户抱怨「像贴图游戏」的直接来源。
**判据全绿，但它锁的是错的方向**。
判据写成断言数值区间容易、但**不写清「为什么是这个区间」**；
一旦基准变化，区间会失效而无人知道依据。
**做法：每条区间判据旁必须写推导过程**（换算式 + 为何合理），
并在基准变更时**重新论证而非简单放宽**。

---

## 四、有副作用的「判脏」函数不可复用（第六十轮血泪）

`_static_geometry_dirty()`（小地图）**判脏时会写快照**。
在新增的 `_redraw_needed()` 里调它来判断「几何变没变」——
结果 `update_view` 里的判脏**永远为 false**，第五十八轮的脏标记被**静默架空**，
而编译期与运行期都不报错。

**「判脏 + 推进状态」函数是一等危险品**，不得被任何别的路径调用。

**正解**：判「要不要重绘」用**独立的只读比较**
（六个 `_geom_sig_*` 标量 + `_consume_redraw_state()` 独立推进）。
由 `_verify_minimap_throttle.py` 的 H2 锁死。

**推论：每加一个「脏标记/节流」函数，都要问它有没有副作用。**

---

## 五、脏标记改造范式（可复用于任何 `_draw` 重计算）

1. **穷举全部几何输入快照**（小地图 7 项：ctrl_size/map_size/expanded/
   view_mode/zoom/pan_center/player_pos），漏一项＝局部退化。
2. **只让真正影响窗口的输入进脏标记**：局部模式窗口由玩家位置推导，
   **漏 `_player_pos` 会让小地图彻底卡住不跟随**。
3. **快照同步放 `_recalc_geometry` 内部末尾**，不放调用方（8 处直接调用会漏）；
   且须在 clamp **之后**（expanded 分支就地改写 `_pan_center`，
   记在改写前 → 永久判脏＝优化根本没加上）。
4. **精确 `!=`**。Vector2/float/bool/int 可快照；
   **集合/数组不能**（改内容不改身份 → 恒相等假绿灯）。
5. **等价性用 headless 双跑**（脏标记版 vs 每帧重算版逐帧比 `_world_window`/
   `_scale`/`_origin`，覆盖静止/位移/越界/切模式）+「静止 N 帧判脏 ≤1 次」。
   `_verify_minimap_geom.py` 31 项。
6. **早退分支是隐式杀手**：`return` 跳过末尾同步 → 早退分支须**自己内联写快照**
   兜底（不能调同步函数）。判据锚「七项赋值全在 return true 之前」。

---

## 六、每帧重绘节流范式

立即模式 `_draw` 没有子控件可单独重绘，所以「让某个小元素动起来」会拖着
整幅画面每帧重画。做法：把**唯一的逐帧动画**（如呼吸光晕）节流到 12fps，
其余真实变化走立即重绘。

**判据必须双向都测**：既测「静止时省了多少帧」，也测「移动时是否被吞帧」——
只测前者会矫枉过正成「界面冻住」，只测后者则节流根本没生效。
实测：静止 60 帧 60→9~10 次，移动 60 帧仍 59 次。

**判定函数里别用 `[a,b,c]` 打包数组做签名**（那是每帧新建数组）；
用独立标量字段比较，同样精确且零分配。

---

## 七、UI 铁律

- **水墨描金**：墨底 `#171B26` + 描金 `#C7A45C`；面板 1040×780；
  触控 ≥84px（`UITheme.TOUCH_H` 强制兜底）；符号图标替文字、标题居中、返回钮左上。
- **全屏锚点**用 `set_anchors_and_offsets_preset(FULL_RECT)`；
  `PRESET_CENTER` 配 grow BOTH。
- **autoload 信号用方法绑定**（勿 lambda 捕获 self，会叠僵尸 handler）。
- **重建容器先 `remove_child` 再 `queue_free`**（防同帧双击双扣）；
  ScrollContainer 重建后 `scroll_vertical=0`。
- 触控双事件同帧派生 → 对话推进按 `process_frames` 去重。

### 按钮高度单一来源是 `UITheme.button()` 工厂
不要在工厂之后再写 `custom_minimum_size` 覆盖它
（第五十三轮就抓到 settings 返回按钮被 `ROW_H=62` 覆盖回 62）。
全工程 `const ROW_H` 不得低于 `UITheme.TOUCH_H`。
交互菜单是例外——它保留自有配色，只补高度与 `AudioManager.ui_click`。

### 对话选项超 4 项必须两列
`MAX_OPT_VISIBLE` 的两列意图一直只写在注释里没实现：
单列 8~10 项总高 756~948px 会把尾部按钮顶出屏幕下边界 236~428px 点不到
（真实有 13 个超 4 项节点，liubei_intro 10 / caocao_intro 9 / strategist_intro 8）。
现由 `_options_box` 内挂 `_opt_grid: GridContainer`（columns 1/2）实现，
`_verify_dialogue_layout.py` 锁 180 节点 / 370 按钮。

### `_any_ui_open()` 判定表已锁死
world_map 13 项 / city_scene 12 项，红线在 `_verify_ui_layering.py`。
**加面板必须同步加进 `_ready()` 的 `_ui_panels` 并更新校验器里的红线清单**——
漏项的后果是「面板开着但人还在跑」，不崩不报错，编译期与运行时探针都抓不到。
另：城内 `_dialogue` / `_trade` 是 `create()` 出来的，登记必须放在创建之后。

### Toast 是队列不是单条
`ToastLayer` 每条提示独立 Panel + VBox 堆叠 + 独立 Tween
（`MAX_VISIBLE=4` 挤最旧）。改它时务必用 `_verify_toast_queue.py` 验，
回退成单 Panel 会静默退化为「后一条顶掉前一条」。

### 移动端安全区
`UITheme.safe_insets(vp) -> Vector4(left,top,right,bottom)` +
`apply_safe_top_left` / `apply_safe_bottom_right`。
无刘海机恒全 0 → 布局逐像素不变（由 `_verify_safe_area.py` 逐字段断言）。

**新增贴边控件时须接对应 apply 函数**；hud 资源条右缘是 `-24.0 - safe.z`，
写死 `-24.0` 会顶掉安全区左移量。

### DataManager 缓存
`DataManager.get_heroes6()` 已加缓存（`_heroes6_cache`，`load_all()` 失效），
返回同一数组实例。人物志搜索走 `SEARCH_DEBOUNCE=0.22s` 去抖，
改它必用 `_verify_hero_dex_search.py`（直连重建因 `queue_free` 帧末生效导致同帧空窗）。

---

## 八、encounter_manager / 大地图铁律

### 判定顺序铁律（第五十四轮）
`_process` 内 `_triggered_ids.has()` 必须**早于** `_is_manual()`。
顺序颠倒会让已结算战斗点落进「走近自动触发」分支
→ 站着不动也每帧重开战斗。由 `_verify_encounter_perf.py` 锁死。

### 提示唯一性必须用恒等式
多处 Hint「只亮最近一个」都要写 `_set_hint(node, node == near_manual)`，
不可写成「谁不是最近就收起谁」——后者有遍历顺序依赖，会同屏亮两串
（`world_map.gd:1122` 已同源修过一次）。

### 每帧已缓存
`_enc_nodes`（全部点）/ `_manual_nodes`（手动类子集）生成期登记，
`reload_region` 两处必须同时 `clear()`；比较一律 `distance_squared_to`
且半径同步平方化；对外 `dist` 必须 `sqrt` 还原
（返回平方值不报错，只是量纲错）。

### 城池半径已缓存（第五十五轮）
`_compute_place_radius` 在 `_create_marker` 时算好落 `place_radius` meta，
`_place_radius` 只读它（不得退回读 `city_data`）；
`_find_nearest_place` 用 `distance_squared_to` + `cutoff*cutoff` 粗筛后
**必须 `sqrt` 还原**给 `best_dist` / `score`；
`_cull_offscreen` 的 `visible` / `scale` 仅变化才写
（`lod==1.0` 时跳过 scale 已论证与原式逐位等价）。

### 节点集合缓存套路
生成期 append 到 `Array[Node2D]`；**唯一移除路径必须 `clear()`**；
每帧遍历前判 `is_instance_valid`；只读缓存的函数内**不得再有 `get_children()`**；
全仓 grep 确认无第二条增删路径。
容器类判据配元素过滤（`$NPCs` 混有 Label 等非 Node2D）；
子类 `_ready` 早于父，父 `_ready` 收集子集合安全。
候选集合别存 Dictionary，只存 node 引用。

---

## 九、玩法关键（勿回退）

- 时间 **15 秒/天**；升级 `C(lv)=115×lv^1.625`（上限 120）；单挑 `f(s)=30+s×0.5`
- 跑商：买入=基础价×level×commerce×specialty，
  卖出=该城买入×(0.74+商埠 0.08)，同城回收 0.74~0.82（禁刷金）；
  参数全在 `shop_goods.json`
- 遭遇「已解决」仅**胜负后**写（败记 `total_days`，当日封锁次日复活）；
  主角 6 槽装备已接入战斗
- 战斗：`tick_rate=0.25`、`base_dps_scale=0.085`、`damage_variance=0.16`、
  `defense_scale=115`、`defense_floor=0.38`、`rout_morale_threshold=18`
- 攻城：`garrison_per_defense=6`、`spearman_ratio=0.35`、`archer_ratio=0.25`、
  `min_garrison=24`、`max_garrison=420`；110 城 defense min=4/median=7/mean=20.9/max=90（长安）
- 队伍耐久：`HP_SCALE=8.0`、`HP_TROOP_REF=40`、
  `HP_TROOP_MIN_RATIO=0.30`、`HP_TROOP_MAX_RATIO=4.00`（**封顶 160 兵等效**，
  超编只加输出不加耐久——是设计意图不是缺陷）
- 士气按秒结算（`morale_grind_per_sec=2.2`、`morale_grind_idle_mult=0.35`），
  不是按挨打次数

### 季节全游戏仅一套定义
一律调 `GameState.get_season()` 比对
`SEASON_SPRING/SUMMER/AUTUMN/WINTER`（1-3春/4-6夏/7-9秋/10-12冬）。
曾 TerrainPainter 走 get_season 而 DayNightTint 按 month 自定 → 1/2/12 月冲突。
`_verify_season_consistency` 锁三层同源。

### 跨场景演出定式（第四十轮）
事实层 GameState（autoload 常驻 + 入存档）+ 演出层静态类 WeatherFx
（读事实造粒子/染色/音频）。**场景树之间绝不互相引用**；
headless 粒子恒 null 规避 CPUParticles2D 挂死坑。
雨声实现收口单份（`WeatherFx.make_rain_stream`），三场景同源。

### 确定性视觉取证
shot_probe 支持 SHOT_SEED / SHOT_WEATHER / SHOT_DAYF——
同种子雨/晴两图相减＝纯天气层；**背景随机时像素对比全是噪声**。

### 复合 action 双路径须同源
`dialogue_ui.gd` 任务过滤用 `substr(...)`、执行路径先 `split(",")`
→ 复合指令 qid 变整串、任务状态恒 false（不崩只静默失效）。
已抽 `_first_action_arg(action, cmd_prefix)` 共用；
qid 空时 pass 交回通用按钮，后续 `if` 改 `elif`。

### 其他
- collect 进度走 quest_progress 计数器**不查物品表**；
  判「能否被产出」看 encounters 的 gather_item + loot_table
- JSON 存档把 int 键变 str 键是已知地雷
  （faction_relations 靠 `_restore_int_keys` 还原）

---

## 十、数据闭合：剧情留痕 vs 真断链（勿误判）

`apply_unlock_value` 先问 `SelfRuleService.grant_by_flag`
（`sr_*`→师傅链、`seal_jade`/`seal_tiger_tally`→信物），
未命中才落 `GameState.story_flags`。

**主线靠 quests 的 `next` 链**（37 个 `type=mainline` 首尾相接），
不依赖 unlock 标记 → `mj_*` 无读取方属**留痕**，非主线脱节。
未知标记登记进 `_verify_data_closure.py` 的 `STORY_TRAIL_FLAGS`。

### 「伏笔是否兑现」看可达性不看标记名
`story_flags` 无读取方 ≠ 未兑现。
判据是 `_verify_data_closure.py` [C2] 从每个 NPC 的 `dialogue_root`
沿 `next` / `options[].next` 遍历检出孤立节点。

**约定式动态入口必须计入种子**：
- `mj_ch{N}_end/_start`（`_queue_narration` 运行时拼名）
- `mj_finale_{emperor,han,hegemon,hermit}`（`finale_dialogue_id()` 按结局返回）
- `intro`（首进图）
- NPC 对话根 `_pending` / `_turnin` 后缀

`side_hezi.future_necklace` 已兑现，勿再判缺口。

---

## 十一、不可逆操作防误触（铁律）

**不可逆操作必须有二次确认；可反悔操作不得平白加确认**（妨碍救火）。
典型：弃城失地、处死俘虏、解散部队、交出城池、覆盖存档。

### 三要素（缺一即不合格）
1. 确认态有**独立显式出口按钮**
2. 取消后**完整还原初始状态（含文案！追加型须存原文快照，
   否则反复点无限追加）**
3. `open()` 每次**复位确认态**，防弹窗复用带上次状态

### 同屏文案必须同源
正文与二次确认一律用**入参快照**；一入参一重查实时，
两次点击间状态变了就同屏两个矛盾值。

危险按钮与安全按钮**不得同高同宽平级**（弃城 vs 迎战）；确认行撤销放左。

### 对称拦截
同屏「删除」有确认而「覆盖」一点即过＝真实缺口。
覆盖确认：① 展示旧档摘要防盲确认 ② 摘要走入参快照
③ 空槽保持直达不加步骤 ④ 撤销放左 ⑤ 与删除确认同一套 sub-modal 视觉 + 幂等守卫。

### 「不可逆」看两面
磁盘数据 + 玩家未存进度。覆盖存档丢前者，读档丢后者。
判据：自动存档触发点 grep + 游戏内 `SaveManager.` 调用 grep 为零 + from_dict 字段数。

### 确认文案不得写不成立的兜底承诺
「自动存档已保留」在「返回主菜单」成立，在「读档」**不成立**
（读档直接覆盖内存态，回不到那个时间点）。
有对局判据用独立字段，别拿 `pending_return` 反推（表现层字段），形参默认 false。

---

## 十二、美术 / 音频（事实结论，勿再误判缺资源）

### 美术资源早已全部落库
旧记载「14 兵种立绘待生成」**已证伪**：
- `assets/sprites/units/` 14 张兵种立绘
  （**不是**不存在的 `assets/art/heroes6/`）
- `assets/sprites/npcs/` 862 张
- units.json 14 个 id 与磁盘 png 一一对应、0 缺 0 孤儿
- heroes6 825 人缺口为 0（那 6 个缺口是 `is_dummy` 占位记录 id2–6
  与走 `player/` 立绘的主角 id=1）
- `_load_unit_icon()` 接线完好

**立绘没有待办，只有防护**——由 `_verify_art_pipeline.py`（75 项）守着。

### 唯一美术待办
主角四向行走精灵表 `res://assets/sprites/player/walk.png`（四向×4帧），
`PlayerController._try_use_sprite_sheet` 已就绪；受 ImageGen 429 限流暂缓。

**ImageGen 并发不隔离** → 互异 prompt + 共享暂存归位；出图带水印 erase 后 `--import`。

### assets/audio 资产真实存在
推翻 39 轮误判，**勿再引用「全 ogg 空桩」**：
- `sfx/*.ogg`（7–48KB，如 ui_click.ogg=7062B/0.267s）
- `bgm/*.ogg`（338–919KB）
- 真缺的只有 `ui_panel_open` / `ui_panel_close`（已合成填补）
- `bgm/*.res` 是烘焙产物

**空桩探测守卫 `_stream_usable`**：命中 ogg 后须判 `get_length() > 0.01s` 才放行，
否则回退占位合成；真实音频落入自动放行，缺失/空壳（1~27B）自动兜底。

### GDScript 预渲染长 BGM 不可行（实测）
单曲 136~235 万采样 × 四层织体，战斗曲（最短 62s）合成 >110s 未完成。
**长音频一律走构建期离线烘焙成 WAV，不在运行时合成。**

管线：`scripts/audio/bgm_synth.gd`（基元）+ `bgm_composer.gd`（作曲）
→ `tools/_bake_bgm.py` 烘焙 → `assets/audio/bgm/*.res`；验收 `_verify_bgm.py`。
规格见 `docs/audio/bgm_direction.md`（第 11 章为性能实测与路径修正）。

**长音频存 `.res` 不存 `.wav`**：AudioStreamWAV 的 loop_mode/mix_rate/loop_end
随资源序列化；存 .wav 走导入流程且 loop_mode 默认关闭，要改 .import 再重导。

### audio_manager._finish_stop 顺序铁律
**先 `stream=null` 再 `stop()`**——AudioServer 侧 playback 握流引用，
反序退出报 "1 resources still in use"。

### UiSfxSynth
短音 ≤400ms + 首尾淡 + 去直流 + 不循环 + 固定种子 + 峰值余量 0.36~0.52；
`UITheme.button` 一处接按键音，`make_modal` 绑 `owner.visible` 出面板开合音
（meta 去重）。
`_synth_pluck` 的 `amp` 曾从未参与运算（已修）；
Karplus-Strong 用分数延迟修音准（整数延迟 22050Hz 下 2093Hz 偏 90 音分）。

### 良性告警勿当 bug
退出期「resources still in use city_service.gd/formation_calculator.gd」
是 Godot 4 class_name 全局注册表持引用（引擎侧、无法消）；
2 个空路径孤儿 Node 是探针快速建/毁 + 立即 quit 时 `queue_free` 未冲刷。

---

## 十三、记忆与现实不符时

记忆里的「待办」可能早已过时（曾误判「14 兵种立绘待生成」「全 ogg 空桩」）。
**发现过时就地纠正记忆。**

判定「记忆过时」须**先证伪自身怀疑**——
曾一度误判 units.json id 与磁盘文件名断链，实际 id 就是 snake_case 且 14/14 全命中。

---

## 判据自身的六种假绿/假红（第六十九轮·战斗演出强化）

本轮新增 2 个校验器 + 1 个探针，**七次踩在判据自己身上**。
这些不是一次性事故，是可复现的通用陷阱。

### 1. `str.find` 命中注释里的词 → 恒假红
判「先判 A 再判 B」时用 `body.find("_begin_rout()")`。
但函数注释里就写着「走 `_begin_rout()` 就 return」——
**注释位置 1891 < 真实调用 2232**，判据把注释当代码，恒假红。
**正解**：逐行扫描 + **跳过 `#` 开头行**，只取真正的调用位置。

### 2. 判据名有前缀关系 → 子串匹配双向出错
判据叫 `B1` / `B1b` / `B2b`。反向验证用 `"[FAIL] " + key in out` 匹配：
- 期望 `B1b` 会被输出里的 `[FAIL] B1` **误配成真**（假绿）
- 判据实际报红的是 `B1b` 而期望列表写 `B1` → **永远匹配不上**（假失败）

**正解**：`re.search(r"\[FAIL\]\s+" + re.escape(k) + r"\b", out)`。
注意 `[FAIL]` 的方括号**必须转义**，否则被当字符类。

### 3. 判据只判「存在某个调用」会被别处凑数
判「转身用 move_toward 插值」写成 `move_toward(_facing_x` in body，
结果反向验证把**同侧插值**改成硬切后，另一处**反向转身的钳位分支**
仍有同一前缀 → 判据照样绿 → 用例假失败。
**正解**：判据必须带**目标参数**（`move_toward(_facing_x, _facing_target`）才唯一。

### 4. 封顶型判据「配一次就够」是假绿
「轨迹点数不超过 7」—— 但点数**早已封顶在 7**，
单位动不动都是 7，判据恒绿，测了个寂寞。
**正解**：封顶判据必须**另配一条前置**「该状态下确实在增长/确实在记」，
两者合起来才构成对照。

### 5. 采样点取错位置 → 前后值相同 → 恒假红
判「轨迹 alpha 会淡出」，取样点取在「站定后 20 帧」——
那时 alpha 已被淡到 **0.00**，前后都是 0.00 → 恒假红。
**正解**：取样点必须在**状态刚切换的那一帧**取（`刚转 ENGAGE` 的第 1 帧）。

### 6. 单次采样比值型判据必然假红
`calc_damage` 带 `variance(±0.16)` 随机浮动。判「克制 1.25 的伤害高于被克 0.8」：
理论比值 `1.25/0.8 = 1.5625`，阈值 1.4 本应稳过，**单次采样只到 1.36**。
**正解**：60 次采样取均值（得 1.58）。这是本项目**第 4 次**踩同一个坑，
已从「个案修补」升级为通用规则。

### 7. 「变量里存了节点名」不等于「探针能按名字取到」
`_charge_trail = Line2D.new()` 但**没设 `name`** →
探针 `get_node_or_null("Art/ChargeTrail")` 恒 null → 测了个寂寞还报「节点未建」。
**正解**：新建的、可被探针按路径定位的节点一律显式 `name`。

---

## 「死代码三元表达式」——本次抓到的最有意思的缺陷

```gdscript
_body.scale.x = 1.0 if dir.x >= 0.0 else 1.0
```

**两个分支完全相同，等于什么都不做。** 这个 `_face()` 被调用了无数次，
每帧都在「更新朝向」—— 但朝向永远是 +1。
战场表现：一堆**左右对称的图钉站在原地互砍**，没有任何「他冲着我来」的实感。

**怎么发现的**：不是读代码看出来的，是探针断言「敌人往左时朝向应变负」报红。
**这类缺陷静态扫描永远抓不到**（语法完全合法、无警告、无 unused 警告），
**只能靠行为断言**。

**同类排查清单**（写战斗/演出代码时逐条对照）：
- 三元表达式两个分支是否真的不同？
- 函数被调用但改了某个字段后，**有没有真的被渲染层读到**？
- 演出 tween 绑的节点，**是否在这条代码路径上真的存在**？

---

## 「演出永远轮不到」——判定顺序比判定条件更重要

`take_damage` 原判定顺序：
```gdscript
if morale <= threshold and state != State.ROUTED:
    _begin_rout()
    return          # ← 提前返回
if hp <= 0.0 or count <= 0:
    _die(false)      # ← 永远到不了
```
血量见底的那一击，**必然先把士气打到阈值以下**（伤害冲击与 `morale_denom` 同源），
走 `_begin_rout()` 就 return → **`_die` 永远执行不到**。
后果：**被一击打崩的部队直接静默退场**，玩家看到「怪凭空消失」——
恰恰是战斗中最该有演出的一击最没演出。

**正解**：**先判阵亡并 return**，溃散只对还活着的人有意义。

**取证方法**（不靠读代码猜）：`await process_frame` 逐帧打印演出节点的
`rotation` / `visible`。实测 90 帧后 `visible` 仍为 `true`
→ 演出**根本没执行** → 反查判定顺序。

**通用推论**：`if A: act_a(); return` + `if B: act_b()` 这种结构里，
**A 抢在 B 前面就会吞掉 B**。写这类代码时必须问：
「A 的触发条件会不会天然覆盖 B？如果会，B 是不是死代码？」

---

## Godot 2D 旋转方向感（倒地演出用）

`y` 轴朝下 → **正 `rotation` = 顺时针**。

「朝右的部队被打倒」应该是**向前扑**（顺着力矩向下），
即 `rotation = +angle`（顺时针）；写成 `-_facing_x` 会变成**后仰**。

这个方向感极容易搞反，**必须写进注释**，否则后人「好心」改成负号就变后仰。
探针要断言**符号**而不只是绝对值（`rotation > 0.0` 而非 `abs() > 0.05`），
否则两个方向都判绿。

---

## 「同一属性被两处写」——后写的整个覆盖先写的

战斗单位身上有**多个视觉维度**会写同一个属性 `_facing.scale`：
- 朝向翻转（`scale.x = ±_facing_x`）
- 受击形变（squash：`scale.x` 压扁 + `scale.y` 微涨）
- 阵亡倒地（只动 `rotation`）

`tick()` 里的调用顺序：
```
_refresh_flash(delta)      ← 这里若写 _facing.scale
...
_apply_impulse(delta)      ← 最后一步，会把 _facing.scale 整个覆盖
```

**我第一版实现就把形变写在了 `_refresh_flash` 里** —— 逻辑上更「就近」，
但**运行期完全无效**（前一版被判据抓到，探针 S2 报红）。

**正解**：凡是同一属性被多处写，**必须收敛到最后一处**（本例是 `_apply_impulse`
既有的「统一合成到本体」那一段），且在那里**一次性合成所有维度**：
```gdscript
var sx := _facing_x * (1.0 - HIT_SQUASH_X * _flash_amount)
var sy := 1.0 + HIT_SQUASH_Y * _flash_amount
_facing.scale = Vector2(sx, sy)
```
**推论**：写第二个维度之前必须问「还有谁在写这个属性？它在我前面还是后面？」
本项目已有同类约定（MEMORY：「一次性合成到本体：分两次写会被后者覆盖」）。

**另一处易错**：形变必须乘 `_facing_x`。漏乘则**挨一下打**会把朝左的
部队静默重置为朝右 —— 视觉上就是「挨打瞬间突然转身」，极难察觉。

---

## 阵亡瞬间必须冻结所有「跟随量」

`_dead` 置真后 `tick` 首行就 return，`_refresh_flash` 也直接 return。
于是**所有按帧推进的衰减量会定格在最后一帧的值上**。

实测：受击形变定格在 0.85 压扁量上，跟着倒地 tween 一起歪 ——
看起来像「歪着身子还压扁着」。修法：`_play_death` 开头显式清零。

**通用检查清单**（任何进入「终态」的函数都要过一遍）：
- 有没有按 `delta` 推进的衰减量？→ 终态时会**定格**，须显式归位。
- 有没有循环 tween？→ 须 `kill()`（本例 `_banner_tween` 已做）。
- 有没有 `visible = false` 收尾？→ 淡出期间不能被其它逻辑改回来。

---

## 反向验证锚点：**不要用 `\n` 转义串**

```python
# ✗ 错：\n 嵌进 Python 字符串后，反斜杠被二次转义
anchor = "\tif a:/n/t/treturn"        # 实际是「反斜杠」+「n」两个字符
# → src.count(anchor) == 0 → AssertionError 崩掉**整个**反向验证

# ✓ 对：三引号原始字符串，换行直接落盘
anchor = """	if a:
		return"""
```
本轮在 R12 / R13 两个用例上连踩两次，第一次崩在 R12、
修完 R12 才发现 R13 同样是错的写法。
**凡是锚点含换行，一律用三引号原始串。**

---

## 探针里 `await` 的传染性

一个探针函数里**只要有一处 `await`**，整个函数就成了协程，
所有调用点都必须写 `await`：
```gdscript
okc += _group_s(fails)      # ✗ Parse Error: Function "_group_s()" is a coroutine
okc += await _group_s(fails) # ✓
```
报错是 **Parse Error**（不是运行期），**整份探针一个判定都不跑**。
本轮两次触发（D 组、S 组各一次），第二次是「加了一组就立刻炸」——
说明加协程函数时必须同步检查调用点。

## 「已实现的能力」若接线断了，表现与「没实现」完全一致

**本轮最大的取证收获。** 玩家抱怨「城池是贴图，不像站在地形上」，
第一反应都是「功能没做 → 去实现」。实际取证发现功能**早就写好了**：

```gdscript
# world_map._apply_height(actor) —— 早就在给固定实体抬升
vis = n2.get_node_or_null(NodePath("Art"))
if vis == null:
    vis = n2.get_node_or_null(NodePath("Visual"))
if vis == null or not (vis is Node2D):
    return          # ← 静默 return，不报错、不打日志
```

而 `CityMarkerArt.build` 原先把 `Sprite2D` / `Polygon2D`
**直接挂在 marker 根上** —— 两者都没有，于是每个城池都走那条静默 return：
**110 个城池从未被抬升过**，全贴在原始平面上。

修法只是补一个 `Art` 容器（外加按坡度倾斜），本模块不重复实现抬升逻辑。

**三条推论：**
1. **先查接线，再查功能是否存在。** 「按名字找子节点」这种接线方式一旦对上名字，
   断了就是静默 return —— 症状与「没写」一模一样。
2. **节点名必须字面一致。** `_apply_height` 写死 `NodePath("Art")`，
   改名成 `ArtNode` / `Visual2D` 就静默失效。判据必须直接锁住那个字面量。
3. **判据也必须按「已实现」写。** 只判「Art 子节点存在」是不够的 ——
   若 `_apply_height` 被改成去改 `marker.position`，M1~M3 全绿而玩法已坏。
   必须**复刻调用链端到端验**（探针 M4：走一遍 `TerrainHeight.apply_to`，
   断言位移落在 Art 上、marker 坐标逐位不变）。

**同类高危接线点（本仓已修/需守）：**
- `_apply_height` 找 `Art` / `Visual` —— 城池标记、遭遇点标记、其它带可视子树的实体。
- 高度场**只抬可视子节点，绝不碰实体 `position`**（实体 position 被
  `_find_nearest_place` 的距离判定与存档坐标直读，改它＝「走到城下」判定全错）。

## 探针里 `await` 的传染性 + 编译失败后的「残留输出缓冲」

第 23 节已记「探针里 `await` 的传染性」。本轮又撞上它的**孪生兄弟**：

**`--headless --script` 不加载 autoload**，所以任何经依赖链碰到
`GameState` / `DataManager` 的脚本都会**加载期编译失败**
（`Identifier not found: GameState`）。
但引擎**仍会吐出上一次的输出缓冲** —— 校验器照样读到 `PROBE_DONE 19/19`：

```python
# 判据必须显式检测，否则绿灯是假的
load_failed = "Failed to load script" in probe_out
check("L0-a 探针真正加载执行（未编译失败）", not load_failed, ...)
```

本轮为绕开它做了三件事：
1. `city_marker_art.faction_color` 改走 `_autoload("GameState")` 兜底
   （`Engine.get_main_loop()` 取单例，无头环境返回 null 时退回哈希色）。
   **表现层对数据层零容错本身也是缺陷** —— 正常运行期数据缺失会直接崩，
   而这只该让城池退回中性配色。
2. 探针里**删掉 `TerrainPainter.new()`**（它的 `_get_city_mask` 调 `DataManager`），
   改走零 autoload 依赖的 `TerrainHeight` 静态函数。
3. `TerrainMesh.setup` 的形参刻意是 `Object` 而非 `TerrainPainter`
   （MEMORY 铁律「写死具体基类会破坏测试替身」留的口子）→
   探针里写一个**只实现 `sample_height` 的 RefCounted 替身**。

**替身带来的新问题：法线必须真实非 UP。** mesh 传 `null` 时
`_heights` 为空，`normal_at` 返回 `Vector3.UP` → 倾斜权重恒 0 →
「倾斜在 ±14° 内」这类**限幅判据恒真通过 = 假绿**。
正解是加一条**前置判定**证明输入真的分化：

```gdscript
# M0：法线必须真的不是 UP，否则后面所有倾斜判据全部无效
_ok(fails, probe_n.z < 0.999, "M0【前置】mesh 法线真实非 UP（z=...）")
# M5：双向都测 —— 不越界 **且** 确有非零倾斜
_ok(fails, bad == 0 and tilted > 0, "...")
```

**通用铁律：任何「限幅 / 越界 / 范围」型判据，都要问一句「被测量在该输入下会不会恒为常量」。**
会的话，这条判据就是永真的假绿，必须补前置判定或改输入。

## 判据不能靠几何特征猜目标对象

本轮 S1/M8 两条判据首版都写成「找一个压扁的椭圆 Polygon2D 当接地投影」，
结果 **误抓了 faction 底盘的内盘**：

```
Polygon2D verts=20 col=(0.82, 0.4141, 0.369, 0.30) pos=(0.0, 13.0)   ← 势力底盘
Polygon2D verts=18 col=(0.0, 0.0, 0.0, 0.2)       pos=(0.0, 8.0)    ← 接地投影
```

底盘内盘同样是「压扁椭圆」（ry/rx≈0.32）、同样 `y>0`、同样 `position.y` 为正，
**且 alpha 0.30 也落在 `0 < a < 0.5` 区间里** —— 只判单个数值区间必然误抓。

正解是用**能唯一锁定目标的组合特征**：影子是**纯黑**半透明
（`color.r < 0.05`），底盘是彩色（`r=0.82`）。S1 因为多判了这一条而通过，
M8 漏了而假红 —— 两条判据的差异自己暴露了缺口。

**推论：判据的每个数值条件都该问「还有别的对象也满足吗」。**
能用组合特征唯一定位，就不要用单值区间。

## 判据的方向：Godot 2D 的 y 轴朝下

本轮 M4 判据首版写 `art.position.y > 0.5` 判「抬升生效」，实跑报红。
取证发现是**判据写反了**：

```gdscript
# terrain_height.gd 的真实实现
node.position.y = float(node.get_meta("base_y")) - lift_at(wx, wy, world, city_mask)
```

2D 的 y 轴朝下，「向上抬」= y **减小**。所以满量程抬升的正确表现是
`Art.y = -714.0`，判据应写 `art.position.y < -0.5` 且 `-art.position.y == lift`。

**推论：判「位移生效」不能只判符号，要判「量值 == 期望值」。**
`is_equal_approx(-art.position.y, expect_lift)` 才能同时锁住方向与幅度 ——
只判 `< -0.5` 的话，一个恒抬 1px 的假实现也能过。

## `func_body` 的参数规范化：只剥 `func `，不剥 `static `

`_gs_func.func_body(src, name)` 会把参数规范化成函数名：
去掉 `func ` 前缀 → 取首个 `(` 之前的部分。

所以：

| 传入 | 规范化后 | 结果 |
|---|---|---|
| `"_apply_height"` | `_apply_height` | ✅ |
| `"func _apply_height("` | `_apply_height` | ✅ |
| `"static func build("` | `static func build` | ❌ 匹配不到 |

本轮首次跑校验器时 A/B/D 三组**整段假红**（15 项），根因就是传了
`"static func build("`。修法是传 `"func build("`，并加一条**元判据**钉住：

```python
_fb_bare = func_body(src, "build")
_fb_pref = func_body(src, "func build(")
check("A0z func_body 取体非空（防参数形态踩坑）",
      bool(_fb_bare) and bool(_fb_bare == _fb_pref) and len(_fb_bare) > 200, ...)
```

**推论：共享工具的「参数宽容度」是判据的一等失效面。**
凡工具声称支持多种参数形态，就得有一条判据证明每种形态都能用 ——
否则后人踩坑时，整组判据会**静默集体假红**，而绿灯/假红方向还可能搞反。

---

## 目录索引 vs逐个stat：110 城贴图查找438ms → 5.6ms

第七十一轮，`world_map._ready()` 端到端 1356ms。逐层插桩定位：

| 阶段 | 耗时 |
|---|---|
| 面板构造段 | 420~434ms |
| `_spawn_city_markers()` | 538~824ms |
| `mesh.setup()`（地形网格） | 226ms |

`_spawn_city_markers` 内再细分：`CityMarkerArt.build` **460ms/110 城**，
Label 60ms，`add_child` 0ms；`build` 内部再分：`base=6ms tex=450ms`
⇒ **tex 段是唯一主因**（`miss=110 hit=0 tmiss=437ms`，首次 miss 仅 974μs）。

### 为什么「加缓存」一毫秒都没省

- 每次落空要连试 **3 个扩展名**（`.png`/`.webp`/`.jpg`）⇒ 最多 **330 次磁盘 stat**
- **负缓存命中率恒为 0** —— 110 城各查一次，每次都是「第一次」

缓存命中率 0 ⇒ 缓存路径永远走不到 ⇒ 优化等于没做。

### 正解：一次性目录索引

```gdscript
static var _map_index: Dictionary = {}
static var _map_index_built: bool = false

static func _ensure_map_index() -> void:
	if _map_index_built:          # 幂等守卫（缺了这条 = N 次 readdir）
		return
	_map_index_built = true
	_scan_dir_into("res://assets/sprites/map/", "", _map_index)
```

`exists()` 每次是独立系统调用；`readdir` 是一次批量枚举。
**1 次 readdir（3.4ms）替代 330 次 stat（438ms）≈ 78 倍。**

三个必须遵守的点：
1. **惰性构建** —— 首次真正查图时才扫。不碰 `cities.json`/`units.json`
   等玩家数据表，也不在无图场景白付扫描代价。
2. **扩展名白名单** —— 否则 `.import` 等文件会污染索引。
3. **两阶段：先收集后统一倒出** ——

```gdscript
	var found: Dictionary = {}          # 先收集
	for f in dir.get_files():
		...
		found[base] = slot
	for base in found.keys():           # 循环后再统一倒出
		out[base] = String(found[base]["p"])
```

`get_files()` **返回顺序不确定**。边遍历边写会让后到的扩展名
覆盖先到的（`scene_2.jpg`排在 `scene_2.png` 后面就把 `.png` 顶掉），
与原式「`.png`→`.webp`→`.jpg` 依次 exists」的优先级不一致。

### 顺带纠正一个错判

曾写「城 id 与贴图文件名命名不同 ⇒ 110 次全部落空」——**错的**。
实测 `cities.json` 的 id 就是 `scene_2`…`scene_111`，
`assets/sprites/map/` 里有 18 张同名 png ⇒ **18 命中、92 落空**。
**下结论前先取证。**

---

## 重复计算比IO 更值得查：`lift_at()` 里又调了一次 `elevation_at()`

`terrain_painter.sample_height()` 原式：

```gdscript
var e := TerrainHeight.elevation_at(wx, wy, world, m)   # 算一次
var l := TerrainHeight.lift_at(wx, wy, world, m)       # 内部又调一次！
```

而`lift_at` 内部就是 `elevation_at(...) * 常数`。而 `base_elevation` 内含
**两次 `FastNoiseLite.get_noise_2d`** —— 是本工程最贵的单次计算。
⇒ 每格的噪声采样被**翻倍执行**（4095 格 × 2 = 8190 次，~55μs/格）。

**修法**（语义 bit 级等价）：

```gdscript
var e := TerrainHeight.elevation_at(wx, wy, world, m)
return {
	"elev": e,
	# 【单一真源】lift 由已算好的 e 线性导出，不再重算
	"lift": e * TerrainHeight.HEIGHT_SCALE * TerrainHeight.VERT_EXAGGERATE,
	...
}
```

效果：`mesh.setup` 226ms → ~180ms。

**通用判据**：凡「函数 B 内部只是 A×常数」就该复用 A 的结果，别再调一次。

---

## ★ 反向验证报绿的三态判别（本项目最值钱的一条）

反向验证（注入缺陷 → 校验器必须报红）报绿时，**有三种完全不同的原因**：

| 态 | 症状 | 正解 |
|---|---|---|
| ① 判据功效不足 | 注入确实破坏了语义，判据只查了存在性 | 补判据（判位置/缩进/结构，别判字面量） |
| ② **改法本就等价** | 注入是等价改法，**根本没引入缺陷** | **重写注入**，找一个真会出问题的改法 |
| ③ 注入点走错路径 | 注入没落到被锁性质的代码上 | 重写注入锚点 |

### 实例 ②：等价改法当注入＝白忙

原注入「把缓存读挪到 `_ensure_map_index()` 之后」→ 校验器全绿。
排查后发现 `_ensure_map_index` **是幂等的**（第二次起直接 `return`），
**挪前挪后成本都是 0** —— 这是等价改法，不是缺陷。

真缺陷必须挪到 **`load()` 之后**（每次调用都真去 IO，缓存彻底形同虚设）：

```python
#旧注入（等价，无效）
old = '\tif _tex_cache.has(key):\n\t\treturn _tex_cache[key] as Texture2D\n\t_ensure_map_index()\n'
new = '\t_ensure_map_index()\n\tif _tex_cache.has(key):\n\t\treturn _tex_cache[key] as Texture2D\n'
# 新注入（真缺陷：挪到 load 之后）
old = ('\tif _tex_cache.has(key):\n\t\treturn ...\n'
       '\t_ensure_map_index()\n'
       '\tvar found: Texture2D = null\n'
       '\tif _map_index.has(city_id):\n'
       '\t\tvar res := load(String(_map_index[city_id]))\n'
       '\t\tif res is Texture2D:/n/t/t/tfound = res\n')
new = old去掉开头两行 + 把缓存读append到 load 之后
```

**注入必须破坏被锁的那个性质，不是「看起来更差」。**

### 实例 ①：判据只判存在性 ⇒ 恒真

- `A0b` 判「函数体里**存在** `_tex_cache.has(key)`」
  ⇒把它挪到 IO 之后，这行仍在，照样绿。
  **正解**：新增 `A0b2` 判**位置** —— 缓存读须早于第一个 IO 入口
  （`_map_index.has` / `load(` / `DirAccess` 取最早位置）。
- `D0e` 判`'"i"' in idx_c and "idx" in idx_c`
  ⇒ 边遍历边写的写法里这两个字面量**仍然都在**，照样绿。
  **正解**：判**两阶段结构** —— 必须有中间表 `found`、
  且 `for base in found.keys():` 出现在 `for f in dir.get_files():` **之后**。

### 实例 ③：锚点随实现重写而失效

目录索引方案把「逐扩展名 exists 循环」整个删掉了，
原锚点 `for ext in _TEX_EXTS:` 命中 0 次 ⇒ 反向验证自身
报「锚点预检失败」而非判据红 —— **两种失败的表象完全不同**。
另外 `_tex_cache.has(key)` 在`_try_texture`/`_type_texture` **两处都出现**，
只锚前 2 行会命中 2 次（要求==1）⇒ 必须带 `_ensure_map_index()` 做唯一性区分。

---

## CRLF 陷阱：`city_marker_art.gd` 是纯 CRLF

反向验证器里：

```python
def read(p):
    with open(p, "r", encoding="utf-8") as f:   # 文本模式 → CRLF 自动转 \n
        return f.read()

def write(p, t):
    with open(p, "w", encoding="utf-8", newline="") as f:  # 原样写出
        f.write(t)
```

⇒ **锚点必须按 `\n` 写**。用 `newline=''` 诊断时读到的是 `\r\n`，
两种视角不一致 ⇒ `count == 0`，而字节明明在那儿。

本轮在同一个坑上连踩 3~4 次。**每次改文件前先探测行尾**：

```python
raw = open(p, "rb").read()
is_crlf = raw.count(b"\r\n") > 0
```

**另**：Git Bash 下 `/tmp` 与 Python `open()` 的路径视角不一致，
`/tmp/xxx.bak` 会 `FileNotFoundError` ⇒ 临时备份放**工程内**（`*.rv3`）。

---

## GDScript 插桩的三个编译期错误（都只有真跑才现形）

1. **局部变量被别的函数引用** → `Parse Error: Identifier "_pf_t0" not declared`
   —— 计时变量必须提为**成员变量**。
2. **同函数内重复声明** → `Parse Error: Expected end of statement after expression, found ":"`
   —— 插桩时很容易在两处都写 `var _pf_m :=`。
3. **删错行** —— 修第2 条时删了声明留下裸赋值 `_pf_m := Time.get_ticks_usec()`
   ⇒ 又报一次同类错误。

**定位手段**：引擎报 `at: GDScript::reload (res://scripts/world/world_map.gd:2041)`
⇒ 按文件+行号直接看，别猜。

---

## Bash heredoc 会吞 Python 的转义

连续 3 次 `SyntaxError`：`a = "func _ready() -> void:/n/t..."`（`\n` 被吞成 `/n`）、
`unterminated triple-quoted string`（`"""` 被吞）。

**正解：插桩 / 改锚点一律用 Edit 工具逐处替换，不写 heredoc 脚本。**
且heredoc 可能**改完内存却没落盘**（后续 assert 抛异常 ⇒ write 不执行）
⇒ 每次改完必须 `python -c` 确认落盘。

>本项目里heredoc 唯一可靠的用法是**整段替换**（无嵌套三引号、无 `\n`），
> 且必须**无 assert**（assert 抛异常会跳过write）。

---

## 判据把注释当代码

`D3c` 判「索引只读贴图目录，不扫玩家数据表」，读的是整份源码 ⇒
`grep -n "cities.json" city_marker_art.gd` 显示它**只出现在 261 行的注释里**，
判据却报了红。

**正解：只看 `code_only()` 剔除注释后的代码。**

```python
check("D3c 索引只读贴图目录，不扫玩家数据表",
      "res://assets/sprites/map/" in cma_src
      and "cities.json" not in cma_c        # cma_c = code_only(cma_src)
      and "units.json" not in cma_c, ...)
```

---

## CPU 烘焙类资源：先问「输入全是常量吗」

第七十二/七十三轮连续两次踩到同一类问题，都是**运行时用 CPU 烘焙**资源
（噪声纹理 / 音频波形），而烘焙函数被设计成「一次性」的，实际每次进场景都重做。

### 云影纹理 228.9ms → 0.2ms

`WorldAmbience._bake_cloud_texture()` 单段 228.9ms，占 `world_map._ready`
的 29%。源码原注释写「一次 ~40ms，加载期无感」—— **比实测便宜 5.7 倍，
假设已被现实推翻**。两个真因：

1. **输入全是常量**：`noise.seed = 20261001` 写死、环面公式与 `fractal_octaves`
   都是常量 ⇒ 每次算出的图**逐像素完全相同**，纯重复劳动。
2. **`Image.set_pixel` 逐像素写 512×512 = 26 万次跨语言调用**。
   这是真正的耗时大头（每次都要过Variant 转换与边界检查）。
   改 `PackedByteArray` 一次填充 + `Image.create_from_data`。

> 视觉等价性论证：云的暗色来自 `sp.modulate` **乘算**
> （`Color(0.05, 0.08, 0.10, CLOUD_ALPHA)`），纹理 RGB 填255（白）
> 与原式 `Color(1,1,1,a)` **逐位等价**。填白不会改变任何可见效果。

### 雨声/风声 235ms → 5μs

- `pl:weather` 81.8ms = `_make_rain()` 合成 7s × 22050Hz = 15.4 万采样
- `pl:ambaudio` 77.6ms = `_make_wind()` 合成 6s × 22050Hz = 13.2 万采样

`make_rain_stream()` 有 **3 个调用点**（battle / city / world_map），
一次游玩「进城→战斗→回图」至少重合成 3 段一模一样的音频。
加 `static var _rain_stream_cache: AudioStreamWAV`。

> **多调用点共用一个 AudioStreamWAV 是安全的**——三处都只做
> `a.stream = ...; a.play()`，不改动流本身。Godot 资源是引用计数的，
> 多个 AudioStreamPlayer 播同一 stream 是正常用法。
> **前提是先grep 确认没有调用点会改流的属性**（如 `loop_end`）。

### 端到端效果（scene_boot_probe 二次启动口径）

| 场景 | 优化前 | 优化后 |
|---|---|---|
| world_map | 2038ms | **1367.7ms**（-670ms / -33%）|
| city_scene | 300ms | 239.8ms |
| battle_scene | 121ms | 96.3ms |

---

## ★ 缓存的确定性前提，必须单列一条判据

**这是本项目最容易写出「看起来全绿其实已坏」判据的地方。**

判据 A 组若只验「两次调用结果相同」，那么把 `rng.seed = 20261002`
换成 `rng.randomize()` 时——

- 编译器不报错
- 合成照样成功
- 字节数、循环头、`loop_end` 全部正确
- **A1/A2/A3/A4/A6 全部照常 PASS**

而这个缺陷对**循环音频恰好听起来还行**（还是一片雨声），
只是每次进图听到的是同一份。缺陷被完全掩盖。

**正解：加「清掉缓存重新合成，字节必须与第一次逐位相同」这一组。**
它拿一份**新的**输出来对拍，能抓住「两次相同但都等于错值」。

反向验证里的 **I3 注入（seed → randomize()）就是这条判据的存在理由**：
实测确认只有 A5（确定性自证）与 B4（seed 前提）报红，其余全绿。

### 反向保护：`randomize()` 的合成禁止缓存

`_synth_bird_song()` / `_synth_cricket()` 用 `rng.randomize()`，
源码注释原文是「随机音高/音量防复读机」——**这是设计意图**。
若将来有人「顺手」也给它们加缓存，玩家每 5~11 秒就听到同一个音。

这类缺陷**编译期无感、探针也测不出**（因为「合成成功」仍然是 true），
**只能静态锁**：

```python
check("B8a 鸟鸣未被缓存（randomize 的防复读机意图必须保留）",
      "_wind_cache" not in body_bird and "rng.randomize()" in body_bird, ...)
```

---

## 两个 Godot 实例并发会互踩 `.godot`

本项目的校验器大量用 `subprocess` 起 Godot 无头实例。
**聚合校验正在跑时另起一个 Godot 实例**，新实例会静默失败：

- `_verify_weatheraudio_cache.py` A 组 12 项全红，读到的全是 `-1`
- 手动用**完全相同的参数**跑却成功

**诊断口诀：A 组大面积读 -1 ⇒ 先查Godot 进程数，别怀疑判据。**

```bash
tasklist | grep -ci "godot"   # >1 就是并发冲突，等聚合跑完再验
```

---

## 场景切换性能：三开关 + 三段分离口径

### 根因不是纹理加载，是同步阻塞

`change_scene_to_file` **同步阻塞**：它在主线程跑完新场景的 `_ready()` 才返回，
期间**一帧都不推进** ⇒ 纯黑屏。
总时长 ≈ 渐隐 300+ 阻塞 `_ready()` + 渐亮 300（第六十九轮实测约 3.3 秒）。

### 三个开关

1. `SceneRouter.prewarm()` —— 把首次 `load()` 挪到画面还可见的那一段。
2. 阻塞期显示「载入中…」—— **消不掉**阻塞，只把死机感变成在加载。
3. 削 `_ready()` 本身（目录索引/ 去重计算 / 缓存烘焙，见上面几节）。

### ★ 测量口径：必须分离三段，且必须看「二次启动」

headless 分离三段实测（`tests/scene_boot_probe.gd`）：`load` 首载 /
`instantiate` / `_ready`+3帧。分开量才不会被"load 是瓶颈"误导——
真实玩家路径有 `prewarm()`，`load` 早已被覆盖，玩家等的是**「已缓存 load + `_ready`」**。

`_run_scene_boot.py` 的**二次启动测量**就是模拟 prewarm 已生效：

| 场景 | 冷启动 | 二次（玩家实际） | 其中 `_ready` |
|---|---|---|---|
| main_menu | 329ms | 70ms | 35ms |
| battle_scene | 1139ms | 121ms | 115ms |
| city_scene | 1302ms | 300ms | 296ms |
| **world_map** | 5134ms | **2038ms** | **2021ms（99%）** |

⇒ 瓶颈非常明确：`world_map._ready` 一家占掉了玩家等待的 99%。
