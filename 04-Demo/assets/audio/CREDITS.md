# 音频资产来源登记（CREDITS）

> 口径（2026-09-25）：**当前工程内 0 个第三方录音资产**。全部声音为
> `scripts/autoload/audio_manager.gd` 内置的「国风占位合成器」运行时合成
> （Karplus-Strong 拨弦 / 木鱼 / 兵刃 / 锣 / 战鼓 / 铜钱 / 五声琶音 BGM），
> 无版权负担，商用无需署名。真实 ogg 落入本目录对应路径后自动取代占位音
> （`res://assets/audio/bgm/*.ogg`、`res://assets/audio/sfx/*.ogg`），
> 无需改任何调用点。**真实 ogg 必须在导入设置开 loop（BGM），否则播完即静默。**

## 待落地清单（音频规划第一批，见 04-Demo/review/audio-plan.md）

| 文件 | 覆盖场景 | 循环 |
|---|---|---|
| bgm/main_menu.ogg | 主菜单 + 创角 | loop=true |
| bgm/battle.ogg | 战斗（含布阵） | loop=true |
| sfx/click.ogg、confirm.ogg、cancel.ogg、hit.ogg | 既有挂点 | 否 |
| sfx/battle_skill.ogg、encounter_battle.ogg、battle_win.ogg、coin_trade.ogg | 一批新挂点 | 否 |

## 第三方素材登记表

| 文件 | 来源 | 许可证 | 登记日期 |
|---|---|---|---|
| （暂无） | — | — | — |

> 落地纪律：每个第三方文件在此登记 来源 + 许可证 + 日期，供合规审查。
> 爱给网等国内素材站版权状态混乱，不建议用于任何将来可能上架的版本。
