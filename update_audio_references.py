#!/usr/bin/env python3
# 更新《纪元三国》音频管理器引用路径

import os
import re
from pathlib import Path

def update_audio_manager():
    audio_manager_path = Path(r"E:/Work buddy/2026-09-21-17-49-04/纪元三国/04-Demo/scripts/autoload/audio_manager.gd")
    
    if not audio_manager_path.exists():
        print(f"错误：找不到音频管理器文件: {audio_manager_path}")
        return
    
    with open(audio_manager_path, 'r', encoding='utf-8') as f:
        content = f.read()
    
    # 定义音频路径映射
    audio_updates = {
        # 更新常用音效封装
        'sfx_click.*"res://assets/audio/sfx/click.ogg"': 'func sfx_click() -> void:\n\tplay_sfx("res://assets/audio/sfx/ui_click.ogg")',
        'sfx_confirm.*"res://assets/audio/sfx/confirm.ogg"': 'func sfx_confirm() -> void:\n\tplay_sfx("res://assets/audio/sfx/ui_confirm.ogg")',
        'sfx_cancel.*"res://assets/audio/sfx/cancel.ogg"': 'func sfx_cancel() -> void:\n\tplay_sfx("res://assets/audio/sfx/ui_cancel.ogg")',
        'sfx_hit.*"res://assets/audio/sfx/hit.ogg"': 'func sfx_hit() -> void:\n\t# 战斗打击音从4个变体中随机选择一个\n\tvar hit_variants = [\n\t\t"res://assets/audio/sfx/battle_hit_1.ogg",\n\t\t"res://assets/audio/sfx/battle_hit_2.ogg",\n\t\t"res://assets/audio/sfx/battle_hit_3.ogg",\n\t\t"res://assets/audio/sfx/battle_hit_4.ogg"\n\t]\n\tvar random_index = randi() % hit_variants.size()\n\tplay_sfx(hit_variants[random_index])'
    }
    
    # 应用更新
    updated_content = content
    for pattern, replacement in audio_updates.items():
        # 使用正则表达式替换
        updated_content = re.sub(pattern, replacement, updated_content, flags=re.DOTALL)
    
    # 检查_sfx_kind函数是否需要更新
    if '_sfx_kind' in content:
        print("检查 _sfx_kind 函数...")
        # 分析当前的_sfx_kind函数
        sfx_kind_pattern = r'func _sfx_kind\(path: String\) -> String:(.*?)return "other"'
        sfx_kind_match = re.search(sfx_kind_pattern, updated_content, re.DOTALL)
        
        if sfx_kind_match:
            print("_sfx_kind 函数已存在")
            # 可以在_sfx_kind函数中添加新音效类型的判断
            # 但这不是必须的，因为真实音频到位后占位音自动失效
    
    # 检查是否需要添加新的音效封装函数
    new_functions = '''
## 新增音效封装（对应导入的音频文件）
func sfx_battle_skill() -> void:
	play_sfx("res://assets/audio/sfx/battle_skill.ogg")

func sfx_encounter_battle() -> void:
	play_sfx("res://assets/audio/sfx/encounter_battle.ogg")

func sfx_coin_trade() -> void:
	play_sfx("res://assets/audio/sfx/coin_trade.ogg")

func sfx_gather_ok() -> void:
	play_sfx("res://assets/audio/sfx/gather_ok.ogg")

func sfx_treasure_open() -> void:
	play_sfx("res://assets/audio/sfx/treasure_open.ogg")

func sfx_victory() -> void:
	# 胜利结算音乐（one-shot，可叠加在BGM上）
	play_sfx("res://assets/audio/bgm/victory.ogg")
'''
    
    # 在sfx_hit函数后插入新函数
    sfx_hit_end = updated_content.find('func set_master_volume')
    if sfx_hit_end != -1:
        updated_content = updated_content[:sfx_hit_end] + new_functions + updated_content[sfx_hit_end:]
    
    # 写入更新
    backup_path = audio_manager_path.with_suffix('.gd.backup')
    with open(backup_path, 'w', encoding='utf-8') as f:
        f.write(content)
    print(f"已创建备份文件: {backup_path}")
    
    with open(audio_manager_path, 'w', encoding='utf-8') as f:
        f.write(updated_content)
    
    print(f"音频管理器已更新: {audio_manager_path}")

def check_bgm_references():
    """检查游戏中的BGM引用"""
    print("\n检查BGM引用...")
    
    project_dir = Path(r"E:/Work buddy/2026-09-21-17-49-04/纪元三国/04-Demo")
    
    # 查找所有.gd文件中包含play_bgm调用的地方
    gd_files = list(project_dir.rglob("*.gd"))
    
    bgm_paths = {
        "main_menu": "res://assets/audio/bgm/main_menu.ogg",
        "world_map": "res://assets/audio/bgm/world_map.ogg", 
        "city": "res://assets/audio/bgm/city.ogg",
        "battle": "res://assets/audio/bgm/battle.ogg"
    }
    
    for gd_file in gd_files:
        try:
            with open(gd_file, 'r', encoding='utf-8') as f:
                content = f.read()
            
            # 查找play_bgm调用
            play_bgm_matches = re.findall(r'play_bgm\s*\(\s*"([^"]+)"\s*\)', content)
            if play_bgm_matches:
                print(f"\n{gd_file.relative_to(project_dir)}:")
                for match in play_bgm_matches:
                    print(f"  - play_bgm(\"{match}\")")
        except Exception as e:
            print(f"读取文件失败 {gd_file}: {e}")

def main():
    print("开始更新音频引用...")
    update_audio_manager()
    check_bgm_references()
    
    print("\n" + "=" * 60)
    print("更新完成！")
    print("\n重要提醒:")
    print("1. 音频管理器已备份为 .gd.backup 文件")
    print("2. 请测试以下音效：")
    print("   - 按钮点击、确认、取消音效")
    print("   - 战斗打击音（应有4种变体）")
    print("   - 新增的音效封装函数")
    print("3. 在Godot中重新编译项目")
    print("4. 验证音频文件循环设置（BGM需要loop=true）")

if __name__ == "__main__":
    main()