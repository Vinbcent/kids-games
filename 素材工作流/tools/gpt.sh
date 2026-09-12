#!/bin/bash
# 終端機版「請 GPT 做設計」：用 Codex CLI 跑文字任務（企劃／場景設計／素材清單／設定圖），產出直接寫進遊戲資料夾
#
# 用法（Git Bash）：
#   素材工作流/tools/gpt.sh "遊戲N-名稱" plan      # 做企劃   → plan.md
#   素材工作流/tools/gpt.sh "遊戲N-名稱" scene     # 做場景設計 → scene.md
#   素材工作流/tools/gpt.sh "遊戲N-名稱" assets    # 做素材清單 → assets.gpt.json
#   素材工作流/tools/gpt.sh "遊戲N-名稱" ref REF001 "挖土機角色設定圖：正側面主圖＋正面＋三個表情"   # → pic/_ref/REF001.png
#   素材工作流/tools/gpt.sh "遊戲N-名稱" ask "任何問題"        # 純文字問答（印出來）
#   素材工作流/tools/gpt.sh "遊戲N-名稱" doc 檔名.md "指示"     # 任意文件任務 → 該檔名
#
# 模型：預設 GPT-6 Astra（需 codex >= 0.154）。要換：GPT_MODEL=gpt-5.6-sol gpt.sh …
#
# 【2026-09-12 改版：文件一律內嵌，不再叫 codex 自己讀檔】
#   codex 0.154 在 Windows 上把 model 發出的 shell 指令全部擋掉（exec_command … rejected: blocked by policy），
#   read-only / workspace-write / disk-full-read-access 都一樣，所以它讀不到 AGENTS.md 也讀不到 project-resources。
#   解法：這支腳本把 AGENTS.md ＋ 00~05 規格 ＋ 本款現有文件串成 prompt 前綴，用 stdin 餵進去
#   （走 stdin 是為了避開 Windows 的命令列長度上限）。
set -u
M="${GPT_MODEL:-gpt-6-astra}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
GAME="$1"; TASK="$2"; shift 2
DIR="$REPO/$GAME"; W=$(cygpath -w "$DIR")
[ -f "$DIR/AGENTS.md" ] || { echo "請先建立 $DIR/AGENTS.md（可複製 遊戲2-水泥車大作戰/AGENTS.md 改畫風）"; exit 1; }
OUT="$REPO/素材工作流/_run/gpt-$TASK-$(date +%H%M%S).txt"; mkdir -p "$(dirname "$OUT")"

# 把一份文件包成帶檔名標頭的區塊
emit() { [ -f "$1" ] || return 0; echo; echo "===== 檔案：$(basename "$1") ====="; cat "$1"; echo; }
# 規格包：$1=full 時連 00~05 全附；否則只附 AGENTS.md 與美術規範（生圖用）
pack() {
  echo "以下是本專案的規格文件與現況文件，全文內嵌在這則訊息裡（你的 shell 工具在這台機器上被政策封鎖，讀檔會失敗，不要嘗試讀檔或搜尋）。讀完後直接做事。"
  emit "$DIR/AGENTS.md"
  if [ "${1:-full}" = full ]; then
    for f in "$REPO/素材工作流/project-resources/"0*.md; do emit "$f"; done
    for f in plan.md scene.md assets.json; do emit "$DIR/$f"; done
  else
    emit "$REPO/素材工作流/project-resources/03-美術規範與已知失敗模式.md"
  fi
  for f in "$@"; do case "$f" in full|art) ;; *) emit "$REPO/$f" ;; esac; done
}
FINAL='你的「最後一則回覆」必須是這份文件的完整內容本身（從第一行標題到最後一行），前後不要加任何說明、問候或程式碼圍欄。不要嘗試寫檔或讀檔。'

# $1=prompt  → 純文字，印出來
run_text() {
  { pack full; echo; echo "===== 任務 ====="; echo "$1"; } \
    | timeout 900 codex exec -m "$M" -C "$W" -s read-only --skip-git-repo-check -o "$(cygpath -w "$OUT")" >/dev/null 2>&1
  cat "$OUT"
}
# $1=prompt $2=目標檔名 → 存檔（順手剝掉最外層 ``` 圍欄）
run_doc() {
  { pack full; echo; echo "===== 任務 ====="; echo "$1"; } \
    | timeout 900 codex exec -m "$M" -C "$W" -s read-only --skip-git-repo-check -o "$(cygpath -w "$OUT")" >/dev/null 2>&1
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

case "$TASK" in
  plan)
    run_doc "請做企劃：照 04 第五節的企劃書格式寫出完整 Markdown。$FINAL" plan.md ;;
  scene)
    run_doc "請做場景設計：照 04 第六節格式，以 plan.md 為準，寫出完整 Markdown。$FINAL" scene.md ;;
  assets)
    run_doc "請做素材清單：照 04 第三節 schema，以 plan.md 與 scene.md 為準，輸出可直接 parse 的 JSON。每個 prompt 都要引用對應的設定圖檔名（REFxxx.png），結尾一律加上洋紅底那句，輸出欄一律 {}。$FINAL" assets.gpt.json ;;
  doc)
    F="$1"; shift; run_doc "$1 $FINAL" "$F" ;;
  ref)
    ID="$1"; DESC="$2"
    before=$(ls -d ~/.codex/generated_images/*/ 2>/dev/null | sort)
    { pack art; echo; echo "===== 任務 ====="; echo "\$imagegen 這是一張設定圖（不是遊戲素材）：$DESC。照上面 AGENTS.md 的畫風；設定圖背景用白色或淺灰即可；圖上不要有任何文字、編號、標籤、箭頭。直接生圖，不要問問題。"; } \
      | timeout 600 codex exec -m "$M" -C "$W" -s read-only --skip-git-repo-check >/dev/null 2>&1
    after=$(ls -d ~/.codex/generated_images/*/ 2>/dev/null | sort)
    png=$(ls -t "$(comm -13 <(echo "$before") <(echo "$after") | tail -1)"*.png 2>/dev/null | head -1)
    [ -n "$png" ] && mkdir -p "$DIR/pic/_ref" && cp "$png" "$DIR/pic/_ref/$ID.png" && echo "OK → pic/_ref/$ID.png" || echo "FAIL：沒有產出圖" ;;
  ask)
    run_text "先不要生圖，用文字回答：$1" ;;
  *) echo "未知任務 $TASK（plan|scene|assets|ref|ask|doc）"; exit 1 ;;
esac
