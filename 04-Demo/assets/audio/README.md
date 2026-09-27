# 《纪元三国》音频资产导入记录

## 导入信息
- **导入时间**: 2026-09-27
- **源游戏**: 《三国大时代4》
- **导入方式**: 手动选择 + 脚本导入
- **导入文件**: 17 个文件

## 文件映射表

### 背景音乐 (BGM)
| 场景 | 源文件 | 目标文件 | 大小 |
|------|--------|----------|------|
| Battle | bgm7.ogg | bgm/battle.ogg | 919,041 字节 |
| City | bgm4.ogg | bgm/city.ogg | 338,260 字节 |
| Main Menu | bgm3.ogg | bgm/main_menu.ogg | 689,513 字节 |
| Victory | snd39.ogg | bgm/victory.ogg | 45,471 字节 |
| World Map | bgm5.ogg | bgm/world_map.ogg | 747,529 字节 |

### 音效 (SFX)
| 音效类型 | 源文件 | 目标文件 | 大小 |
|----------|--------|----------|------|
| battle hit 1 | snd22.ogg | sfx/battle_hit_1.ogg | 6,124 字节 |
| battle hit 2 | snd23.ogg | sfx/battle_hit_2.ogg | 6,951 字节 |
| battle hit 3 | snd24.ogg | sfx/battle_hit_3.ogg | 12,961 字节 |
| battle hit 4 | snd27.ogg | sfx/battle_hit_4.ogg | 10,647 字节 |
| battle skill | snd19.ogg | sfx/battle_skill.ogg | 11,349 字节 |
| coin trade | snd8.ogg | sfx/coin_trade.ogg | 26,338 字节 |
| encounter battle | snd10.ogg | sfx/encounter_battle.ogg | 47,564 字节 |
| gather ok | snd34.ogg | sfx/gather_ok.ogg | 40,294 字节 |
| treasure open | snd33.ogg | sfx/treasure_open.ogg | 22,609 字节 |
| ui cancel | snd31.ogg | sfx/ui_cancel.ogg | 16,566 字节 |
| ui click | snd36.ogg | sfx/ui_click.ogg | 7,062 字节 |
| ui confirm | snd32.ogg | sfx/ui_confirm.ogg | 25,134 字节 |

## 导入统计
- **BGM文件数**: 5
- **SFX文件数**: 12
- **总文件数**: 17
- **总大小**: 2,973,413 字节 (2.84 MB)

## 使用说明
1. 确保所有文件已正确复制到 `assets/audio/` 目录下
2. 在Godot中需要重新导入音频文件：运行 `godot --headless --import --path "E:/Work buddy/2026-09-21-17-49-04/纪元三国/04-Demo"`
3. 检查音频文件的循环设置（BGM需要设置loop=true）
4. 验证音频管理器中的引用路径是否正确
