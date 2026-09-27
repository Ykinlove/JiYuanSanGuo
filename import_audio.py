#!/usr/bin/env python3
# 《纪元三国》音频文件导入脚本
# 将《三国大时代4》的音频文件导入到《纪元三国》项目中

import os
import shutil
import json
from pathlib import Path
import sys

def main():
    # 路径配置
    source_dir = Path(r"E:/Users/27904/Desktop/JiyuanSanGuo/三国大时代4/funlight.com.game.sg4lz.anzhi/assets/snd")
    target_base = Path(r"E:/Work buddy/2026-09-21-17-49-04/纪元三国/04-Demo")
    target_audio_dir = target_base / "assets" / "audio"
    
    # 创建目标目录结构
    target_dirs = {
        "bgm": target_audio_dir / "bgm",
        "sfx": target_audio_dir / "sfx"
    }
    
    for dir_path in target_dirs.values():
        dir_path.mkdir(parents=True, exist_ok=True)
    
    # 音频文件映射配置（根据用户选择）
    audio_mapping = {
        # BGM文件
        "bgm3.ogg": "bgm/main_menu.ogg",
        "bgm5.ogg": "bgm/world_map.ogg",
        "bgm4.ogg": "bgm/city.ogg", 
        "bgm7.ogg": "bgm/battle.ogg",
        "snd39.ogg": "bgm/victory.ogg",
        
        # SFX文件
        "snd36.ogg": "sfx/ui_click.ogg",
        "snd32.ogg": "sfx/ui_confirm.ogg",
        "snd31.ogg": "sfx/ui_cancel.ogg",
        "snd22.ogg": "sfx/battle_hit_1.ogg",
        "snd23.ogg": "sfx/battle_hit_2.ogg",
        "snd24.ogg": "sfx/battle_hit_3.ogg",
        "snd27.ogg": "sfx/battle_hit_4.ogg",
        "snd19.ogg": "sfx/battle_skill.ogg",
        "snd10.ogg": "sfx/encounter_battle.ogg",
        "snd8.ogg": "sfx/coin_trade.ogg",
        "snd34.ogg": "sfx/gather_ok.ogg",
        "snd33.ogg": "sfx/treasure_open.ogg",
    }
    
    # 创建导入报告
    report = {
        "successful": [],
        "failed": [],
        "source_count": 0,
        "target_count": 0
    }
    
    print("开始导入音频文件...")
    print(f"源目录: {source_dir}")
    print(f"目标目录: {target_audio_dir}")
    print("-" * 60)
    
    # 导入文件
    for source_file, rel_target_path in audio_mapping.items():
        source_path = source_dir / source_file
        target_rel_path = Path(rel_target_path)
        
        # 根据扩展名确定目标目录
        if target_rel_path.parent.name == "bgm":
            target_dir = target_dirs["bgm"]
        else:
            target_dir = target_dirs["sfx"]
        
        target_path = target_dir / target_rel_path.name
        
        try:
            if source_path.exists():
                # 复制文件
                shutil.copy2(source_path, target_path)
                file_size = source_path.stat().st_size
                report["successful"].append({
                    "source": str(source_file),
                    "target": str(rel_target_path),
                    "size": file_size
                })
                print(f"✓ 成功导入: {source_file} → {rel_target_path} ({file_size:,} 字节)")
            else:
                report["failed"].append({
                    "source": str(source_file),
                    "error": "源文件不存在"
                })
                print(f"✗ 文件不存在: {source_file}")
        except Exception as e:
            report["failed"].append({
                "source": str(source_file),
                "error": str(e)
            })
            print(f"✗ 导入失败 {source_file}: {e}")
    
    # 更新音频配置文件
    audio_config = {
        "version": "1.0",
        "date": "2026-09-27",
        "import_source": "三国大时代4",
        "audio_files": audio_mapping,
        "categories": {
            "bgm": {
                "main_menu": "res://assets/audio/bgm/main_menu.ogg",
                "world_map": "res://assets/audio/bgm/world_map.ogg",
                "city": "res://assets/audio/bgm/city.ogg",
                "battle": "res://assets/audio/bgm/battle.ogg",
                "victory": "res://assets/audio/bgm/victory.ogg"
            },
            "sfx": {
                "ui_click": "res://assets/audio/sfx/ui_click.ogg",
                "ui_confirm": "res://assets/audio/sfx/ui_confirm.ogg",
                "ui_cancel": "res://assets/audio/sfx/ui_cancel.ogg",
                "battle_hit": [
                    "res://assets/audio/sfx/battle_hit_1.ogg",
                    "res://assets/audio/sfx/battle_hit_2.ogg",
                    "res://assets/audio/sfx/battle_hit_3.ogg",
                    "res://assets/audio/sfx/battle_hit_4.ogg"
                ],
                "battle_skill": "res://assets/audio/sfx/battle_skill.ogg",
                "encounter_battle": "res://assets/audio/sfx/encounter_battle.ogg",
                "coin_trade": "res://assets/audio/sfx/coin_trade.ogg",
                "gather_ok": "res://assets/audio/sfx/gather_ok.ogg",
                "treasure_open": "res://assets/audio/sfx/treasure_open.ogg"
            }
        }
    }
    
    # 保存配置文件
    config_path = target_audio_dir / "audio_config.json"
    with open(config_path, 'w', encoding='utf-8') as f:
        json.dump(audio_config, f, ensure_ascii=False, indent=2)
    
    # 创建README文件
    readme_content = f"""# 《纪元三国》音频资产导入记录

## 导入信息
- **导入时间**: 2026-09-27
- **源游戏**: 《三国大时代4》
- **导入方式**: 手动选择 + 脚本导入
- **导入文件**: {len(audio_mapping)} 个文件

## 文件映射表

### 背景音乐 (BGM)
| 场景 | 源文件 | 目标文件 | 大小 |
|------|--------|----------|------|
"""
    
    # 添加BGM表格
    bgm_list = []
    for source, target in audio_mapping.items():
        if target.startswith("bgm/"):
            source_path = source_dir / source
            size = source_path.stat().st_size if source_path.exists() else 0
            bgm_list.append({
                "scene": target.replace("bgm/", "").replace(".ogg", "").replace("_", " ").title(),
                "source": source,
                "target": target,
                "size": size
            })
    
    bgm_list.sort(key=lambda x: x["scene"])
    for item in bgm_list:
        readme_content += f"| {item['scene']} | {item['source']} | {item['target']} | {item['size']:,} 字节 |\n"
    
    readme_content += "\n### 音效 (SFX)\n| 音效类型 | 源文件 | 目标文件 | 大小 |\n|----------|--------|----------|------|\n"
    
    # 添加SFX表格
    sfx_list = []
    for source, target in audio_mapping.items():
        if target.startswith("sfx/"):
            source_path = source_dir / source
            size = source_path.stat().st_size if source_path.exists() else 0
            sfx_list.append({
                "type": target.replace("sfx/", "").replace(".ogg", "").replace("_", " "),
                "source": source,
                "target": target,
                "size": size
            })
    
    sfx_list.sort(key=lambda x: x["type"])
    for item in sfx_list:
        readme_content += f"| {item['type']} | {item['source']} | {item['target']} | {item['size']:,} 字节 |\n"
    
    # 添加导入统计
    total_size = sum(item["size"] for item in bgm_list + sfx_list)
    readme_content += f"""
## 导入统计
- **BGM文件数**: {len(bgm_list)}
- **SFX文件数**: {len(sfx_list)}
- **总文件数**: {len(audio_mapping)}
- **总大小**: {total_size:,} 字节 ({total_size/1024/1024:.2f} MB)

## 使用说明
1. 确保所有文件已正确复制到 `assets/audio/` 目录下
2. 在Godot中需要重新导入音频文件：运行 `godot --headless --import --path "E:/Work buddy/2026-09-21-17-49-04/纪元三国/04-Demo"`
3. 检查音频文件的循环设置（BGM需要设置loop=true）
4. 验证音频管理器中的引用路径是否正确
"""
    
    readme_path = target_audio_dir / "README.md"
    with open(readme_path, 'w', encoding='utf-8') as f:
        f.write(readme_content)
    
    # 输出报告
    print("\n" + "=" * 60)
    print("导入完成！")
    print(f"成功导入: {len(report['successful'])} 个文件")
    if report['failed']:
        print(f"失败: {len(report['failed'])} 个文件")
        for fail in report['failed']:
            print(f"  - {fail['source']}: {fail['error']}")
    
    print(f"\n配置文件: {config_path}")
    print(f"README文件: {readme_path}")
    print("\n下一步操作：")
    print("1. 运行Godot导入命令以生成 .import 文件")
    print("2. 检查音频管理器中的引用路径")
    print("3. 在Godot编辑器中验证BGM循环设置")

if __name__ == "__main__":
    main()