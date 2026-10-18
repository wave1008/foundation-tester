# 「レスポンス計測」のページの図(images/response_measurement/{ja,en}/*.png)を作り直す。文言は T の ja/en を対で直す。
# 実行: python3 docs/user-docs/images/response_measurement/gen_diagrams.py(Google Chrome のヘッドレスで 2 倍の PNG を書く)
# 部品と配色は images/fleet/gen_diagrams.py と揃える(あちらは import すると描画まで走るので写している)
import subprocess, os, tempfile
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
OUT=os.path.dirname(os.path.abspath(__file__))
FONT="'Hiragino Sans','Hiragino Kaku Gothic ProN','Helvetica Neue',Arial,sans-serif"
C=dict(ink="#1f2937",sub="#6b7280",line="#9ca3af",ft="#0e7490",ftBg="#e0f2fe",dev="#15803d",devBg="#dcfce7",
       file="#374151",fileBg="#f3f4f6",sb="#b45309",sbBg="#fffbeb",no="#b91c1c",noBg="#fee2e2")
def svg(w,h,body):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" font-family="{FONT}">
<defs><marker id="ahg" markerWidth="6" markerHeight="6" refX="5" refY="3" orient="auto"><path d="M0,0 L6,3 L0,6 z" fill="{C['dev']}"/></marker><marker id="ah" markerWidth="10" markerHeight="10" refX="9" refY="5" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="{C['line']}"/></marker></defs>
<rect width="{w}" height="{h}" fill="#ffffff" rx="16"/>{body}</svg>'''
def text(x,y,s,size=14,color=None,weight=400,anchor="start",mono=False):
    f=' font-family="Menlo,monospace" xml:space="preserve"' if mono else ""
    return f'<text x="{x}" y="{y}" text-anchor="{anchor}" font-size="{size}" font-weight="{weight}" fill="{color or C["ink"]}"{f}>{s}</text>'
def seg(x1,x2,y,h,fill,stroke,label=None,lc=None,dash=False):
    d=' stroke-dasharray="6 5"' if dash else ""
    s=f'<rect x="{x1}" y="{y}" width="{x2-x1}" height="{h}" rx="8" fill="{fill}" stroke="{stroke}" stroke-width="2"{d}/>'
    if label:
        s+=text((x1+x2)/2,y+h/2+5,label,13,lc or stroke,700,"middle")
    return s
def vline(x,y1,y2,color=None):
    return f'<line x1="{x}" y1="{y1}" x2="{x}" y2="{y2}" stroke="{color or C["line"]}" stroke-width="1.5" stroke-dasharray="4 4"/>'
def marker(x,y,color,label,anchor="middle"):
    # 下向きの三角 = その時刻に入力を注入した
    return (f'<path d="M{x-9},{y-14} L{x+9},{y-14} L{x},{y} z" fill="{color}"/>'
            +text(x,y-22,label,14,color,700,anchor))
def bracket(x1,x2,y,color,label):
    return (f'<path d="M{x1},{y-8} L{x1},{y} L{x2},{y} L{x2},{y-8}" fill="none" stroke="{color}" stroke-width="2.5"/>'
            +text(x2+10,y+5,label,15,color,700))
def rowlabel(y,label,sub=None):
    s=text(30,y,label,15,C["ink"],700)
    if sub: s+=text(30,y+20,sub,12,C["sub"])
    return s
def frames(x1,x2,y,step=18):
    return "".join(f'<rect x="{x}" y="{y}" width="8" height="34" rx="2" fill="{C["ft"]}"/>' for x in range(x1,x2,step))

T={
 "ja":dict(
   r_op="シナリオの操作", r_fr="アプリのフレーム", r_fr_sub="画面に出した絵",
   r_el="次に操作する要素", r_el_sub="例: 「マイページ」ボタン",
   wait="描画が止まるのを待つ(最長 10 秒)",
   inj="tap「ログイン」= 入力を注入", next="tap「マイページ」(次の操作)",
   anim="画面遷移のアニメーション", idle="描画なし",
   el_none="まだ無い", el_moving="見つかるが動いている", el_ready="押せる",
   ff="最初のフレームまで(firstFrameMs)", ready="操作可能まで(readyMs)",
   n1="「押せる」= 見つかる・有効・他の要素に覆われていない・止まっている",
   n2="時刻はすべて端末の時計で打つ(Mac と端末の通信の時間は入らない)",
   s_head="シナリオ", r_head="そのステップに残る値",
   steps=[('tap("ログイン")',None),('exist("ようこそ")',None),('tap("マイページ")',None),('tap("設定")',"最後の操作")],
   res=[("最初のフレームまで: 測る","操作可能まで: 「マイページ」が押せるまで"),
        ("測らない(検証のステップ)",None),
        ("最初のフレームまで: 測る","操作可能まで: 「設定」が押せるまで"),
        ("最初のフレームまで: 測る","操作可能まで: 出ない(次の操作が無い)")],
   s_note="操作可能まで は、シナリオで次に操作した要素で決まる(値は次の計測ステップで確定する)",
   m_op="入力の注入", m_el="次に操作する要素",
   m_inj=["1回目","2回目","3回目(最後)"],
   m_early="揃っても数えない", m_wait="揃っていない", m_ok="押せる",
   m_shade="最後の注入より前",
   m_note="1つの操作で何度も注入するステップ(繰り返しフリック等)は、最初の注入から測り、条件は最後の注入より後で揃ったものだけを数える",
 ),
 "en":dict(
   r_op="Scenario actions", r_fr="App frames", r_fr_sub="Pictures presented",
   r_el="Element operated next", r_el_sub="e.g. the My page button",
   wait="Wait until drawing stops (≤ 10 s)",
   inj="tap \"Log in\" = input injected", next="tap \"My page\" (next action)",
   anim="Screen transition animation", idle="No drawing",
   el_none="Not there yet", el_moving="Found but moving", el_ready="Can be pressed",
   ff="Time to first frame (firstFrameMs)", ready="Time until ready (readyMs)",
   n1="\"Can be pressed\" = found, enabled, not covered by another element, not moving",
   n2="All times are taken on the device's clock (Mac-to-device communication is not included)",
   s_head="Scenario", r_head="Values kept for the step",
   steps=[('tap("Log in")',None),('exist("Welcome")',None),('tap("My page")',None),('tap("Settings")',"last action")],
   res=[("Time to first frame: measured","Time until ready: until My page can be pressed"),
        ("Not measured (verification step)",None),
        ("Time to first frame: measured","Time until ready: until Settings can be pressed"),
        ("Time to first frame: measured","Time until ready: none (no next action)")],
   s_note="Time until ready is decided by the element the scenario operates next (the value arrives with the next measured step)",
   m_op="Input injections", m_el="Element operated next",
   m_inj=["1st","2nd","3rd (last)"],
   m_early="Met, but not counted", m_wait="Not met", m_ok="Can be pressed",
   m_shade="Before the last injection",
   m_note="A step that injects input several times (repeated flicks, …) is measured from the first injection; only conditions met after the last injection count",
 ),
}

def timeline(t):
    W,H=1200,520
    t0,t1,t2,t3=560,610,900,1080
    b=rowlabel(90,t["r_op"])+rowlabel(180,t["r_fr"],t["r_fr_sub"])+rowlabel(270,t["r_el"],t["r_el_sub"])
    b+=vline(t0,66,430,C["ft"])+vline(t1,150,430,C["ft"])+vline(t2,240,430,C["dev"])+vline(t3,66,300)
    b+=seg(235,t0-12,72,34,C["sbBg"],C["sb"],t["wait"],dash=True)
    b+=marker(t0,64,C["ft"],t["inj"])
    b+=marker(t3,64,C["ink"],t["next"])
    # フレーム: 待ちの間は描画なし → 注入の後に遷移のアニメーション → 止まる
    b+=text(391,203,t["idle"],13,C["sub"],400,"middle")
    b+=f'<rect x="{t1}" y="160" width="8" height="34" rx="2" fill="{C["no"]}"/>'
    b+=frames(t1+18,880,160)
    b+=text(745,150,t["anim"],13,C["ft"],700,"middle")
    b+=seg(t0,680,252,34,C["fileBg"],C["line"],t["el_none"],C["sub"])
    b+=seg(680,t2,252,34,C["sbBg"],C["sb"],t["el_moving"])
    b+=seg(t2,1160,252,34,C["devBg"],C["dev"],t["el_ready"])
    b+=bracket(t0,t1,350,C["no"],t["ff"])
    b+=bracket(t0,t2,410,C["dev"],t["ready"])
    b+=text(30,470,t["n1"],14,C["ink"])
    b+=text(30,498,t["n2"],14,C["sub"])
    return svg(W,H,b)

def steps(t):
    W,H=1200,450
    b=text(90,50,t["s_head"],15,C["ink"],700)+text(620,50,t["r_head"],15,C["ink"],700)
    ys=[70,150,230,310]
    for i,((code,tag),(a,r)) in enumerate(zip(t["steps"],t["res"])):
        y=ys[i]
        fill,stroke=(C["ftBg"],C["ft"]) if i!=1 else (C["fileBg"],C["line"])
        b+=f'<rect x="90" y="{y}" width="440" height="60" rx="10" fill="{fill}" stroke="{stroke}" stroke-width="2"/>'
        b+=text(110,y+37,f"{i+1}. {code}",17,C["ink"],400,mono=True)
        if tag: b+=text(512,y+37,tag,13,C["sub"],400,"end")
        b+=f'<line x1="534" y1="{y+30}" x2="610" y2="{y+30}" stroke="{C["line"]}" stroke-width="2" marker-end="url(#ah)"/>'
        if r is None:
            b+=text(620,y+36,a,15,C["sub"])
        else:
            b+=text(620,y+24,a,15,C["no"],700)
            col=C["sub"] if i==3 else C["dev"]
            b+=text(620,y+48,r,15,col,700)
    # 操作可能まで の行き先: 3 → 1、4 → 3(次に操作した要素)
    b+=f'<path d="M88,{ys[2]+22} C20,{ys[2]+22} 20,{ys[0]+38} 84,{ys[0]+38}" fill="none" stroke="{C["dev"]}" stroke-width="2.5" stroke-dasharray="6 5" marker-end="url(#ahg)"/>'
    b+=f'<path d="M88,{ys[3]+22} C45,{ys[3]+22} 45,{ys[2]+44} 84,{ys[2]+44}" fill="none" stroke="{C["dev"]}" stroke-width="2.5" stroke-dasharray="6 5" marker-end="url(#ahg)"/>'
    b+=text(40,420,"⤴ "+t["s_note"],14,C["dev"])
    return svg(W,H,b)

def multi(t):
    W,H=1200,400
    i1,i2,i3,ready=360,520,680,900
    b=rowlabel(90,t["m_op"])+rowlabel(190,t["m_el"])
    b+=f'<rect x="{i1}" y="40" width="{i3-i1}" height="260" fill="{C["noBg"]}" opacity="0.45"/>'
    b+=text((i1+i3)/2,295,t["m_shade"],13,C["no"],700,"middle")
    for x,l in zip((i1,i2,i3),t["m_inj"]):
        b+=marker(x,110,C["ft"],l)
        b+=vline(x,110,340,C["ft"])
    b+=vline(ready,190,340,C["dev"])
    b+=seg(i1+20,i2-50,172,34,C["fileBg"],C["line"],t["m_wait"],C["sub"])
    b+=seg(i2-40,i2+120,172,34,C["devBg"],C["dev"],t["m_early"],C["no"],dash=True)
    b+=seg(i3,ready,172,34,C["fileBg"],C["line"],t["m_wait"],C["sub"])
    b+=seg(ready,1160,172,34,C["devBg"],C["dev"],t["m_ok"])
    b+=bracket(i1,ready,345,C["dev"],t["ready"])
    b+=text(30,385,t["m_note"],13,C["sub"])
    return svg(W,H,b)

def render(name,lang,svgtext,w,h):
    os.makedirs(f"{OUT}/{lang}",exist_ok=True)
    html=f"<html><body style='margin:0;background:#fff'>{svgtext}</body></html>"
    p=os.path.join(tempfile.gettempdir(),f"ft_diagram_rm_{name}_{lang}.html"); open(p,"w").write(html)
    out=f"{OUT}/{lang}/{name}.png"
    subprocess.run([CHROME,"--headless=new","--disable-gpu","--hide-scrollbars","--force-device-scale-factor=2",f"--window-size={w},{h}",f"--screenshot={out}",f"file://{p}"],check=True,capture_output=True)
    print(out)
for lang,t in T.items():
    render("timeline",lang,timeline(t),1200,520)
    render("steps",lang,steps(t),1200,450)
    render("multi_injection",lang,multi(t),1200,400)
