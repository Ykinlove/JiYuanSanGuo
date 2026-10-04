# -*- coding: utf-8 -*-
"""校验器共用的**玩家存档指纹**单一真源。

【为什么必须抽出来】
本仓曾有 11 份各自拷贝的 `saves_fingerprint` / `save_fp`。
拷贝 = 各自漂移 = 反复踩坑，且其中一份已经漂移成了**假判据**：
`_verify_battle_logic_reverse.py` 里那份同时犯了三个错 ——

  ① **扫错了地方**：扫的是**源码仓库根目录**，而真存档在
     `%APPDATA%/Godot/app_userdata/纪元三国/saves/*.json`。
     仓库里根本没有玩家存档 → 它从头到尾没看过真存档一眼。
  ② **通配太宽**：条件是 `"save" in fn.lower()`，于是
     `save_manager.gd` / `_verify_save_load.py` / `save_menu.tscn`
     这些**源码**全被当成存档；再叠 `sorted()[:200]` 截断。
  ③ **把 `.pyc` 算进去了**：`__pycache__/*.pyc` 每个进程重新生成，
     跨进程必然不同 → 指纹跨运行漂移 → Z2「存档指纹一致」**偶发假红**
     （实测同一天内出现 7082beff / 81200046 / b79d53f3 三个值）。

另外 10 份的 `SAVES_DIR` 都是对的，只有这一份错。正解：唯一真源，
谁也别再自己拷一份。

【用法】
    from _gs_save import saves_fingerprint
    fp = saves_fingerprint()      # -> {文件名: sha256[:16]}
    if saves_fingerprint() != fp: ...   # 校验跑完后比对
"""
import hashlib
import os


def saves_dir() -> str:
    """Godot user:// 在 Windows 上的实际落盘目录（saves 子目录）。"""
    if os.name == "nt":
        base = os.path.join(os.environ.get("APPDATA", ""), "Godot",
                            "app_userdata")
    else:
        base = os.path.join(os.path.expanduser("~"), ".local", "share",
                            "godot", "app_userdata")
    # 项目名以 _project.godot 的 config/name 为准，此处对已知项目名做扫描匹配，
    # 避免把「三国纪元」「[unnamed project]」等历史目录也算进来。
    target = "纪元三国"
    if os.path.isdir(os.path.join(base, target, "saves")):
        return os.path.join(base, target, "saves")
    if os.path.isdir(base):
        for proj in sorted(os.listdir(base)):
            p = os.path.join(base, proj, "saves")
            if os.path.isdir(p):
                return p
    return os.path.join(base, target, "saves")


def saves_fingerprint() -> dict:
    """玩家存档指纹：{文件名: sha256[:16]}。目录不存在时返回空 dict。

    【只认 saves 目录下的普通文件】—— 不递归、不按子串通配、不看 __pycache__，
    这三点正是旧实现漏掉真存档、又掺进 .pyc 的根因。
    """
    d = saves_dir()
    fp = {}
    if not os.path.isdir(d):
        return fp
    for name in sorted(os.listdir(d)):
        p = os.path.join(d, name)
        if not os.path.isfile(p):
            continue
        try:
            with open(p, "rb") as f:
                fp[name] = hashlib.sha256(f.read()).hexdigest()[:16]
        except OSError:
            pass
    return fp


def fp_str(fp: dict) -> str:
    """把指纹 dict 压成一行可读串，用于日志与报错。"""
    if not fp:
        return "无存档"
    return " ".join("%s=%s" % (k, v) for k, v in sorted(fp.items()))
