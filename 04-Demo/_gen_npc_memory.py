# -*- coding: utf-8 -*-
"""为发任务的 NPC 补 _pending / _turnin 对话节点（NPC 记忆性）。

只做两件事：
  1. 备份 dialogues.json
  2. 在 JSON 结构层面插入新节点，保持缩进/换行风格（indent=4 / CRLF / 无尾换行）

台词里的 {quest_goal} 由 DialogueUI 在显示层替换成「当前差事的目标」，
因此一个 _pending 节点就能覆盖该 NPC 名下所有任务，不会写死后过期。
"""
import io
import json
import os
import re
import shutil

ROOT = os.path.dirname(os.path.abspath(__file__))
PATH = os.path.join(ROOT, "assets", "data", "dialogues.json")
BAK = PATH + ".bak_npc_memory"

# root -> (NPC名, 神态, 追问句, 催促句, 验货神态, 验货句, 交差句)
VOICE = {
    "elder_intro": ("寨中长者",
        "（老人把烟袋在鞋底磕了两下，抬眼看你）",
        "我托你的那桩事——{quest_goal}——办得怎么样了？",
        "寨子里的人都记着呢。办成了再来寻我，莫要糊弄老汉。",
        "（老人眯眼打量你半晌，忽然笑了）",
        "嗯……{quest_goal}，都了了。老汉我看得出来，你没说空话。",
        "拿来我看——赏功一事，寨子从不亏待人。"),
    "temple_elder_intro": ("祠堂老者",
        "（老者拂去案上香灰，声音低而稳）",
        "香案前不说虚言：{quest_goal}，办到几成了？",
        "未了之前，祠堂里没有别的差事派给你。",
        "（老者拈香的手一顿）",
        "香火未断，事情已了——{quest_goal}，成了。",
        "既是了了，便到案前领了这份谢礼去。"),
    "mengqian_intro": ("孟迁",
        "（孟迁合上账簿，笔尖点着册页）",
        "册子上还挂着你的名字——{quest_goal}，可有着落？",
        "公务不兴拖沓，办妥了即刻来回话。",
        "（孟迁翻到那一页，提笔）",
        "{quest_goal}……数目对得上，事情是了了。",
        "画了押，这份功劳便记在你名下。"),
    "ahei_intro": ("阿黑",
        "（阿黑老远就迎上来，挠着头）",
        "大哥！那事——{quest_goal}——你办得咋样啦？",
        "没办完也没事，我等你！办成了记得头一个告诉我啊。",
        "（阿黑瞪大眼睛，一把抓住你胳膊）",
        "真办成啦？！{quest_goal}——大哥你太厉害了！",
        "快快快，把这个交了，我给你数赏钱！"),
    "traveler_intro": ("行脚商人",
        "（商人放下货担，掂了掂算珠）",
        "客官，先前那桩买卖——{quest_goal}——走得如何了？",
        "货没到手，价钱可说不上。办妥了咱再谈下一笔。",
        "（商人眼里一亮，搓了搓手）",
        "好眼力！{quest_goal}，一样不差。",
        "一手交货，一手交钱——咱们两清。"),
    "zhurong_intro": ("祝融夫人",
        "（祝融夫人把长刀往地上一插，抬眼看你）",
        "我托你的事——{quest_goal}——办得怎么样了？",
        "刀出鞘就得见血。事没办成，别来回话说闲话。",
        "（夫人拔起长刀，刀锋映着你的脸）",
        "哦？{quest_goal}——这就办成了？",
        "既是办成了，赏功不亏你。拿来我看。"),
    "menghuo_intro": ("孟获",
        "（孟获拍案，酒碗一晃）",
        "哈哈！我交代你的——{quest_goal}——可办妥了？",
        "我南中人不兴空口白话，办成了才配与我同席饮酒！",
        "（孟获大笑，把酒碗推到你面前）",
        "好！{quest_goal}，一样不落，是条汉子！",
        "来，先把差事交了，这碗酒我敬你！"),
    "mentor_yangleipeng": ("杨雷鹏",
        "（杨雷鹏抬手止住话头）",
        "我教你的不是嘴上功夫——{quest_goal}，做到几成了？",
        "没到手便回去接着练，别在我面前耍嘴。",
        "（杨雷鹏上下打量你一眼，微微颔首）",
        "{quest_goal}……算是过关。",
        "既已达成，便把结果交上来，我替你记着。"),
    "mentor_yangzixuan": ("杨子轩",
        "（杨子轩合上手中书卷）",
        "先前那件小事——{quest_goal}——可还顺手？",
        "不急，慢慢来；只是未了之前，我不好再添新功课。",
        "（杨子轩唇角微扬）",
        "{quest_goal}，都妥了？拿来我看。",
        "既已了结，这份酬谢你且收下。"),
    "mentor_liming": ("李明",
        "（李明放下手中算筹）",
        "账还挂着呢——{quest_goal}，办到哪一步了？",
        "事没清，账不销。办妥了再来找我。",
        "（李明拨了两下算筹，点头）",
        "{quest_goal}，数目不差，是了了。",
        "销账吧，该你的那份一文不少。"),
    "han_envoy_intro": ("朝廷使者",
        "（使者展开手中诏书一角，神色不动）",
        "本使且问：{quest_goal}，可已办妥？",
        "王命在身，不可拖延。办成了再来缴令。",
        "（使者收起诏书，目光一沉）",
        "{quest_goal}……既有实证，本使便认了。",
        "缴令吧，朝廷的赏赐自会落到你头上。"),
    "caocao_intro": ("曹操",
        "（曹操以指节叩案，抬眼看你）",
        "孤交代的事——{quest_goal}——办得如何了？",
        "孤用人，只认结果。事未成，休来讨赏。",
        "（曹操抚掌，眼中精光一闪）",
        "好。{quest_goal}，果然办成了。",
        "既已成事，孤不吝赏。交上来吧。"),
    "strategist_intro": ("军中谋士",
        "（谋士推开盘中棋子，抬眼）",
        "那一着还未落定——{quest_goal}，办到几成了？",
        "棋没下完，不好开新局。办妥了再来。",
        "（谋士拈起一子，轻轻落下）",
        "{quest_goal}……这一着，落定了。",
        "既已收官，便把结果报上来。"),
    "historian_intro": ("史官",
        "（史官搁下手中刀笔）",
        "且慢，先答我一句：{quest_goal}，可有着落？",
        "史册只记已成之事，未了之前，我无话可写。",
        "（史官重新提起刀笔）",
        "{quest_goal}——既已了结，该落笔了。",
        "把结果交来，我替你记上一笔。"),
    "bamen_intro": ("白门楼守将",
        "（守将按住腰间刀柄，上下打量你）",
        "城防之事不是儿戏——{quest_goal}，办妥没有？",
        "没办妥，便别上我这门楼来闲话。",
        "（守将松开了刀柄）",
        "{quest_goal}……做得干净。",
        "既是办成了，把差事交了，我给你记功。"),
    "yushi_intro": ("朝廷御史",
        "（御史正了正冠冕，目光如刀）",
        "本官只问一句：{quest_goal}，可已了结？",
        "法度不容拖延，未了之前，休提他事。",
        "（御史翻过一卷案牍）",
        "{quest_goal}，有据可查，本官认了。",
        "交割吧，该给的赏，本官不会短你。"),
    "liubei_intro": ("刘备",
        "（刘备垂目，语声温和）",
        "那桩事——{quest_goal}——不知办得如何了？",
        "百姓还等着呢。办妥了，再来与我说。",
        "（刘备抬眼，眼中有了笑意）",
        "{quest_goal}，都妥了？好，好。",
        "既已了结，这份酬劳你且收下，莫嫌薄。"),
    "jing_intro": ("荆州从事",
        "（从事摊开一卷文书，指着其中一行）",
        "这一条还挂在你名下——{quest_goal}，办到几成了？",
        "文书未销，不便另派。办妥了即刻来回话。",
        "（从事提笔，在文书上一点）",
        "{quest_goal}……数目相符，可销。",
        "交割吧，我这就把这条划去。"),
    "lusu_intro": ("鲁肃",
        "（鲁肃拱手，笑意不改）",
        "先前托付的事——{quest_goal}——可还顺利？",
        "子敬不催你，只是这一桩未了，旁的不好开口。",
        "（鲁肃展颜，亲自迎上两步）",
        "{quest_goal}，都办成了？好啊。",
        "既已了结，这份谢礼万莫推辞。"),
    "sunquan_intro": ("孙权",
        "（孙权抬眼，目光沉静）",
        "孤托你的事——{quest_goal}——办得如何？",
        "事未成，孤不另派。办妥了再来见孤。",
        "（孙权微微颔首，指节轻叩几案）",
        "{quest_goal}……孤知道了，办得不错。",
        "交割吧，江东不亏有功之人。"),
    "jianggan_intro": ("蒋干",
        "（蒋干摇着折扇，笑嘻嘻凑上来）",
        "兄台，那点小事——{quest_goal}——办得如何啦？",
        "事没办成，你我也不好再谈别的嘛，是不是？",
        "（蒋干合扇一击掌心）",
        "妙啊！{quest_goal}，一样不差。",
        "交割交割，蒋某最喜与爽快人打交道。"),
    "fazheng_intro": ("法正",
        "（法正捻须，眼中带笑）",
        "先前那一桩——{quest_goal}——可有着落了？",
        "没着落之前，孝直不便再添新谋。办妥了再来。",
        "（法正笑意更深）",
        "{quest_goal}……果然不出孝直所料。",
        "既已成局，交割便是，赏功随后就到。"),
    "zhuge_intro": ("诸葛亮",
        "（孔明轻摇羽扇，目光如水）",
        "那一计尚在局中——{quest_goal}，办到几成了？",
        "局未收，亮不便另出谋划。办妥了再来。",
        "（孔明羽扇一顿，微微一笑）",
        "{quest_goal}……此局，收了。",
        "既已了结，交割吧，该你的分毫不少。"),
    "wutugu_intro": ("兀突骨",
        "（兀突骨把藤甲敲得咚咚响）",
        "你答应我的——{quest_goal}——办成了没有？",
        "没办成就别来，兀突骨不欢喜说空话的人！",
        "（兀突骨咧嘴，一掌拍在你肩上）",
        "好！{quest_goal}，办成了！",
        "交出来！赏你！"),
    "zhu_dawang_intro": ("祝老大王",
        "（祝老大王放下酒碗，眯着眼看你）",
        "我说的那件事——{quest_goal}——办得怎么样了？",
        "老骨头不爱听推脱，办成了再来跟我讨酒喝。",
        "（祝老大王哈哈一笑，把酒碗推过来）",
        "{quest_goal}，办成了？好，我信你。",
        "交割了，这碗酒归你。"),
    "jinhuan_intro": ("金环三结",
        "（金环三结把三节铜环抖得叮当作响）",
        "喂！那桩事——{quest_goal}——办妥了没？",
        "没办妥就别站我面前，碍眼！",
        "（金环三结收了铜环，咧嘴）",
        "哈！{quest_goal}，真让你办成了。",
        "拿来！赏钱我早备好了。"),
    "scout_intro": ("卧龙书僮",
        "（书僮踮着脚凑近，压低声音）",
        "先生让我问你——{quest_goal}——办得怎么样啦？",
        "这事没回话，先生不好再派别的差事呢。",
        "（书僮眼睛一亮，转身就要往里跑）",
        "办成啦？{quest_goal}——我这就去禀先生！",
        "快把差事交了，我好去回话！"),
    "zhouyu_intro": ("周瑜",
        "（周瑜按剑而立，眉梢微挑）",
        "公瑾托你之事——{quest_goal}——可有着落？",
        "事未了，公瑾不另遣。办妥了再来。",
        "（周瑜抚剑而笑，意气风发）",
        "{quest_goal}……果然不负所托。",
        "交割吧。既已成事，赏功岂可迟。"),
    "zhaoyu_intro": ("赵云",
        "（赵云抱枪而立，微微一笑）",
        "那桩差事——{quest_goal}——可办妥了？",
        "云不催你，只是这一桩未了，旁的不好相托。",
        "（赵云点头，枪尖轻点地面）",
        "{quest_goal}，都了了？好。",
        "既已了结，交割便是。"),
    "yicheng_intro": ("蜀道驿丞",
        "（驿丞翻着驿簿，抬头招呼）",
        "客官，账上还挂着呢——{quest_goal}，办到哪一步了？",
        "这条不销，小的不好给您派新差事呀。",
        "（驿丞提笔，笑得眼睛眯起来）",
        "{quest_goal}……都办妥啦？小的这就销账。",
        "交割吧，驿站的例钱一文不少。"),
    "ahei_luoyang_intro": ("北上的阿黑",
        "（阿黑搓着手，眼睛发亮地迎上来）",
        "大哥！你答应我的——{quest_goal}——办得咋样了？",
        "不着急不着急，办成了再来找我就行！",
        "（阿黑一把拉住你，声音都抖了）",
        "办成啦？！{quest_goal}——大哥，谢谢你！",
        "快交了快交了，我这就去收拾行李！"),
    "dianwei_intro": ("典韦",
        "（典韦把双戟往地上一顿，地面一颤）",
        "你应下的事——{quest_goal}——办成了没有？",
        "没办成就回去办，典韦不爱听闲话！",
        "（典韦咧嘴，把双戟往肩上一扛）",
        "好！{quest_goal}，办成了！",
        "交出来！某家敬你是条汉子！"),
    "caiwenji_intro": ("蔡琰",
        "（蔡琰停下手中琴弦，抬眼看你）",
        "先前那件事——{quest_goal}——可有着落了？",
        "事未了，我不便再开口相托。办妥了再来罢。",
        "（蔡琰指尖落在弦上，轻轻一按）",
        "{quest_goal}……都了了？",
        "既已了结，交割便是。这一曲，权当谢你。"),
}


def build(root: str, v) -> list:
    name, act, ask, tail, act2, done, pay = v
    pending = {
        "id": root + "_pending",
        "speaker": name,
        "lines": [act, ask, tail],
        "options": [
            {"text": "尚未办妥，且容几日", "next": ""},
            {"text": "想问点别的事", "next": root},
        ],
    }
    turnin = {
        "id": root + "_turnin",
        "speaker": name,
        "lines": [act2, done, pay],
        "options": [
            {"text": "办成了，交差（{quest}）", "next": root, "action": "turn_in:all"},
            {"text": "改日再来交", "next": ""},
        ],
    }
    return [pending, turnin]


def node_body(nd: dict) -> str:
    """把一个节点序列化成与现有文件完全一致的排版（CRLF，不含首尾换行）。

    原文件是 indent=4 / CRLF，但历史上脚本化编辑留下了 `"lines": [` 多缩进 4 格
    的既有样式；整表 json.dump 会把这点抹平，产生几千行无意义 diff。
    这里按原样复刻，保证 git diff 只有纯新增。
    """
    body = json.dumps(nd, ensure_ascii=False, indent=4)
    body = body.replace('\n    "lines": [', '\n        "lines": [')
    body = "\r\n".join("  " + ln for ln in body.split("\n"))
    return body


def join_inserts(bodies: list, at_last: bool) -> str:
    """把若干新节点块拼成可直接插入的字符串。

    切块时上一块的结尾保留了 \\r、下一块的开头是 \\n，中间插入必须用 \\n 开头、
    \\r 结尾才能接得上；插在文件最后一个节点之后时首尾都要补全。
    """
    if at_last:
        return "\r\n" + ",\r\n".join(bodies) + ","
    return "".join("\n" + b + ",\r" for b in bodies)


def main() -> None:
    raw = io.open(PATH, encoding="utf-8", newline="").read()
    data = json.loads(raw)
    nodes = data["nodes"] if isinstance(data, dict) else data
    exist = {n["id"] for n in nodes}

    # 1) 计算每个 root 的插入位置（该 root 最后一个节点之后）
    insert_at = {}          ## node_index -> [待插入节点 dict]
    for root, v in VOICE.items():
        if root not in exist:
            print("[WARN] root 节点不存在，跳过：%s" % root)
            continue
        pos = -1
        for i in range(len(nodes) - 1, -1, -1):
            nid = nodes[i]["id"]
            if nid == root or nid.startswith(root + "_"):
                pos = i
                break
        for nd in build(root, v):
            if nd["id"] in exist:
                print("[SKIP] 已存在：%s" % nd["id"])
                continue
            exist.add(nd["id"])
            insert_at.setdefault(pos, []).append(nd)

    # 2) 按原文本切块：每个 chunk 形如 "\r\n  {\r\n ... \r\n  },\r\n"
    starts = [m.start() for m in re.finditer(r'\n  \{\r?\n    "id": "', raw)]
    if not starts:
        raise SystemExit("[ERR] 未按预期格式找到节点块")
    tail_idx = raw.rindex("\r\n]")
    chunks = [raw[s: (starts[i + 1] if i + 1 < len(starts) else tail_idx)]
              for i, s in enumerate(starts)]

    # 3) 拼装：原块顺序不变，在指定块后追加新块
    #    相邻块之间靠「上一块结尾的 \r + 下一块开头的 \n」自然拼成 CRLF，勿再补换行。
    out = [raw[: starts[0]]]
    made = 0
    for i, ck in enumerate(chunks):
        out.append(ck)
        ins = insert_at.get(i, [])
        if ins:
            out.append(join_inserts([node_body(nd) for nd in ins], i == len(chunks) - 1))
            made += len(ins)
    out.append(raw[tail_idx:])

    shutil.copyfile(PATH, BAK)
    print("[BAK] %s" % BAK)
    with io.open(PATH, "w", encoding="utf-8", newline="") as f:
        f.write("".join(out))
    print("[OK] 新增 %d 个节点" % made)

    # 4) 自检：新文件必须能被解析，且节点数 = 旧 + 新增
    chk = json.loads(io.open(PATH, encoding="utf-8").read())
    cn = chk["nodes"] if isinstance(chk, dict) else chk
    print("[CHECK] 节点 %d -> %d" % (len(nodes), len(cn)))


if __name__ == "__main__":
    main()
