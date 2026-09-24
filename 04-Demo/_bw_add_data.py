# -*- coding: utf-8 -*-
"""《霸王立志篇》数据实施脚本——参照三国大时代4体系补全剧本层。

写入内容：
1. quests.json   +7 环（bw_01/02/03 三试托付 + 4 条名士支线）
2. encounters.json +2（泰山狱卒 battle / 传国玺暗格 treasure）
3. npcs.json     +5（水寿/北上的阿黑/典韦/典母/蔡琰）
4. dialogues.json 改 5 段（三名士 intro + 阿黑 + 刘备）+ 新增 15 节点

幂等：重复运行会先移除同 id 旧条目再写入。
"""
import json
import io

BASE = "assets/data/"


def load(name):
    with io.open(BASE + name, "r", encoding="utf-8") as f:
        return json.load(f)


def save(name, data):
    with io.open(BASE + name, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
        f.write("\n")


def upsert(lst, items, key="id"):
    ids = {str(it[key]) for it in items}
    lst[:] = [x for x in lst if str(x.get(key)) not in ids]
    lst.extend(items)


# ---------------------------------------------------------------- quests
QUESTS = [
    {
        "id": "bw_01", "type": "side", "title": "民望之试",
        "region": "nanzhong", "giver_npc": "mentor_yangleipeng",
        "description": "杨雷鹏的托付：乱世之中，民心思安。护送南中流民一路平安，再出资三百金托他赈济灾民——收拢民望，是立业第一课。",
        "objectives": [
            {"type": "battle", "target": "enc_bandit", "count": 2, "desc": "击退劫掠流民的山贼"},
            {"type": "give_gold", "target": "mentor_yangleipeng", "count": 300, "desc": "出资三百金托杨雷鹏赈济流民"}
        ],
        "rewards": {"exp": 300, "fame": 8, "unlock": "sr_yangleipeng"},
        "next": ""
    },
    {
        "id": "bw_02", "type": "side", "title": "名分之试",
        "region": "zhongyuan", "giver_npc": "mentor_yangzixuan",
        "description": "杨子轩的托付：名不正则言不顺。传国玉玺自董卓之乱后下落成谜——亲赴洛阳探听玺踪，回禀于他。",
        "objectives": [
            {"type": "reach", "target": "city_luoyang", "count": 1, "desc": "亲赴洛阳探听传国玉玺下落"},
            {"type": "talk", "target": "mentor_yangzixuan", "count": 1, "desc": "回禀杨子轩所探得的玺踪"}
        ],
        "rewards": {"exp": 300, "fame": 6, "unlock": "sr_yangzixuan"},
        "next": ""
    },
    {
        "id": "bw_03", "type": "side", "title": "兵锋之试",
        "region": "zhongyuan", "giver_npc": "mentor_liming",
        "description": "李明的托付：泰山贼首张闿占山设营，掳掠乡民。攻破泰山大营、救出被困义士的家人，再回禀李明——治军先立威信。",
        "objectives": [
            {"type": "battle", "target": "enc_taishan_prison", "count": 1, "desc": "攻破泰山大营，击溃狱卒"},
            {"type": "talk", "target": "npc_shuishou", "count": 1, "desc": "往濮阳寻蒙难义士水寿问明营中情形"},
            {"type": "talk", "target": "mentor_liming", "count": 1, "desc": "回禀李明破营经过"}
        ],
        "rewards": {"gold": 600, "exp": 400, "fame": 8, "unlock": "sr_liming"},
        "next": ""
    },
    {
        "id": "side_ahhei_reunion", "type": "side", "title": "洛阳重逢",
        "region": "sili", "giver_npc": "a_hei",
        "description": "阿黑先一步北上闯荡去了。他捎话说已在洛阳落脚——去洛阳城找他，看看这个南中少年闯出了一片怎样的天地。",
        "objectives": [
            {"type": "reach", "target": "city_luoyang", "count": 1, "desc": "前往洛阳城寻阿黑"},
            {"type": "talk", "target": "npc_ahei_luoyang", "count": 1, "desc": "在洛阳与阿黑重逢"}
        ],
        "rewards": {"gold": 600, "exp": 200, "fame": 8, "random_item": True},
        "next": ""
    },
    {
        "id": "side_caomao", "type": "side", "title": "玄德草鞋",
        "region": "jing", "giver_npc": "npc_liubei",
        "description": "刘备仍亲手织席贩履。他托你携新织的草鞋去许昌、下邳两市代售——他说要亲眼看看，这乱世里还有几人记得百姓脚上的冷暖。",
        "objectives": [
            {"type": "reach", "target": "city_xuchang", "count": 1, "desc": "携草鞋赴许昌东市代售"},
            {"type": "reach", "target": "city_xapi", "count": 1, "desc": "携草鞋赴下邳市集代售"},
            {"type": "talk", "target": "npc_liubei", "count": 1, "desc": "回禀刘备代售所得"}
        ],
        "rewards": {"gold": 400, "exp": 300, "fame": 6},
        "next": ""
    },
    {
        "id": "side_dianwei", "type": "side", "title": "古之恶来",
        "region": "zhongyuan", "giver_npc": "npc_dianwei",
        "description": "陈留侠士典韦为寻老母流落至此，囊中已尽。听闻有人见老太太往许昌方向去了——替他走一趟，成全这一段母子重逢。",
        "objectives": [
            {"type": "talk", "target": "npc_dianmu", "count": 1, "desc": "在许昌寻得典母"},
            {"type": "talk", "target": "npc_dianwei", "count": 1, "desc": "回禀典韦母子下落"}
        ],
        "rewards": {"gold": 500, "exp": 350, "fame": 5},
        "next": ""
    },
    {
        "id": "side_caiwenji", "type": "side", "title": "文姬之择",
        "region": "zhongyuan", "giver_npc": "npc_caiwenji",
        "description": "陈留郊道，乱兵劫掠了一队流民——被掳的女子竟是大学者蔡邕之女蔡琰。击退乱兵救下她之后，如何安置这位才女，需听她自己的决断。",
        "objectives": [
            {"type": "battle", "target": "enc_bandit", "count": 1, "desc": "击退劫道的乱兵"},
            {"type": "talk", "target": "npc_caiwenji", "count": 1, "desc": "与蔡琰定夺去留"}
        ],
        "rewards": {"gold": 400, "exp": 300, "fame": 6},
        "next": ""
    },
]

# ------------------------------------------------------------ encounters
ENCOUNTERS = [
    {
        "id": "enc_taishan_prison", "name": "泰山狱卒", "type": "battle",
        "icon_color": "#8A4A38", "quest_target": "enc_taishan_prison", "weight": 3,
        "regions": ["china"], "terrain_prefer": ["mountain", "plain"],
        "level_range": [4, 7],
        "enemy_units": [
            {"unit_id": "infantry", "count": 70},
            {"unit_id": "cavalry", "count": 20}
        ],
        "boss_hero_id": "357",
        "rewards": {"exp": [150, 300], "gold": [120, 260], "fame": 3},
        "description": "泰山贼首张闿麾下的看营狱卒。营中囚着不肯入伙的义士家眷——破营救人，正在今日。"
    },
    {
        "id": "enc_hidden_jade_seal", "name": "传国玺暗格", "type": "treasure",
        "icon_color": "#C7A45C", "secret": True, "weight": 2,
        "regions": ["sili"],
        "loot_table": ["treasure_jade_seal"],
        "rewards": {"exp": [300, 500], "fame": 12, "unlock": "seal_jade"},
        "description": "洛阳城南废井旁的一处暗格——传说孙坚藏玺于此。井底石匣中隐有龙纹微光。"
    },
]

# ----------------------------------------------------------------- npcs
NPCS = [
    {
        "id": "npc_shuishou", "name": "水寿", "title": "濮阳 · 蒙难义士",
        "npc_type": "resident", "tags": ["story"],
        "position": [0, 0], "region": "", "color": "#8A9A6A",
        "dialogue_root": "shuishou_intro",
        "description": "从泰山大营逃出来的义士，形容憔悴，双目却亮。",
        "lore": "因不肯与泰山贼张闿合流，举家被掳，独他一人趁夜逃出，藏身濮阳。家人仍陷营中，日夜以泪洗面。",
        "city_id": "scene_23"
    },
    {
        "id": "npc_ahei_luoyang", "name": "北上的阿黑", "title": "洛阳 · 酒肆伙计",
        "npc_type": "resident", "tags": ["story"],
        "position": [0, 0], "region": "", "color": "#B8A88A",
        "dialogue_root": "ahei_luoyang_intro",
        "description": "在南中寨里长大的阿黑，如今在洛阳酒肆跑堂，晒黑的脸上满是笑。",
        "lore": "当年那个嚷着要去中原闯荡的南中少年，如今真在洛阳扎下了根。他一直记着寨子里帮过他的每一个人。",
        "city_id": "scene_19"
    },
    {
        "id": "npc_dianwei", "name": "典韦", "title": "陈留 · 江湖侠士",
        "npc_type": "resident", "tags": ["story", "quest_giver"],
        "position": [0, 0], "region": "", "color": "#7A5A4A",
        "dialogue_root": "dianwei_intro",
        "description": "形貌魁梧、双臂有千斤之力的侠士，为寻老母流落陈留。",
        "lore": "陈留己吾人。此刻他只是一个找不着母亲的儿子——他日提戟护主、死战不退的「古之恶来」，也先是娘的儿子。",
        "city_id": "scene_22"
    },
    {
        "id": "npc_dianmu", "name": "典母", "title": "许昌 · 寻子的老妇",
        "npc_type": "resident", "tags": ["story"],
        "position": [0, 0], "region": "", "color": "#9A8A7A",
        "dialogue_root": "dianmu_intro",
        "description": "白发苍苍的老妇，拄着一根木杖，逢人便打听儿子的下落。",
        "lore": "典韦之母。儿子出门寻食许久未归，她便自己一路寻来，坚信儿子一定还活着。",
        "city_id": "scene_21"
    },
    {
        "id": "npc_caiwenji", "name": "蔡琰", "title": "陈留 · 才女",
        "npc_type": "resident", "tags": ["story", "quest_giver"],
        "position": [0, 0], "region": "", "color": "#8A7A9A",
        "dialogue_root": "caiwenji_intro",
        "description": "大学者蔡邕之女，博学才情冠绝当世，乱世中颠沛流离。",
        "lore": "字文姬。此刻尚在中原；史载她此后将被虏往南匈奴十二年，直至曹操遣使金璧赎归——而你要替她选一条路。",
        "city_id": "scene_22"
    },
]

# ------------------------------------------------------------- dialogues
D_NEW = [
    # ---- 名士 lore 节点（托付对话的分支出入口） ----
    {
        "id": "mentor_yangleipeng_lore", "speaker": "杨雷鹏",
        "lines": [
            "民心如水，可载舟亦可覆舟。",
            "开仓赈济是一时之仁，修渠屯田是一世之利；然则乱世之中，最要紧的是让人信你——言出必践，四个字，够你用一辈子。"
        ],
        "options": [{"text": "受教了", "next": ""}]
    },
    {
        "id": "mentor_yangzixuan_lore", "speaker": "杨子轩",
        "lines": [
            "传国玉玺，卞和之璧所琢，秦皇命李斯篆「受命于天，既寿永昌」八字。",
            "汉室传之四百年，至十常侍之乱失于宫中。传闻太监孙坚……哦不，长沙孙坚讨董时于洛阳城南废井中得玺——又传闻玺未出井，仍在暗格之中。",
            "信与不信，足下亲往一看便知。"
        ],
        "options": [{"text": "井底之玺……记下了", "next": ""}]
    },
    {
        "id": "mentor_liming_lore", "speaker": "李明",
        "lines": [
            "兵马未动，粮草先行；将卒用命，赏罚先行。",
            "老夫领兵四十年，只信一条：令出必行。今日之诺，明日必偿——士卒敢效死力，靠的不是刀，是信。"
        ],
        "options": [{"text": "谨受教", "next": ""}]
    },
    # ---- 水寿（濮阳） ----
    {
        "id": "shuishou_intro", "speaker": "水寿",
        "lines": [
            "（城角一个衣衫褴褛的汉子警惕地抬头，看清你不是贼人装束才松了口气）",
            "壮士……我名水寿，本在山下务农。张闿那伙贼人占了大营，逼我入伙不从，便掳了我全家，只我一人趁夜逃了出来。",
            "家人还陷在那泰山大营里……张闿的狱卒看守极严，我一个人回去就是送死啊。"
        ],
        "options": [
            {"text": "贼营之事，包在我身上", "next": "shuishou_after"},
            {"text": "节哀，先行保重", "next": ""}
        ]
    },
    {
        "id": "shuishou_after", "speaker": "水寿",
        "lines": [
            "壮士若真能破营救人，水寿结草衔环也要报答！",
            "营中看守约莫百来人，头目使一把开山大斧——壮士务必多带人手。"
        ],
        "options": [{"text": "等我的好消息", "next": ""}]
    },
    # ---- 北上的阿黑（洛阳） ----
    {
        "id": "ahei_luoyang_intro", "speaker": "北上的阿黑",
        "lines": [
            "（酒肆里跑堂的少年回头一看，手里的盘子差点摔了）",
            "是、是你？！我从南中出来这天起就盼着再见到熟人！快坐快坐，今天这顿我请！",
            "当年在寨子里，大家都说我痴心妄想——如今我靠这双手在洛阳吃上饭了！这全靠你当年肯信我。"
        ],
        "options": [
            {"text": "（重逢叙旧）", "next": "ahei_luoyang_after",
             "action": "accept_quest:side_ahhei_reunion"},
            {"text": "（只是路过，点头致意）", "next": ""}
        ]
    },
    {
        "id": "ahei_luoyang_after", "speaker": "北上的阿黑",
        "lines": [
            "（阿黑从怀里掏出一条打磨得溜光的狼牙项链）",
            "这个给你！进山打的头一头野猪的牙，磨了整整一年——在咱南中，这是把最好的运气送给最亲的人的意思。"
        ],
        "options": [{"text": "（郑重收下）愿你前程似锦", "next": ""}]
    },
    # ---- 典韦（陈留） ----
    {
        "id": "dianwei_intro", "speaker": "典韦",
        "lines": [
            "（市集边一个铁塔般的汉子蹲在墙根，脚边只有一双磨破的草鞋）",
            "……壮士看我作甚？我典韦不是叫花子，只是在找我娘。",
            "我出来给娘寻吃的，回来人就不见了。听行商说，有人见一位白发老妇往许昌去了——可我盘缠用尽，一步也走不动了。"
        ],
        "options": [
            {"text": "替你去许昌寻母（接下托付）", "next": "dianwei_after",
             "action": "accept_quest:side_dianwei"},
            {"text": "壮士好臂力，来日必成大器", "next": "dianwei_praise"},
            {"text": "爱莫能助", "next": ""}
        ]
    },
    {
        "id": "dianwei_after", "speaker": "典韦",
        "lines": [
            "当真？！许昌……她一个老人家，是怎么走到许昌的……",
            "大恩不言谢。他日典韦若有出头之日，必为壮士执戟牵马！"
        ],
        "options": [{"text": "先寻人要紧", "next": ""}]
    },
    {
        "id": "dianwei_praise", "speaker": "典韦",
        "lines": [
            "（汉子咧嘴一笑，露出白牙）",
            "什么大器，能吃饱饭就行。等找到我娘，天下再乱，我也得先让娘吃上热饭。"
        ],
        "options": [{"text": "（点头告辞）", "next": ""}]
    },
    # ---- 典母（许昌） ----
    {
        "id": "dianmu_intro", "speaker": "典母",
        "lines": [
            "（一位白发老妇拄着木杖，正挨个问过路人）",
            "后生……你可曾见过一个高大壮实的汉子？浓眉大眼，走路带风，是我儿典韦。",
            "他打小就孝顺，我儿是来找吃的的，怎么就把我弄丢了……我这把老骨头，可不敢走远啊。"
        ],
        "options": [
            {"text": "老人家放心，你儿安好", "next": "dianmu_after"},
            {"text": "（默默递上干粮）", "next": "dianmu_after"}
        ]
    },
    {
        "id": "dianmu_after", "speaker": "典母",
        "lines": [
            "（老妇浑浊的眼睛一下子亮了，攥住你的手不放）",
            "他还在找？好、好……劳烦后生捎个话：娘在许昌东市等人，让他别慌，先把自己顾好。"
        ],
        "options": [{"text": "一定带到", "next": ""}]
    },
    # ---- 蔡琰（陈留） ----
    {
        "id": "caiwenji_intro", "speaker": "蔡琰",
        "lines": [
            "（乱兵散去，被掳的女子整了整衣襟，临乱不惊）",
            "多谢壮士援手。琰蔡氏，陈留人，家父蔡邕。",
            "家中藏书四千卷毁于战火，我流落至此，方才又遭此劫……这乱世，连书都容不下了。"
        ],
        "options": [
            {"text": "愿为文姬姑娘效劳（接下托付）", "next": "caiwenji_ask",
             "action": "accept_quest:side_caiwenji"},
            {"text": "姑娘可有去处？", "next": "caiwenji_ask"},
            {"text": "保重，告辞", "next": ""}
        ]
    },
    {
        "id": "caiwenji_ask", "speaker": "蔡琰",
        "lines": [
            "乱世女子，谈何去处。右贤王遣人在中原搜掠女子，我这样的……迟早是笼中之物。",
            "罢了。壮士既出手相救，想必是有主张的人——琰有一事，想请壮士替我拿个主意。"
        ],
        "options": [{"text": "姑娘请讲", "next": "caiwenji_choice"}]
    },
    {
        "id": "caiwenji_choice", "speaker": "蔡琰",
        "lines": [
            "陈留太守府与曹公有旧，若托太守府转呈此事，曹公必遣人护送我去兖州安置——从此有靠，却也从此欠下人情，身不由己。",
            "若不声张，我自往陈留乡下投奔舅家，粗茶淡饭，倒也自在——只是兵荒马乱，谁能保得长久？",
            "告知，还是不告知——请壮士替琰决断。"
        ],
        "options": [
            {"text": "乱世求存，托庇曹公为上（告知曹操）",
             "next": "caiwenji_choice_tell", "action": "set_flag:caiwenji_told_caocao"},
            {"text": "且自安稳，不涉他人门户（秘而不宣）",
             "next": "caiwenji_choice_hide", "action": "set_flag:caiwenji_hidden"}
        ]
    },
    {
        "id": "caiwenji_choice_tell", "speaker": "蔡琰",
        "lines": [
            "（蔡琰敛衽一礼，神色释然）",
            "既如此，琰便托壮士代为转呈曹公。他日曹公若问起引荐之人，琰必据实相告。",
            "——琰平生第一次觉得，把命运交到别人手里，也没那么可怕。"
        ],
        "options": [{"text": "（此事曹公记下了）", "next": ""}]
    },
    {
        "id": "caiwenji_choice_hide", "speaker": "蔡琰",
        "lines": [
            "（蔡琰轻轻一笑，眉眼间难得有了几分少女的神气）",
            "好。那琰便不去凑那些热闹——读书人自有一方天地，一卷书、一支笔，走到哪里都是天下。",
            "壮士今日之德，琰记在心里，不挂在嘴上。"
        ],
        "options": [{"text": "（就此别过）", "next": ""}]
    },
    # ---- 刘备草鞋支线节点 ----
    {
        "id": "liubei_caomao", "speaker": "刘备",
        "lines": [
            "（刘备从行囊里取出一双新织的草鞋，鞋底细密齐整）",
            "足下莫笑——这手艺是备吃饭的根本，丢不得。",
            "许昌、下邳两市人多，烦请足下携几双前去代售。备想知道，这乱世里，还有几人肯买百姓脚上的物件。"
        ],
        "options": [{"text": "公所托，必不辱命", "next": ""}]
    },
    {
        "id": "liubei_caomao_gold", "speaker": "刘备",
        "lines": [
            "（刘备把金子推了回来，神色如常）",
            "足下的心意，备领了。但这万金若收下，备怕自己有一天会习惯「不来钱就不做事」的日子。",
            "玄德谢过——倒是足下这般义气，他日必是诸侯争抢的人物。他日备若得志，愿与足下共图大事。"
        ],
        "options": [{"text": "（肃然起敬）", "next": ""}]
    },
]

# ---- 既有对话改版（整体替换） ----
D_REPLACE = {
    "mentor_yangleipeng": {
        "id": "mentor_yangleipeng", "speaker": "杨雷鹏",
        "lines": [
            "壮士留步。老夫观你骨相，非久居人下之辈。",
            "欲成大事，先得人心。老夫正有一事相托——南中流民为山贼所困，你若能击退贼众，再出资三百金作赈银交由老夫施散，便算过了这「民望之试」。"
        ],
        "options": [
            {"text": "愿领民望之试（接下托付）", "next": "mentor_yangleipeng_2",
             "action": "accept_quest:bw_01"},
            {"text": "奉上三百金赈银", "next": "mentor_yangleipeng_2",
             "action": "give_gold:300",
             "require": {"quest_active": "bw_01", "gold": 300}},
            {"text": "收拢民望，可有法门？", "next": "mentor_yangleipeng_lore"},
            {"text": "容我三思", "next": ""}
        ]
    },
    "mentor_yangzixuan": {
        "id": "mentor_yangzixuan", "speaker": "杨子轩",
        "lines": [
            "阁下可是胸怀大志之人？子轩久候矣。",
            "然则名不正则言不顺。立国须凭传国玉玺——董卓乱政以来，玺之下落成谜。你若亲赴洛阳探得玺踪，回禀于我，这「名分之试」便算你过。"
        ],
        "options": [
            {"text": "愿领名分之试（接下托付）", "next": "mentor_yangzixuan_2",
             "action": "accept_quest:bw_02"},
            {"text": "玉玺有何来历？", "next": "mentor_yangzixuan_lore"},
            {"text": "容后再议", "next": ""}
        ]
    },
    "mentor_liming": {
        "id": "mentor_liming", "speaker": "李明",
        "lines": [
            "小将军，老夫李明，半生戎马。",
            "治军先立威信。泰山贼首张闿占山设营，掳掠乡民——破营救人、再回禀于我，这「兵锋之试」便算你过。"
        ],
        "options": [
            {"text": "愿领兵锋之试（接下托付）", "next": "mentor_liming_2",
             "action": "accept_quest:bw_03"},
            {"text": "治军之道，愿闻其详", "next": "mentor_liming_lore"},
            {"text": "且待整备", "next": ""}
        ]
    },
}

# ---- 既有对话增量选项 ----


def patch_ahei(d):
    if any(o.get("action") == "accept_quest:side_ahhei_reunion"
           for o in d["options"]):
        return d
    d["options"].insert(0, {
        "text": "中原闯荡得如何了？（重逢叙旧）", "next": "",
        "action": "accept_quest:side_ahhei_reunion",
        "require": {"min_chapter": 2}
    })
    return d


def patch_liubei(d):
    if any(o.get("action") == "accept_quest:side_caomao"
           for o in d["options"]):
        return d
    d["options"].insert(1, {
        "text": "草鞋代售之事，愿代劳", "next": "liubei_caomao",
        "action": "accept_quest:side_caomao",
        "require": {"min_chapter": 4}
    })
    d["options"].insert(2, {
        "text": "愿赠万金，助公起兵", "next": "liubei_caomao_gold",
        "action": "give_gold:10000",
        "require": {"min_chapter": 4, "quest_active": "side_caomao", "gold": 10000}
    })
    return d


PATCH_FN = {"ahei_intro": patch_ahei, "liubei_intro": patch_liubei}


def main():
    # 1. quests
    q = load("quests.json")
    upsert(q, QUESTS)
    save("quests.json", q)
    print("quests.json -> %d 条" % len(q))

    # 2. encounters
    e = load("encounters.json")
    upsert(e, ENCOUNTERS)
    save("encounters.json", e)
    print("encounters.json -> %d 条" % len(e))

    # 3. npcs
    n = load("npcs.json")
    upsert(n, NPCS)
    save("npcs.json", n)
    print("npcs.json -> %d 条" % len(n))

    # 4. dialogues
    d = load("dialogues.json")
    by_id = {str(x.get("id")): x for x in d}
    # 替换既有节点
    for k, v in D_REPLACE.items():
        if k in by_id:
            d[d.index(by_id[k])] = v
        else:
            d.append(v)
    # 增量选项
    for x in d:
        fn = PATCH_FN.get(str(x.get("id")))
        if fn:
            fn(x)
    # 追加新节点
    upsert(d, D_NEW)
    save("dialogues.json", d)
    print("dialogues.json -> %d 条" % len(d))

    # 校验 next 引用完整性
    ids = {str(x.get("id")) for x in d}
    missing = []
    for x in d:
        for o in x.get("options", []):
            nxt = str(o.get("next", ""))
            if nxt and nxt not in ids:
                missing.append("%s -> %s" % (x.get("id"), nxt))
    if missing:
        print("[FAIL] 悬空 next 引用:")
        for m in missing:
            print("  ", m)
    else:
        print("[OK] 全部对话 next 引用完整")


if __name__ == "__main__":
    main()
