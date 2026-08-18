# ChatGPT 網頁版 DOM 操作手冊（實測版）

> 實測日期：2026-08-18　瀏覽器：Chrome + Claude in Chrome 擴充功能
> 帳號：ChatGPT Plus。以下每一條都是在真實頁面上跑過、確認可用的。
> **原則：一律用 `aria-label` / `data-testid` / `alt` 定位，不要用 class**（ChatGPT 的 class 是 build 產生的亂碼，改版就壞）。

---

## 1. 網址規則

| 用途 | 網址 |
|---|---|
| Project 首頁 | `https://chatgpt.com/g/g-p-<projectId>-<slug>/project` |
| 單一對話 | `https://chatgpt.com/c/<conversationId>` |
| 新對話（無專案） | `https://chatgpt.com/` |

在 Project 首頁的輸入框送出訊息 → 自動在該專案底下開一個新對話，網址跳到 `/c/<id>`。
**這就是「開新對話」最省事的做法**：`navigate` 到 project 網址，直接打字送出。

## 2. 關鍵元素（實測 selector）

| 元素 | Selector | 備註 |
|---|---|---|
| 輸入框 | `#prompt-textarea` | `<div contenteditable="true">`（ProseMirror），**不是 textarea** |
| 送出鈕 | `[data-testid="send-button"]` | `aria-label="Send prompt"`；輸入框空時 disabled |
| 停止鈕 | `[data-testid="stop-button"]` | **只在生成中出現** → 這是「還在跑」最可靠的訊號 |
| 附檔鈕 | `[data-testid="composer-plus-btn"]` | `aria-label="Add files and more"` |
| 檔案 input | `input[type=file][accept="image/*"]` | 給 `file_upload` MCP 工具用的 ref 目標 |
| 專案詳情 | `button[aria-label="Show project details"]` | 開啟後可編輯 Project instructions / 檔案 |
| 訊息區塊 | `[data-message-author-role="user"|"assistant"]` | **對話是虛擬捲動的**，只有視窗附近的訊息在 DOM 裡 |
| 生成的圖 | `img[alt^="Generated image"]` | 例：`alt="Generated image: Orange Superhero Squirrel Sprite Sheet"` |

## 3. 灌入長 prompt（不會誤觸送出）

`#prompt-textarea` 是 ProseMirror。直接改 `innerText` **不會**同步 React 狀態，送出的會是空訊息。
用 `execCommand('insertText')`：瀏覽器會發出真正的 `beforeinput`/`input` 事件，ProseMirror 正常接收。

```js
const pt = document.querySelector('#prompt-textarea');
pt.focus();
document.execCommand('selectAll');
document.execCommand('delete');                 // 先清乾淨
document.execCommand('insertText', false, PROMPT_TEXT);   // 支援 \n 換行、支援中文
// 檢查
({ text: pt.innerText, sendReady: !document.querySelector('[data-testid="send-button"]').disabled })
```

> 實測：38 字中文含兩個 `\n` 完整灌入，送出鈕變 enabled，**不會自動送出**。
> 比用 `computer` 工具一個字一個字打快非常多，也不會因為 Enter 而提早送出。

清空輸入框（收工/中止時用）：
```js
const pt = document.querySelector('#prompt-textarea');
pt.focus(); document.execCommand('selectAll'); document.execCommand('delete');
```

## 4. 送出

```js
document.querySelector('[data-testid="send-button"]').click();
```

## 5. 等生圖完成（**必須分段輪詢**）

`javascript_tool` 單次執行有逾時（約 30 秒），生圖要 30～90 秒，
所以**不能在頁面裡 await 到好**，要寫成「回報目前狀態」的探針，由外面重複呼叫。

```js
/* probe：每次呼叫回報一次狀態，外面重複叫到 done 為止 */
await new Promise(r => setTimeout(r, 8000));       // 每次探針內先等 8 秒，省呼叫次數
const streaming = !!document.querySelector('[data-testid="stop-button"]');
const turns = [...document.querySelectorAll('[data-message-author-role="assistant"]')];
const last  = turns[turns.length - 1];
const imgs  = last ? [...last.querySelectorAll('img')].filter(i => i.naturalWidth >= 512) : [];
const txt   = last ? last.innerText.slice(-400) : '';
JSON.stringify({
  streaming,                                  // true = 還在生成
  imgCount: imgs.length,
  sizes: imgs.map(i => [i.naturalWidth, i.naturalHeight]),
  done: !streaming && imgs.length > 0,
  tail: txt,                                  // 用來看有沒有限流/拒絕訊息
})
```

判定規則：
- `streaming === true` → 還在跑，再探一次。
- `streaming === false && imgCount > 0` → **完成**。
- `streaming === false && imgCount === 0` → 出事了，看 `tail`（限流、內容政策拒絕、要求澄清）。
- 連續探 15 次（約 2 分鐘）還是 `streaming` → 視為卡住，截圖給人看。

## 6. 取圖：解析度與位元組

- 對話裡的 `<img>` **就是全解析度原圖**（實測 `naturalWidth=1536, naturalHeight=1024`），
  不需要點開燈箱找「原始大小」。
- 圖片網址是 `https://chatgpt.com/backend-api/estuary/content?id=…&sig=…`，
  **同源 + 需要 cookie**，所以只能在頁面裡抓，不能複製網址給 `curl` / `Invoke-WebRequest`。
- 頁面內 `fetch` 可以：實測 `fetch(img.src, {credentials:'include'})` → `200 image/png 325788 bytes`。

> ⚠️ 擴充功能會**擋住**把含 query string 的網址回傳給我（`[BLOCKED: Cookie/query string data]`），
> 所以「讀出網址再自己下載」這條路是死的。

## 7. 存檔：只能走「瀏覽器下載資料夾」

**實測結論：`chatgpt.com` 的 CSP `connect-src` 會擋掉連本機的請求**，
所以「頁面 fetch 圖片 → POST 到 `http://127.0.0.1:9911` 本機接收器 → 直接寫進專案資料夾」
這個最漂亮的方案**行不通**（`TypeError: Failed to fetch`，本機伺服器完全收不到封包）。

可行做法：在頁面裡把圖抓成 blob，用 `<a download>` 觸發下載，**檔名由我指定**：

```js
/* 下載最後一則助理訊息裡的第 idx 張圖，存成 name */
async function grab(name, idx = 0) {
  const turns = [...document.querySelectorAll('[data-message-author-role="assistant"]')];
  const last  = turns[turns.length - 1];
  const imgs  = [...last.querySelectorAll('img')].filter(i => i.naturalWidth >= 512);
  const im = imgs[idx];
  if (!im) return 'NO_IMAGE';
  const blob = await fetch(im.src, { credentials: 'include' }).then(r => r.blob());
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = name;                       // ← 檔名完全由我控制
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(a.href), 10000);
  return JSON.stringify({ saved: name, bytes: blob.size, size: [im.naturalWidth, im.naturalHeight] });
}
await grab('CHAR001.png');
```

檔案會落在 `C:\Users\id753\Downloads\`，再用 shell 搬進專案：

```bash
mv "/c/Users/id753/Downloads/CHAR001.png" "遊戲N-名稱/pic/raw/CHAR001.png"
```

**防呆**：下載前先記錄資料夾快照，下載後比對新增了哪個檔，避免撞到同名舊檔（Chrome 會自動改成 `CHAR001 (1).png`）。

```bash
# 下載前
ls "/c/Users/id753/Downloads" > /tmp/dl_before.txt
# 下載後
comm -13 /tmp/dl_before.txt <(ls "/c/Users/id753/Downloads")
```

> 第一次跑的時候 Chrome 可能會跳「這個網站想要下載多個檔案」→ 需要你按一次 **允許**，之後就不會再問。

## 8. 上傳參考圖

`input[type=file][accept="image/*"]` 存在，可用 MCP 的 `file_upload` 工具指定 ref 上傳。
**限制**：`file_upload` 只接受「使用者分享給這個 session 的檔案」（附件、session 的 outputs/uploads 資料夾）。
專案資料夾裡的圖能不能直接上傳**尚未實測** → 第一次跑要先試一張。
若不行，退路是**同一個對話裡連續生成**（ChatGPT 看得到自己前面生的圖），不必上傳。

## 9. 絕對不要做

- 不要觸發 `alert` / `confirm` / `prompt` → 會卡死整個擴充功能。
- 不要碰專案的 `⋯` 選單裡的刪除項目。
- 不要動使用者其他分頁；工作分頁用完要關掉。
- 不要在對話裡送出任何含小孩名字/個資的文字（見 `遊戲設計注意事項.md` 隱私規則）。

---

# 實跑修正（2026-08-18，遊戲7 第一批 8 次生圖跑完後）

前面第 1~9 節是靜態探勘寫的。實際跑完一整批之後，以下幾條**被證明是錯的或不完整的**，以實跑為準。

## A. 點擊一律用 JS `.click()`，不要用 ref 或座標

`computer` 工具的 ref 點擊與座標點擊在 ChatGPT 上**會靜默失敗**（「New project」按鈕連點兩次才開、
「Create project」點三次都沒反應）。而且同一個頁面前後兩張截圖的縮放比例會變（1531×784 vs 1549×794，
內容渲染倍率不同），座標對映不可靠。

```js
const btn=[...document.querySelectorAll('button')].find(b=>b.innerText.trim()==='Create project' && !b.disabled);
btn.click();   // ← 一次就成功
```

## B. 生成的圖**不在** `[data-message-author-role="assistant"]` 裡

第 5 節寫「找最後一則助理訊息裡的 img」——**錯的**。圖片訊息用不同的容器，
`document.querySelectorAll('[data-message-author-role="assistant"]')` 在只有圖的回合裡是空的。

正確做法：**全域找 `img[alt^="Generated image"]`**，alt 形如 `Generated image: Chibi Golden Goddess with Jade Tablet`。

## C. 圖片是 lazy-load，不先捲進畫面就永遠是 0×0

抓到元素不代表抓得到圖。`naturalWidth` 會一直是 0，等 20 秒也不會變，直到它進入視窗。

```js
im.scrollIntoView({block:'center'});
im.loading='eager';          // 兩者都要
```
少了這步，會誤判成「還在生成」然後無限等待。

## D. 對話是虛擬捲動的 → 用「最後一張」，不要用「總張數」

捲出畫面的圖會被移出 DOM，所以 `imgs.length` 會忽多忽少（實測從 3 掉到 2）。
判斷「這張是不是新的」要看**最後一張的 alt / src**，不要數數量。

## E. 「停止鍵消失」不等於「圖好了」

`[data-testid="stop-button"]` 消失時，圖片元素可能還是 `naturalWidth=0` 的佔位。
完成條件必須是**兩個都成立**：`stop-button 不存在` **且** `最後一張圖 naturalWidth >= 512`。

## F. `javascript_tool` 有 45 秒硬逾時

實測 `CDP sendCommand "Runtime.evaluate" timed out after 45000ms`。
所以頁面內的等待迴圈**總時長要壓在 20 秒以內**，不夠就從外面再呼叫一次。
逾時的那次呼叫**可能已經執行了一半**（實測：prompt 送出去了但下載沒做、或下載做了但沒送下一則），
所以每一步都要能重入：先查狀態，再決定要不要重做。

## G. 送出後輸入框不一定會被清空

實測送出成功後，composer 仍留著同一段文字。下一次 `insertText` 就會疊上去變成兩段。
**每次送出後強制清一次**：
```js
const p=document.querySelector('#prompt-textarea');
if(p.innerText.trim().length){ p.focus(); document.execCommand('selectAll'); document.execCommand('delete'); }
```

## H. 別用送出鈕判斷「有沒有送成功」

生成中送出鈕會被換成停止鈕，所以送出後立刻查 `send-button` 會拿到 `null`，
造成「其實送出去了卻回報 nextClicked:false」的假陰性（實跑遇到兩次，差點重送）。
改看 `stop-button 出現` 或「使用者訊息數增加」。

## I. 下載檔名要加一次性前綴

`Downloads` 是共用髒資料夾（實測 209 個檔）。直接用 `CH101.png` 撞到舊檔，
Chrome 會自動存成 `CH101 (1).png`，後面的自動改名就對不上。
**用 `_g7b1_CH101.png` 這種一次性前綴**，撞名機率歸零。

好消息：`<a download>` 觸發下載**沒有跳出任何 Chrome 詢問**，一次都沒有。

## J. 擴充功能會中途斷線

實測跑到第 6 張時出現 `Browser extension is not connected`。
重新呼叫 `tabs_context_mcp` 就恢復了，而且**頁面裡注入的 `window.__step` helper 還活著**。
斷線那一刻的動作結果不明 → 先查 `Downloads` 有沒有落檔再決定要不要補做。

## K. 生圖結果的實際樣貌（8 張的統計）

| 現象 | 實際數字 |
|---|---|
| 輸出尺寸 | 1024×1536 ×4、1536×1024、1402×1122、1254×1254 —— **非原生尺寸是常態**，不能拿尺寸當閘門 |
| 背景是真透明的 | **8 張裡只有 1 張**。其餘是棋盤格（3）或純色底（4） |
| 檔案大小 | 1.4~2.3MB |
| 生成耗時 | 約 40~90 秒／張 |

→ Project instructions 第 1 條白紙黑字寫「背景全透明」，**服從率 1/8**。
   所以本機的三路分流去背（真alpha／棋盤格／純色底）是必需品，不是保險。

---

# 接進 Three.js 場景時踩到的坑（遊戲7 實作）

## L. 白色／淺色主體一定要指定「對比色背景」

第一版的雲是「白色的雲畫在白色背景上」（實測背景 `#FEFEFE`、雲心 `#F1ECEC`）——
**任何容差都分不開**，去背直接把雲吃光，只剩一條白邊，輸出 4KB。

解法：在那一則訊息裡明確要求
> 「這一張**背景請填滿鮮豔的洋紅色純色底**（不要透明、不要白色、不要漸層），方便我後製去背」

洋紅 vs 白色在 RGB 上差 255（綠通道），容差開到 60 都不會誤傷。一次就成功。

**通則：主體本身是白/米白/淺灰時，一律走 chroma key，不要指望透明背景。**

## M. Sprite 的 scale 是「世界單位寬高」，不會照圖片比例

Three.js 的 `Sprite.scale.set(w, h, 1)` 跟貼圖長寬比完全無關。
原本的手繪貼圖都是正方形（256×256），所以程式裡到處寫 `scale.set(1.5, 1.5, 1)`。
換成依內容裁切的 AI 圖（512×1160 之類）後直接沿用，角色會被壓扁成矮胖。

做法：建一張長寬比表，寬度一律用「高 × 長寬比」算。
```js
const AR = { mazu: 512/1160, qian: 512/936, dhead: 640/566, /* ... */ };
pic(texMazu(), 1.45 * AR.mazu, 1.45);
```

**更容易漏掉的是「每幀覆寫 scale」的地方**——遊戲7 有三處
（龍頭依行進方向翻面、獅頭慶典放大、媽祖祝福淡入放大），
它們每一幀都把 scale 寫回正方形，只改建立處是沒用的：
```js
dragon.head.scale.set((dir >= 0 ? 1 : -1) * dscl * AR.dhead, dscl, 1);
lion.scale.set(lscl * AR.lion, lscl, 1);
mazuHelper.scale.set(s * AR.mazu, s, 1);
```

## N. `const` 不會 hoist，貼圖工廠要放在第一個使用點之前

`function` 宣告會 hoist，但 `const AR = {...}` 不會。
把 AR 放在檔案中段、卻在前段就用它建背景板 → `Cannot access 'AR' before initialization`。
整塊（`ART_VER` / `AR` / `imgTexCache` / `imgTex`）要移到第一個使用點之前。

## O. 用指令碼改單行箭頭函式時，`//` 註解會吃掉整行後半

```js
// 改壞的樣子（後面的 s.position.set(...) 和 }); 全被註解掉了）
dragon.segs.forEach((s, i) => { const k = (i+1) * 0.34;   // 註解 s.position.set(...); });
```
錯誤訊息是 `SyntaxError: missing ) after argument list`，離真正的問題行很遠。
**註解要放在整行的上一行**。改完一定要跑一次語法檢查：
```bash
node -e "const fs=require('fs');const s=fs.readFileSync('x.html','utf8');
const m=s.match(/<script type=\"module\">([\s\S]*?)<\/script>/);
try{new Function(m[1].replace(/^import .*/gm,''));console.log('語法 OK')}catch(e){console.log('錯誤:',e.message)}"
```

## P. 背景板放在霧裡會被洗白

遊戲7 有 `Fog(0xd6e6ea, 26, 80)`。遠山背景板放太遠會被霧洗掉大半。
實測放在 `z = -46`（沿視線 depth 約 57）還看得清楚，再遠就開始糊。
另外用 `Sprite` 而不是 `Mesh + PlaneGeometry`：Sprite 永遠面向鏡頭、也不吃 MeshToonMaterial 的光照，
背景板要的就是這個效果。
