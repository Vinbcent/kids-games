# 跑步改善四影格處理：pic/跑步改善/run_frame_0*.png -> pic/opt/RUN1..4.png
# 1) 清掉小殘片（如 frame04 上緣被裁到的橘色碎塊）：只保留大的連通區
# 2) 底部基準線對齊（每格內容底部貼齊同一條線，動畫不跳動）
# 3) 縮到 576x384
Add-Type -AssemblyName System.Drawing

$src = Join-Path $PSScriptRoot 'pic\跑步改善'
$dst = Join-Path $PSScriptRoot 'pic\opt'

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
public static class RunFix {
  // 只保留 >= 最大連通區 8% 的部件，其餘變透明；回傳保留內容的 bbox
  public static Rectangle KeepBigParts(Bitmap bmp) {
    int w = bmp.Width, h = bmp.Height, n = w * h;
    var d = bmp.LockBits(new Rectangle(0,0,w,h), ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
    int minX=w, minY=h, maxX=-1, maxY=-1;
    unsafe {
      byte* p0 = (byte*)d.Scan0;
      var solid = new bool[n];
      for (int y=0; y<h; y++) { byte* row = p0 + y*d.Stride;
        for (int x=0; x<w; x++) solid[y*w+x] = row[x*4+3] > 12; }
      var label = new int[n]; for (int i=0;i<n;i++) label[i] = -1;
      var sizes = new List<long>();
      var stack = new Stack<int>();
      for (int s=0; s<n; s++) {
        if (!solid[s] || label[s] >= 0) continue;
        int id = sizes.Count; long cnt = 0;
        label[s] = id; stack.Push(s);
        while (stack.Count > 0) { int i = stack.Pop(); cnt++; int x = i % w, y = i / w;
          if (x>0   && solid[i-1] && label[i-1]<0) { label[i-1]=id; stack.Push(i-1); }
          if (x<w-1 && solid[i+1] && label[i+1]<0) { label[i+1]=id; stack.Push(i+1); }
          if (y>0   && solid[i-w] && label[i-w]<0) { label[i-w]=id; stack.Push(i-w); }
          if (y<h-1 && solid[i+w] && label[i+w]<0) { label[i+w]=id; stack.Push(i+w); } }
        sizes.Add(cnt);
      }
      long biggest = 0; foreach (long s2 in sizes) if (s2 > biggest) biggest = s2;
      for (int y=0; y<h; y++) { byte* row = p0 + y*d.Stride;
        for (int x=0; x<w; x++) { int i=y*w+x;
          if (!solid[i]) continue;
          if (sizes[label[i]] < biggest * 0.08) { row[x*4]=0; row[x*4+1]=0; row[x*4+2]=0; row[x*4+3]=0; }
          else { if (x<minX) minX=x; if (x>maxX) maxX=x; if (y<minY) minY=y; if (y>maxY) maxY=y; }
        } }
    }
    bmp.UnlockBits(d);
    return new Rectangle(minX, minY, Math.Max(1,maxX-minX+1), Math.Max(1,maxY-minY+1));
  }
  public static Bitmap ComposeBaseline(Bitmap src, Rectangle bb, int outW, int outH, int bottomMargin) {
    // 內容底部貼齊 outH-bottomMargin，水平位置維持原樣
    var bmp = new Bitmap(src.Width, src.Height, PixelFormat.Format32bppArgb);
    using (var g = Graphics.FromImage(bmp)) {
      g.CompositingMode = CompositingMode.SourceCopy;
      int dy = (src.Height - bottomMargin) - (bb.Y + bb.Height);
      g.DrawImage(src, 0, dy, src.Width, src.Height);
    }
    var outBmp = new Bitmap(outW, outH, PixelFormat.Format32bppArgb);
    using (var g = Graphics.FromImage(outBmp)) {
      g.InterpolationMode = InterpolationMode.HighQualityBicubic;
      g.SmoothingMode = SmoothingMode.HighQuality;
      g.PixelOffsetMode = PixelOffsetMode.HighQuality;
      using (var ia = new ImageAttributes()) {
        ia.SetWrapMode(WrapMode.TileFlipXY);
        g.DrawImage(bmp, new Rectangle(0,0,outW,outH), 0, 0, bmp.Width, bmp.Height, GraphicsUnit.Pixel, ia);
      }
    }
    bmp.Dispose();
    return outBmp;
  }
}
"@

for ($n = 1; $n -le 4; $n++) {
  $raw = [System.Drawing.Bitmap]::FromFile((Join-Path $src "run_frame_0$n.png"))
  $img = New-Object System.Drawing.Bitmap($raw); $raw.Dispose()
  $bb = [RunFix]::KeepBigParts($img)
  $out = [RunFix]::ComposeBaseline($img, $bb, 576, 384, 8)
  $out.Save((Join-Path $dst "RUN$n.png"), [System.Drawing.Imaging.ImageFormat]::Png)
  Write-Host ("RUN{0}: bbox {1},{2} {3}x{4}  centerX={5:P0}" -f $n, $bb.X, $bb.Y, $bb.Width, $bb.Height, (($bb.X + $bb.Width/2) / $img.Width))
  $out.Dispose(); $img.Dispose()
}
Write-Host 'OK'
