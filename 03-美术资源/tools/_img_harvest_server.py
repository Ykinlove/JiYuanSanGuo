# -*- coding: utf-8 -*-
"""NPC 立绘收割管线：本地服务 + 浏览器页面。

为什么需要它：text_to_image 接口对非浏览器 TLS 形态的请求一律返回 default.jpeg
占位图（已验证：urllib/带浏览器头/JWT 均无效）；只有真实浏览器 <img> 加载才会
同步返回生成好的图片（约 6-12 秒）。因此由浏览器页面负责加载图片、canvas 取像素、
POST 回本地服务落盘。

路由：
  GET  /            harvester.html
  GET  /jobs?limit=N&pilot=1   待生成任务 [{id,name,prompt,size}]
  POST /save/<id>   {name,b64}  -> 存 AI源图/npcs/<id>_<name>.png
  GET  /progress    {done,total,saved:[...]}

运行：
  python _img_harvest_server.py [--port 8932] [--limit 0] [--pilot]
然后浏览器打开 http://127.0.0.1:<port>/
"""
import argparse
import io
import json
import os
import re
import sys
import threading
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _portrait_gen import build_prompt, load_heroes, safe_name, RAW, SPR, PILOT_NAMES, SKIP  # noqa
from PIL import Image

lock = threading.Lock()
STATE = {'done': 0, 'saved': [], 'errors': []}


def list_jobs(limit=0, pilot=False):
    heroes = load_heroes()
    have = set(os.path.splitext(f)[0] for f in os.listdir(SPR) if f.endswith('.png'))
    jobs = []
    for hid, h in heroes.items():
        name = str(h.get('name', ''))
        if not name or name == '无' or name in SKIP or h.get('is_dummy'):
            continue
        if pilot and name not in PILOT_NAMES:
            continue
        if str(hid) in have:
            continue
        raw_path = os.path.join(RAW, '%d_%s.png' % (hid, safe_name(name)))
        if os.path.exists(raw_path):
            continue
        jobs.append({'id': hid, 'name': name,
                     'prompt': build_prompt(h), 'size': 'portrait_4_3'})
    jobs.sort(key=lambda j: j['id'])
    if limit > 0:
        jobs = jobs[:limit]
    return jobs


HTML = """<!DOCTYPE html><html><head><meta charset="utf-8"><title>harvest</title>
<style>body{font-family:monospace;padding:12px;background:#222;color:#9f9}
#log{white-space:pre-wrap;font-size:13px;line-height:1.5}#bar{height:14px;background:#033;margin:8px 0}#fill{height:14px;background:#3c6;width:0}</style></head>
<body><h3 id="st">starting</h3><div id="bar"><div id="fill"></div></div><div id="log"></div>
<script>
const CONC=4, PH_W=1832;
let jobs=[], idx=0, ok=0, fail=0;
const logEl=document.getElementById('log'), stEl=document.getElementById('st'), fillEl=document.getElementById('fill');
function L(s){logEl.textContent+=s+'\\n';}
async function pullSave(job, url){
  const r=await fetch('/pull/'+job.id,{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({name:job.name,url})});
  if(!r.ok) throw new Error('pull http '+r.status);
  const j=await r.json();
  if(!j.ok) throw new Error(j.err||'pull fail');
  return j;
}
const VARIANTS=['','，再次强调背景必须是纯白色','，纯白摄影棚背景四角纯白','，全身立绘纯白背景无杂物','，干净的纯白色背景',
  '，浅色简洁的背景','，明亮的白色背景','，白色背景无投影','，素白背景','，纯色白底','，浅色素净背景',
  '，白墙前的全身像','，浅色干净的背景','，影棚白底','，无背景的纯白底人物'];
const VOFF=parseInt(new URLSearchParams(location.search).get('off')||'0');
function loadImg(job, attempt){
  return new Promise((resolve,reject)=>{
    const im=new Image();
    const vi=Math.min(VOFF+attempt-1,VARIANTS.length-1);
    const url='https://trae-api-cn.mchost.guru/api/ide/v1/text_to_image?prompt='
      +encodeURIComponent(job.prompt+VARIANTS[vi])
      +'&image_size='+job.size;
    const t0=Date.now();
    const timer=setTimeout(()=>{im.src='';reject(new Error('timeout'));},90000);
    im.onload=()=>{clearTimeout(timer);
      if(im.naturalWidth===PH_W && im.naturalHeight===PH_W){reject(new Error('placeholder'));return;}
      resolve({url,ms:Date.now()-t0,w:im.naturalWidth,h:im.naturalHeight});
    };
    im.onerror=()=>{clearTimeout(timer);reject(new Error('imgerror'));};
    im.src=url;
  });
}
async function worker(n){
  while(idx<jobs.length){
    const job=jobs[idx++];
    let err=null;
    for(let attempt=1;attempt<=5;attempt++){
      try{ const r=await loadImg(job,attempt);
           const s=await pullSave(job,r.url);
        ok++; L('[w'+n+'] OK  '+job.id+' '+job.name+(attempt>1?' (v'+attempt+')':'')+'  gen='+r.ms+'ms '+r.w+'x'+r.h); err=null; break;
      }catch(e){ err=e; await new Promise(res=>setTimeout(res,5000)); }
    }
    if(err){ fail++; L('[w'+n+'] FAIL '+job.id+' '+job.name+'  '+err.message);
      try{await fetch('/fail/'+job.id,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:job.name,err:String(err.message)})});}catch(e){} }
    const done=ok+fail;
    stEl.textContent=done+'/'+jobs.length+'  ok='+ok+' fail='+fail;
    fillEl.style.width=(done/jobs.length*100)+'%';
  }
}
(async()=>{
  const qs=new URLSearchParams(location.search);
  const r=await fetch('/jobs?'+qs.toString());
  jobs=await r.json();
  L('jobs: '+jobs.length);
  if(!jobs.length){stEl.textContent='NO JOBS';return;}
  await Promise.all(Array.from({length:CONC},(_,i)=>worker(i+1)));
  L('=== DONE ok='+ok+' fail='+fail+' ===');
  document.title='DONE '+ok+'/'+fail;
})();
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype='application/json'):
        if isinstance(body, str):
            body = body.encode('utf-8')
        self.send_response(code)
        self.send_header('Content-Type', ctype + '; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass

    def do_GET(self):
        path = self.path.split('?')[0]
        qs = self.path.split('?')[1] if '?' in self.path else ''
        if path == '/':
            return self._send(200, HTML, 'text/html')
        if path == '/jobs':
            import urllib.parse as up
            q = dict(up.parse_qsl(qs))
            jobs = list_jobs(int(q.get('limit', 0)), q.get('pilot') == '1')
            return self._send(200, json.dumps(jobs, ensure_ascii=False))
        if path == '/progress':
            with lock:
                return self._send(200, json.dumps(STATE))
        return self._send(404, '{}')

    def do_POST(self):
        path = self.path.split('?')[0]
        n = int(self.headers.get('Content-Length', 0))
        payload = json.loads(self.rfile.read(n).decode('utf-8'))
        m = re.match(r'^/(save|pull|fail)/(\d+)$', path)
        if not m:
            return self._send(404, '{}')
        kind, hid = m.group(1), int(m.group(2))
        with lock:
            if kind == 'pull':
                up = payload['url']
                req = urllib.request.Request(up, headers={'User-Agent': 'Mozilla/5.0'})
                with urllib.request.urlopen(req, timeout=120) as r:
                    data = r.read()
                im = Image.open(io.BytesIO(data)).convert('RGB')
                if im.size == (1832, 1832):
                    return self._send(200, json.dumps({'ok': False, 'err': 'placeholder@origin'}))
                w, h = im.size
                pts = [(2, 2), (w - 3, 2), (2, h - 3), (w - 3, h - 3),
                       (w // 2, 2), (w // 2, h - 3), (2, h // 2), (w - 3, h // 2)]
                vs = sorted(max(im.getpixel(p)) for p in pts)
                ss = sorted(max(im.getpixel(p)) - min(im.getpixel(p)) for p in pts)
                med_v, med_s = vs[len(vs) // 2], ss[len(ss) // 2]
                if med_v < 200 or med_s > 22:
                    return self._send(200, json.dumps(
                        {'ok': False, 'err': 'badbg', 'v': med_v, 's': med_s}))
                # 白底图里出现大面积深色块（黑幕布/黑相框）：正常黑甲武将暗部占比 <18%
                dark = tot = 0
                for yy in range(0, h, 4):
                    for xx in range(0, w, 4):
                        r, g, b = im.getpixel((xx, yy))
                        tot += 1
                        if max(r, g, b) < 70 and max(r, g, b) - min(r, g, b) < 40:
                            dark += 1
                if dark / max(tot, 1) > 0.25:
                    return self._send(200, json.dumps(
                        {'ok': False, 'err': 'darkframe', 'ratio': round(dark / tot, 3)}))
                # 边缘 8px 内一周不应有大面积深色（黑幕布/黑边），细兵器忽略
                dark = tot = 0
                for x in range(0, w, 4):
                    for y in list(range(0, 10)) + list(range(h - 10, h)):
                        r, g, b = im.getpixel((x, y))
                        tot += 1
                        if max(r, g, b) < 140 and max(r, g, b) - min(r, g, b) < 35:
                            dark += 1
                for y in range(0, h, 4):
                    for x in list(range(0, 10)) + list(range(w - 10, w)):
                        r, g, b = im.getpixel((x, y))
                        tot += 1
                        if max(r, g, b) < 140 and max(r, g, b) - min(r, g, b) < 35:
                            dark += 1
                if dark / max(tot, 1) > 0.03:
                    return self._send(200, json.dumps(
                        {'ok': False, 'err': 'darkedge', 'ratio': round(dark / tot, 3)}))
                rgba = im.convert('RGBA')
                fp = os.path.join(RAW, '%d_%s.png' % (hid, safe_name(payload['name'])))
                tmp = fp + '.tmp'
                rgba.save(tmp, 'PNG')
                os.replace(tmp, fp)
                STATE['done'] += 1
                STATE['saved'].append(hid)
                return self._send(200, json.dumps({'ok': True, 'size': list(im.size), 'bytes': len(data)}))
            STATE['errors'].append({'id': hid, 'name': payload.get('name'), 'err': payload.get('err')})
            return self._send(200, '{"ok":true}')


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', type=int, default=8932)
    ap.add_argument('--limit', type=int, default=0)
    ap.add_argument('--pilot', action='store_true')
    a = ap.parse_args()
    os.makedirs(RAW, exist_ok=True)
    jobs = list_jobs(a.limit, a.pilot)
    print('待生成任务: %d（pilot=%s），端口 %d' % (len(jobs), a.pilot, a.port))
    for j in jobs[:10]:
        print('  ', j['id'], j['name'])
    srv = ThreadingHTTPServer(('127.0.0.1', a.port), Handler)
    srv.serve_forever()
