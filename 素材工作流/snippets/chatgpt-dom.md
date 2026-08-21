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

---

# 第三批（角色與載具影格）再補的坑

## Q. 「同一個角色的多張影格」要一個對話連續生

小師傅四格（站立／蹲挖／舉水泥桶／歡呼）在同一個對話裡連續生，四張的臉、安全帽、背心、褲子完全一致，
一次過關沒有重生。**這是目前維持角色一致性最有效的手段**，比寫在 Project instructions 有用得多。

而且模型會自己補有用的細節：蹲姿那格自己加了鏟子和土堆、舉手那格自己加了水泥桶——
剛好對上「挖地基」和「倒水泥」兩個關卡。**prompt 只描述動作、不要限制道具**，留空間給它發揮。

## R. 但同一個對話裡「主體差太多」會被上下文帶歪

工程車那批連續生了五台車之後，第六張要「一顆破壞鐵球」——模型**又畫了一台水泥車**。
重生時在句首明講「**這一張不要畫任何車輛**」才拉回來。

→ 連續生同系列物件時，若某張的主體跟前面差異很大，要主動切斷上下文。

## S. 左右相反用「水平翻轉」修，不要重生

五台車裡有一台（破壞車）生出來是鏡像的（駕駛艙在右、吊臂朝左上，其他車都是駕駛艙在左）。
`assets.json` 的 `輸出.水平翻轉: true` 一行解決，**省一次生圖額度**。
生圖前先在 prompt 統一寫死朝向（「車頭朝向畫面右邊」），生完發現反了就翻轉。

## T. 每張影格的「圖高」不等於「角色身高」

四張影格正規化到同一個寬度後，高度是 995 / 679 / 1020 / 626 ——差異很大，
因為圖裡除了角色本人還有**舉高的手、鏟子、水泥桶**這些延伸物，各張佔比不同。

所以不能四張都用同一個 sprite 高度，會變成「舉手的時候整個人縮水」。
做法是每張各給一個世界高度，挑的原則是**讓「角色本人」看起來一樣大**：
```js
const KID_FRAMES = {
  idle:      { file:'CH001.webp', ar:400/995,  h:1.75 },
  crouch:    { file:'CH002.webp', ar:400/679,  h:1.25 },   // 蹲著本來就矮
  armsUp:    { file:'CH003.webp', ar:400/1020, h:2.15 },   // 圖裡有水泥桶，要放大才不會縮水
  celebrate: { file:'CH004.webp', ar:400/626,  h:2.15 },
};
```
四個數字是看著實機畫面調的，**沒有辦法自動算**——因為 AI 每張的取景比例都不一樣。

## U. 換掉有動畫語意的 3D 物件時，要保留那個「語意」

- 小師傅蹲下原本是 `scale.y 0.9→0.62` 把整個人壓扁。換成蹲姿影格後視覺更好，
  但仍保留 `0.94` 的輕微壓縮，讓按下去有回饋——**回饋不能因為換美術而消失**。
- 破壞車的鐵球擺盪是全遊戲最好笑的地方，拆成「車體」＋「鐵球」兩張圖後，
  鐘擺數學完全保留。**Sprite 會吃父層的位置變換但不吃朝向**，所以鐵鏈要另外
  `material.rotation = pivot.rotation.z` 才會跟著甩，不然球在盪、鏈子卻是直的。
- 水泥車滾筒、壓路機滾筒的連續旋轉，2D 單張圖真的做不到 → **誠實捨棄**，
  不要硬用兩張圖輪播假裝（會變成抽搐）。捨棄前先確認它不是玩法回饋，只是裝飾。

---

# 生圖失敗時，怎麼分辨「額度用完」還是「服務異常」

2026-08-19 遇到連續生圖失敗，訊息只有 `I wasn't able to generate the image due to an error on my side.`
這種泛用訊息分不出原因，用下面三步判斷（成本很低，只花一張圖的額度）：

1. **看失敗發生在哪個階段**
   - 進度條跑到 **98~99% 才報錯** → 偏向服務端在最後一步掛掉。
   - 一開始就拒絕、而且附上理由 → 內容政策。
   - 明講「已達上限」並顯示恢復時間 → 才是真的額度。

2. **換一個極簡且完全無關的 prompt**（例如「畫一顆紅色的球。」）
   - 也失敗 → **不是敏感詞、也不是你的 prompt 太複雜**。
   - 成功 → 問題出在原本那段 prompt 的內容或構圖要求。

3. **直接用文字問 ChatGPT**（開頭寫「先不要生圖，請用文字回答」，不花生圖額度）
   > 剛才連續生圖都失敗，錯誤是「error on my side」。是不是額度用完了？
   > 如果是請說何時重置；如果不是，請說明你看到的實際錯誤原因。

   它會回報工具層實際收到的訊息。這次得到的是
   `We experienced an error when generating images.`，
   而且**沒有** `rate limit` / `quota exceeded` / `usage limit reached` / `too many requests` 任何一種代碼
   → 判定為服務端異常，不是額度。

4. 補充佐證：真的觸及額度時，ChatGPT 的 **UI 會另外跳出「已達圖片建立上限」的提示並顯示恢復時間**。
   介面上沒有那個提示，就更能排除額度。

> 這次的結論是服務端異常，等一段時間再重試即可，不需要改 prompt、也不需要換帳號。

---

# Project「Sources」實測（2026-08-20）

工作流改成「GPT 做企劃／場景設計／素材設計」之後，Project 的 **Sources**（專案資源）
從可有可無變成主要載體。這一節是在真實頁面上一條一條試出來的。

## V. Sources 分頁：`.click()` 切不過去，要先 `pointerdown`

```js
const b = [...document.querySelectorAll('button[role=tab]')]
            .find(e => (e.textContent || '').trim() === 'Sources');
b.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }));
b.click();                       // 只有 click() 時 aria-selected 不會變
```

網址會變成 `…/project?tab=sources`，但**直接 navigate 到那個網址不會自動選中分頁**，
載入後仍要再點一次。判斷成功看 `b.getAttribute('aria-selected') === 'true'`。

## W. `Add sources` 有五個入口，其中兩個對自動化特別重要

| 入口 | 用途 | 能不能全自動 |
|---|---|---|
| **Text input** | 貼純文字建立一份 source | ✅ **最好用**，見下 |
| **Upload** | 上傳本機檔案 | ✅ 用 `file_upload` 工具，見 Y |
| **Add from library** | 從「已生成圖片庫」挑 | ⚠️ 可以，但**檔名會變成圖庫標題**（`Cheerful Glossy Baby Dinosaur`），不是我要的 `CH001.png` |
| Google Drive / Slack | 連外部服務 | 不用 |

## X. Text input：規格文件不必碰檔案對話框

`Add sources → Text input` 開的是 `Add text source` 對話框：

```
Title (optional)   <input  placeholder="e.g., Team onboarding notes">
Text               <textarea placeholder="Paste or type your text here…">
[Back]  [Save]
```

兩個欄位 **`maxLength` 都是 -1（無上限）**。
這代表**企劃書、場景設計、素材清單、美術規範這類長文件，可以整份用 JS 灌進去**，
完全不需要產檔案、也不需要開作業系統的檔案選取視窗。

React 受控元件要用原生 setter 才吃得到：

```js
function setReactValue(el, v) {
  const proto = el.tagName === 'TEXTAREA'
    ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
  Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, v);
  el.dispatchEvent(new Event('input', { bubbles: true }));
}
```

## Y. `file_upload` **可以**傳本機檔案——舊文件說不行是錯的

README 舊表把「用 `file_upload` 傳專案裡的參考圖」列為 ❌ 不可行（標註「未實測」）。
**2026-08-20 實測：可行。**

```
1. 先把檔案複製到本 session 的 scratchpad 目錄（工具只收「使用者分享給本 session」的路徑，
   專案資料夾原路徑會被拒，scratchpad 會過）
2. Add sources 選單打開後，用 find 工具拿 file input 的 ref
   （會找到 5 個 input[type=file]，要的是描述含「Add sources dialog」那個）
3. mcp__claude-in-chrome__file_upload({ paths:[scratchpad\CH001.png], ref, tabId })
```

實測結果：`Uploaded 1 file(s): CH001.png (1190 KB)`，
Sources 列表出現 **`CH001.png` / `Image · Aug 20, 2026`**——**檔名原封保留**。

> 這條是整套「設定圖」機制的關鍵：檔名可控，才能在後續 prompt 裡用
> 「請參考 CH001.png」精確指到那一張。走 `Add from library` 會拿到圖庫自動取的英文標題，指不準。
> 單次上傳總大小上限 10 MB。

## Z. 後續新對話**真的看得到** Sources 裡的圖（實測，不是推測）

這是整個機制成不成立的關鍵，所以用「不花生圖額度」的文字探針測：

> 先不要生圖。請打開這個專案 Sources 裡的 CH001.png，描述你**實際看到**的角色外觀……
> 如果你其實看不到，請老實說「我看不到」，不要用猜的。

回答具體到：黃色安全帽上有紅色圓徽與「廟」字、兩側青綠雲紋、白色短袖 T、藍色吊帶牛仔褲、
紅領巾、黃橘工作靴配紅鞋帶與深咖啡鞋頭、約 3 頭身、腰間工具帶與鐵鎚、背後斜插捲筒圖紙。
**細節密度不可能是從檔名猜出來的** → 判定：模型確實取得了圖片畫面。

## AA. 「參考 CH001 生成另一個姿勢」——設計一致性成立，指令服從度沒有變好

同一個新對話接著送：

> 完全沿用 CH001.png 裡那個角色（配色與配件一模一樣，不要改造型），
> 畫成雙腳離地往上跳、雙手高舉歡呼，面向右邊。背景全透明，只有他一個人，不要地面陰影文字。

| 項目 | 結果 |
|---|---|
| 安全帽（黃底＋紅圓徽＋「廟」字＋綠雲紋） | ✅ 對 |
| 紅領巾、白 T、藍吊帶牛仔褲、胸前金色廟宇圖案 | ✅ 對 |
| 黃橘工作靴＋紅鞋帶＋深色鞋頭、黃黑手套 | ✅ 對 |
| 工具帶＋鐵鎚＋背後捲筒圖紙 | ✅ 對 |
| 三頭身比例 | ✅ 對 |
| 指定的姿勢（跳起歡呼） | ✅ 對 |
| **「面向右邊」** | ❌ **沒服從**，畫成正面偏左 |
| **「背景全透明」** | ❌ **沒服從**，白底 |

> **結論要記牢：參考圖解決的是「設計一致性」（同一個角色、同樣配色配件比例），
> 不解決「指令服從度」，更不解決「幾何一致性」。**
> 方向、背景、構圖這些照舊會漂，照舊要靠本機 `build.ps1`（幾何正規化、去背、水平翻轉）收尾。

## AB. Project settings 的欄位

`sidebar → button[aria-label="Open project options for <專案名>"] → Project settings`

| 欄位 | 型別 | 備註 |
|---|---|---|
| Project name | `input` | 無 maxLength |
| **Instructions** | `textarea` | **無 maxLength**（前端沒設限；仍建議寫短，長指令會稀釋服從度） |
| Memory | 選項 | 預設 `Default memory` |
| Library access | 開關 | `Enabled`；**分享專案會關掉圖庫存取** |

> 指令要短、規格放 Sources：Instructions 是每則訊息都吃的成本，
> Sources 是要用才撈的參考。把長規格塞進 Instructions 只會稀釋真正重要的那幾條。

## AC. Source 只能 **Download / Delete**，**不能改名、不能編輯**

每一列右側 `button[aria-label="Source actions"]` 的選單只有兩項：

```
Download
Delete
```

兩個推論，都會影響工作流設計：

1. **`Add from library` 實務上不能用來放設定圖**。從圖庫加進來的檔名是圖庫自己取的英文標題
   （`Cheerful Glossy Baby Dinosaur`），而且**改不掉**。
   要讓 prompt 能寫「請參考 CH001.png」，就只能走 **`file_upload` 上傳本機檔名**（見 Y）。
2. **文件沒有「編輯」**。規格改版＝先 `Delete` 舊的、再 `Text input` 貼新的。
   所以 **repo 才是規格的唯一真相**，Sources 只是它的一份投影；
   不要在 ChatGPT 上直接改文件，改完 repo 再整份推上去。

> `Delete` 是不可逆的破壞性操作，自動化腳本不要自己按。
> 需要刪的時候先跟使用者確認，或請使用者自己點。

## AD. `.md` 也能當 source，所以**規格文件走 `file_upload`，不要走 Text input**

實測把 `G7-素材清單.md`（25 KB）丟進 `Add sources` 的 file input：

```
Uploaded 1 file(s): G7-素材清單.md (25 KB total)
→ Sources 列表出現「G7-素材清單.md / File · Aug 20, 2026」
```

檔名一樣原封保留。**這比 Text input 好，理由有三個**：

| | `file_upload` | `Text input` |
|---|---|---|
| 檔名 | 完全可控（`04-素材命名與交付格式.md`），prompt 裡指得到 | 只有 Title，指起來沒那麼明確 |
| 內容怎麼進去 | 直接讀本機檔，**內容不用經過我的工具呼叫** | 要把整份文字塞進 JS 字串，一份 10 KB 文件就是 10 KB 的呼叫 |
| 真相在哪 | repo 檔案就是真相，改完重推即可 | 內容散在瀏覽器操作紀錄裡 |

> 所以標準做法是：**文件寫在 repo → 複製到本 session 的 scratchpad → `file_upload`**。
> Text input 留給臨時的短東西。

## AE. Sources 會**自動被檢索**，但別把「每張圖都要遵守的鐵則」丟進去

實測：在新對話裡問「這個專案的素材規劃裡，第一批包含哪幾個 ID？」
**完全沒有提到檔名**，它仍然正確答出 `CH101 媽祖 / CH201 千里眼 / CH301 順風耳 /
EV001 龍頭 / EV002 龍身 / EV101 獅頭 / TP001 燈籠`（與 `assets.json` 第一批完全吻合），
而且回答末尾自己標了引用來源 `G7-素材清單`。

→ **Sources 是 RAG，會依問題自動撈，不需要在 prompt 裡指名。**

但要注意這個實驗的條件：**那是一則「明顯在問資料」的訊息**。
生圖訊息長得完全不一樣（「畫一隻⋯⋯」），**不保證會觸發檢索**。所以分配原則是：

| 放哪裡 | 放什麼 | 理由 |
|---|---|---|
| **Project Instructions** | 每張圖都必須遵守的鐵則（單一主體／無文字／留白／背景色／一致性） | 永遠在 context 裡，不靠檢索 |
| **Sources** | 企劃約束、技術約束、規範細節與理由、素材清單、設定圖 | 要用才撈；放這裡不佔每則訊息的成本 |

> 反過來做（把鐵則放 Sources、把長篇規格塞 Instructions）兩頭都輸：
> 鐵則可能沒被撈到，而長 Instructions 會稀釋服從度。

## AF. 取回 GPT 的**文字**產出：也走 blob 下載，不要用分段讀 innerText

新工作流裡 GPT 會交出企劃書、場景設計、素材清單這種**長文字**。取回來的方式很重要：

**`javascript_tool` 的回傳實測約 1000 字元就截斷。**
（用一段 10,399 字元的可預測字串測：`slice(0,9000)` 只拿回到第 38 行就 `[TRUNCATED]`。）
一份 6000 字的企劃書要分七八次讀，而且每次都要對齊切點，很容易漏段。

**改用已經驗證過的 blob 下載，一次拿完整份：**

```js
const md = document.querySelectorAll('[data-message-author-role="assistant"]');
const text = md[md.length - 1].innerText;          // 或指定某一則
const blob = new Blob([text], { type: 'text/markdown' });
const u = URL.createObjectURL(blob);
const a = document.createElement('a');
a.href = u; a.download = '_g7_企劃書.md';           // 檔名完全由我決定
document.body.appendChild(a); a.click(); a.remove();
setTimeout(() => URL.revokeObjectURL(u), 4000);
```

實測：10,399 字元原封落到 `Downloads\`，首行 `L000-…`、末行 `L399-…` 都在，**沒有截斷**。
之後照舊用 shell 搬進 repo。

> 跟圖片走的是同一條路（README 第二節），所以不需要新機制、也不需要新的授權。
> 記得加一次性前綴（`_g7_`）避免跟舊檔撞名，搬完就把 Downloads 裡的清掉。

---

# 雙向管線總結（2026-08-20 全部實測通過）

```
repo ──file_upload──► Project Sources        檔名原封保留，.md 與 .png 都吃，單次總量 < 10 MB
                                             （要先複製到本 session 的 scratchpad，專案原路徑會被拒）

Project 對話 ──blob <a download>──► Downloads ──shell──► repo
                                             圖片與文字都適用，無截斷
```

**repo 是唯一真相**：Sources 不能編輯只能刪除重加，所以規格一律在 repo 改，改完整份重推。
