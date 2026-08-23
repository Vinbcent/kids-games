#!/bin/bash
# 終端機版生圖：assets.json → Codex CLI `$imagegen`（吃 ChatGPT Plus 額度，不用 API key）→ pic/_raw/<ID>.png
#
# 用法（Git Bash）：
#   素材工作流/tools/gen-images.sh "遊戲3-挖土機挖挖樂"              # 生所有 pic/_raw 裡還沒有的
#   素材工作流/tools/gen-images.sh "遊戲3-挖土機挖挖樂" VH501 VH502  # 只生指定 ID（已存在會跳過；要重生先刪 _raw 的檔）
#   FORCE=1 ...                                                     # 強制重生
#
# 機制：
#   - 在遊戲資料夾執行 codex，它會自動讀該資料夾的 AGENTS.md（= 以前的 Project Instructions）
#   - prompt 裡提到 REFxxx.png 的，自動用 -i 把 pic/_ref/REFxxx.png 附上（= 以前的 Sources 設定圖）
#   - 圖落在 ~/.codex/generated_images/<session>/*.png，複製成 pic/_raw/<ID>.png（檔名由我們控制，不靠下載順序）
#   - 狀態由檔案系統表達：_raw 有檔＝已生成。中斷後重跑不會重生已有的
#   - 每張約 60 秒；</dev/null 是必要的，否則 codex 會把後面的輸入吃掉
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
GAME="$1"; shift || true
DIR="$REPO/$GAME"
[ -f "$DIR/assets.json" ] || { echo "找不到 $DIR/assets.json"; exit 1; }
mkdir -p "$DIR/pic/_raw" "$DIR/pic/_ref"
W=$(cygpath -w "$DIR")
LOG="$REPO/素材工作流/_run/gen-images-$(date +%Y%m%d-%H%M%S).log"; mkdir -p "$(dirname "$LOG")"

# 取出 id\tprompt（只挑要做的）
ONLY="$*"
node -e '
const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
const only=process.argv.slice(2);
for(const b of j.批次) for(const a of b.素材){ if(only.length && !only.includes(a.id)) continue; console.log(a.id+"\t"+a.prompt.replace(/\s+/g," ")); }
' "$(cygpath -w "$DIR/assets.json")" $ONLY > "$LOG.list"

ok=0; fail=0; skip=0
while IFS=$'\t' read -r id prompt; do
  [ -z "$id" ] && continue
  out="$DIR/pic/_raw/$id.png"
  if [ -f "$out" ] && [ "${FORCE:-0}" != "1" ]; then skip=$((skip+1)); continue; fi
  # 附設定圖：prompt 裡出現的 REFxxx.png
  refs=(); for r in $(grep -oE 'REF[0-9]{3}\.png' <<<"$prompt" | sort -u); do [ -f "$DIR/pic/_ref/$r" ] && refs+=(-i "$W\\pic\\_ref\\$r"); done
  echo "== $id  (refs: ${#refs[@]}/2)" | tee -a "$LOG"
  before=$(ls -d ~/.codex/generated_images/*/ 2>/dev/null | sort)
  timeout 300 codex exec "\$imagegen $prompt" -C "$W" -s read-only --skip-git-repo-check "${refs[@]}" </dev/null >>"$LOG" 2>&1
  after=$(ls -d ~/.codex/generated_images/*/ 2>/dev/null | sort)
  newdir=$(comm -13 <(echo "$before") <(echo "$after") | tail -1)
  png=$(ls -t "$newdir"*.png 2>/dev/null | head -1)
  if [ -z "$png" ]; then echo "   FAIL $id：沒有產出圖（看 $LOG）" | tee -a "$LOG"; fail=$((fail+1)); continue; fi
  dim=$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$png"); w=${dim%,*}; h=${dim#*,}
  if [ "$(( w>h ? w : h ))" -lt 1000 ]; then echo "   FAIL $id：尺寸 $w x $h 太小" | tee -a "$LOG"; fail=$((fail+1)); continue; fi
  cp "$png" "$out" && echo "   OK   $id  ${w}x${h}" | tee -a "$LOG"; ok=$((ok+1))
done < "$LOG.list"
echo "完成：成功 $ok／失敗 $fail／跳過 $skip → $DIR/pic/_raw   （接著跑 build.ps1 去背縮圖）"
