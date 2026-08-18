# 入庫：瀏覽器下載資料夾 -> 遊戲N\pic\_raw\{ID}.png
#
# 兩種模式：
#   1. 指名模式（手動下載的圖已經有正確檔名時）
#        .\ingest.ps1 -Game "遊戲7-蓋廟大作戰" -Names BG001,CH001,CH101
#   2. 快照模式（自動化跑批次時用；先拍快照，生完圖再比對新增了什麼）
#        .\ingest.ps1 -Game "遊戲7-蓋廟大作戰" -Snapshot          # 開跑前
#        .\ingest.ps1 -Game "遊戲7-蓋廟大作戰" -Expect CH201,CH301  # 跑完後，依下載時間對回順序
#
# 設計要點（都是踩過的坑）：
#   - 比對**所有副檔名**，不是只比 .png。ChatGPT 有時交 webp，只比 png 會判成「下載失敗」
#     然後無謂重生、白燒額度。
#   - 絕不刪除 Downloads 裡任何檔案，只複製。
#   - 落地只驗三件事：檔案寫完整、短邊夠大、長寬比合理。
#     **不驗「尺寸必須是 1024x1024 之類的原生值」**——實測合格素材有 1122x1402、1672x941
#     這種非原生尺寸，拿尺寸當硬閘門會把好圖丟掉。
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string] $Game,
  [string[]] $Names  = @(),
  [string[]] $Expect = @(),
  [switch]   $Snapshot,
  [string]   $Downloads = "$env:USERPROFILE\Downloads",
  [int]      $MinSide = 900
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$raw  = Join-Path (Join-Path $repo $Game) 'pic\_raw'
New-Item -ItemType Directory -Force $raw | Out-Null
$snapFile = Join-Path (Join-Path $repo '素材工作流') '_run\snapshot.txt'

$imgExt = @('.png','.webp','.jpg','.jpeg')

if ($Snapshot) {
  New-Item -ItemType Directory -Force (Split-Path $snapFile) | Out-Null
  Get-ChildItem $Downloads -File |
    Where-Object { $imgExt -contains $_.Extension.ToLower() } |
    Select-Object -ExpandProperty Name |
    Set-Content $snapFile -Encoding UTF8
  Write-Host ("快照完成：{0} 個圖檔" -f (Get-Content $snapFile).Count) -ForegroundColor Cyan
  return
}

# ---- 挑出候選檔 ----
if ($Names.Count -gt 0) {
  $cands = foreach ($n in $Names) {
    $hit = Get-ChildItem $Downloads -File |
           Where-Object { $_.BaseName -eq $n -and $imgExt -contains $_.Extension.ToLower() } |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $hit) { Write-Host "MISS $n（Downloads 裡找不到）" -ForegroundColor Yellow; continue }
    [pscustomobject]@{ Id = $n; File = $hit }
  }
} elseif ($Expect.Count -gt 0) {
  if (-not (Test-Path $snapFile)) { throw "沒有快照，請先跑 -Snapshot" }
  $before = @{}; Get-Content $snapFile -Encoding UTF8 | ForEach-Object { $before[$_] = $true }
  $new = Get-ChildItem $Downloads -File |
         Where-Object { $imgExt -contains $_.Extension.ToLower() -and -not $before.ContainsKey($_.Name) } |
         Sort-Object LastWriteTime
  Write-Host ("快照後新增 {0} 個圖檔，預期 {1} 個" -f $new.Count, $Expect.Count)
  if ($new.Count -ne $Expect.Count) {
    Write-Host "數量對不上——列出候選讓人判斷，不自動停手：" -ForegroundColor Yellow
    $new | ForEach-Object { Write-Host ("  {0}  {1}  {2}KB" -f $_.LastWriteTime.ToString('HH:mm:ss'), $_.Name, [int]($_.Length/1KB)) }
  }
  # 依下載時間順序對回送出順序（這是 ID 對應的唯一來源；ID 不進 prompt，免得被畫進圖裡）
  $cands = for ($i = 0; $i -lt [Math]::Min($new.Count, $Expect.Count); $i++) {
    [pscustomobject]@{ Id = $Expect[$i]; File = $new[$i] }
  }
} else {
  throw "要給 -Names 或 -Expect，或用 -Snapshot"
}

# ---- 驗證後入庫 ----
$ok = 0
foreach ($c in $cands) {
  $f = $c.File
  # 檔案還在寫？（.crdownload 或大小仍在變）
  $s1 = $f.Length; Start-Sleep -Milliseconds 250; $f.Refresh()
  if ($f.Length -ne $s1) { Write-Host ("WAIT {0} 還在下載中，跳過" -f $c.Id) -ForegroundColor Yellow; continue }

  try { $b = [System.Drawing.Bitmap]::FromFile($f.FullName) }
  catch { Write-Host ("BAD  {0} 不是可讀的圖：{1}" -f $c.Id, $f.Name) -ForegroundColor Red; continue }
  $w = $b.Width; $h = $b.Height; $fmt = $b.PixelFormat; $b.Dispose()

  if ([Math]::Min($w, $h) -lt $MinSide) {
    Write-Host ("BAD  {0} 短邊只有 {1}px（<{2}），可能抓到縮圖" -f $c.Id, [Math]::Min($w,$h), $MinSide) -ForegroundColor Red
    continue
  }

  $dst = Join-Path $raw "$($c.Id).png"
  if ($f.Extension -ieq '.png') {
    Copy-Item $f.FullName $dst -Force
  } else {
    # webp/jpg 一律轉成 png 入庫（不要判失敗，ChatGPT 有時就是交 webp）
    $b2 = [System.Drawing.Bitmap]::FromFile($f.FullName)
    $b2.Save($dst, [System.Drawing.Imaging.ImageFormat]::Png); $b2.Dispose()
  }
  Write-Host ("OK   {0,-8} <- {1,-40} {2}x{3}  {4}" -f $c.Id, $f.Name, $w, $h, $fmt) -ForegroundColor Green
  $ok++
}
Write-Host ("`n入庫 {0}/{1} 張 -> {2}" -f $ok, $cands.Count, $raw) -ForegroundColor Green
