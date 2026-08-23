#!/bin/bash
# 終端機版「請 GPT 做設計」：用 Codex CLI 跑文字任務（企劃／場景設計／素材清單／設定圖），產出直接寫進遊戲資料夾
#
# 用法（Git Bash）：
#   素材工作流/tools/gpt.sh "遊戲N-名稱" plan      # 做企劃   → plan.md（codex 以最後回覆交全文，腳本存檔；Windows 沙箱不放行寫檔）
#   素材工作流/tools/gpt.sh "遊戲N-名稱" scene     # 做場景設計 → scene.md
#   素材工作流/tools/gpt.sh "遊戲N-名稱" assets    # 做素材清單 → assets.gpt.json（Claude 再補「輸出」欄轉成 assets.json）
#   素材工作流/tools/gpt.sh "遊戲N-名稱" ref REF001 "挖土機角色設定圖：正側面主圖＋正面＋三個表情"   # 設定圖 → pic/_ref/REF001.png
#   素材工作流/tools/gpt.sh "遊戲N-名稱" ask "任何問題"                                            # 純文字問答（印出來）
#
# 前提：遊戲資料夾有 AGENTS.md（角色、畫風、鐵則、規格文件路徑）——codex 會自動讀，等於以前的 Project Instructions。
#       規格文件在 ../素材工作流/project-resources/，等於以前的 Sources；codex 用讀檔工具自己去讀。
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
GAME="$1"; TASK="$2"; shift 2
DIR="$REPO/$GAME"; W=$(cygpath -w "$DIR")
[ -f "$DIR/AGENTS.md" ] || { echo "請先建立 $DIR/AGENTS.md（可複製 遊戲3-挖土機挖挖樂/AGENTS.md 改畫風）"; exit 1; }
OUT="$REPO/素材工作流/_run/gpt-$TASK-$(date +%H%M%S).txt"; mkdir -p "$(dirname "$OUT")"
DOCS='先用讀檔工具讀 ../素材工作流/project-resources/ 裡的 00~05 六份規格，以及本資料夾裡已有的企劃／場景／現況文件，再動手。'

run_text() { # $1=prompt $2=sandbox
  timeout 900 codex exec "$1" -C "$W" -s "$2" --skip-git-repo-check -o "$(cygpath -w "$OUT")" </dev/null >/dev/null 2>&1
  cat "$OUT"
}
# Windows 版 codex 的 workspace-write 沙箱實測不放行寫檔（patch rejected），所以文件類任務一律請它把「完整內容」當最後回覆，
# 由這裡存檔；順手剝掉最外層的 ``` 圍欄。$1=prompt $2=目標檔名
run_doc() {
  timeout 900 codex exec "$1" -C "$W" -s read-only --skip-git-repo-check -o "$(cygpath -w "$OUT")" </dev/null >/dev/null 2>&1
  python - "$(cygpath -w "$OUT")" "$(cygpath -w "$DIR/$2")" <<'PY'
import sys,re
s=open(sys.argv[1],encoding='utf-8').read().strip()
m=re.match(r'^```[a-zA-Z]*\n(.*)\n```\s*$', s, re.S)
if m: s=m.group(1)
open(sys.argv[2],'w',encoding='utf-8').write(s+'\n')
print(f'→ {sys.argv[2]}  ({len(s)} 字)')
PY
  head -c 400 "$DIR/$2"; echo; echo ...
}
FINAL='你的「最後一則回覆」必須是這份文件的完整內容本身（從第一行標題到最後一行），前後不要加任何說明、問候或程式碼圍欄；不要嘗試寫檔，工作區是唯讀的。'

case "$TASK" in
  plan)
    run_doc "$DOCS 請做企劃：照 04 第五節的企劃書格式寫出完整 Markdown。$FINAL" plan.md ;;
  scene)
    run_doc "$DOCS 請做場景設計：照 04 第六節格式，以 plan.md 為準，寫出完整 Markdown。$FINAL" scene.md ;;
  assets)
    run_doc "$DOCS 請做素材清單：照 04 第三節 schema，以 plan.md 與 scene.md 為準，輸出可直接 parse 的 JSON。每個 prompt 都要引用對應的設定圖檔名（REFxxx.png），結尾一律加上洋紅底那句，輸出欄一律 {}。$FINAL" assets.gpt.json ;;
  ref)
    ID="$1"; DESC="$2"
    before=$(ls -d ~/.codex/generated_images/*/ 2>/dev/null | sort)
    timeout 300 codex exec "\$imagegen 這是一張設定圖（不是遊戲素材）：$DESC。照 AGENTS.md 的畫風；設定圖背景用白色或淺灰即可；圖上不要有任何文字、編號、標籤、箭頭。" -C "$W" -s read-only --skip-git-repo-check </dev/null >/dev/null 2>&1
    after=$(ls -d ~/.codex/generated_images/*/ 2>/dev/null | sort)
    png=$(ls -t "$(comm -13 <(echo "$before") <(echo "$after") | tail -1)"*.png 2>/dev/null | head -1)
    [ -n "$png" ] && mkdir -p "$DIR/pic/_ref" && cp "$png" "$DIR/pic/_ref/$ID.png" && echo "OK → pic/_ref/$ID.png" || echo "FAIL：沒有產出圖" ;;
  ask)
    run_text "先不要生圖，用文字回答：$1" read-only ;;
  *) echo "未知任務 $TASK（plan|scene|assets|ref|ask）"; exit 1 ;;
esac
