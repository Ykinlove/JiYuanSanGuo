#!/usr/bin/env python3
# 《纪元三国》第二批音频导入：用户弹窗指定的 5 个 SFX + 全部剩余文件入池
import shutil
import json
from pathlib import Path

SRC = Path(r"E:/Users/27904/Desktop/JiyuanSanGuo/三国大时代4/funlight.com.game.sg4lz.anzhi/assets/snd")
DEMO = Path(r"E:/Work buddy/2026-09-21-17-49-04/纪元三国/04-Demo")
AUDIO = DEMO / "assets" / "audio"
POOL = AUDIO / "pool"

# 第二批映射（用户弹窗指定）
BATCH2 = {
    "snd35.ogg": "sfx/battle_lose.ogg",
    "snd38.ogg": "sfx/recruit_ok.ogg",
    "snd4.ogg": "sfx/enhance_ok.ogg",
    "snd41.ogg": "sfx/enhance_fail.ogg",
    "snd27.ogg": "sfx/duel_round.ogg",
}

# 第一批已导入的源文件
BATCH1 = {
    "bgm3.ogg", "bgm5.ogg", "bgm4.ogg", "bgm7.ogg", "snd39.ogg",
    "snd36.ogg", "snd32.ogg", "snd31.ogg", "snd22.ogg", "snd23.ogg",
    "snd24.ogg", "snd27.ogg", "snd19.ogg", "snd10.ogg", "snd8.ogg",
    "snd34.ogg", "snd33.ogg",
}

def main():
    # 1. 第二批 5 个文件
    ok, fail = 0, 0
    for src_name, rel in BATCH2.items():
        src = SRC / src_name
        dst = AUDIO / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        if src.exists():
            shutil.copy2(src, dst)
            print(f"[OK] {src_name} -> {rel} ({src.stat().st_size:,} B)")
            ok += 1
        else:
            print(f"[MISS] {src_name} 源文件不存在")
            fail += 1

    # 2. 剩余全部文件入池（原名保留，便于日后重映射）
    POOL.mkdir(parents=True, exist_ok=True)
    pool_files = []
    for f in sorted(SRC.glob("*.ogg")):
        if f.name in BATCH1 or f.name in BATCH2:
            continue
        shutil.copy2(f, POOL / f.name)
        pool_files.append(f.name)
    print(f"\n[POOL] 其余 {len(pool_files)} 个文件已入池 assets/audio/pool/")

    # 3. 更新 audio_config.json（补第二批 + 池目录说明）
    cfg_path = AUDIO / "audio_config.json"
    cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
    cfg["audio_files"].update({k: v for k, v in BATCH2.items()})
    cfg["categories"]["sfx"]["battle_lose"] = "res://assets/audio/sfx/battle_lose.ogg"
    cfg["categories"]["sfx"]["recruit_ok"] = "res://assets/audio/sfx/recruit_ok.ogg"
    cfg["categories"]["sfx"]["enhance_ok"] = "res://assets/audio/sfx/enhance_ok.ogg"
    cfg["categories"]["sfx"]["enhance_fail"] = "res://assets/audio/sfx/enhance_fail.ogg"
    cfg["categories"]["sfx"]["duel_round"] = "res://assets/audio/sfx/duel_round.ogg"
    cfg["notes"] = {
        "pool_dir": "res://assets/audio/pool/ —— 未分配的备用音频（原名保留），可随时重映射",
        "conflict": "snd27.ogg 同时用作 battle_hit_4 与 duel_round（用户指定复用）",
        "batch2_date": "2026-09-27",
    }
    cfg_path.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"[CFG] {cfg_path} 已更新")

    print(f"\n汇总：第二批导入 {ok} 个（失败 {fail}），入池 {len(pool_files)} 个")

if __name__ == "__main__":
    main()
