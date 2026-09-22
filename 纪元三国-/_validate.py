# -*- coding: utf-8 -*-
"""M2 工程校验脚本：JSON 数据表 / 脚本语法要点 / 资源引用 / tscn ext_resource 路径"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
errors = []
warns = []


def walk_files(sub, exts):
    base = os.path.join(ROOT, sub)
    out = []
    for dirpath, _dirs, files in os.walk(base):
        for f in files:
            if f.lower().endswith(exts):
                out.append(os.path.join(dirpath, f))
    return out


# 1. JSON 数据表
data_dir = os.path.join(ROOT, "assets", "data")
tables = []
if os.path.isdir(data_dir):
    for f in sorted(os.listdir(data_dir)):
        if f.endswith(".json"):
            path = os.path.join(data_dir, f)
            try:
                with open(path, "r", encoding="utf-8") as fh:
                    data = json.load(fh)
                if isinstance(data, list):
                    tables.append((f, len(data)))
                elif isinstance(data, dict):
                    tables.append((f, len(data.get("regions", data))))
            except Exception as e:
                errors.append("JSON 解析失败 %s: %s" % (f, e))

# 2. 脚本
scripts = walk_files("scripts", (".gd",))
scene_ext = walk_files("scenes", (".tscn",))

# 3. class_name 重复检查
class_names = {}
for s in scripts:
    with open(s, "r", encoding="utf-8") as fh:
        for line in fh:
            m = re.match(r"^class_name\s+([A-Za-z_][A-Za-z0-9_]*)", line)
            if m:
                name = m.group(1)
                class_names.setdefault(name, []).append(os.path.relpath(s, ROOT))
for name, files in class_names.items():
    if len(files) > 1:
        errors.append("class_name 重复: %s -> %s" % (name, files))

# 4. ext_resource 路径存在性
for sc in scene_ext:
    with open(sc, "r", encoding="utf-8") as fh:
        content = fh.read()
    for m in re.finditer(r'path="res://([^"]+)"', content):
        rel = m.group(1)
        target = os.path.join(ROOT, rel.replace("/", os.sep))
        if not os.path.exists(target):
            errors.append("场景 %s 引用缺失资源: res://%s" % (os.path.basename(sc), rel))

# 5. 检查每个场景的根节点存在
for sc in scene_ext:
    with open(sc, "r", encoding="utf-8") as fh:
        content = fh.read()
    if "[node " not in content:
        warns.append("场景缺少 node 定义: %s" % os.path.basename(sc))
    # 节点数量统计
    node_count = len(re.findall(r"^\[node ", content, re.M))
    if node_count == 0:
        warns.append("场景无有效节点: %s" % os.path.basename(sc))
    else:
        print("  场景 %-24s %d 个节点" % (os.path.basename(sc), node_count))

print("=== 数据表 (%d) ===" % len(tables))
for name, n in tables:
    print("  %-20s %d 条" % (name, n))
print("=== 脚本 %d 个 / 场景 %d 个 ===" % (len(scripts), len(scene_ext)))
print("=== class_name %d 个 ===" % len(class_names))
for name in sorted(class_names):
    print("  %s" % name)

print("")
if errors:
    print("[ERROR] %d 项" % len(errors))
    for e in errors:
        print("  - " + e)
else:
    print("[OK] 无错误")
if warns:
    print("[WARN] %d 项" % len(warns))
    for w in warns:
        print("  - " + w)
