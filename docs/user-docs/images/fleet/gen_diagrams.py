# 「フリートを拡張する」の章の概念図(images/fleet/{ja,en}/*.png)を作り直す。文言は T の ja/en を対で直す。
# 実行: python3 docs/user-docs/images/fleet/gen_diagrams.py(Google Chrome のヘッドレスで 2 倍の PNG を書く)
# 部品と配色は images/security/gen_diagrams.py と揃える(あちらは import すると描画まで走るので写している)
import subprocess, os, tempfile
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
OUT=os.path.dirname(os.path.abspath(__file__))
FONT="'Hiragino Sans','Hiragino Kaku Gothic ProN','Helvetica Neue',Arial,sans-serif"
C=dict(ink="#1f2937",sub="#6b7280",line="#9ca3af",ft="#0e7490",ftBg="#e0f2fe",dev="#15803d",devBg="#dcfce7",
       file="#374151",fileBg="#f3f4f6",sb="#b45309",sbBg="#fffbeb",no="#b91c1c",noBg="#fee2e2")
def box(x,y,w,h,fill,stroke,title,sub=None,r=14,ts=20):
    s=f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}" stroke="{stroke}" stroke-width="2"/>'
    lines=title.split("\n"); lh=ts+4
    total=len(lines)*lh+(22 if sub else 0)
    ty=y+h/2-total/2+ts
    for i,l in enumerate(lines):
        s+=f'<text x="{x+w/2}" y="{ty+i*lh}" text-anchor="middle" font-size="{ts}" font-weight="700" fill="{stroke}">{l}</text>'
    if sub:
        s+=f'<text x="{x+w/2}" y="{ty+(len(lines)-1)*lh+24}" text-anchor="middle" font-size="13" fill="{C["sub"]}">{sub}</text>'
    return s
def arrow(x1,y1,x2,y2,label=None,lx=None,ly=None,color=None,dash=False,anchor="middle"):
    color=color or C["line"]
    d=' stroke-dasharray="6 5"' if dash else ""
    s=f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{color}" stroke-width="2.5"{d} marker-end="url(#ah)"/>'
    if label:
        lx=lx if lx is not None else (x1+x2)/2; ly=ly if ly is not None else (y1+y2)/2-10
        s+=f'<text x="{lx}" y="{ly}" text-anchor="{anchor}" font-size="14" fill="{C["ink"]}">{label}</text>'
    return s
def svg(w,h,body):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" font-family="{FONT}">
<defs><marker id="ahs" markerWidth="10" markerHeight="10" refX="1" refY="5" orient="auto"><path d="M10,0 L0,5 L10,10 z" fill="{C['line']}"/></marker><marker id="ah" markerWidth="10" markerHeight="10" refX="9" refY="5" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="{C['line']}"/></marker></defs>
<rect width="{w}" height="{h}" fill="#ffffff" rx="16"/>{body}</svg>'''
def lane(x,y,w,h,label,color,stroke="#e5e7eb",fill="none",sub=None):
    s=(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="16" fill="{fill}" stroke="{stroke}" stroke-width="2" stroke-dasharray="6 6"/>'
       f'<text x="{x+18}" y="{y+30}" font-size="17" font-weight="700" fill="{color}">{label}</text>')
    if sub:
        s+=f'<text x="{x+18}" y="{y+50}" font-size="13" fill="{C["sub"]}">{sub}</text>'
    return s
def code(x,y,lines,ts=14):
    return "".join(f'<text x="{x}" y="{y+i*(ts+7)}" font-size="{ts}" font-family="Menlo,monospace" xml:space="preserve" fill="{C["ink"]}">{l}</text>'
                   for i,l in enumerate(lines))

T={
 "ja":dict(
   local="手元の Mac(発行側)", localsub="あなたが操作する Mac。マシン名は local",
   you="AIアシスタント・VSCode・CLI", yousub="テストを頼む・結果を見る",
   proj="テストプロジェクト", projsub="シナリオ・プロファイル・アプリ",
   ldev="この Mac のデバイス", ldevsub="Simulator・Emulator・USB の実機",
   r1="ランナー機 M1Max", r2="ランナー機 M2Ultra", rsub="SSH で入れる別の Mac",
   rdev1="Simulator・Emulator", rdev2="Simulator・実機", rdevsub="そのマシンにあるデバイス",
   send="→ 送る: シナリオ・プロファイル・アプリ", back="← 回収: レポート・録画・ログ",
   ssh="SSH(鍵認証)だけ",
   prof="実行プロファイル(どのマシンのどのデバイスで回すか)",
   code=['"devices": [',
         '  { "machine": "local",   "name": "iPhone 17 Pro-01", ... },',
         '  { "machine": "M1Max",   "name": "Pixel 9-01", ... },',
         '  { "machine": "M2Ultra", "kind": "physical", "udid": "...", ... }',
         ']'],
   pnote="シナリオは、各マシンのデバイスの台数に応じて振り分けられ、同時に実行される",
   mon="デバイスモニターには全マシンのデバイスが並ぶ(マシン名のバッジ付き)",
 ),
 "en":dict(
   local="Your Mac (dispatching side)", localsub="The Mac you operate. Its machine name is local",
   you="AI assistant, VS Code, CLI", yousub="Ask for tests, read results",
   proj="Test project", projsub="Scenarios, profiles, app",
   ldev="This Mac's devices", ldevsub="Simulator, Emulator, USB physical",
   r1="Runner machine M1Max", r2="Runner machine M2Ultra", rsub="Another Mac reachable over SSH",
   rdev1="Simulator, Emulator", rdev2="Simulator, physical", rdevsub="Devices on that machine",
   send="→ Sends: scenarios, profiles, app", back="← Collects: reports, recordings, logs",
   ssh="SSH (key auth) only",
   prof="Run profile (which device on which machine runs the tests)",
   code=['"devices": [',
         '  { "machine": "local",   "name": "iPhone 17 Pro-01", ... },',
         '  { "machine": "M1Max",   "name": "Pixel 9-01", ... },',
         '  { "machine": "M2Ultra", "kind": "physical", "udid": "...", ... }',
         ']'],
   pnote="Scenarios are split across machines by how many devices each has, and run at the same time",
   mon="The device monitor lists the devices of every machine (with a machine-name badge)",
 ),
}

def link(x1,y1,x2,y2):
    return f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{C["line"]}" stroke-width="2.5" marker-start="url(#ahs)" marker-end="url(#ah)"/>'

def concept(t):
    W,H=1200,760
    b=lane(20,20,380,470,t["local"],C["ink"],sub=t["localsub"])
    b+=box(40,90,340,80,C["ftBg"],C["ft"],t["you"],t["yousub"],r=12,ts=18)
    b+=box(40,195,340,80,C["fileBg"],C["file"],t["proj"],t["projsub"],r=12,ts=18)
    b+=box(40,385,340,80,C["devBg"],C["dev"],t["ldev"],t["ldevsub"],r=12,ts=18)
    b+=arrow(210,277,210,381)
    # ランナー機
    for i,(name,dev) in enumerate([(t["r1"],t["rdev1"]),(t["r2"],t["rdev2"])]):
        y=20+i*245
        b+=lane(790,y,390,225,name,C["ft"],stroke=C["ft"],fill="#f8fdff",sub=t["rsub"])
        b+=box(810,y+120,350,80,C["devBg"],C["dev"],dev,t["rdevsub"],r=12,ts=18)
    # SSH の中継
    b+=f'<rect x="450" y="180" width="260" height="110" rx="12" fill="#ffffff" stroke="{C["ft"]}" stroke-width="2"/>'
    b+=f'<text x="580" y="210" text-anchor="middle" font-size="16" font-weight="700" fill="{C["ft"]}">{t["ssh"]}</text>'
    b+=f'<text x="462" y="242" font-size="13" fill="{C["ink"]}">{t["send"]}</text>'
    b+=f'<text x="462" y="270" font-size="13" fill="{C["ink"]}">{t["back"]}</text>'
    b+=link(384,235,446,235)
    b+=link(714,210,786,132)
    b+=link(714,260,786,377)
    # 実行プロファイル
    b+=lane(20,510,1160,190,t["prof"],C["sb"],stroke=C["sb"],fill=C["sbBg"])
    b+=code(45,570,t["code"])
    b+=f'<text x="45" y="688" font-size="14" fill="{C["sb"]}">{t["pnote"]}</text>'
    b+=f'<text x="30" y="736" font-size="13" fill="{C["sub"]}">{t["mon"]}</text>'
    return svg(W,H,b)

def render(name,lang,svgtext,w,h):
    os.makedirs(f"{OUT}/{lang}",exist_ok=True)
    html=f"<html><body style='margin:0;background:#fff'>{svgtext}</body></html>"
    p=os.path.join(tempfile.gettempdir(),f"ft_diagram_{name}_{lang}.html"); open(p,"w").write(html)
    out=f"{OUT}/{lang}/{name}.png"
    subprocess.run([CHROME,"--headless=new","--disable-gpu","--hide-scrollbars","--force-device-scale-factor=2",f"--window-size={w},{h}",f"--screenshot={out}",f"file://{p}"],check=True,capture_output=True)
    print(out)
for lang,t in T.items():
    render("concept",lang,concept(t),1200,760)
