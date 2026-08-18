# 驗收總覽圖：把一個資料夾的素材拼成一張 contact sheet
#
# 每格左半鋪洋紅、右半鋪深綠——兩種底色都鋪，去背殘留的白邊與破洞會非常明顯，
# 單一底色常常看不出來（淺色殘留在洋紅上看得到，在綠上看不到，反之亦然）。
#
# 用法：
#   .\contact.ps1 -Dir "..\..\遊戲7-蓋廟大作戰\pic\opt" -Out "..\..\遊戲7-蓋廟大作戰\pic\opt\_contact.jpg"
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string] $Dir,
  [string] $Out,
  [string] $SizeFrom,
  [int]    $Cell = 420,
  [int]    $Cols = 4
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if (-not $Out) { $Out = Join-Path $Dir '_contact.jpg' }

# _ 開頭的是產出物（_contact / _build / 舊 preview），不要放進來
$files = Get-ChildItem $Dir -File |
         Where-Object { $_.Extension -match '^\.(png|jpg)$' -and $_.Name -notlike '_*' } |
         Sort-Object Name
if ($files.Count -eq 0) { Write-Host "（$Dir 裡沒有素材）" -ForegroundColor DarkGray; return }

$pad  = 26
$rows = [Math]::Ceiling($files.Count / $Cols)
$W    = $Cols * $Cell
$H    = $rows * ($Cell + $pad)

$sheet = New-Object System.Drawing.Bitmap($W, $H)
$g = [System.Drawing.Graphics]::FromImage($sheet)
$g.Clear([System.Drawing.Color]::FromArgb(24,24,28))
$g.InterpolationMode = 'HighQualityBicubic'
$g.SmoothingMode     = 'HighQuality'

$font    = New-Object System.Drawing.Font('Consolas', 13, [System.Drawing.FontStyle]::Bold)
$white   = [System.Drawing.Brushes]::White
$magenta = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255,0,255))
$green   = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(0,110,60))

$i = 0
foreach ($f in $files) {
  $col = $i % $Cols; $row = [int][Math]::Floor($i / $Cols)
  $x = $col * $Cell; $y = $row * ($Cell + $pad) + $pad

  $g.FillRectangle($magenta, $x, $y, [int]($Cell/2), $Cell)
  $g.FillRectangle($green, ($x + [int]($Cell/2)), $y, [int]($Cell/2), $Cell)

  $b = [System.Drawing.Bitmap]::FromFile($f.FullName)
  $s  = [Math]::Min($Cell / $b.Width, $Cell / $b.Height)
  $dw = [int]($b.Width * $s); $dh = [int]($b.Height * $s)
  $g.DrawImage($b, [int]($x + ($Cell - $dw)/2), [int]($y + ($Cell - $dh)/2), $dw, $dh)

  # 實際輸出可能是 webp（System.Drawing 讀不了），所以畫面從 PNG 中繼檔來、
  # 檔案大小從真正的輸出資料夾查
  $sf = $f
  if ($SizeFrom) {
    $real = Get-ChildItem $SizeFrom -File -Filter "$($f.BaseName).*" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notlike '_*' } | Select-Object -First 1
    if ($real) { $sf = $real }
  }
  $kb    = [int]($sf.Length / 1KB)
  $label = "{0}  {1}x{2}  {3}KB {4}" -f $f.BaseName, $b.Width, $b.Height, $kb, $sf.Extension.TrimStart('.')
  $g.DrawString($label, $font, $white, [single]($x + 6), [single]($y - $pad + 4))

  $b.Dispose(); $i++
}
$g.Dispose()

$codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
$ep = New-Object System.Drawing.Imaging.EncoderParameters(1)
$ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]82)
$sheet.Save($Out, $codec, $ep)
$sheet.Dispose()

Write-Host ("contact sheet: {0}  ({1} 張)" -f $Out, $files.Count) -ForegroundColor Cyan
