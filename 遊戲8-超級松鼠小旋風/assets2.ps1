# 素材優化批次處理：pic/素材優化/ -> pic/opt/
# 1) 光暈修剪：alpha 低於 knee 的半透明暈去掉（漸層 remap，不會有硬邊圈）
# 2) 蜜蜂/小鳥水平翻轉（要面向左邊的玩家）
# 3) 樹枝裁掉左緣被切斷的樹幹
# 4) 依內容裁切 + 縮到遊戲用尺寸
Add-Type -AssemblyName System.Drawing

$src = Join-Path $PSScriptRoot 'pic\素材優化'
$dst = Join-Path $PSScriptRoot 'pic\opt'

$cp = New-Object System.CodeDom.Compiler.CompilerParameters
$cp.CompilerOptions = '/unsafe'
[void]$cp.ReferencedAssemblies.Add('System.dll')
[void]$cp.ReferencedAssemblies.Add('System.Core.dll')
[void]$cp.ReferencedAssemblies.Add('System.Drawing.dll')

Add-Type -CompilerParameters $cp -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Drawing.Drawing2D;
public static class Asset2 {
  // alpha remap：a <= knee 歸零，其餘線性拉回 0..255（去光暈、保邊緣漸層）
  public static void AlphaKnee(Bitmap bmp, int knee) {
    if (knee <= 0) return;
    var d = bmp.LockBits(new Rectangle(0,0,bmp.Width,bmp.Height), ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
    unsafe {
      byte* p = (byte*)d.Scan0;
      for (int y=0; y<bmp.Height; y++) { byte* row = p + y*d.Stride;
        for (int x=0; x<bmp.Width; x++) {
          int a = row[x*4+3];
          row[x*4+3] = (byte)(a <= knee ? 0 : (a - knee) * 255 / (255 - knee));
        } }
    }
    bmp.UnlockBits(d);
  }
  public static Rectangle AlphaBounds(Bitmap b, int thr) {
    var d = b.LockBits(new Rectangle(0,0,b.Width,b.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
    int minX=b.Width, minY=b.Height, maxX=-1, maxY=-1;
    unsafe {
      byte* p = (byte*)d.Scan0;
      for (int y=0; y<b.Height; y++) { byte* row = p + y*d.Stride;
        for (int x=0; x<b.Width; x++) if (row[x*4+3] > thr) {
          if (x<minX) minX=x; if (x>maxX) maxX=x; if (y<minY) minY=y; if (y>maxY) maxY=y; } }
    }
    b.UnlockBits(d);
    if (maxX < 0) return new Rectangle(0,0,b.Width,b.Height);
    return new Rectangle(minX, minY, maxX-minX+1, maxY-minY+1);
  }
  public static Bitmap CropScale(Bitmap src, Rectangle crop, int w, int h, bool flip) {
    var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
    using (var g = Graphics.FromImage(bmp)) {
      g.InterpolationMode = InterpolationMode.HighQualityBicubic;
      g.SmoothingMode = SmoothingMode.HighQuality;
      g.PixelOffsetMode = PixelOffsetMode.HighQuality;
      if (flip) { g.TranslateTransform(w, 0); g.ScaleTransform(-1, 1); }
      using (var ia = new ImageAttributes()) {
        ia.SetWrapMode(WrapMode.TileFlipXY);
        g.DrawImage(src, new Rectangle(0,0,w,h), crop.X, crop.Y, crop.Width, crop.Height, GraphicsUnit.Pixel, ia);
      }
    }
    return bmp;
  }
}
"@

# name | knee(光暈修剪門檻) | flip(水平翻轉) | cropLeft(先裁掉左緣比例) | targetW(輸出寬)
$jobs = @(
  @{ n='BG003';   knee=40;  flip=$false; cropL=0;    tw=720 },
  @{ n='BG004';   knee=40;  flip=$false; cropL=0;    tw=680 },
  @{ n='OBS001';  knee=110; flip=$false; cropL=0;    tw=560 },
  @{ n='OBS002';  knee=110; flip=$false; cropL=0;    tw=520 },
  @{ n='OBS003';  knee=110; flip=$false; cropL=0;    tw=660 },
  @{ n='OBS101';  knee=110; flip=$true;  cropL=0;    tw=460 },
  @{ n='OBS102';  knee=110; flip=$false; cropL=0.24; tw=640 },
  @{ n='OBS103';  knee=110; flip=$true;  cropL=0;    tw=500 },
  @{ n='ITEM001'; knee=8;   flip=$false; cropL=0;    tw=256 },
  @{ n='ITEM002'; knee=8;   flip=$false; cropL=0;    tw=272 }
)

foreach ($j in $jobs) {
  $raw = [System.Drawing.Bitmap]::FromFile((Join-Path $src "$($j.n).png"))
  $img = New-Object System.Drawing.Bitmap($raw); $raw.Dispose()
  [Asset2]::AlphaKnee($img, $j.knee)
  $bb = [Asset2]::AlphaBounds($img, 10)
  if ($j.cropL -gt 0) {
    $cut = [int]($img.Width * $j.cropL)
    if ($bb.X -lt $cut) { $bb.Width = $bb.Width - ($cut - $bb.X); $bb.X = $cut }
  }
  $tw = $j.tw; $th = [int]($tw * $bb.Height / $bb.Width)
  $out = [Asset2]::CropScale($img, $bb, $tw, $th, $j.flip)
  $out.Save((Join-Path $dst "$($j.n).png"), [System.Drawing.Imaging.ImageFormat]::Png)
  Write-Host ("{0}: crop {1},{2} {3}x{4} -> {5}x{6}{7}" -f $j.n, $bb.X, $bb.Y, $bb.Width, $bb.Height, $tw, $th, $(if ($j.flip) { ' (翻轉)' } else { '' }))
  $out.Dispose(); $img.Dispose()
}

# 預覽：鋪在天空藍→草綠漸層上（模擬遊戲背景），檢查光暈效果
$pv = New-Object System.Drawing.Bitmap(1600, 900)
$g = [System.Drawing.Graphics]::FromImage($pv)
$br = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.Point(0,0)), (New-Object System.Drawing.Point(0,900)), [System.Drawing.Color]::FromArgb(140,200,255), [System.Drawing.Color]::FromArgb(110,190,90))
$g.FillRectangle($br, 0, 0, 1600, 900)
$i = 0
foreach ($j in $jobs) {
  $im = [System.Drawing.Bitmap]::FromFile((Join-Path $dst "$($j.n).png"))
  $cw = 320; $ch = [int]($cw * $im.Height / $im.Width)
  if ($ch -gt 420) { $ch = 420; $cw = [int]($ch * $im.Width / $im.Height) }
  $x = ($i % 5) * 320 + (320 - $cw) / 2; $y = [int][Math]::Floor($i / 5) * 450 + (440 - $ch)
  $g.DrawImage($im, [int]$x, [int]$y, $cw, $ch)
  $im.Dispose(); $i++
}
$g.Dispose(); $br.Dispose()
$codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
$ep = New-Object System.Drawing.Imaging.EncoderParameters(1)
$ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]88)
$pv.Save((Join-Path $dst '_assets2preview.jpg'), $codec, $ep)
$pv.Dispose()
Write-Host 'OK preview'
