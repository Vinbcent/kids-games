#!/bin/bash
# 等 ChatGPT 額度重置 → 立刻接著把剩下的素材生完
# 用法：素材工作流/tools/wait-quota.sh "遊戲9-花市小老闆"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; GAME="$1"
LOG="$REPO/素材工作流/_run/wait-quota.log"; : > "$LOG"
for i in $(seq 1 40); do
  out=$(timeout 120 codex exec "ok" -m "${GPT_MODEL:-gpt-6-astra}" -s read-only --skip-git-repo-check </dev/null 2>&1)
  if grep -q "usage limit" <<<"$out"; then
    echo "$(date +%H:%M) 第 $i 次：還在限額中" >> "$LOG"
    sleep 600
  else
    echo "$(date +%H:%M) 第 $i 次：額度回來了 → 開始生圖" >> "$LOG"
    "$REPO/素材工作流/tools/gen-images.sh" "$GAME" >> "$LOG" 2>&1
    echo "$(date +%H:%M) 生圖結束" >> "$LOG"
    exit 0
  fi
done
echo "$(date +%H:%M) 等太久放棄（>6.5 小時）" >> "$LOG"
