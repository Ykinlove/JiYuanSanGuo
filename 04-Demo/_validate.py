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

# 6. GDScript 类型推断静态扫描
#    捕捉 `var x := <表达式>` 在表达式类型不明确时会报的错误：
#      错误 (行, 列)： Cannot infer the type of "x" variable because the value doesn't have a set type.
#    典型成因 A：与「无类型数组字面量」的 for 循环变量相加
#    典型成因 B：字符串与「未标注类型」的变量/函数参数相加
#    注意：被 int() / float() / str() / bool() 显式包裹的 Variant 是安全的，
#          已标注类型的 Array[T] / Dictionary 取值也是安全的，均不报告。
UNTYPED_ARRAY_LOOP = re.compile(
    r"^\s*for\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\s+\[[^\]]*\]\s*:")
TYPED_CONTAINER = re.compile(
    r"(?:Array|Dictionary)\s*\[|:\s*Array\[|:\s*Dictionary")
SAFE_WRAPPERS = ("int(", "float(", "str(", "bool(", "String(", "as ")


def _stripped(expr):
    """去掉注释，用于分析。"""
    return re.split(r"#", expr)[0].strip()


def _safe(expr):
    """表达式是否已被显式类型化（无需再报）。"""
    return any(w in expr for w in SAFE_WRAPPERS)


infer_found = 0
for s in scripts:
    rel = os.path.relpath(s, ROOT)
    with open(s, "r", encoding="utf-8") as fh:
        lines = fh.readlines()

    # ---- 收集本文件中类型不确定的变量名 ----
    variant_vars = set()
    for line in lines:
        # 有类型容器的声明，其元素不算 Variant
        m = UNTYPED_ARRAY_LOOP.match(line)
        if m:
            # 若该行所在容器声明有类型则跳过 —— 简化处理：数组字面量一律视为 Variant 来源
            variant_vars.add(m.group(1))
    # 函数参数未标注类型 → Variant
    for line in lines:
        fm = re.match(r"^\s*func\s+[A-Za-z_][A-Za-z0-9_]*\s*\((.*?)\)", line)
        if fm and fm.group(1).strip():
            for param in fm.group(1).split(","):
                if ":" not in param:
                    pname = param.strip().split("=")[0].strip()
                    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", pname):
                        variant_vars.add(pname)

    if not variant_vars:
        continue

    for ln, line in enumerate(lines, 1):
        m = re.search(r"\bvar\s+([A-Za-z_][A-Za-z0-9_]*)\s*:=\s*(.+)$", line)
        if not m:
            continue
        var_name, expr = m.group(1), _stripped(m.group(2))
        if _safe(expr):
            continue
        used = [v for v in variant_vars
                if re.search(r"\b%s\b" % re.escape(v), expr)]
        if not used or "+" not in expr:
            continue
        infer_found += 1
        errors.append(
            "类型推断风险 %s:%d —— `var %s := ...` 中含无类型变量 %s，"
            "请改为显式声明（如 `var %s: String = ...`）。原文：%s"
            % (rel, ln, var_name, used, var_name, line.strip()))

print("=== 类型推断扫描：%d 处风险 ===" % infer_found)


# 7. 缩进规范 —— GDScript 要求用 Tab，混用空格会直接报错
tab_issues = 0
for s in scripts:
    rel = os.path.relpath(s, ROOT)
    with open(s, "r", encoding="utf-8") as fh:
        for ln, line in enumerate(fh, 1):
            stripped = line.rstrip("\n")
            if not stripped.strip():
                continue
            if stripped.startswith(" ") and stripped.lstrip() != "":
                tab_issues += 1
                errors.append(
                    "缩进用了空格 %s:%d —— GDScript 要求 Tab 缩进。原文：%s"
                    % (rel, ln, stripped[:60]))
print("=== 缩进规范扫描：%d 处问题 ===" % tab_issues)


# 8. class_name 与 Godot 原生类撞名检查
#    报错形式：Class "Xxx" hides a native class.
#    清单来自 Godot 4.7.2 的 ClassDB.get_class_list()（见 _godot_native/native_classes.json）。
#    重新生成方法：godot --headless --script <导出脚本>（脚本内含用法说明）
native_path = os.path.join(ROOT, "_godot_native", "native_classes.json")
collide = 0
if os.path.exists(native_path):
    with open(native_path, "r", encoding="utf-8") as fh:
        native_classes = set(json.load(fh))
    for name, files in class_names.items():
        if name in native_classes:
            collide += 1
            errors.append(
                "class_name 撞原生类 %s -> %s（Godot 已内置同名类，必须改名）"
                % (name, files))
    print("=== 原生类撞名检查：%d 处（对照 %d 个原生类）==="
          % (collide, len(native_classes)))
else:
    warns.append("缺少 _godot_native/native_classes.json，跳过原生类撞名检查")

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
