#!/usr/bin/env python3
"""`fleetest api remote-compat` の JSON(stdin)から、e2e.sh --align が撃つ align の計画を出す。

出力は1行1件の `action|host|reason`(`|` は区切りなので理由からは除去する):
  align|<machine>|            揃える(ランナーがこの clone の祖先 = remoteBehind のときだけ)
  skip|<machine>|<説明>       触らない。**説明は必ず出す** —— 黙って飛ばすと、揃えたつもりで
                              プロファイルが開始前に落ちる理由が分からなくなる

契約: 判定の定義元は `FTCore.RevisionRelation` / `RemoteCompat.classifyRelation`(Swift)。
ここは**その分類を行動へ写すだけ**で、独自に祖先関係を計算しない(2つ目の実装を作らない)。
`revisionRelation` は **published のときだけ**入る(未 push の rev は align 案内が誤誘導になるため
Swift 側が nil にする)= nil を「揃えてよい」と読まない。
"""
import json
import sys

label = sys.argv[1] if len(sys.argv) > 1 else ""


def emit(action, host, reason=""):
    print("%s|%s|%s" % (action, host, reason.replace("|", "/")))


try:
    data = json.load(sys.stdin)
except Exception as e:  # 解釈できない出力を「揃えるものなし」に化けさせない
    sys.stderr.write("cannot parse remote-compat JSON: %s\n" % e)
    raise SystemExit(2)

published = data.get("revisionPublished", True)
for m in data.get("machines", []):
    host = m.get("machine") or m.get("sshTarget") or "?"
    where = "%s %s" % (label, host)
    if not m.get("reachable"):
        emit("skip", host, "%s: 到達できません(align では直りません): %s"
             % (where, (m.get("error") or "reason unknown")))
        continue
    if m.get("toolchainCompatible") is False:
        emit("skip", host, "%s: toolchain が違います(align では直りません。Xcode を揃える)" % where)
    if m.get("revisionCompatible") is False:
        relation = m.get("revisionRelation")
        if relation == "remoteBehind":
            emit("align", host)
        elif relation == "localBehind":
            emit("skip", host, "%s: この clone のほうが古いので触りません(先に自分を更新する)" % where)
        elif relation == "diverged":
            emit("skip", host, "%s: 版が分岐しています(ブランチ作業。共有ランナーでは解決しない)" % where)
        elif not published:
            emit("skip", host, "%s: HEAD が未 push なのでランナーが取得できません(先に push する)" % where)
        else:
            emit("skip", host, "%s: 版のズレの向きを判定できません(手で確認する)" % where)
