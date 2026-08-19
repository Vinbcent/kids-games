# 素材後處理：pic\_raw\ -> pic\opt\
#
# 三路自動分流去背（實測遊戲7 素材三種情況都出現過）：
#   1. 真 alpha（透明像素 >5%）                           -> AlphaKnee 修光暈
#   2. 假透明棋盤格（雙峰亮灰 244/254）                   -> RemoveCheckerBg
#   3. 純色不透明底（例：CH201/CH301 的 #D4CAC0 米色底）  -> RemoveSolidBg 邊緣 flood fill
#
# 用法：
#   .\build.ps1 -Game "遊戲7-蓋廟大作戰"
#   .\build.ps1 -Game "遊戲7-蓋廟大作戰" -Only CH201,CH301   # 只重跑某幾張
#
# 設定來源：遊戲資料夾下的 assets.json
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string] $Game,
  [string[]] $Only = @(),
  [switch]   $NoContact
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$dir  = Join-Path $repo $Game
$raw  = Join-Path $dir 'pic\_raw'
$opt  = Join-Path $dir 'pic\opt'
$tmpd = Join-Path $dir 'pic\_tmp'
$cfgP = Join-Path $dir 'assets.json'
if (-not (Test-Path $raw))  { throw "找不到 $raw" }
if (-not (Test-Path $cfgP)) { throw "找不到 $cfgP" }
New-Item -ItemType Directory -Force $opt  | Out-Null
New-Item -ItemType Directory -Force $tmpd | Out-Null

# WebP 用 ffmpeg 編碼（System.Drawing 不會寫 webp）。實測同一張廟宇圖：
#   PNG 1666KB -> WebP q80 約 213KB（省 88%），而 alpha 通道 PSNR = inf（libwebp 預設無損壓 alpha）
$ffmpeg = (Get-Command ffmpeg -ErrorAction SilentlyContinue)
if (-not $ffmpeg) { Write-Host '找不到 ffmpeg，webp 輸出會自動退回 png' -ForegroundColor Yellow }

$cfg = Get-Content $cfgP -Raw -Encoding UTF8 | ConvertFrom-Json

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
public static class Build {

  // ---- 診斷：透明像素比例 ----
  public static double TransparentRatio(Bitmap b) {
    int w=b.Width, h=b.Height; long n=0;
    var d = b.LockBits(new Rectangle(0,0,w,h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
    unsafe { byte* p=(byte*)d.Scan0;
      for (int y=0;y<h;y++){ byte* r=p+y*d.Stride; for(int x=0;x<w;x++) if(r[x*4+3]<16) n++; } }
    b.UnlockBits(d);
    return (double)n/(w*(long)h);
  }

  // ---- 診斷：邊緣像素像不像棋盤格（兩個相近的亮色調峰值）----
  public static bool LooksChecker(Bitmap b) {
    int w=b.Width, h=b.Height;
    var hist = new int[256];
    var d = b.LockBits(new Rectangle(0,0,w,h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
    unsafe { byte* p=(byte*)d.Scan0;
      for (int y=0;y<h;y++){
        if (y>6 && y<h-7) continue;
        byte* r=p+y*d.Stride;
        for(int x=0;x<w;x++){
          int bb=r[x*4], gg=r[x*4+1], rr=r[x*4+2];
          int mx=Math.Max(rr,Math.Max(gg,bb)), mn=Math.Min(rr,Math.Min(gg,bb));
          if (mx-mn <= 14 && mx >= 200) hist[mx]++;
        } } }
    b.UnlockBits(d);
    int m1=0; for(int v=1;v<256;v++) if(hist[v]>hist[m1]) m1=v;
    int m2=-1; for(int v=0;v<256;v++){ if(Math.Abs(v-m1)<5) continue; if(m2<0||hist[v]>hist[m2]) m2=v; }
    if (m2<0 || hist[m1]==0) return false;
    int gap = Math.Abs(m1-m2);
    return gap>=6 && gap<=22 && hist[m2] > hist[m1]*0.25;
  }

  // ---- 去背 1：假透明棋盤格（沿用 optimize.ps1 已驗證的演算法）----
  static bool BgLike(byte r, byte g, byte b) {
    int mx = Math.Max(r, Math.Max(g, b)), mn = Math.Min(r, Math.Min(g, b));
    int diff = mx - mn;
    return (diff <= 14 && mx >= 232) || (diff <= 10 && mx >= 165);
  }
  public static void RemoveCheckerBg(Bitmap bmp) {
    int w=bmp.Width, h=bmp.Height, n=w*h;
    var d = bmp.LockBits(new Rectangle(0,0,w,h), ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
    unsafe {
      byte* p0=(byte*)d.Scan0;
      bool[] like=new bool[n]; byte[] mxv=new byte[n];
      for(int y=0;y<h;y++){ byte* row=p0+y*d.Stride;
        for(int x=0;x<w;x++){ byte b=row[x*4],g=row[x*4+1],r=row[x*4+2];
          like[y*w+x]=BgLike(r,g,b); mxv[y*w+x]=Math.Max(r,Math.Max(g,b)); } }
      var isBg=new bool[n]; var stack=new Stack<int>();
      Action<int> push = i => { if (like[i] && !isBg[i]) { isBg[i]=true; stack.Push(i); } };
      for(int x=0;x<w;x++){ push(x); push((h-1)*w+x); }
      for(int y=0;y<h;y++){ push(y*w); push(y*w+w-1); }
      while(stack.Count>0){ int i=stack.Pop(); int x=i%w,y=i/w;
        if(x>0)push(i-1); if(x<w-1)push(i+1); if(y>0)push(i-w); if(y<h-1)push(i+w); }
      var seen=(bool[])isBg.Clone(); var region=new List<int>();
      for(int s=0;s<n;s++){
        if(!like[s]||seen[s]) continue;
        region.Clear(); seen[s]=true; stack.Push(s);
        while(stack.Count>0){ int i=stack.Pop(); region.Add(i); int x=i%w,y=i/w;
          if(x>0   && like[i-1] && !seen[i-1]){seen[i-1]=true;stack.Push(i-1);}
          if(x<w-1 && like[i+1] && !seen[i+1]){seen[i+1]=true;stack.Push(i+1);}
          if(y>0   && like[i-w] && !seen[i-w]){seen[i-w]=true;stack.Push(i-w);}
          if(y<h-1 && like[i+w] && !seen[i+w]){seen[i+w]=true;stack.Push(i+w);} }
        if(region.Count<60) continue;
        int[] hist=new int[256]; foreach(int i in region) hist[mxv[i]]++;
        int m1=0; for(int v=1;v<256;v++) if(hist[v]>hist[m1]) m1=v;
        int m2=-1; for(int v=0;v<256;v++){ if(Math.Abs(v-m1)<5) continue; if(m2<0||hist[v]>hist[m2]) m2=v; }
        if(m2<0) continue;
        int gap=Math.Abs(m1-m2); long cov=0;
        for(int v=0;v<256;v++) if(Math.Abs(v-m1)<=2||Math.Abs(v-m2)<=2) cov+=hist[v];
        if(gap>=6 && gap<=22 && cov>=region.Count*0.7) foreach(int i in region) isBg[i]=true;
      }
      Erode1AndApply(p0, d.Stride, w, h, isBg);
    }
    bmp.UnlockBits(d);
  }

  // ---- 去背 2：純色不透明底（從四邊 flood fill，色距在容差內就算背景）----
  //      比「全圖同色一律刪」安全：角色身上出現同色不會被挖洞，因為沒連到邊緣
  public static void RemoveSolidBg(Bitmap bmp, int tol) {
    int w=bmp.Width, h=bmp.Height, n=w*h;
    var d = bmp.LockBits(new Rectangle(0,0,w,h), ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
    unsafe {
      byte* p0=(byte*)d.Scan0;
      int[] xs={2,w-3,2,w-3,w/2,w/2,2,w-3}, ys={2,2,h-3,h-3,2,h-3,h/2,h/2};
      var rs=new List<int>(); var gs=new List<int>(); var bs=new List<int>();
      for(int k=0;k<8;k++){ byte* q=p0+ys[k]*d.Stride+xs[k]*4; bs.Add(q[0]); gs.Add(q[1]); rs.Add(q[2]); }
      rs.Sort(); gs.Sort(); bs.Sort();
      int kr=rs[4], kg=gs[4], kb=bs[4];
      var isBg=new bool[n]; var stack=new Stack<int>();
      Func<int,bool> near = i => { int x=i%w,y=i/w; byte* q=p0+y*d.Stride+x*4;
        return Math.Abs(q[2]-kr)<=tol && Math.Abs(q[1]-kg)<=tol && Math.Abs(q[0]-kb)<=tol; };
      Action<int> push = i => { if(!isBg[i] && near(i)){ isBg[i]=true; stack.Push(i); } };
      for(int x=0;x<w;x++){ push(x); push((h-1)*w+x); }
      for(int y=0;y<h;y++){ push(y*w); push(y*w+w-1); }
      while(stack.Count>0){ int i=stack.Pop(); int x=i%w,y=i/w;
        if(x>0)push(i-1); if(x<w-1)push(i+1); if(y>0)push(i-w); if(y<h-1)push(i+w); }
      Erode1AndApply(p0, d.Stride, w, h, isBg);
    }
    bmp.UnlockBits(d);
  }

  // 邊界向內收 1px（吃掉與背景混色的邊）後套用透明
  static unsafe void Erode1AndApply(byte* p0, int stride, int w, int h, bool[] isBg) {
    var grow=new List<int>();
    for(int y=0;y<h;y++) for(int x=0;x<w;x++){ int i=y*w+x;
      if(isBg[i]) continue;
      if((x>0&&isBg[i-1])||(x<w-1&&isBg[i+1])||(y>0&&isBg[i-w])||(y<h-1&&isBg[i+w])) grow.Add(i); }
    foreach(int i in grow) isBg[i]=true;
    for(int y=0;y<h;y++){ byte* row=p0+y*stride;
      for(int x=0;x<w;x++) if(isBg[y*w+x]){ row[x*4]=0; row[x*4+1]=0; row[x*4+2]=0; row[x*4+3]=0; } }
  }

  // ---- 邊緣羽化：四邊往內 pct 比例做 alpha 線性淡出 ----
  //      給「鋪在既有純色面上的貼圖」用（例如地面），讓它自然融進底色而不是一條硬邊
  public static void FeatherEdges(Bitmap bmp, double pct) {
    if (pct <= 0) return;
    int w=bmp.Width, h=bmp.Height;
    int fx=Math.Max(1,(int)(w*pct)), fy=Math.Max(1,(int)(h*pct));
    var d=bmp.LockBits(new Rectangle(0,0,w,h), ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
    unsafe { byte* p=(byte*)d.Scan0;
      for(int y=0;y<h;y++){ byte* row=p+y*d.Stride;
        double fyv = Math.Min(1.0, Math.Min(y, h-1-y) / (double)fy);
        for(int x=0;x<w;x++){
          double fxv = Math.Min(1.0, Math.Min(x, w-1-x) / (double)fx);
          double f = Math.Min(fxv, fyv);
          row[x*4+3] = (byte)(row[x*4+3] * f);
        } } }
    bmp.UnlockBits(d);
  }

  // ---- 修半透明光暈 ----
  public static void AlphaKnee(Bitmap bmp, int knee) {
    if (knee<=0) return;
    var d=bmp.LockBits(new Rectangle(0,0,bmp.Width,bmp.Height), ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
    unsafe { byte* p=(byte*)d.Scan0;
      for(int y=0;y<bmp.Height;y++){ byte* row=p+y*d.Stride;
        for(int x=0;x<bmp.Width;x++){ int a=row[x*4+3];
          row[x*4+3]=(byte)(a<=knee ? 0 : (a-knee)*255/(255-knee)); } } }
    bmp.UnlockBits(d);
  }

  public static Rectangle AlphaBounds(Bitmap b, int thr) {
    var d=b.LockBits(new Rectangle(0,0,b.Width,b.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
    int minX=b.Width,minY=b.Height,maxX=-1,maxY=-1;
    unsafe { byte* p=(byte*)d.Scan0;
      for(int y=0;y<b.Height;y++){ byte* row=p+y*d.Stride;
        for(int x=0;x<b.Width;x++) if(row[x*4+3]>thr){
          if(x<minX)minX=x; if(x>maxX)maxX=x; if(y<minY)minY=y; if(y>maxY)maxY=y; } } }
    b.UnlockBits(d);
    if(maxX<0) return new Rectangle(0,0,b.Width,b.Height);
    return new Rectangle(minX,minY,maxX-minX+1,maxY-minY+1);
  }

  public static Bitmap CropScale(Bitmap src, Rectangle crop, int w, int h, bool flip) {
    var bmp=new Bitmap(w,h,PixelFormat.Format32bppArgb);
    using(var g=Graphics.FromImage(bmp)){
      g.InterpolationMode=InterpolationMode.HighQualityBicubic;
      g.SmoothingMode=SmoothingMode.HighQuality;
      g.PixelOffsetMode=PixelOffsetMode.HighQuality;
      g.CompositingQuality=CompositingQuality.HighQuality;
      if(flip){ g.TranslateTransform(w,0); g.ScaleTransform(-1,1); }
      using(var ia=new ImageAttributes()){
        ia.SetWrapMode(WrapMode.TileFlipXY);
        g.DrawImage(src, new Rectangle(0,0,w,h), crop.X,crop.Y,crop.Width,crop.Height, GraphicsUnit.Pixel, ia);
      } }
    return bmp;
  }
}
"@

function Save-Jpg([System.Drawing.Bitmap]$bmp, [string]$path, [int]$q) {
  $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
  $ep = New-Object System.Drawing.Imaging.EncoderParameters(1)
  $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]$q)
  $bmp.Save($path, $codec, $ep)
}

# 攤平 assets.json 的批次結構
$items = @()
foreach ($batch in $cfg.批次) { foreach ($a in $batch.素材) { $items += $a } }
if ($Only.Count -gt 0) { $items = $items | Where-Object { $Only -contains $_.id } }

$report = @()
foreach ($a in $items) {
  $src = Join-Path $raw "$($a.id).png"
  if (-not (Test-Path $src)) { Write-Host ("SKIP {0}  (pic\_raw 沒有這個檔)" -f $a.id) -ForegroundColor DarkGray; continue }

  $tmp  = [System.Drawing.Bitmap]::FromFile($src)
  $srcW = $tmp.Width; $srcH = $tmp.Height
  $img  = New-Object System.Drawing.Bitmap($srcW, $srcH, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g0   = [System.Drawing.Graphics]::FromImage($img)
  $g0.Clear([System.Drawing.Color]::Transparent)
  $g0.DrawImage($tmp, 0, 0, $srcW, $srcH)
  $g0.Dispose(); $tmp.Dispose()

  $o     = $a.輸出
  $knee  = if ($null -ne $o.knee) { [int]$o.knee } else { 60 }
  $trim  = [bool]$o.裁切
  $flip  = [bool]$o.水平翻轉
  $fmt   = if ($o.格式) { $o.格式 } elseif ($ffmpeg) { 'webp' } else { 'png' }
  $wq    = if ($null -ne $o.webp品質) { [int]$o.webp品質 } else { 80 }
  $dekey = if ($null -ne $o.去背) { [bool]$o.去背 } else { $true }

  # ---- 三路分流 ----
  $tr = [Build]::TransparentRatio($img)
  if (-not $dekey) {
    # 滿版背景之類不需要去背的素材。少了這個旗標，BG001 會被誤判成「純色底」
    # 而從天空邊緣往內 flood fill——這次只是運氣好（天空有雲有漸層，很快就停）
    $route = '不去背'
  } elseif ($tr -gt 0.05) {
    $route = '真alpha'
    [Build]::AlphaKnee($img, $knee)
  } elseif ([Build]::LooksChecker($img)) {
    $route = '棋盤格'
    [Build]::RemoveCheckerBg($img)
  } else {
    $route = '純色底'
    $tol = if ($null -ne $o.純色容差) { [int]$o.純色容差 } else { 26 }
    [Build]::RemoveSolidBg($img, $tol)
  }

  # ---- 邊緣羽化（鋪在既有色面上的貼圖用，例如地面）----
  if ($null -ne $o.邊緣淡出) { [Build]::FeatherEdges($img, [double]$o.邊緣淡出) }

  # ---- 裁切 / 縮放 ----
  if ($trim) { $bb = [Build]::AlphaBounds($img, 12) }
  else       { $bb = New-Object System.Drawing.Rectangle(0, 0, $img.Width, $img.Height) }
  $tw = if ($o.w) { [int]$o.w } else { 512 }
  $th = if ($o.h) { [int]$o.h } else { [int][Math]::Round($tw * $bb.Height / $bb.Width) }
  $out = [Build]::CropScale($img, $bb, $tw, $th, $flip)

  # ---- 存檔 ----
  # 一律先出一張 PNG 到 _tmp（contact sheet 用得到，System.Drawing 讀不了 webp）
  $mid = Join-Path $tmpd "$($a.id).png"
  $out.Save($mid, [System.Drawing.Imaging.ImageFormat]::Png)
  Get-ChildItem $opt -File -Filter "$($a.id).*" | Remove-Item -Force   # 清掉上一輪其他格式的殘檔

  if ($fmt -eq 'jpg') {
    $dst  = Join-Path $opt "$($a.id).jpg"
    $flat = New-Object System.Drawing.Bitmap($tw, $th)
    $gg   = [System.Drawing.Graphics]::FromImage($flat)
    $gg.Clear([System.Drawing.Color]::White); $gg.DrawImage($out, 0, 0, $tw, $th); $gg.Dispose()
    Save-Jpg $flat $dst 85; $flat.Dispose()
  } elseif ($fmt -eq 'webp' -and $ffmpeg) {
    $dst = Join-Path $opt "$($a.id).webp"
    & ffmpeg -y -loglevel error -i $mid -c:v libwebp -quality $wq -compression_level 6 $dst
    if (-not (Test-Path $dst)) { throw "ffmpeg 編碼 webp 失敗：$($a.id)" }
  } else {
    $dst = Join-Path $opt "$($a.id).png"
    Copy-Item $mid $dst -Force
  }
  $kb  = [int]((Get-Item $dst).Length / 1KB)
  $cov = [int](100.0 * $bb.Width * $bb.Height / ($srcW * $srcH))

  Write-Host ("OK   {0,-8} {1,-8} {2,4}x{3,-5} -> {4,4}x{5,-5} {6,5}KB {7,-5} 內容{8,3}%  {9}" -f `
    $a.id, $route, $srcW, $srcH, $tw, $th, $kb, $fmt, $cov, $(if ($flip) { '翻轉' } else { '' }))

  $report += [pscustomobject]@{ id = $a.id; 分流 = $route; 原始 = "${srcW}x${srcH}"; 輸出 = "${tw}x${th}"; 格式 = $fmt; KB = $kb; 內容佔比 = $cov }
  $out.Dispose(); $img.Dispose()
}

$report | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $opt '_build.json') -Encoding UTF8

if (-not $NoContact) {
  & (Join-Path $PSScriptRoot 'contact.ps1') -Dir $tmpd -SizeFrom $opt -Out (Join-Path $opt '_contact.jpg')
}
Write-Host ("`n完成 {0} 張 -> {1}" -f $report.Count, $opt) -ForegroundColor Green
