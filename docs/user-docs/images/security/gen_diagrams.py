# セキュリティの章の概念図(images/security/{ja,en}/*.png)を作り直す。文言は T の ja/en を対で直す。
# 実行: python3 docs/user-docs/images/security/gen_diagrams.py(Google Chrome のヘッドレスで 2 倍の PNG を書く)
# 部品と配色は images/tutorial/gen_diagrams.py と揃える(あちらは import すると描画まで走るので写している)
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
    color=color or C["line"]; marker="ahn" if color==C["no"] else "ah"
    d=' stroke-dasharray="6 5"' if dash else ""
    s=f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{color}" stroke-width="2.5"{d} marker-end="url(#{marker})"/>'
    if label:
        lx=lx if lx is not None else (x1+x2)/2; ly=ly if ly is not None else (y1+y2)/2-10
        s+=f'<text x="{lx}" y="{ly}" text-anchor="{anchor}" font-size="14" fill="{C["ink"]}">{label}</text>'
    return s
def svg(w,h,body):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" font-family="{FONT}">
<defs><marker id="ah" markerWidth="10" markerHeight="10" refX="9" refY="5" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="{C['line']}"/></marker>
<marker id="ahn" markerWidth="10" markerHeight="10" refX="9" refY="5" orient="auto"><path d="M0,0 L10,5 L0,10 z" fill="{C['no']}"/></marker></defs>
<rect width="{w}" height="{h}" fill="#ffffff" rx="16"/>{body}</svg>'''
def lane(x,y,w,h,label,color,stroke="#e5e7eb",fill="none"):
    return (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="16" fill="{fill}" stroke="{stroke}" stroke-width="2" stroke-dasharray="6 6"/>'
            f'<text x="{x+18}" y="{y+30}" font-size="17" font-weight="700" fill="{color}">{label}</text>')

T={
 "ja":dict(
   mac="この Mac", sandbox="サンドボックス(Seatbelt)", sc="シナリオ", scsub="あなたのシナリオ(.swift)",
   w="✓ 書ける: TestLog のフォルダ", r="✓ 読める: プロジェクト・データセット",
   deny="サンドボックスが断る",
   d=[("✕ 秘密の読み取り","~/.ssh・キーチェーン など"),("✕ 任意の場所への書き込み","ソース・ホーム・/tmp"),
      ("✕ 他のアプリの起動","open -a など"),("✕ 環境変数のトークン","シェル・.mcp.json の env")],
   ask="デバイス操作の依頼・\n外部への通信",
   ft="fleetest 本体(枠の外)", broker="デバイス操作の代行", brokersub="決まった形の操作だけ実行",
   proxy="プロキシ", proxysub="allowedDomains の宛先だけ中継",
   dev="デバイス", devsub="Simulator・Emulator・実機", bridge="ブリッジ(localhost)",
   ok="許可した宛先", oksub="API・社内のサーバ", ng="✕ 許可していない宛先", ngsub="インターネット・LAN",
   note="設定はこの Mac の ~/.config/fleetest/config.json だけ(プロジェクトからは緩められない)",
   fcols=[("作業フォルダ",[("W","★ レポートの出力先","TestLog.directoryForLog"),("W","作業フォルダ・プロジェクトの .fleetest/","hooks/ など本体が実行するものは書けない"),
                           ("R","シナリオのソース・dataset/","TestProjects/&lt;プロジェクト&gt;/"),("R","fleetest 本体のクローン",None)]),
          ("ホーム(~)",[("D","~/.ssh・~/.aws・~/.gnupg など","認証情報・鍵・シェルの履歴"),("D","~/.config","下の fleetest を除く"),
                         ("R","~/.config/fleetest","設定・この Mac だけのデータセット"),("D","キーチェーン・ブラウザ・メール","~/Library の下"),
                         ("W","~/.fleetest など","~/Library/Caches/fleetest など fleetest が使う場所"),("R","その他(~/Documents など)",None)]),
          ("一時フォルダ・その他",[("W","★ シナリオ専用の一時フォルダ","TestLog.directoryForTemp"),("R","/tmp・NSTemporaryDirectory()","書けない"),
                         ("W","使っている Simulator のアプリのデータ","clearAppData のため(その1台だけ)"),("R","システム(/System・/Applications)",None)])],
   legend=[("W","書ける(読める)"),("R","読めるだけ"),("D","読めない")], star="★ シナリオのコードから書くのはこの2つ",
   fnote="読めない場所は ~/.config/fleetest/config.json の sandbox.denyRead で足せます(既定の一覧は網羅ではありません)",
   net=dict(mac="この Mac", out="Mac の外", sc="シナリオ", scsub="サンドボックスの中",
     lh="localhost のサービス", lhsub="ブリッジ など", adb="✕ adb サーバ・Emulator のポート", adbsub="5037・5554〜5585(adb は本体が代行)",
     proxy="fleetest 本体のプロキシ", proxysub="127.0.0.1・allowedDomains と照合", env="HTTP(S)_PROXY",
     warn="⚠ localhost のローカルプロキシや\nデバッグポートは迂回路になる",
     ios="Wi-Fi で繋いだ iOS 実機", iossub="そのブリッジのポートだけ", ok="allowedDomains の宛先", oksub="例: api.example.com:443",
     ng="✕ それ以外の宛先", ngsub="インターネット・社内 LAN", relay="中継", deny="403", direct="直接は ✕(UDP・自作の URLSession など)",
     note="httpRequest と fleetestURLSession はプロキシを設定済み。自分で作った URLSession は環境変数のプロキシを読みません"),
 ),
 "en":dict(
   mac="This Mac", sandbox="Sandbox (Seatbelt)", sc="Scenario", scsub="Your scenarios (.swift)",
   w="✓ Write: TestLog folders", r="✓ Read: project, datasets",
   deny="Refused by the sandbox",
   d=[("✕ Reading secrets","~/.ssh, keychain, ..."),("✕ Writing anywhere","sources, home, /tmp"),
      ("✕ Starting other apps","open -a, ..."),("✕ Tokens in env vars","shell, env in .mcp.json")],
   ask="Device operation requests,\noutbound traffic",
   ft="fleetest itself (outside)", broker="Device operations", brokersub="Runs only fixed forms",
   proxy="Proxy", proxysub="Relays only to allowedDomains",
   dev="Devices", devsub="Simulator, Emulator, physical", bridge="Bridge (localhost)",
   ok="Allowed destinations", oksub="APIs, company servers", ng="✕ Other destinations", ngsub="Internet, LAN",
   note="Settings live only in ~/.config/fleetest/config.json on this Mac (projects cannot loosen them)",
   fcols=[("Work folder",[("W","★ Report directory","TestLog.directoryForLog"),("W",".fleetest/ in work folder and project","not hooks/ etc. that fleetest runs"),
                           ("R","Scenario sources, dataset/","TestProjects/&lt;project&gt;/"),("R","The fleetest clone",None)]),
          ("Home (~)",[("D","~/.ssh, ~/.aws, ~/.gnupg, ...","credentials, keys, shell history"),("D","~/.config","except fleetest below"),
                         ("R","~/.config/fleetest","settings, this Mac's datasets"),("D","Keychain, browsers, mail","under ~/Library"),
                         ("W","~/.fleetest, ...","~/Library/Caches/fleetest etc. used by fleetest"),("R","Everything else (~/Documents, ...)",None)]),
          ("Temporary and others",[("W","★ Per-scenario temporary folder","TestLog.directoryForTemp"),("R","/tmp, NSTemporaryDirectory()","not writable"),
                         ("W","App data of the Simulator in use","for clearAppData (that one only)"),("R","System (/System, /Applications)",None)])],
   legend=[("W","Writable (and readable)"),("R","Read only"),("D","Unreadable")], star="★ The only two your scenario code should write to",
   fnote="Add unreadable places with sandbox.denyRead in ~/.config/fleetest/config.json (the default list is not exhaustive)",

   net=dict(mac="This Mac", out="Outside the Mac", sc="Scenario", scsub="inside the sandbox",
     lh="Services on localhost", lhsub="bridges, ...", adb="✕ adb server, Emulator ports", adbsub="5037, 5554–5585 (fleetest runs adb)",
     proxy="fleetest's proxy", proxysub="127.0.0.1, checks allowedDomains", env="HTTP(S)_PROXY",
     warn="⚠ Local proxies and debug ports\non localhost are bypasses",
     ios="Physical iOS device on Wi-Fi", iossub="its bridge port only", ok="allowedDomains", oksub="e.g. api.example.com:443",
     ng="✕ Other destinations", ngsub="internet, company LAN", relay="relay", deny="403", direct="Direct ✕ (UDP, your own URLSession, ...)",
     note="httpRequest and fleetestURLSession already use the proxy. A URLSession you create does not read the proxy from env vars"),
 )}

def sandbox(t):
    W,H=1200,660
    b=lane(20,20,880,620,t["mac"],C["ink"])
    # 断られるもの(左の列)
    b+=f'<text x="150" y="82" text-anchor="middle" font-size="16" font-weight="700" fill="{C["no"]}">{t["deny"]}</text>'
    for i,(title,sub) in enumerate(t["d"]):
        b+=box(40,100+i*80,220,64,C["noBg"],C["no"],title,sub,r=10,ts=15)
    # サンドボックス
    b+=lane(290,70,330,280,t["sandbox"],C["sb"],stroke=C["sb"],fill=C["sbBg"])
    b+=box(310,115,290,90,"#ffffff",C["sb"],t["sc"],t["scsub"])
    b+=box(310,222,290,48,C["devBg"],C["dev"],t["w"],None,r=10,ts=15)
    b+=box(310,282,290,48,C["devBg"],C["dev"],t["r"],None,r=10,ts=15)
    # 本体へ
    b+=arrow(455,352,455,396)
    for i,l in enumerate(t["ask"].split("\n")):
        b+=f'<text x="470" y="{372+i*18}" font-size="14" fill="{C["ink"]}">{l}</text>'
    b+=lane(290,400,330,180,t["ft"],C["ft"],stroke=C["ft"],fill="#f8fdff")
    b+=box(310,440,290,60,C["ftBg"],C["ft"],t["broker"],t["brokersub"],r=10,ts=16)
    b+=box(310,512,290,60,C["ftBg"],C["ft"],t["proxy"],t["proxysub"],r=10,ts=16)
    # 右側: デバイスと宛先
    b+=box(930,90,250,110,C["devBg"],C["dev"],t["dev"],t["devsub"])
    b+=arrow(602,150,926,145,t["bridge"],ly=135)
    b+=arrow(602,470,955,204)
    b+=box(930,250,250,80,C["noBg"],C["no"],t["ng"],t["ngsub"],r=12,ts=17)
    b+=arrow(622,300,926,290,color=C["no"],dash=True)
    b+=box(930,450,250,90,C["fileBg"],C["file"],t["ok"],t["oksub"],r=12,ts=18)
    b+=arrow(602,542,926,500)
    b+=f'<text x="40" y="622" font-size="13" fill="{C["sub"]}">{t["note"]}</text>'
    return svg(W,H,b)

def folders(t):
    W,H=1200,660
    col={"W":(C["devBg"],C["dev"]),"R":(C["fileBg"],C["file"]),"D":(C["noBg"],C["no"])}
    b=""
    for ci,(title,items) in enumerate(t["fcols"]):
        x=30+ci*390
        b+=f'<text x="{x+175}" y="44" text-anchor="middle" font-size="18" font-weight="700" fill="{C["ink"]}">{title}</text>'
        for ri,(k,name,sub) in enumerate(items):
            fill,stroke=col[k]
            b+=box(x,62+ri*74,350,62,fill,stroke,name,sub,r=10,ts=15)
            if name.startswith("★"):
                b+=f'<rect x="{x-3}" y="{62+ri*74-3}" width="356" height="68" rx="12" fill="none" stroke="{stroke}" stroke-width="2"/>'
    y=548; x=30
    for k,label in t["legend"]:
        fill,stroke=col[k]
        b+=f'<rect x="{x}" y="{y}" width="28" height="20" rx="5" fill="{fill}" stroke="{stroke}" stroke-width="2"/>'
        b+=f'<text x="{x+38}" y="{y+16}" font-size="15" fill="{C["ink"]}">{label}</text>'
        x+=240
    b+=f'<text x="{x}" y="{y+16}" font-size="15" font-weight="700" fill="{C["dev"]}">{t["star"]}</text>'
    b+=f'<text x="30" y="612" font-size="14" fill="{C["sub"]}">{t["fnote"]}</text>'
    return svg(W,H,b)

def network(t):
    n=t["net"]; W,H=1200,700
    b=lane(20,20,760,610,n["mac"],C["ink"])
    b+=lane(800,180,390,380,n["out"],C["ink"])
    b+=lane(30,250,250,135,"",C["sb"],stroke=C["sb"],fill=C["sbBg"])
    b+=box(45,262,220,110,"#ffffff",C["sb"],n["sc"],n["scsub"])
    b+=box(420,60,320,75,C["devBg"],C["dev"],n["lh"],n["lhsub"],r=10,ts=17)
    b+=box(420,160,320,75,C["noBg"],C["no"],n["adb"],n["adbsub"],r=10,ts=15)
    b+=box(420,300,320,80,C["ftBg"],C["ft"],n["proxy"],n["proxysub"],r=10,ts=17)
    b+=box(420,550,320,70,"#fffbeb",C["sb"],n["warn"],None,r=10,ts=14)
    b+=box(830,230,340,70,C["devBg"],C["dev"],n["ios"],n["iossub"],r=10,ts=16)
    b+=box(830,330,340,80,C["devBg"],C["dev"],n["ok"],n["oksub"],r=10,ts=17)
    b+=box(830,450,340,80,C["noBg"],C["no"],n["ng"],n["ngsub"],r=10,ts=17)
    b+=arrow(282,280,416,100)
    b+=arrow(282,300,416,200,color=C["no"],dash=True)
    b+=arrow(282,292,826,267)
    b+=arrow(282,325,416,340)
    b+=f'<text x="335" y="358" text-anchor="middle" font-size="12" fill="{C["sub"]}">{n["env"]}</text>'
    b+=arrow(742,335,826,368,n["relay"],lx=784,ly=338)
    b+=arrow(742,365,826,482,color=C["no"],dash=True)
    b+=f'<text x="770" y="445" text-anchor="end" font-size="13" font-weight="700" fill="{C["no"]}">{n["deny"]}</text>'
    b+=arrow(155,387,826,505,color=C["no"],dash=True)
    b+=f'<text x="300" y="488" font-size="13" fill="{C["no"]}">{n["direct"]}</text>'
    b+=f'<text x="30" y="668" font-size="13" fill="{C["sub"]}">{n["note"]}</text>'
    return svg(W,H,b)

def render(name,lang,svgtext,w,h):
    os.makedirs(f"{OUT}/{lang}",exist_ok=True)
    html=f"<html><body style='margin:0;background:#fff'>{svgtext}</body></html>"
    p=os.path.join(tempfile.gettempdir(),f"ft_diagram_{name}_{lang}.html"); open(p,"w").write(html)
    out=f"{OUT}/{lang}/{name}.png"
    subprocess.run([CHROME,"--headless=new","--disable-gpu","--hide-scrollbars","--force-device-scale-factor=2",f"--window-size={w},{h}",f"--screenshot={out}",f"file://{p}"],check=True,capture_output=True)
    print(out)
for lang,t in T.items():
    render("sandbox",lang,sandbox(t),1200,660)
    render("folders",lang,folders(t),1200,660)
    render("network",lang,network(t),1200,700)
