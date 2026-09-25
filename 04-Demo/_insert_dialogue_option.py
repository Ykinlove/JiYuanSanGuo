"""在 dialogues.json 指定锚点选项块之后插入新的 accept_quest 选项块。

用法：python _insert_dialogue_option.py <锚点文本关键字> <新选项json文件>
只做行级插入，保持原文件缩进与格式不变（避免整体重排造成巨大 diff）。
"""
import json
import sys


def insert_after_option(path: str, anchor_kw: str, new_opt: dict) -> bool:
    with open(path, "r", encoding="utf-8") as f:
        lines = f.read().split("\n")

    # 找锚点行
    ai = -1
    for i, ln in enumerate(lines):
        if anchor_kw in ln:
            ai = i
            break
    if ai < 0:
        print("锚点未找到：%s" % anchor_kw)
        return False

    indent = len(lines[ai]) - len(lines[ai].lstrip())
    inner = " " * (indent + 1)

    # 锚点所在选项块：向上找到 '{'，向下找到配平的 '}'（简单计数）
    start = ai - 1
    while start >= 0 and lines[start].strip() != "{":
        start -= 1
    depth = 0
    end = start
    for j in range(start, len(lines)):
        depth += lines[j].count("{") - lines[j].count("}")
        if depth == 0:
            end = j
            break
    if lines[end].strip() not in ("},", "}"):
        print("块结束行异常：%r" % lines[end])
        return False

    block = [" " * indent + "{"]
    block.append(inner + '"text": %s,' % json.dumps(new_opt["text"], ensure_ascii=False))
    block.append(inner + '"next": %s,' % json.dumps(new_opt.get("next", ""), ensure_ascii=False))
    if new_opt.get("action"):
        block.append(inner + '"action": %s,' % json.dumps(new_opt["action"], ensure_ascii=False))
    if new_opt.get("require"):
        block.append(inner + '"require": {')
        for k, v in new_opt["require"].items():
            block.append(inner + " " + '"%s": %s' % (k, json.dumps(v, ensure_ascii=False)))
        block.append(inner + "}")
    block.append(" " * indent + "},")

    lines[end + 1: end + 1] = block
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    print("已插入：%s（第 %d 行后）" % (new_opt["text"], end + 1))
    return True


if __name__ == "__main__":
    anchor = sys.argv[1]
    opt = json.loads(sys.argv[2])
    ok = insert_after_option("assets/data/dialogues.json", anchor, opt)
    sys.exit(0 if ok else 1)
