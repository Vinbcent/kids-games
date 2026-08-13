# 一次性素材優化：pic/ -> pic/opt/
# 1) 去除 AI 圖的「假透明棋盤格」背景（含腳下陰影、封閉孔洞）
# 2) 角色縮到 512x512、BG001 轉 JPG、BG002 依內容裁切
Add-Type -AssemblyName System.Drawing

$src = Join-Path $PSScriptRoot 'pic'
$dst = Join-Path $src 'opt'
New-Item -ItemType Directory -Force $dst | Out-Null

$cp = New-Object System.CodeDom.Compiler.CompilerParameters
$cp.CompilerOptions = '/unsafe'
[void]$cp.ReferencedAssemblies.Add('System.dll')
[void]$cp.ReferencedAssemblies.Add('System.Core.dll')
[void]$cp.ReferencedAssemblies.Add('System.Drawing.dll')

Add-Type -CompilerParameters $cp -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Drawing.Drawing2D;
public static class ImgOpt {
  // 判斷是否像「棋盤格背景」像素：亮的中性色（棋盤格）或灰陰影
  static bool BgLike(byte r, byte g, byte b) {
    int mx = Math.Max(r, Math.Max(g, b)), mn = Math.Min(r, Math.Min(g, b));
    int diff = mx - mn;
    return (diff <= 14 && mx >= 232) || (diff <= 10 && mx >= 165);
  }

  public static void RemoveCheckerBg(Bitmap bmp) {
    int w = bmp.Width, h = bmp.Height, n = w * h;
    var d = bmp.LockBits(new Rectangle(0,0,w,h), ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
    unsafe {
      byte* p0 = (byte*)d.Scan0;
      bool[] like = new bool[n];
      byte[] mxv = new byte[n];
      for (int y=0; y<h; y++) { byte* row = p0 + y*d.Stride;
        for (int x=0; x<w; x++) { byte b=row[x*4], g=row[x*4+1], r=row[x*4+2];
          like[y*w+x] = BgLike(r,g,b); mxv[y*w+x] = Math.Max(r, Math.Max(g,b)); } }

      // 1) 從四邊 flood fill：連到外面的 bgLike 都是背景
      var isBg = new bool[n];
      var stack = new Stack<int>();
      Action<int> push = i => { if (like[i] && !isBg[i]) { isBg[i] = true; stack.Push(i); } };
      for (int x=0; x<w; x++) { push(x); push((h-1)*w + x); }
      for (int y=0; y<h; y++) { push(y*w); push(y*w + w-1); }
      while (stack.Count > 0) { int i = stack.Pop(); int x = i % w, y = i / w;
        if (x > 0) push(i-1); if (x < w-1) push(i+1);
        if (y > 0) push(i-w); if (y < h-1) push(i+w); }

      // 2) 封閉孔洞：沒連到外面的 bgLike 連通區，若呈「兩種色調各佔一定比例」= 棋盤格 → 也是背景
      //    （牙齒/眼白幾乎都是 250+ 的單一色調，不會被誤刪）
      var seen = (bool[])isBg.Clone();
      var region = new List<int>();
      for (int s=0; s<n; s++) {
        if (!like[s] || seen[s]) continue;
        region.Clear(); seen[s] = true; stack.Push(s);
        while (stack.Count > 0) { int i = stack.Pop(); region.Add(i); int x = i % w, y = i / w;
          if (x > 0   && like[i-1] && !seen[i-1]) { seen[i-1]=true; stack.Push(i-1); }
          if (x < w-1 && like[i+1] && !seen[i+1]) { seen[i+1]=true; stack.Push(i+1); }
          if (y > 0   && like[i-w] && !seen[i-w]) { seen[i-w]=true; stack.Push(i-w); }
          if (y < h-1 && like[i+w] && !seen[i+w]) { seen[i+w]=true; stack.Push(i+w); } }
        if (region.Count < 60) continue;
        // 棋盤格特徵：兩個「平坦色調峰值」（例如 244 與 254），合計覆蓋 >= 70%
        // 眼白/牙齒是連續漸層，覆蓋率不會這麼高，不會被誤刪
        int[] hist = new int[256];
        foreach (int i in region) hist[mxv[i]]++;
        int m1 = 0; for (int v=1; v<256; v++) if (hist[v] > hist[m1]) m1 = v;
        int m2 = -1; for (int v=0; v<256; v++) { if (Math.Abs(v-m1) < 5) continue; if (m2 < 0 || hist[v] > hist[m2]) m2 = v; }
        if (m2 < 0) continue;
        int gap = Math.Abs(m1 - m2);
        long cov = 0;
        for (int v=0; v<256; v++) if (Math.Abs(v-m1) <= 2 || Math.Abs(v-m2) <= 2) cov += hist[v];
        if (gap >= 6 && gap <= 22 && cov >= region.Count * 0.7)
          foreach (int i in region) isBg[i] = true;
      }

      // 3) 邊界向內收 1px（吃掉與背景混色的白邊）
      var grow = new List<int>();
      for (int y=0; y<h; y++) for (int x=0; x<w; x++) { int i=y*w+x;
        if (isBg[i]) continue;
        if ((x>0 && isBg[i-1]) || (x<w-1 && isBg[i+1]) || (y>0 && isBg[i-w]) || (y<h-1 && isBg[i+w]))
          grow.Add(i); }
      foreach (int i in grow) isBg[i] = true;

      // 套用透明
      for (int y=0; y<h; y++) { byte* row = p0 + y*d.Stride;
        for (int x=0; x<w; x++) if (isBg[y*w+x]) { row[x*4]=0; row[x*4+1]=0; row[x*4+2]=0; row[x*4+3]=0; } }
    }
    bmp.UnlockBits(d);
  }

  public static Rectangle AlphaBounds(Bitmap b) {
    var r = new Rectangle(0,0,b.Width,b.Height);
    var d = b.LockBits(r, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
    int minX=b.Width, minY=b.Height, maxX=-1, maxY=-1;
    unsafe {
      byte* p = (byte*)d.Scan0;
      for (int y=0; y<b.Height; y++) { byte* row = p + y*d.Stride;
        for (int x=0; x<b.Width; x++) if (row[x*4+3] > 12) {
          if (x<minX) minX=x; if (x>maxX) maxX=x; if (y<minY) minY=y; if (y>maxY) maxY=y; } }
    }
    b.UnlockBits(d);
    if (maxX < 0) return r;
    return new Rectangle(minX, minY, maxX-minX+1, maxY-minY+1);
  }

  public static Bitmap Resize(Image src, Rectangle crop, int w, int h) {
    var bmp = new Bitmap(w, h, PixelFormat.Format32bppArgb);
    using (var g = Graphics.FromImage(bmp)) {
      g.InterpolationMode = InterpolationMode.HighQualityBicubic;
      g.SmoothingMode = SmoothingMode.HighQuality;
      g.PixelOffsetMode = PixelOffsetMode.HighQuality;
      g.CompositingQuality = CompositingQuality.HighQuality;
      using (var ia = new ImageAttributes()) {
        ia.SetWrapMode(WrapMode.TileFlipXY);  // 避免邊緣半透明黑邊
        g.DrawImage(src, new Rectangle(0,0,w,h), crop.X, crop.Y, crop.Width, crop.Height, GraphicsUnit.Pixel, ia);
      }
    }
    return bmp;
  }
}
"@

function Save-Png([System.Drawing.Bitmap]$bmp, [string]$path) {
  $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
}
function Save-Jpg([System.Drawing.Bitmap]$bmp, [string]$path, [int]$q) {
  $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
  $ep = New-Object System.Drawing.Imaging.EncoderParameters(1)
  $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]$q)
  $bmp.Save($path, $codec, $ep)
}

# 角色：去背 -> 整張縮到 512（不裁切，保留各動作影格對齊）
Get-ChildItem "$src\CHAR*.png" | ForEach-Object {
  $raw = [System.Drawing.Bitmap]::FromFile($_.FullName)
  $img = New-Object System.Drawing.Bitmap($raw); $raw.Dispose()
  [ImgOpt]::RemoveCheckerBg($img)
  $out = [ImgOpt]::Resize($img, (New-Object System.Drawing.Rectangle(0,0,$img.Width,$img.Height)), 512, 512)
  Save-Png $out (Join-Path $dst $_.Name)
  $out.Dispose(); $img.Dispose()
  Write-Host "OK $($_.Name)"
}

# BG001：森林背景 -> 1600 寬 JPG（本來就滿版，不需去背）
$bg1 = [System.Drawing.Bitmap]::FromFile("$src\BG001.png")
$h1 = [int](1600 * $bg1.Height / $bg1.Width)
$out1 = [ImgOpt]::Resize($bg1, (New-Object System.Drawing.Rectangle(0,0,$bg1.Width,$bg1.Height)), 1600, $h1)
Save-Jpg $out1 (Join-Path $dst 'BG001.jpg') 85
$out1.Dispose(); $bg1.Dispose()
Write-Host "OK BG001.jpg 1600x$h1"

# BG002：地面 -> 去背 -> 依內容裁切 -> 1400 寬 PNG
$bg2raw = [System.Drawing.Bitmap]::FromFile("$src\BG002.png")
$bg2 = New-Object System.Drawing.Bitmap($bg2raw); $bg2raw.Dispose()
[ImgOpt]::RemoveCheckerBg($bg2)
$bb = [ImgOpt]::AlphaBounds($bg2)
Write-Host "BG002 bounds: $($bb.X),$($bb.Y) $($bb.Width)x$($bb.Height)"
$w2 = 1400; $h2 = [int]($w2 * $bb.Height / $bb.Width)
$out2 = [ImgOpt]::Resize($bg2, $bb, $w2, $h2)
Save-Png $out2 (Join-Path $dst 'BG002.png')
$out2.Dispose(); $bg2.Dispose()
Write-Host "OK BG002.png ${w2}x$h2"

# 預覽圖：把去背結果鋪在洋紅色上，方便人工檢查
$preview = New-Object System.Drawing.Bitmap(1536, 1024)
$g = [System.Drawing.Graphics]::FromImage($preview)
$g.Clear([System.Drawing.Color]::Magenta)
$i = 0
foreach ($n in @('CHAR001.png','CHAR002.png','CHAR006.png','CHAR007.png','CHAR008.png','CHAR101.png','CHAR201.png','BG002.png')) {
  $im = [System.Drawing.Bitmap]::FromFile((Join-Path $dst $n))
  $x = ($i % 4) * 384; $y = [int][Math]::Floor($i / 4) * 512
  $g.DrawImage($im, (New-Object System.Drawing.Rectangle($x, $y, 384, 384)))
  $im.Dispose(); $i++
}
$g.Dispose()
Save-Jpg $preview (Join-Path $dst '_preview.jpg') 88
$preview.Dispose()
Write-Host 'OK _preview.jpg'
