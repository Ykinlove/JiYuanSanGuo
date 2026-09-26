# -*- coding: utf-8 -*-
"""功能 NPC / 敌人 / 兵种模板立绘批量生成器。

这批 ID（1-99 之间）不是知名武将，而是城里天天见的商人/铁匠/军官/村民，
以及战斗里反复出现的山贼/黄巾/强盗/各兵种。
用法：
    python _template_portrait_gen.py pilot        # 先生成 9 类城内建筑 NPC
    python _template_portrait_gen.py all          # 生成全部缺失模板
    python _template_portrait_gen.py all --workers 1 # 单线程（安全，防并发覆盖）
"""
import argparse
import io
import json
import os
import sys
import time
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

from PIL import Image

sys.stdout.reconfigure(encoding='utf-8')

ROOT = r'E:\Work buddy\2026-09-21-17-49-04\纪元三国'
DEMO = os.path.join(ROOT, '04-Demo')
DATA = os.path.join(DEMO, 'assets', 'data')
SPR = os.path.join(DEMO, 'assets', 'sprites', 'npcs')
RAW = os.path.join(ROOT, '03-美术资源', 'AI源图', 'npcs')
API = 'https://trae-api-cn.mchost.guru/api/ide/v1/text_to_image'
IMG_SIZE = 'portrait_4_3'

STYLE = '二次元国风2D手绘全身立绘，明快色调，怀旧感，不华丽厚重，线条清晰，色彩平涂带轻描边'
FOOT = ('正面平视视角，居中构图，单人全身像，双脚自然站立，脚底对齐画面底边。'
        '背景必须是纯白色（#FFFFFF）纯白摄影棚背景，整张图四角到边缘都是纯白色，'
        '禁止黑色、灰色、深色或彩色背景，禁止渐变背景，无阴影，无地面，无任何环境元素，'
        '画面中绝对不出现任何文字、字母与印章。')

# 按名字给出具体造型提示（名字相同者共享）
ROLE_PROMPT = {
    '主角': ' customizable player character placeholder, no face detail, neutral stance',
    '伯乐': '中年相马师，面带和善微笑，身着褐色布衣短打，头戴斗笠，腰挂马鞭',
    '书商': '儒雅中年书肆老板，身着青灰色长袍，手捧竹简，神情谦和',
    '军官': '严肃的汉朝基层军官，头戴铁盔，身着玄色札甲，腰佩环首刀',
    '村长': '慈祥的乡村老者，白发长须，身着褐色深衣，手持拐杖',
    '商铺老板': '精明干练的中年商人，身着绸布短褐，腰系钱袋，笑容可掬',
    '铁匠': '健壮的中年铁匠，挽袖赤膊，肩搭汗巾，手持铁锤',
    '酒店老板': '热情的酒馆掌柜，微胖，身着褐色短打，肩搭白巾，手托酒壶',
    '药店老板': '清癯的中年医者，身着素色长袍，背药囊，手持药杵',
    '旅馆老板': '和蔼的中年店主，身着深色布衣，笑容殷勤，手作请势',
    '驯马师': '精干驯马师，身着皮革短打，手持缰绳，神态专注',
    '米店老板': '朴实的粮商，身着褐色布衣，肩搭布袋，面带忠厚',
    '治安官': '威严的巡逻衙役，头戴皂巾，身着深色公服，手持水火棍',
    '首饰商': '精明的中年女商人，身着织锦襦裙，手持珠钗，笑容得体',
    '旅人': '风尘仆仆的中年行旅者，头戴软巾，身披斗篷，肩背行囊',
    '村民青年': '朴实的农家青年，身着粗布短褐，面带微笑，姿态放松',
    '村民老翁': '佝偻的老年村民，白发稀疏，手持拐杖，神情慈祥',
    '村民女孩': '活泼的乡村少女，梳双鬟髻，身着素色襦裙，手提竹篮',
    '村民少妇': '端庄的年轻村妇，身着麻布襦裙，挽髻插木簪，双手交叠',
    '村民老妇': '慈祥的老年村妇，白发挽髻，手持拐杖，身着深色布衣',
    '鹿': '一只棕色成年鹿，站姿，四足着地，短尾竖耳，神态警觉',
    '野猪': '一只棕黑色野猪，站姿，獠牙外露，体型壮实，神态凶悍',
    '虎': '一只黄斑猛虎，站姿，四足着地，长尾下垂，神态威猛',
    '熊': '一只棕熊，站姿，四足着地，体型粗壮，神态憨厚中透凶猛',
    '兄弟会首领': '神秘组织首领，黑色劲装，面带半幅面具，眼神阴鸷',
    '暗夜堂头目': '刺客组织头目，黑色蒙面劲装，肩披暗甲，手持短刀',
    '罗马军官': '古罗马百夫长军官，红色横羽头盔，片板甲，红色披风，手持短剑与椭圆盾',
    '山贼斧兵': '手持长柄斧的山贼小兵，身着破布皮甲，头裹破巾，面目凶狠',
    '黄巾军枪兵': '头裹黄色巾帻的黄巾军小兵，手持木柄长枪，身着土黄短打',
    '强盗刀兵': '手持环首刀的强盗，衣着凌乱，面带横肉，神色贪婪',
    '强盗弓兵': '手持短弓的强盗，身形瘦削，眼神阴狠，腰间挂箭壶',
    '流寇刀盾兵': '手持短刀与木盾的流寇，衣着褴褛，神情凶悍',
    '流寇弓箭手': '手持短弓的流寇，身姿敏捷，面带狡黠',
    '乱军骑兵': '骑着无马具暗示的乱军骑兵，手持长枪，衣甲残破',
    '乱军弩手': '手持弩机的乱军士兵，半蹲瞄准姿态，衣着杂乱',
    '黑旗骑兵': '黑马旗骑兵，身着暗色皮甲，手持长枪，旗帜为黑色',
    '黑旗弩手': '黑旗军弩手，身着深色短打，手持弩机，神情冷酷',
    '民兵': '地方民兵，头戴斗笠，身着朴素布衣，手持长枪',
    '枪兵': '汉朝枪兵，头戴铁盔，身着札甲，手持长枪，站姿端正',
    '弓兵': '汉朝弓兵，身着轻甲，背负长弓与箭壶，站姿警觉',
    '长枪兵': '重装长枪兵，头戴铁兜鍪，身着铁甲，手持长柄大枪',
    '长弓兵': '精锐长弓手，身姿挺拔，手持长弓，腰挂箭壶',
    '重甲枪兵': '全身重甲枪兵，手持长枪，盔甲厚重，气势沉稳',
    '精准弓兵': '经验丰富的弓手，眼神锐利，拉弓待发',
    '枪骑兵': '骑马民族的枪骑兵，手持长枪，身披皮甲与披风',
    '白耳兵': '刘备精锐白耳兵，身着白色轻甲，手持长刀，英武干练',
    '陷阵营': '高顺陷阵营重步兵，全身铁甲，手持长戟，气势肃杀',
    '藤甲兵': '南蛮藤甲兵，身披藤编护甲，手持短刀，身形矫健',
    '羽林兵': '汉朝羽林禁卫，头戴羽冠盔，身着华丽札甲，手持长枪',
    '元戎弩': '蜀汉元戎弩手，操作大型连弩，身着褐色轻甲',
    '狄弓手': '西羌狄族弓手，身着皮裘，手持角弓，游牧装扮',
    '西凉铁骑': '西凉铁骑，手持长枪，身披重甲与披风，骑乘姿态',
    '羌族弓骑': '羌族骑马弓手，身着皮甲毡帽，拉弓骑射',
    '虎豹骑': '曹魏虎豹骑精锐骑兵，手持长枪，玄黑铁甲，气势凶猛',
    '刺客': '黑衣刺客，蒙面劲装，手持短刀，身形隐匿姿态',
    '剑客': '江湖剑客，身着布衣劲装，腰悬长剑，姿态洒脱',
    '罗马步兵': '古罗马军团步兵，手持短剑与矩形长盾，片板甲，红色羽盔',
    '山贼头目': '山贼小头目，手持大刀，身披破皮甲，满脸横肉',
    '黄巾军头目': '黄巾军小头目，头裹黄巾，手持长刀，神情狂热',
    '强盗头子': '强盗头目，手持大刀，身形魁梧，面带刀疤',
    '流寇首领': '流寇首领，手持长刀与盾牌，衣衫褴褛，眼神凶狠',
    '乱军将领': '乱军将领，手持长枪，衣甲残破，披头散发',
    '黑旗将领': '黑旗军将领，手持长刀，身着暗色战甲，气势阴沉',
    '元戎头领': '元戎弩部队首领，操作连弩，沉稳干练',
    '羌族武将': '羌族武将，身着皮裘披风，手持长刀，骑乘姿态',
    '南蛮武将': '南蛮部族武将，身披兽皮藤甲，手持巨斧，魁梧雄壮',
    '义军将领': '起义义军将领，手持长枪，身着布衣外罩皮甲，神情坚毅',
    '鲜卑将领': '鲜卑将领，身着游牧皮甲，手持长刀，骑乘姿态',
    '陷阵将领': '陷阵营统领，全身重甲，手持长戟，威风凛凛',
    '羽林将领': '羽林军统领，头戴羽冠盔，身着华丽札甲，手持长枪',
    '西凉将领': '西凉军将领，手持长刀，身披棕色皮甲与披风',
    '近卫军官': '皇帝近卫军官，身着明光铠甲，手持长戟，英姿挺拔',
    '老者': '白发苍苍的耄耋老者，身着褐色深衣，手持拐杖，神情慈祥',
}


PILOT_BUILDING = ['书商', '军官', '村长', '商铺老板', '铁匠', '酒店老板', '药店老板', '旅馆老板', '驯马师']


def load_heroes():
    with open(os.path.join(DATA, 'heroes6.json'), encoding='utf-8') as f:
        d = json.load(f)
    return d if isinstance(d, list) else next(v for v in d.values() if isinstance(v, list))


def targets(heroes, pilot=False):
    have = {os.path.splitext(f)[0] for f in os.listdir(SPR) if f.endswith('.png')}
    out = []
    for h in heroes:
        hid = str(h.get('id', ''))
        name = str(h.get('name', ''))
        if not hid or not name or name == '无' or h.get('is_dummy'):
            continue
        if hid in have:
            continue
        raw_path = os.path.join(RAW, '%s_%s.png' % (hid, name))
        if os.path.exists(raw_path):
            continue
        if pilot:
            if name not in PILOT_BUILDING:
                continue
        out.append((hid, h, raw_path))
    out.sort(key=lambda t: int(t[0]))
    return out


def build_prompt(h):
    name = str(h.get('name', ''))
    gender = '女性' if str(h.get('gender', '1')) == '2' else '男性'
    desc = ROLE_PROMPT.get(name, '')
    if not desc:
        desc = '%s%s角色' % (gender, name)
    return '游戏角色立绘素材，%s，%s。%s' % (desc, STYLE, FOOT)


def fetch_one(hid, h, raw_path, retries=3):
    url = API + '?prompt=' + urllib.parse.quote(build_prompt(h)) + '&image_size=' + IMG_SIZE
    delay = 6
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
            with urllib.request.urlopen(req, timeout=180) as r:
                data = r.read()
            im = Image.open(io.BytesIO(data)).convert('RGBA')
            tmp = raw_path + '.tmp'
            im.save(tmp, 'PNG')
            os.replace(tmp, raw_path)
            return hid, h.get('name', ''), None, im.size
        except Exception as e:
            err = '%s: %s' % (type(e).__name__, e)
            if attempt < retries - 1:
                time.sleep(delay * (attempt + 1))
            else:
                return hid, h.get('name', ''), err, None


def run(mode, workers=1):
    os.makedirs(RAW, exist_ok=True)
    heroes = load_heroes()
    todo = targets(heroes, pilot=(mode == 'pilot'))
    print('待生成: %d 张（workers=%d, size=%s）' % (len(todo), workers, IMG_SIZE))
    if not todo:
        return
    t0 = time.time()
    ok = fail = 0
    failures = []
    # 用 ThreadPoolExecutor 但 workers 默认 1，避免并发同秒覆盖与服务器限流
    with ThreadPoolExecutor(max_workers=workers) as ex:
        futs = {ex.submit(fetch_one, hid, h, rp): (hid, h.get('name', '')) for hid, h, rp in todo}
        for i, fut in enumerate(as_completed(futs), 1):
            hid, name, err, size = fut.result()
            if err:
                fail += 1
                failures.append({'id': hid, 'name': name, 'err': err})
                print('[%d/%d] FAIL %s %s -> %s' % (i, len(todo), hid, name, err[:80]))
            else:
                ok += 1
                print('[%d/%d] OK   %s %s %s (%.1fs)'
                      % (i, len(todo), hid, name, size, time.time() - t0), flush=True)
    with open(os.path.join(RAW, '_template_failures.json'), 'w', encoding='utf-8') as f:
        json.dump(failures, f, ensure_ascii=False, indent=2)
    print('完成：成功 %d / 失败 %d / 用时 %.1f 分钟' % (ok, fail, (time.time() - t0) / 60))
    if failures:
        print('失败清单：AI源图/npcs/_template_failures.json')


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('mode', choices=['pilot', 'all'])
    ap.add_argument('--workers', type=int, default=1)
    a = ap.parse_args()
    run(a.mode, a.workers)
