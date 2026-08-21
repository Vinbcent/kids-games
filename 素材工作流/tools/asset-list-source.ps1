# 把 遊戲N\assets.json 轉成「要貼進 ChatGPT Project Sources 的素材清單」
#
# 為什麼要單獨一份 resource：
#   素材清單是 GPT 在整個專案裡唯一的「全域視野」。它每次只生一張圖，
#   沒有這份清單就不知道這張圖在整體規劃裡的位置，容易畫出風格/尺度不一致的東西。
#   放進 Sources 之後，每個新對話都撈得到。
#
# 為什麼要過濾欄位：
#   輸出.knee / 去背 / 格式 / 水平翻轉 / 裁切 都是本機 build.ps1 的後製參數，
#   GPT 看了不但用不到，還會稀釋它真正要遵守的美術規則。只給設計層欄位。
#
# 用法：
#   .\asset-list-source.ps1 -Game "遊戲7-蓋廟大作戰"
#   產物在 素材工作流\_run\source-素材清單-<遊戲>.md，內容直接貼進 Add sources -> Text input
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string] $Game
)

$ErrorActionPreference = 'Stop'

$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$src  = Join-Path (Join-Path $repo $Game) 'assets.json'
if (-not (Test-Path $src)) { throw "找不到 $src" }

$json = Get-Content $src -Raw -Encoding UTF8 | ConvertFrom-Json

$sb = New-Object System.Text.StringBuilder
function W([string]$s) { [void]$sb.AppendLine($s) }

W "# 素材清單：$($json.遊戲)"
W ""
W "> 這是本款遊戲的**完整素材規劃**，由你（ChatGPT）維護。"
W "> 每次我請你生一張圖時，先看這份清單確認那張圖在整體裡的位置、屬於哪一批、跟誰要保持一致。"
W "> 清單有變動時我會整份換掉——所以**以這份為準**，不要沿用對話裡的舊版本。"
W ""
W "## 全案畫風"
W ""
W $json.畫風前綴
W ""

$n = 0
foreach ($b in $json.批次) {
  W "---"
  W ""
  W "## $($b.名稱)"
  W ""
  if ($b.說明) { W "$($b.說明)"; W "" }
  foreach ($a in $b.素材) {
    $n++
    W "### $($a.id)"
    W ""
    W "- **用途**：$($a.用途)"
    if ($a.比例朝向) { W "- **構圖/朝向**：$($a.比例朝向)" }
    if ($a.組)      { W "- **一致性組**：$($a.組)（同組的圖必須彼此配色、比例、造型一致）" }
    W "- **畫面內容**：$($a.prompt)"
    W ""
  }
}

W "---"
W ""
W "## 使用規則"
W ""
W "1. **ID 只是我這邊的檔名，絕對不要把 ID 畫進圖裡**，也不要在圖上寫任何文字或編號。"
W "2. 我說「生 X」時，就照這份清單裡 X 的『畫面內容』生，不用我再貼一次。"
W "3. 同一個『一致性組』的圖要一次連續生完，配色與造型才不會漂。"
W "4. 清單裡沒有的東西不要自己加（不要多畫地面、陰影、光暈、第二個角色）。"
W ""
W "（共 $n 張素材，$($json.批次.Count) 個批次）"

$out = Join-Path (Join-Path $repo '素材工作流') "_run\source-素材清單-$Game.md"
New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
[System.IO.File]::WriteAllText($out, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

Write-Host ("素材清單 source 產生完成：{0}" -f $out) -ForegroundColor Green
Write-Host ("  {0} 批 / {1} 張 / {2} 字元" -f $json.批次.Count, $n, $sb.Length) -ForegroundColor Cyan
