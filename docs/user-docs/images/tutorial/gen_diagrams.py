# チュートリアルの概念図(images/tutorial/{ja,en}/*.png)を作り直す。文言は T の ja/en を対で直す。
# 実行: python3 docs/user-docs/images/tutorial/gen_diagrams.py(Google Chrome のヘッドレスで 2 倍の PNG を書く)
import subprocess, os, sys, tempfile
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
OUT=os.path.dirname(os.path.abspath(__file__))
FONT="'Hiragino Sans','Hiragino Kaku Gothic ProN','Helvetica Neue',Arial,sans-serif"
C=dict(ink="#1f2937",sub="#6b7280",line="#9ca3af",ai="#7c3aed",aiBg="#f3e8ff",ft="#0e7490",ftBg="#e0f2fe",dev="#15803d",devBg="#dcfce7",you="#b45309",youBg="#fef3c7",file="#374151",fileBg="#f3f4f6")
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
def arrow(x1,y1,x2,y2,label=None,lx=None,ly=None,color=None,anchor="middle"):
    color=color or C["line"]
    s=f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{color}" stroke-width="2.5" marker-end="url(#ah)"/>'
    if label:
        lx=lx if lx is not None else (x1+x2)/2; ly=ly if ly is not None else (y1+y2)/2-10
        s+=f'<text x="{lx}" y="{ly}" text-anchor="{anchor}" font-size="14" fill="{C["ink"]}">{label}</text>'
    return s
def svg(w,h,body):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" font-family="{FONT}">
<defs><marker id="ah" markerWidth="10" markerHeight="10" refX="9" refY="5" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="{C['line']}"/></marker></defs>
<rect width="{w}" height="{h}" fill="#ffffff" rx="16"/>{body}</svg>'''
def lane(x,y,w,h,label,color):
    return (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="16" fill="none" stroke="#e5e7eb" stroke-width="2" stroke-dasharray="6 6"/>'
            f'<text x="{x+18}" y="{y+30}" font-size="17" font-weight="700" fill="{color}">{label}</text>')

T={
 "ja":dict(
   make="① テストを作る(AI アシスタントが働く)", play="② テストを再生する(AI は使わない)",
   you="あなた", ai="AI アシスタント", aisub="Claude Code など", ft="fleetest", ftsub="MCP サーバ", dev="デバイス", devsub="仮想デバイス・実機",
   ask="自然言語で頼む", op="画面を読む・操作する", write="書く", sc="シナリオ", scsub=".swift ファイル",
   ft2sub="決定的に再生", devs="デバイス群", devssub="並列に実行", rep="レポート", repsub="結果・スクリーンショット",
   read="AI アシスタントが読んで報告", same="毎回同じ動き・推論の待ちも利用料も無し",
   s=["画面を操作して\n読む","シナリオを書く","コンパイル","dry-run","デバイスで実行","結果を報告"],
   ssub=["実在する要素だけ","","数秒","デバイス不要","",""],
   flow="依頼を受けた AI アシスタントの作業の流れ",
   par_t="シナリオ", par_d="デバイス", par_q="実行プロファイルのデバイスへ自動で振り分け", par_note="シナリオ側の変更は不要",
 ),
 "en":dict(
   make="1. Creating tests (the AI assistant works)", play="2. Replaying tests (no AI involved)",
   you="You", ai="AI assistant", aisub="Claude Code, etc.", ft="fleetest", ftsub="MCP server", dev="Device", devsub="Virtual or physical",
   ask="Ask in natural language", op="Operate the screen", write="writes", sc="Scenario", scsub=".swift file",
   ft2sub="Deterministic replay", devs="Devices", devssub="Run in parallel", rep="Report", repsub="Results, screenshots",
   read="The AI assistant reads it\nand reports back", same="Same behavior every time,\nno inference wait, no API fees",
   s=["Operate and\nread the screen","Write the\nscenario","Compile","dry-run","Run on\na device","Report\nthe result"],
   ssub=["Real elements only","","Seconds","No device","",""],
   flow="What the AI assistant does after you ask",
   par_t="Scenarios", par_d="Devices", par_q="Distributed automatically across the run profile's devices", par_note="No changes to scenarios needed",
 )}

def overview(t):
    W,H=1200,520
    b=lane(20,20,W-40,230,t["make"],C["ai"])
    b+=box(40,90,150,90,C["youBg"],C["you"],t["you"])
    b+=box(370,90,200,90,C["aiBg"],C["ai"],t["ai"],t["aisub"])
    b+=box(750,90,170,90,C["ftBg"],C["ft"],t["ft"],t["ftsub"])
    b+=box(1010,90,150,90,C["devBg"],C["dev"],t["dev"],t["devsub"],ts=19)
    b+=arrow(192,135,366,135,t["ask"],ly=122)
    b+=arrow(572,135,746,135,t["op"],ly=122)
    b+=arrow(922,135,1006,135)
    b+=f'<line x1="470" y1="182" x2="470" y2="296" stroke="{C["ai"]}" stroke-width="2.5" stroke-dasharray="5 5" marker-end="url(#ah)"/>'
    b+=f'<text x="482" y="228" font-size="14" fill="{C["ai"]}">{t["write"]}</text>'
    b+=lane(20,270,W-40,230,t["play"],C["ft"])
    for i,l in enumerate(t["same"].split("\n")):
        b+=f'<text x="40" y="{324+i*20}" font-size="14" fill="{C["sub"]}">{l}</text>'
    b+=box(370,300,200,80,C["fileBg"],C["file"],t["sc"],t["scsub"])
    b+=box(750,300,170,80,C["ftBg"],C["ft"],t["ft"],t["ft2sub"])
    b+=box(1010,300,150,80,C["devBg"],C["dev"],t["devs"],t["devssub"],ts=19)
    b+=arrow(572,340,746,340)
    b+=arrow(922,340,1006,340)
    b+=box(750,410,170,70,C["fileBg"],C["file"],t["rep"],t["repsub"],ts=18)
    b+=arrow(1085,382,924,428)
    b+=arrow(746,445,574,445)
    b+=box(300,410,270,70,C["aiBg"],C["ai"],t["read"],None,ts=15)
    return svg(W,H,b)

def steps(t):
    W,H=1100,200
    b=f'<text x="30" y="40" font-size="18" font-weight="700" fill="{C["ink"]}">{t["flow"]}</text>'
    n=len(t["s"]); bw=152; gap=(W-60-n*bw)/(n-1); y=70
    cols=[(C["devBg"],C["dev"]),(C["aiBg"],C["ai"]),(C["ftBg"],C["ft"]),(C["ftBg"],C["ft"]),(C["devBg"],C["dev"]),(C["youBg"],C["you"])]
    for i,(s,ss) in enumerate(zip(t["s"],t["ssub"])):
        x=30+i*(bw+gap)
        b+=box(x,y,bw,90,cols[i][0],cols[i][1],s,ss or None,ts=15)
        if i<n-1: b+=arrow(x+bw+2,y+45,x+bw+gap-4,y+45)
    return svg(W,H,b)

def parallel(t):
    W,H=1100,380
    b=f'<text x="60" y="45" font-size="17" font-weight="700" fill="{C["file"]}">{t["par_t"]}</text>'
    b+=f'<text x="820" y="45" font-size="17" font-weight="700" fill="{C["dev"]}">{t["par_d"]}</text>'
    names=["S0010","S0020","S0030","S0040","S0050","S0060"]
    for i,nm in enumerate(names):
        b+=box(60,65+i*48,170,38,C["fileBg"],C["file"],nm,None,r=8,ts=16)
    b+=box(390,140,260,110,C["ftBg"],C["ft"],"fleetest",None,ts=22)
    b+=f'<text x="520" y="285" text-anchor="middle" font-size="14" fill="{C["ink"]}">{t["par_q"]}</text>'
    b+=f'<text x="520" y="308" text-anchor="middle" font-size="14" fill="{C["sub"]}">{t["par_note"]}</text>'
    for i in range(6): b+=arrow(232,84+i*48,386,195)
    devs=[("iPhone 17 Pro",["S0010","S0040"]),("iPhone 17 Pro-01",["S0020","S0050"]),("iPhone 17 Pro-02",["S0030","S0060"])]
    for i,(d,ss) in enumerate(devs):
        y=70+i*100
        b+=box(820,y,230,80,C["devBg"],C["dev"],d,", ".join(ss),ts=16)
        b+=arrow(652,195,816,y+40)
    return svg(W,H,b)

def render(name,lang,svgtext,w,h):
    os.makedirs(f"{OUT}/{lang}",exist_ok=True)
    html=f"<html><body style='margin:0;background:#fff'>{svgtext}</body></html>"
    p=os.path.join(tempfile.gettempdir(),f"ft_diagram_{name}_{lang}.html"); open(p,"w").write(html)
    out=f"{OUT}/{lang}/{name}.png"
    subprocess.run([CHROME,"--headless=new","--disable-gpu","--hide-scrollbars","--force-device-scale-factor=2",f"--window-size={w},{h}",f"--screenshot={out}",f"file://{p}"],check=True,capture_output=True)
    print(out)
for lang,t in T.items():
    render("how_it_works",lang,overview(t),1200,520)
    render("ai_workflow",lang,steps(t),1100,200)
    render("parallel_run",lang,parallel(t),1100,380)
