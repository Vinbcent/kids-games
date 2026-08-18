# 素材自動驗收 QA：量測 pic/opt（或任一資料夾）的圖，輸出 JSON 報告 + contact sheet
#
# 用法：
#   .\qa.ps1 -Path "..\..\遊戲8-超級松鼠小旋風\pic\opt"
#   .\qa.ps1 -Path ".\pic\_raw\CHAR004.png" -Ref ".\pic\opt\CHAR001.png"
#   .\qa.ps1 -Path ".\pic\_raw\RUNSHEET.png" -SheetGrid 2x2      # 檢查 sprite sheet 分格留白
#
# 回傳碼：0 = 全部 pass（可含 warn）；1 = 有 fail；2 = 腳本錯誤
# 風格比照 optimize.ps1 / assets2.ps1：Add-Type + /unsafe + LockBits
[CmdletBinding()]
param(
  [string]   $Path        = '.',
  [string[]] $Include     = @('*.png','*.jpg'),
  [string]   $Manifest    = '',                # assets.json（可選，覆寫門檻）
  [string]   $Json        = '',                # 預設 <Path>\_qa_report.json
  [string]   $SheetOut    = '',                # 預設 <Path>\_qa_sheet.jpg
  [switch]   $NoSheet,
  [string]   $Ref         = '',                # 畫風比對參考圖（色彩直方圖距離）
  [string]   $SheetGrid   = '',                # '2x2' / '4x1' / '2x1'：檢查分格留白
  [ValidateSet('auto','raw','out')]
  [string]   $Stage       = 'auto',            # raw=剛下載的原圖(驗構圖) / out=後處理輸出(驗成品)
  [switch]   $Translucent,                     # 主體本來就有半透明區（翅膀、玻璃）→ 放寬柔邊檢查
  [int]      $AlphaThr    = 12,
  [int]      $PaletteTol  = 90,
  [switch]   $Quiet
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------- C# 量測核心
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

public class QaComp {
  public long Size; public int X0, Y0, X1, Y1;
  public double CY { get { return (Y0 + Y1) / 2.0; } }
  public int BW { get { return X1 - X0 + 1; } }
  public int BH { get { return Y1 - Y0 + 1; } }
}

public class QaMetrics {
  public int W, H, MaxAlpha;
  public bool Empty;
  public double OpaqueRatio;        // a>=250 佔全畫布
  public double AnyRatio;           // a>thr 佔全畫布
  public double HaloRatio;          // 20<=a<=235 佔內容像素（半透明像素比例）
  public double EdgeSoftPx;         // 半透明像素 / 不透明核心周長 ≒ 平均柔邊寬度(px)，1.0=乾淨抗鋸齒
  public double AreaFrac;           // 內容像素 / 全畫布（同組影格的尺度代理量，比 bbox 高度穩）
  public double ZeroColoredRatio;   // a==0 但 RGB!=0 的比例（未清色，縮放會滲色）
  public int BX, BY, BW, BH;        // 全內容 bbox
  public int MX, MY, MW, MH;        // 最大連通區 bbox
  public double FillRatio;          // 內容像素 / bbox 面積
  public int CompCount, FragCount;
  public long CompBiggest, CompOther;
  public double EdgeTop, EdgeBottom, EdgeLeft, EdgeRight;   // 畫布 1px 邊框的內容比例
  public double ColLeftOpaque, ColRightOpaque, SeamDiff;    // 平鋪用
  public double MagentaRatio;       // min(R,B)-G>110（色鍵誤刪風險 / 洋紅殘留）
  public double NeutralBrightRatio; // 近中性且很亮（棋盤格殘留嫌疑）
  public int TextLines, TextGlyphs; // 疑似文字（弱啟發式）
  public string[] TopColors;
  public double[] TopShares;
  public double PaletteCoverage;
  public double[] PalShare;         // 每個配色表顏色各佔多少（最近色歸屬）→ 可驗「招牌色有沒有出現」
  public int[] Hist;                // 4bit x3 = 4096 bins（畫風比對）
  public int GutterX, GutterXW, GutterY, GutterYH;  // sprite sheet 分格留白
}

public static class AssetQa {

  static double RedMean(int r1, int g1, int b1, int r2, int g2, int b2) {
    double rm = (r1 + r2) / 2.0;
    double dr = r1 - r2, dg = g1 - g2, db = b1 - b2;
    return Math.Sqrt((2 + rm / 256.0) * dr * dr + 4 * dg * dg + (2 + (255 - rm) / 256.0) * db * db);
  }

  public static QaMetrics Measure(Bitmap bmp, int thr, int[] pal, int palTol) {
    int w = bmp.Width, h = bmp.Height, n = w * h;
    QaMetrics m = new QaMetrics();
    m.W = w; m.H = h;

    byte[] A = new byte[n], R = new byte[n], G = new byte[n], B = new byte[n];
    BitmapData d = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
    unsafe {
      byte* p0 = (byte*)d.Scan0;
      for (int y = 0; y < h; y++) {
        byte* row = p0 + y * d.Stride;
        for (int x = 0; x < w; x++) {
          int i = y * w + x;
          B[i] = row[x * 4]; G[i] = row[x * 4 + 1]; R[i] = row[x * 4 + 2]; A[i] = row[x * 4 + 3];
        }
      }
    }
    bmp.UnlockBits(d);

    // ---- 基本統計 + bbox
    long cAny = 0, cOpq = 0, cHalo = 0, cZero = 0, cZeroCol = 0, cMag = 0, cNeu = 0;
    int minX = w, minY = h, maxX = -1, maxY = -1, maxA = 0;
    for (int i = 0; i < n; i++) {
      int a = A[i];
      if (a > maxA) maxA = a;
      if (a == 0) { cZero++; if (R[i] != 0 || G[i] != 0 || B[i] != 0) cZeroCol++; }
      if (a >= 250) cOpq++;
      if (a >= 20 && a <= 235) cHalo++;
      if (a > thr) {
        cAny++;
        int x = i % w, y = i / w;
        if (x < minX) minX = x; if (x > maxX) maxX = x;
        if (y < minY) minY = y; if (y > maxY) maxY = y;
      }
      if (a > 128) {
        int k = Math.Min((int)R[i], (int)B[i]) - G[i];
        if (k > 110) cMag++;
        int mx = Math.Max((int)R[i], Math.Max((int)G[i], (int)B[i]));
        int mn = Math.Min((int)R[i], Math.Min((int)G[i], (int)B[i]));
        if (mx - mn <= 14 && mx >= 232) cNeu++;
      }
    }
    // 不透明核心周長：用來把「1px 抗鋸齒」和「好幾 px 的柔光暈」分開
    long peri = 0;
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        int i = y * w + x;
        if (A[i] < 250) continue;
        if (x == 0 || x == w - 1 || y == 0 || y == h - 1 ||
            A[i - 1] < 250 || A[i + 1] < 250 || A[i - w] < 250 || A[i + w] < 250) peri++;
      }
    }
    m.EdgeSoftPx = peri > 0 ? cHalo / (double)peri : (cHalo > 0 ? 99 : 0);
    m.AreaFrac = cAny / (double)n;
    m.MaxAlpha = maxA;
    m.AnyRatio = cAny / (double)n;
    m.OpaqueRatio = cOpq / (double)n;
    m.HaloRatio = cAny > 0 ? cHalo / (double)cAny : 0;
    m.ZeroColoredRatio = cZero > 0 ? cZeroCol / (double)cZero : 0;
    m.MagentaRatio = cAny > 0 ? cMag / (double)cAny : 0;
    m.NeutralBrightRatio = cAny > 0 ? cNeu / (double)cAny : 0;
    if (maxX < 0) { m.Empty = true; m.TopColors = new string[0]; m.TopShares = new double[0]; m.Hist = new int[4096]; return m; }
    m.BX = minX; m.BY = minY; m.BW = maxX - minX + 1; m.BH = maxY - minY + 1;
    m.FillRatio = cAny / (double)(m.BW * (double)m.BH);

    // ---- 畫布 1px 邊框的內容比例（貼邊/被裁切偵測）
    long et = 0, eb = 0, el = 0, er = 0;
    for (int x = 0; x < w; x++) { if (A[x] > thr) et++; if (A[(h - 1) * w + x] > thr) eb++; }
    for (int y = 0; y < h; y++) { if (A[y * w] > thr) el++; if (A[y * w + w - 1] > thr) er++; }
    m.EdgeTop = et / (double)w; m.EdgeBottom = eb / (double)w;
    m.EdgeLeft = el / (double)h; m.EdgeRight = er / (double)h;

    // ---- 左右緣不透明度 + 接縫差（水平平鋪用）
    long lo = 0, ro = 0; double seam = 0; int seamN = 0;
    for (int y = 0; y < h; y++) {
      int i0 = y * w, i1 = y * w + w - 1;
      if (A[i0] >= 250) lo++;
      if (A[i1] >= 250) ro++;
      if (A[i0] >= 250 && A[i1] >= 250) {
        seam += (Math.Abs(R[i0] - R[i1]) + Math.Abs(G[i0] - G[i1]) + Math.Abs(B[i0] - B[i1])) / 765.0;
        seamN++;
      }
    }
    m.ColLeftOpaque = lo / (double)h; m.ColRightOpaque = ro / (double)h;
    m.SeamDiff = seamN > 0 ? seam / seamN : 1.0;

    // ---- 連通區（4 連通）
    int[] label = new int[n];
    for (int i = 0; i < n; i++) label[i] = -1;
    List<QaComp> comps = new List<QaComp>();
    Stack<int> st = new Stack<int>();
    for (int s = 0; s < n; s++) {
      if (A[s] <= thr || label[s] >= 0) continue;
      int id = comps.Count;
      QaComp c = new QaComp();
      c.X0 = w; c.Y0 = h; c.X1 = -1; c.Y1 = -1;
      label[s] = id; st.Push(s);
      while (st.Count > 0) {
        int i = st.Pop(); c.Size++;
        int x = i % w, y = i / w;
        if (x < c.X0) c.X0 = x; if (x > c.X1) c.X1 = x;
        if (y < c.Y0) c.Y0 = y; if (y > c.Y1) c.Y1 = y;
        if (x > 0     && A[i - 1] > thr && label[i - 1] < 0) { label[i - 1] = id; st.Push(i - 1); }
        if (x < w - 1 && A[i + 1] > thr && label[i + 1] < 0) { label[i + 1] = id; st.Push(i + 1); }
        if (y > 0     && A[i - w] > thr && label[i - w] < 0) { label[i - w] = id; st.Push(i - w); }
        if (y < h - 1 && A[i + w] > thr && label[i + w] < 0) { label[i + w] = id; st.Push(i + w); }
      }
      comps.Add(c);
    }
    long big = 0; int bigIdx = 0;
    for (int i = 0; i < comps.Count; i++) if (comps[i].Size > big) { big = comps[i].Size; bigIdx = i; }
    m.CompCount = comps.Count; m.CompBiggest = big; m.CompOther = cAny - big;
    m.MX = comps[bigIdx].X0; m.MY = comps[bigIdx].Y0;
    m.MW = comps[bigIdx].BW; m.MH = comps[bigIdx].BH;
    int frag = 0;
    for (int i = 0; i < comps.Count; i++) if (comps[i].Size < big * 0.08) frag++;
    m.FragCount = frag;

    // ---- 疑似文字（弱啟發式：小、稀疏、成排的獨立連通區）
    List<QaComp> gl = new List<QaComp>();
    for (int i = 0; i < comps.Count; i++) {
      QaComp c = comps[i];
      double frac = c.Size / (double)n;
      double fill = c.Size / (double)(c.BW * (double)c.BH);
      double asp = c.BW / (double)c.BH;
      if (frac > 0.00003 && frac < 0.01 && fill > 0.12 && fill < 0.80 &&
          asp > 0.12 && asp < 3.5 && c.BH >= h * 0.02 && c.BH <= h * 0.20) gl.Add(c);
    }
    gl.Sort(delegate(QaComp a, QaComp b) { return a.CY.CompareTo(b.CY); });
    int lines = 0, glyphs = 0, gi = 0;
    while (gi < gl.Count) {
      int gj = gi + 1;
      double cy = gl[gi].CY, hh = gl[gi].BH;
      while (gj < gl.Count && Math.Abs(gl[gj].CY - cy) < 0.5 * hh && Math.Abs(gl[gj].BH - hh) < 0.5 * hh) gj++;
      int cnt = gj - gi;
      if (cnt >= 3) { lines++; glyphs += cnt; }
      gi = gj;
    }
    m.TextLines = lines; m.TextGlyphs = glyphs;

    // ---- 色彩：4bit/ch 直方圖 + 主色 + 配色表覆蓋率
    int[] hist = new int[4096];
    int np = pal == null ? 0 : pal.Length;
    long[] palCnt = new long[Math.Max(1, np)];
    long solid = 0, inPal = 0;
    for (int i = 0; i < n; i++) {
      if (A[i] < 200) continue;
      solid++;
      hist[((R[i] >> 4) << 8) | ((G[i] >> 4) << 4) | (B[i] >> 4)]++;
      if (np > 0) {
        double best = 1e9; int bi = 0;
        for (int k = 0; k < np; k++) {
          double dd = RedMean(R[i], G[i], B[i], (pal[k] >> 16) & 255, (pal[k] >> 8) & 255, pal[k] & 255);
          if (dd < best) { best = dd; bi = k; }
        }
        if (best <= palTol) { inPal++; palCnt[bi]++; }
      }
    }
    m.Hist = hist;
    m.PaletteCoverage = solid > 0 ? inPal / (double)solid : 0;
    m.PalShare = new double[Math.Max(1, np)];
    for (int k = 0; k < np; k++) m.PalShare[k] = solid > 0 ? palCnt[k] / (double)solid : 0;
    int TOP = 8;
    int[] ti = new int[TOP]; long[] tv = new long[TOP];
    for (int i = 0; i < 4096; i++) {
      for (int k = 0; k < TOP; k++) {
        if (hist[i] > tv[k]) {
          for (int q = TOP - 1; q > k; q--) { tv[q] = tv[q - 1]; ti[q] = ti[q - 1]; }
          tv[k] = hist[i]; ti[k] = i; break;
        }
      }
    }
    m.TopColors = new string[TOP]; m.TopShares = new double[TOP];
    for (int k = 0; k < TOP; k++) {
      int rr = (((ti[k] >> 8) & 15) << 4) | 8, gg = (((ti[k] >> 4) & 15) << 4) | 8, bb = ((ti[k] & 15) << 4) | 8;
      m.TopColors[k] = string.Format("#{0:x2}{1:x2}{2:x2}", rr, gg, bb);
      m.TopShares[k] = solid > 0 ? tv[k] / (double)solid : 0;
    }

    // ---- sprite sheet 分格留白：找中線附近最寬的全透明帶
    int[] colCnt = new int[w]; int[] rowCnt = new int[h];
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) if (A[y * w + x] > thr) { colCnt[x]++; rowCnt[y]++; }
    int gx = -1, gxw = 0, run = 0;
    for (int x = 0; x < w; x++) {
      if (colCnt[x] == 0) { run++; if (run > gxw && x > w * 0.2 && x < w * 0.8) { gxw = run; gx = x - run / 2; } }
      else run = 0;
    }
    int gy = -1, gyh = 0; run = 0;
    for (int y = 0; y < h; y++) {
      if (rowCnt[y] == 0) { run++; if (run > gyh && y > h * 0.2 && y < h * 0.8) { gyh = run; gy = y - run / 2; } }
      else run = 0;
    }
    m.GutterX = gx; m.GutterXW = gxw; m.GutterY = gy; m.GutterYH = gyh;
    return m;
  }

  // 兩張圖的色彩分佈距離（Hellinger，0=完全一致，1=完全不同）
  public static double HistDist(int[] a, int[] b) {
    double sa = 0, sb = 0;
    for (int i = 0; i < a.Length; i++) { sa += a[i]; sb += b[i]; }
    if (sa <= 0 || sb <= 0) return 1.0;
    double bc = 0;
    for (int i = 0; i < a.Length; i++) bc += Math.Sqrt((a[i] / sa) * (b[i] / sb));
    if (bc > 1) bc = 1;
    return Math.Sqrt(1 - bc);
  }
}
"@

# ---------------------------------------------------------------- 設定表
# 配色表（遊戲8）。前 4 個是「角色招牌色」，SIGN 檢查會要求它們真的出現在角色圖上。
# 之後是場景延伸色（樹幹、深淺綠、石灰、木頭、小狗毛色），只用來算覆蓋率。
$PALETTE = @(
  '#e8842a','#2aa7d8','#f7d9a8','#5a3b1e',                                  # 松鼠橘 / 披風藍 / 肚皮米 / 描邊深棕
  '#7ccb5e','#57c1ff','#ffd24a','#ffffff','#2b2b2b',                        # 草綠 / 天空藍 / 能量黃 / 白 / 黑
  '#1e5a28','#4a8c20','#7a4a20','#985818','#582818','#6b6b70','#a89888',    # 深綠 / 中綠 / 樹幹棕 / 木頭 / 深木 / 石灰 / 石亮
  '#a88868','#f8b878'                                                        # 小狗毛棕 / 小狗毛米
)
$SIGN_IDX = @(0,1)          # 招牌色索引：松鼠橘、披風藍
$SIGN_MIN = @(0.06, 0.015)  # 各自至少要佔不透明像素這麼多，否則就是換了角色/換了配色

# 每個 profile 的驗收門檻。hFrac=內容高佔畫布高；cx=內容水平中心；botPad=內容底部到圖框底
#   trimmed = 輸出檔是「依內容裁切」的（bbox 本來就貼滿畫布）→ stage=out 時跳過貼邊/佔比/置中檢查
#   softPx  = 允許的平均柔邊寬度(px)，1.0 ≒ 乾淨抗鋸齒，>2.5 就是 AI 光暈
#   translucent = 主體本來就有半透明區（蜜蜂翅膀）→ 放寬 softPx
$PROFILES = @{
  char_hero = @{ hFrac=@(0.76,0.90); cx=@(0.44,0.56); botPad=@(0.03,0.10); minPad=0.02; maxKB=320; alpha=$true;  softPx=2.2; baseline=$true;  groundContact=$false; trimmed=$false; palMin=0.45; signature=$true }
  char_side = @{ hFrac=@(0.74,0.90); cx=@(0.44,0.56); botPad=@(0.03,0.12); minPad=0.02; maxKB=320; alpha=$true;  softPx=2.2; baseline=$true;  groundContact=$false; trimmed=$false; palMin=0.30 }
  run       = @{ hFrac=@(0.72,0.94); cx=@(0.56,0.68); botPad=@(0.00,0.04); minPad=0.01; maxKB=300; alpha=$true;  softPx=2.2; baseline=$true;  groundContact=$true;  trimmed=$false; palMin=0.45; signature=$true }
  obs_gnd   = @{ hFrac=@(0.55,1.00); cx=@(0.40,0.60); botPad=@(0.00,0.03); minPad=0.05; maxKB=380; alpha=$true;  softPx=2.0; baseline=$true;  groundContact=$true;  trimmed=$true;  palMin=0.22 }
  obs_air   = @{ hFrac=@(0.50,1.00); cx=@(0.35,0.65); botPad=@(0.00,1.00); minPad=0.05; maxKB=320; alpha=$true;  softPx=2.0; baseline=$false; groundContact=$false; trimmed=$true;  palMin=0.22 }
  item      = @{ hFrac=@(0.70,1.00); cx=@(0.38,0.62); botPad=@(0.00,1.00); minPad=0.08; maxKB=160; alpha=$true;  softPx=1.8; baseline=$false; groundContact=$false; trimmed=$true;  palMin=0.30 }
  bg_tree   = @{ hFrac=@(0.80,1.00); cx=@(0.35,0.65); botPad=@(0.00,0.04); minPad=0.03; maxKB=560; alpha=$true;  softPx=3.0; baseline=$true;  groundContact=$true;  trimmed=$true;  palMin=0.15 }
  bg_ground = @{ hFrac=@(0.80,1.00); cx=@(0.40,0.60); botPad=@(0.00,1.00); minPad=0.00; maxKB=600; alpha=$true;  softPx=3.0; baseline=$false; groundContact=$false; trimmed=$true;  palMin=0.15; tile=$true }
  bg_far    = @{ hFrac=@(0.95,1.00); cx=@(0.40,0.60); botPad=@(0.00,1.00); minPad=0.00; maxKB=260; alpha=$false; softPx=99;  baseline=$false; groundContact=$false; trimmed=$true;  palMin=0.15; tile=$true; fullbleed=$true }
  generic   = @{ hFrac=@(0.30,1.00); cx=@(0.30,0.70); botPad=@(0.00,1.00); minPad=0.00; maxKB=400; alpha=$true;  softPx=2.5; baseline=$false; groundContact=$false; trimmed=$true;  palMin=0.20 }
}

function Get-ProfileName([string]$name) {
  switch -Regex ($name) {
    '^RUN\d+$'      { 'run' }
    '^CHAR0\d{2}$'  { 'char_hero' }
    '^CHAR[1-9]\d{2}$' { 'char_side' }
    '^OBS0\d{2}$'   { 'obs_gnd' }
    '^OBS1\d{2}$'   { 'obs_air' }
    '^ITEM\d{3}$'   { 'item' }
    '^BG001$'       { 'bg_far' }
    '^BG002$'       { 'bg_ground' }
    '^BG00[34]$'    { 'bg_tree' }
    default         { 'generic' }
  }
}

# 失敗碼 → 中文說明 / 回饋給 ChatGPT 的修正句 / 是否只需重跑後處理（不必重生圖）
$RULES = @{
  EMPTY_IMAGE       = @{ msg='去背後整張空白（或原圖沒內容）';                       fix='這張圖幾乎是空的，請重新畫一次完整主體，主體要佔畫面約 80% 高。';                                              post=$false }
  FILE_TOO_BIG      = @{ msg='輸出檔太大，GitHub Pages 會變慢';                     fix='';                                                                                                          post=$true  }
  NO_ALPHA          = @{ msg='沒有透明像素，去背失敗（棋盤格/白底被畫進圖裡）';       fix='背景必須是「真正的透明」，不要畫灰白格子、不要白底、不要任何底色；請用可下載的透明 PNG 交付。';               post=$true  }
  EDGE_CLIPPED      = @{ msg='內容碰到畫布邊緣，主體被裁切';                         fix='主體要完整入鏡，四邊各留至少 8% 空白，不可有任何部位被畫面邊緣切掉（尾巴、耳朵、樹枝都要完整）。';           post=$false }
  CONTENT_TOO_SMALL = @{ msg='主體太小，放大後會糊';                                 fix='主體請畫大一點，高度要佔畫面約 82%（上下各留約 9% 空白）。';                                               post=$true  }
  CONTENT_TOO_LARGE = @{ msg='主體太大，快貼到邊';                                   fix='主體請縮小一點，高度佔畫面約 82%，四邊留白至少 8%。';                                                      post=$true  }
  OFF_CENTER        = @{ msg='主體水平中心偏移，動畫會左右飄';                       fix='主體請置中，身體重心對齊畫面正中央（左右一樣寬的留白）。';                                                  post=$true  }
  BASELINE_OFF      = @{ msg='腳底基準線位置不符規格，動畫會上下跳';                 fix='腳掌（或物體底部）請貼在畫面下緣往上約 6% 的同一條水平線上，每一張都要一樣高。';                            post=$true  }
  FRAGMENTS         = @{ msg='有離群小碎片（分離元素或分格溢出）';                   fix='只畫一個完整相連的主體，不要有分開飄浮的東西（灰塵、速度線、汗滴、星星、碎屑都不要）。';                     post=$true  }
  FRAG_AT_EDGE      = @{ msg='碎片貼在畫布邊緣：多半是 sprite sheet 分格切到隔壁格'; fix='四格請明顯分開，每格之間留一條至少 6% 寬的完全空白帶，角色不可跨越到隔壁格。';                              post=$false }
  EDGE_ALIASED      = @{ msg='邊緣抗鋸齒被 alpha_knee 削光，會有鋸齒毛邊';           fix='';                                                                                                          post=$true  }
  HALO_RESIDUE      = @{ msg='半透明光暈殘留';                                       fix='不要加外框光暈、發光邊、柔邊噴槍、陰影或模糊；邊緣要乾淨銳利。';                                            post=$true  }
  CHECKER_RESIDUE   = @{ msg='近白中性色殘留，疑似棋盤格沒去乾淨';                   fix='背景要完全透明，不要有灰白相間的格子圖案。';                                                                post=$true  }
  ALPHA_COLOR_BLEED = @{ msg='透明像素帶顏色，縮放時邊緣會滲深色';                   fix='';                                                                                                          post=$true  }
  PALETTE_DRIFT     = @{ msg='主色偏離配色表';                                       fix='請維持同一套配色：松鼠橘 #e8842a、肚皮米 #f7d9a8、披風與護目鏡藍 #2aa7d8、描邊深棕 #5a3b1e，不要換色調。'; post=$false }
  STYLE_DRIFT       = @{ msg='與參考圖的色彩分佈差太多，畫風可能跑掉';               fix='請和我上一張附的參考圖同一個角色、同一種畫風、同樣粗黑描邊與厚塗上色，不要改設計。';                          post=$false }
  TEXT_SUSPECT      = @{ msg='疑似圖上有文字/標籤（弱偵測，需人眼確認）';           fix='圖上不可以出現任何文字、字母、數字、標籤、logo、浮水印或簽名。';                                            post=$false }
  MAGENTA_IN_SUBJECT= @{ msg='主體含高飽和洋紅，走色鍵去背會被誤刪';                 fix='角色身上不要用洋紅、桃紅、紫色；粉色請改用偏橘的粉 #ffc0cb 或不用。';                                       post=$false }
  TILE_EDGE_SOFT    = @{ msg='左右緣是半透明羽化邊，平鋪會出現亮縫';                 fix='這是要左右無限接續的長條素材，左右兩端必須畫到滿、完全不透明、硬邊，不要淡出或羽化。';                       post=$false }
  TILE_SEAM         = @{ msg='左右緣不吻合，直接平鋪會有接縫';                       fix='左右兩端的內容高度、顏色、厚度要一致，接起來看不出接縫。';                                                  post=$true  }
  SHEET_GUTTER_MISSING = @{ msg='sprite sheet 找不到分格空白帶，無法自動切圖';       fix='請把 4 個動作畫成 2x2 四格，格與格之間留一條明顯的完全空白帶（至少畫面寬的 6%），角色不要跨格。';           post=$false }
  FRAME_SCALE_DRIFT = @{ msg='同組影格大小不一致，播放時會忽大忽小';                 fix='這幾張的角色必須一模一樣大，身高完全相同，不要有的近有的遠。';                                              post=$true  }
  FRAME_CENTER_DRIFT= @{ msg='同組影格水平中心不一致，播放時會左右飄';               fix='這幾張的角色請放在畫面同一個水平位置。';                                                                    post=$true  }
  FRAME_BASELINE_DRIFT = @{ msg='同組影格腳底高度不一致，播放時會上下跳';           fix='這幾張的腳掌都要踩在同一條水平線上（畫面下緣往上約 6%）。';                                                 post=$true  }
}

function New-Check($code, $level, $value, $limit, $extra) {
  $r = $RULES[$code]
  [pscustomobject]@{
    code            = $code
    level           = $level          # fail / warn
    value           = $value
    limit           = $limit
    msg_zh          = $(if ($r) { $r.msg } else { $code })
    fix_prompt_zh   = $(if ($r) { $r.fix } else { '' })
    post_fixable    = $(if ($r) { [bool]$r.post } else { $false })
    detail          = $extra
  }
}

function ToInt([string]$hex) { [Convert]::ToInt32($hex.TrimStart('#'), 16) }

# ---------------------------------------------------------------- 收集檔案
$root = (Resolve-Path $Path).Path
$files = @()
if (Test-Path $root -PathType Leaf) { $files = @(Get-Item $root); $root = Split-Path $root -Parent }
else { foreach ($pat in $Include) { $files += Get-ChildItem -Path $root -Filter $pat -File } }
$files = $files | Where-Object { $_.Name -notlike '_*' } | Sort-Object Name
if ($files.Count -eq 0) { Write-Host "找不到圖檔：$root"; exit 2 }

$stageNow = $Stage
if ($stageNow -eq 'auto') { $stageNow = $(if ((Split-Path $root -Leaf) -match '^(opt|out)$') { 'out' } else { 'raw' }) }
if ($Json -eq '')     { $Json     = Join-Path $root '_qa_report.json' }
if ($SheetOut -eq '') { $SheetOut = Join-Path $root '_qa_sheet.jpg' }

$palInts = @($PALETTE | ForEach-Object { ToInt $_ })
function Get-Family([string]$pn) {
  switch -Regex ($pn) {
    '^(char_hero|run)$' { 'hero' }
    '^char_side$'       { 'side' }
    '^obs_'             { 'obs'  }
    '^bg_'              { 'bg'   }
    default             { $pn    }
  }
}
$refHist = $null; $refFam = ''
if ($Ref -ne '' -and (Test-Path $Ref)) {
  $rp = (Resolve-Path $Ref).Path
  $rb = [System.Drawing.Bitmap]::FromFile($rp)
  $rc = New-Object System.Drawing.Bitmap($rb); $rb.Dispose()
  $refHist = ([AssetQa]::Measure($rc, $AlphaThr, $palInts, $PaletteTol)).Hist
  $rc.Dispose()
  $refFam = Get-Family (Get-ProfileName ([IO.Path]::GetFileNameWithoutExtension($rp)))
}

# ---------------------------------------------------------------- 逐檔量測
$results = @()
foreach ($f in $files) {
  $id   = [IO.Path]::GetFileNameWithoutExtension($f.Name)
  $pn   = Get-ProfileName $id
  $prof = $PROFILES[$pn]
  $raw  = [System.Drawing.Bitmap]::FromFile($f.FullName)
  $bmp  = New-Object System.Drawing.Bitmap($raw); $raw.Dispose()
  $m    = [AssetQa]::Measure($bmp, $AlphaThr, $palInts, $PaletteTol)
  $bmp.Dispose()
  $kb   = [Math]::Round($f.Length / 1KB, 1)
  $checks = @()

  if ($m.Empty) {
    $checks += New-Check 'EMPTY_IMAGE' 'fail' 0 0 ''
    $hFrac = 0; $cx = 0; $botPad = 0; $topPad = 0; $lPad = 0; $rPad = 0
  } else {
    $hFrac  = [Math]::Round($m.BH / $m.H, 4)
    $wFrac  = [Math]::Round($m.BW / $m.W, 4)
    $cx     = [Math]::Round(($m.BX + $m.BW / 2) / $m.W, 4)
    $topPad = [Math]::Round($m.BY / $m.H, 4)
    $botPad = [Math]::Round(($m.H - ($m.BY + $m.BH)) / $m.H, 4)
    $lPad   = [Math]::Round($m.BX / $m.W, 4)
    $rPad   = [Math]::Round(($m.W - ($m.BX + $m.BW)) / $m.W, 4)

    # 1) 檔案大小
    if ($kb -gt $prof.maxKB) { $checks += New-Check 'FILE_TOO_BIG' 'warn' $kb $prof.maxKB "降尺寸或改 JPG q85" }

    # 2) 有無 alpha（去背是否成功）
    if ($prof.alpha -and ($m.AnyRatio -gt 0.995 -or $m.MaxAlpha -eq 0)) {
      $checks += New-Check 'NO_ALPHA' 'fail' ([Math]::Round($m.AnyRatio,4)) 0.995 ''
    }

    # 幾何類檢查只在「畫布是固定框」時才有意義：
    #   raw 階段 → 全部要驗（這是攔 AI 構圖問題的地方）
    #   out 階段 → 依內容裁切過的素材(trimmed) bbox 本來就貼滿畫布，跳過；CHAR/RUN 固定畫布仍要驗
    $geo = ($stageNow -eq 'raw') -or (-not $prof.trimmed)

    # 3) 貼邊 / 被裁切
    if ($geo -and -not $prof.fullbleed) {
      $edgeHit = @()
      if ($m.EdgeTop    -gt 0.002 -or $topPad -lt $prof.minPad) { $edgeHit += 'top' }
      if ($m.EdgeLeft   -gt 0.002 -or $lPad   -lt $prof.minPad) { $edgeHit += 'left' }
      if ($m.EdgeRight  -gt 0.002 -or $rPad   -lt $prof.minPad) { $edgeHit += 'right' }
      if (-not $prof.groundContact -and ($m.EdgeBottom -gt 0.002 -or $botPad -lt $prof.minPad)) { $edgeHit += 'bottom' }
      if ($edgeHit.Count -gt 0) { $checks += New-Check 'EDGE_CLIPPED' 'fail' ($edgeHit -join ',') $prof.minPad '' }
    }

    # 4) 內容佔比
    if ($geo) {
      if ($hFrac -lt $prof.hFrac[0]) { $checks += New-Check 'CONTENT_TOO_SMALL' 'warn' $hFrac $prof.hFrac[0] '' }
      if ($hFrac -gt $prof.hFrac[1]) { $checks += New-Check 'CONTENT_TOO_LARGE' 'warn' $hFrac $prof.hFrac[1] '' }
      # 5) 水平中心
      if ($cx -lt $prof.cx[0] -or $cx -gt $prof.cx[1]) {
        $checks += New-Check 'OFF_CENTER' 'warn' $cx ($prof.cx -join '~') ''
      }
      # 6) 腳底基準線
      if ($prof.baseline -and ($botPad -lt $prof.botPad[0] -or $botPad -gt $prof.botPad[1])) {
        $checks += New-Check 'BASELINE_OFF' 'warn' $botPad ($prof.botPad -join '~') ''
      }
    }

    # 7) 離群碎片
    if ($m.CompCount -gt 1 -and $m.CompBiggest -gt 0) {
      $fr = [Math]::Round($m.CompOther / $m.CompBiggest, 5)
      $atEdge = ($m.FragCount -gt 0) -and (($m.EdgeTop + $m.EdgeBottom + $m.EdgeLeft + $m.EdgeRight) -gt 0.002)
      if ($atEdge)        { $checks += New-Check 'FRAG_AT_EDGE' 'fail' $m.FragCount 0 "碎片數 $($m.FragCount)" }
      elseif ($fr -gt 0.01) { $checks += New-Check 'FRAGMENTS' 'warn' $fr 0.01 "連通區 $($m.CompCount) 個" }
    }

    # 8) 光暈殘留：用「平均柔邊寬度」而不是半透明像素比例，才不會把 1px 抗鋸齒誤判成光暈
    $softLimit = $(if ($Translucent) { $prof.softPx * 3 } else { $prof.softPx })
    if ($m.EdgeSoftPx -gt $softLimit) {
      $checks += New-Check 'HALO_RESIDUE' 'warn' ([Math]::Round($m.EdgeSoftPx,2)) $softLimit '提高 alpha_knee 再跑一次；若主體本來就半透明請加 -Translucent'
    }
    # 8b) 反向：柔邊被削光 → alpha_knee 開太大，邊緣鋸齒
    if ($stageNow -eq 'out' -and $m.EdgeSoftPx -lt 0.55 -and -not $prof.fullbleed) {
      $checks += New-Check 'EDGE_ALIASED' 'warn' ([Math]::Round($m.EdgeSoftPx,2)) 0.55 '調低 alpha_knee（建議 40~70）保住抗鋸齒'
    }

    # 9) 棋盤格殘留（近中性亮色）
    if ($m.NeutralBrightRatio -gt 0.06) {
      $checks += New-Check 'CHECKER_RESIDUE' 'warn' ([Math]::Round($m.NeutralBrightRatio,4)) 0.06 '若主體本來就有大片白色可忽略'
    }

    # 10) 透明像素帶色
    if ($m.ZeroColoredRatio -gt 0.5) {
      $checks += New-Check 'ALPHA_COLOR_BLEED' 'warn' ([Math]::Round($m.ZeroColoredRatio,3)) 0.5 '後處理加 edge-extend 補色'
    }

    # 11) 配色：覆蓋率（是否還在這套色票裡）+ 招牌色（角色是不是同一隻）
    if ($m.PaletteCoverage -lt $prof.palMin) {
      $checks += New-Check 'PALETTE_DRIFT' 'warn' ([Math]::Round($m.PaletteCoverage,3)) $prof.palMin ''
    }
    if ($prof.signature) {
      for ($si = 0; $si -lt $SIGN_IDX.Count; $si++) {
        $sv = [Math]::Round($m.PalShare[$SIGN_IDX[$si]], 4)
        if ($sv -lt $SIGN_MIN[$si]) {
          $checks += New-Check 'PALETTE_DRIFT' 'fail' $sv $SIGN_MIN[$si] ("招牌色 " + $PALETTE[$SIGN_IDX[$si]] + " 幾乎沒出現")
        }
      }
    }

    # 12) 畫風漂移（需 -Ref，且只跟「同族」素材比才有意義）
    #     實測：同一隻松鼠的不同姿勢 vs 待機圖 = 0.31~0.68；換成小狗/石頭/背景 = 0.76~0.97
    if ($refHist -ne $null -and (Get-Family $pn) -eq $refFam) {
      $hd = [Math]::Round([AssetQa]::HistDist($m.Hist, $refHist), 4)
      if ($hd -gt 0.72) { $checks += New-Check 'STYLE_DRIFT' 'warn' $hd 0.72 '' }
    }

    # 13) 疑似文字
    if ($m.TextLines -ge 1) {
      $checks += New-Check 'TEXT_SUSPECT' 'warn' $m.TextLines 0 "疑似字元 $($m.TextGlyphs) 個，請人眼看 contact sheet 確認"
    }

    # 14) 主體含洋紅（色鍵流程致命）
    if ($m.MagentaRatio -gt 0.001) {
      $checks += New-Check 'MAGENTA_IN_SUBJECT' 'warn' ([Math]::Round($m.MagentaRatio,4)) 0.001 ''
    }

    # 15) 平鋪素材
    if ($prof.tile) {
      if ($m.ColLeftOpaque -lt 0.98 -or $m.ColRightOpaque -lt 0.98) {
        $checks += New-Check 'TILE_EDGE_SOFT' 'fail' ([Math]::Round([Math]::Min($m.ColLeftOpaque,$m.ColRightOpaque),3)) 0.98 ''
      }
      if ($m.SeamDiff -gt 0.08) {
        $checks += New-Check 'TILE_SEAM' 'warn' ([Math]::Round($m.SeamDiff,3)) 0.08 '可改用奇數塊鏡像拼接規避'
      }
    }

    # 16) sprite sheet 分格留白
    if ($SheetGrid -ne '') {
      $needV = $SheetGrid -match '^\dx' -and $SheetGrid -notmatch '^1x'
      $minG = [int]($m.W * 0.04)
      if ($m.GutterXW -lt $minG) { $checks += New-Check 'SHEET_GUTTER_MISSING' 'fail' $m.GutterXW $minG '垂直分隔帶' }
      if ($SheetGrid -eq '2x2' -and $m.GutterYH -lt [int]($m.H * 0.04)) {
        $checks += New-Check 'SHEET_GUTTER_MISSING' 'fail' $m.GutterYH ([int]($m.H*0.04)) '水平分隔帶'
      }
    }
  }

  $verdict = 'pass'
  if ($checks | Where-Object { $_.level -eq 'warn' }) { $verdict = 'warn' }
  if ($checks | Where-Object { $_.level -eq 'fail' }) { $verdict = 'fail' }

  $results += [pscustomobject]@{
    id       = $id
    file     = $f.Name
    path     = $f.FullName
    profile  = $pn
    verdict  = $verdict
    kb       = $kb
    metrics  = [pscustomobject]@{
      w = $m.W; h = $m.H
      bbox = @($m.BX, $m.BY, $m.BW, $m.BH)
      h_frac = $hFrac; w_frac = $(if ($m.Empty) { 0 } else { $wFrac })
      center_x = $cx; top_pad = $topPad; bottom_pad = $botPad; left_pad = $lPad; right_pad = $rPad
      fill_ratio        = [Math]::Round($m.FillRatio,4)
      area_frac         = [Math]::Round($m.AreaFrac,4)
      edge_soft_px      = [Math]::Round($m.EdgeSoftPx,2)
      comp_count        = $m.CompCount
      frag_count        = $m.FragCount
      frag_ratio        = $(if ($m.CompBiggest -gt 0) { [Math]::Round($m.CompOther / $m.CompBiggest, 5) } else { 0 })
      halo_ratio        = [Math]::Round($m.HaloRatio,4)
      opaque_ratio      = [Math]::Round($m.OpaqueRatio,4)
      max_alpha         = $m.MaxAlpha
      zero_colored      = [Math]::Round($m.ZeroColoredRatio,3)
      edge_opaque       = @([Math]::Round($m.EdgeTop,4), [Math]::Round($m.EdgeRight,4), [Math]::Round($m.EdgeBottom,4), [Math]::Round($m.EdgeLeft,4))
      neutral_bright    = [Math]::Round($m.NeutralBrightRatio,4)
      magenta_ratio     = [Math]::Round($m.MagentaRatio,4)
      palette_coverage  = [Math]::Round($m.PaletteCoverage,3)
      top_colors        = @(0..4 | ForEach-Object { @{ hex = $m.TopColors[$_]; share = [Math]::Round($m.TopShares[$_],3) } })
      text_lines        = $m.TextLines
      text_glyphs       = $m.TextGlyphs
      tile_left_opaque  = [Math]::Round($m.ColLeftOpaque,3)
      tile_right_opaque = [Math]::Round($m.ColRightOpaque,3)
      seam_diff         = [Math]::Round($m.SeamDiff,3)
      gutter_x          = @($m.GutterX, $m.GutterXW)
      gutter_y          = @($m.GutterY, $m.GutterYH)
      style_dist        = $(if ($refHist -ne $null -and -not $m.Empty) { [Math]::Round([AssetQa]::HistDist($m.Hist, $refHist),4) } else { $null })
    }
    checks   = $checks
  }

  if (-not $Quiet) {
    $tag = switch ($verdict) { 'pass' { 'PASS' } 'warn' { 'WARN' } default { 'FAIL' } }
    Write-Host ("{0,-5} {1,-12} {2,-9} h={3,-6} cx={4,-6} bot={5,-6} halo={6,-6} {7}" -f `
      $tag, $id, $pn, $hFrac, $cx, $botPad, [Math]::Round($m.HaloRatio,3), (($checks | ForEach-Object { $_.code }) -join ','))
  }
}

# ---------------------------------------------------------------- 影格組一致性
$groups = @()
$byGroup = @{}
foreach ($r in $results) {
  $g = switch -Regex ($r.id) {
    '^RUN\d+$'     { 'RUN' }
    '^CHAR0\d{2}$' { 'CHAR_HERO' }
    '^CHAR1\d{2}$' { 'CHAR_PUP1' }
    '^CHAR2\d{2}$' { 'CHAR_PUP2' }
    default        { '' }
  }
  if ($g -ne '') { if (-not $byGroup.ContainsKey($g)) { $byGroup[$g] = @() }; $byGroup[$g] += $r }
}
# 組別容差：RUN 是連播動畫最嚴，CHAR 是切換姿勢次之
#   尺度用「內容面積比 max/min」當代理量（bbox 高度會被姿勢本身影響：飛撲 vs 蹲踞）
$GTOL = @{
  RUN       = @{ area=1.25; h=0.12; cx=0.02; bot=0.02 }
  CHAR_HERO = @{ area=1.45; h=0.20; cx=0.04; bot=0.12 }
  CHAR_PUP1 = @{ area=1.35; h=0.15; cx=0.03; bot=0.10 }
  CHAR_PUP2 = @{ area=1.35; h=0.15; cx=0.03; bot=0.10 }
}
foreach ($k in $byGroup.Keys) {
  $ms = $byGroup[$k]
  if ($ms.Count -lt 2) { continue }
  $tol = $GTOL[$k]
  $hs  = $ms | ForEach-Object { $_.metrics.h_frac }
  $cs  = $ms | ForEach-Object { $_.metrics.center_x }
  $bs  = $ms | ForEach-Object { $_.metrics.bottom_pad }
  $ar  = $ms | ForEach-Object { $_.metrics.area_frac }
  $gc  = @()
  $hR = [Math]::Round((($hs | Measure-Object -Max).Maximum - ($hs | Measure-Object -Min).Minimum), 4)
  $cR = [Math]::Round((($cs | Measure-Object -Max).Maximum - ($cs | Measure-Object -Min).Minimum), 4)
  $bR = [Math]::Round((($bs | Measure-Object -Max).Maximum - ($bs | Measure-Object -Min).Minimum), 4)
  $aMin = ($ar | Measure-Object -Min).Minimum
  $aR = [Math]::Round((($ar | Measure-Object -Max).Maximum / [Math]::Max(0.0001, $aMin)), 3)
  $names = ($ms | ForEach-Object { $_.id }) -join ','
  if ($aR -gt $tol.area) { $gc += New-Check 'FRAME_SCALE_DRIFT'    'fail' $aR $tol.area $names }
  elseif ($hR -gt $tol.h){ $gc += New-Check 'FRAME_SCALE_DRIFT'    'warn' $hR $tol.h    $names }
  if ($cR -gt $tol.cx)   { $gc += New-Check 'FRAME_CENTER_DRIFT'   'warn' $cR $tol.cx   '' }
  if ($bR -gt $tol.bot)  { $gc += New-Check 'FRAME_BASELINE_DRIFT' 'warn' $bR $tol.bot  '' }
  $groups += [pscustomobject]@{
    group = $k
    members = @($ms | ForEach-Object { $_.id })
    area_ratio = $aR; h_frac_range = $hR; center_x_range = $cR; bottom_pad_range = $bR
    verdict = $(if ($gc | Where-Object { $_.level -eq 'fail' }) { 'fail' } elseif ($gc.Count) { 'warn' } else { 'pass' })
    checks = $gc
  }
  if (-not $Quiet) { Write-Host ("GROUP {0,-10} areaRatio={1} hRange={2} cxRange={3} botRange={4}" -f $k, $aR, $hR, $cR, $bR) }
}

# ---------------------------------------------------------------- 下一步動作（給重試引擎吃）
$next = @()
foreach ($r in $results) {
  if ($r.verdict -eq 'pass') { continue }
  $bad  = @($r.checks | Where-Object { $_.level -eq 'fail' -or ($_.level -eq 'warn' -and -not $_.post_fixable) })
  $soft = @($r.checks | Where-Object { $_.post_fixable })
  $action = if ($bad.Count -gt 0) { 'regen' } elseif ($soft.Count -gt 0) { 'rerun_post' } else { 'ok' }
  $adds = @($r.checks | Where-Object { $_.fix_prompt_zh -ne '' } | ForEach-Object { $_.fix_prompt_zh } | Select-Object -Unique)
  $next += [pscustomobject]@{
    id = $r.id
    action = $action
    codes = @($r.checks | ForEach-Object { $_.code })
    prompt_addendum_zh = $(if ($action -eq 'regen') { '上一張的問題請修正：' + ($adds -join ' ') } else { '' })
  }
}

# ---------------------------------------------------------------- Contact sheet
function New-ContactSheet($rows, $out) {
  $cell = 384; $cols = 4; $labelH = 30
  $rowsN = [Math]::Ceiling($rows.Count / $cols)
  $W = $cols * $cell; $H = $rowsN * ($cell + $labelH)
  $bmp = New-Object System.Drawing.Bitmap($W, $H)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'
  $g.InterpolationMode = 'HighQualityBicubic'
  $fnt  = New-Object System.Drawing.Font('Microsoft JhengHei', 11, [System.Drawing.FontStyle]::Bold)
  $fnt2 = New-Object System.Drawing.Font('Consolas', 10)
  $brW  = [System.Drawing.Brushes]::White
  $penB = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(220,255,60,60), 2)
  $penY = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(200,255,220,0), 1)
  $penY.DashStyle = 'Dash'
  $penC = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(160,0,230,255), 1)
  $penC.DashStyle = 'Dot'
  $g.Clear([System.Drawing.Color]::FromArgb(24,26,30))
  $i = 0
  foreach ($r in $rows) {
    $cx0 = ($i % $cols) * $cell
    $cy0 = [int][Math]::Floor($i / $cols) * ($cell + $labelH) + $labelH
    # 底：12px 棋盤格（看得出光暈）＋左上三角形鋪天空藍→草綠漸層（模擬遊戲實境）
    for ($yy = 0; $yy -lt $cell; $yy += 12) {
      for ($xx = 0; $xx -lt $cell; $xx += 12) {
        $c = if ((($xx / 12) + ($yy / 12)) % 2 -eq 0) { [System.Drawing.Color]::FromArgb(235,235,235) } else { [System.Drawing.Color]::FromArgb(180,180,180) }
        $b2 = New-Object System.Drawing.SolidBrush($c)
        $g.FillRectangle($b2, $cx0 + $xx, $cy0 + $yy, 12, 12); $b2.Dispose()
      }
    }
    $p1 = New-Object System.Drawing.Point -ArgumentList $cx0, $cy0
    $p2 = New-Object System.Drawing.Point -ArgumentList $cx0, ($cy0 + $cell)
    $p3 = New-Object System.Drawing.Point -ArgumentList ($cx0 + $cell), $cy0
    $gb = New-Object System.Drawing.Drawing2D.LinearGradientBrush -ArgumentList $p1, $p2,
      ([System.Drawing.Color]::FromArgb(140,200,255)), ([System.Drawing.Color]::FromArgb(110,190,90))
    $tri = @($p1, $p3, $p2)
    $g.FillPolygon($gb, $tri); $gb.Dispose()

    $im = [System.Drawing.Bitmap]::FromFile($r.path)
    $sc = [Math]::Min(($cell - 8) / $im.Width, ($cell - 8) / $im.Height)
    $dw = [int]($im.Width * $sc); $dh = [int]($im.Height * $sc)
    $dx = $cx0 + [int](($cell - $dw) / 2); $dy = $cy0 + [int](($cell - $dh) / 2)
    $g.DrawImage($im, $dx, $dy, $dw, $dh)
    # 規格輔助線：紅框=bbox、黃虛線=腳底基準線、青點線=水平中心
    $bx = $r.metrics.bbox
    $g.DrawRectangle($penB, ($dx + $bx[0] * $sc), ($dy + $bx[1] * $sc), ($bx[2] * $sc), ($bx[3] * $sc))
    $blY = $dy + $dh - ($dh * 0.06)
    $g.DrawLine($penY, $dx, $blY, ($dx + $dw), $blY)
    $g.DrawLine($penC, ($dx + $dw / 2), $dy, ($dx + $dw / 2), ($dy + $dh))
    $im.Dispose()

    $col = switch ($r.verdict) { 'pass' { [System.Drawing.Color]::FromArgb(60,200,110) } 'warn' { [System.Drawing.Color]::FromArgb(240,180,40) } default { [System.Drawing.Color]::FromArgb(235,70,70) } }
    $bb = New-Object System.Drawing.SolidBrush($col)
    $g.FillRectangle($bb, $cx0, ($cy0 - $labelH), $cell, $labelH); $bb.Dispose()
    $codes = @($r.checks | ForEach-Object { $_.code })
    $codeTxt = $(if ($codes.Count -le 2) { $codes -join ' ' } else { ($codes[0..1] -join ' ') + " +$($codes.Count - 2)" })
    $lblRect = New-Object System.Drawing.RectangleF -ArgumentList ([single]($cx0 + 6)), ([single]($cy0 - $labelH + 4)), ([single]($cell - 10)), ([single]($labelH - 4))
    $sf = New-Object System.Drawing.StringFormat
    $sf.Trimming = 'EllipsisCharacter'; $sf.FormatFlags = 'NoWrap'
    $g.DrawString(("{0}  {1}  {2}" -f $r.id, $r.verdict.ToUpper(), $codeTxt), $fnt, $brW, $lblRect, $sf)
    $sf.Dispose()
    $g.DrawString(("h{0:P0} cx{1:P0} bot{2:P0} halo{3:P1} {4}KB" -f $r.metrics.h_frac, $r.metrics.center_x, $r.metrics.bottom_pad, $r.metrics.halo_ratio, $r.kb),
      $fnt2, [System.Drawing.Brushes]::Black, ($cx0 + 6), ($cy0 + $cell - 16))
    $i++
  }
  $g.Dispose(); $fnt.Dispose(); $fnt2.Dispose(); $penB.Dispose(); $penY.Dispose(); $penC.Dispose()
  $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
  $ep = New-Object System.Drawing.Imaging.EncoderParameters(1)
  $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]88)
  $bmp.Save($out, $codec, $ep)
  $bmp.Dispose()
}

# 洋蔥皮：同組影格疊在一起，一眼看出尺度/中心/基準線有沒有飄
function New-OnionSheet($grps, $all, $out) {
  $use = @($grps | Where-Object { $_.members.Count -ge 2 })
  if ($use.Count -eq 0) { return $false }
  $cell = 460; $labelH = 26
  $cols = [Math]::Min(3, $use.Count); $rowsN = [Math]::Ceiling($use.Count / $cols)
  $bmp = New-Object System.Drawing.Bitmap -ArgumentList ($cols * $cell), ($rowsN * ($cell + $labelH))
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.InterpolationMode = 'HighQualityBicubic'
  $g.Clear([System.Drawing.Color]::FromArgb(24,26,30))
  $fnt = New-Object System.Drawing.Font -ArgumentList 'Microsoft JhengHei', 11, ([System.Drawing.FontStyle]::Bold)
  $i = 0
  foreach ($gr in $use) {
    $cx0 = ($i % $cols) * $cell
    $cy0 = [int][Math]::Floor($i / $cols) * ($cell + $labelH) + $labelH
    $bg = New-Object System.Drawing.SolidBrush -ArgumentList ([System.Drawing.Color]::FromArgb(245,245,245))
    $g.FillRectangle($bg, $cx0, $cy0, $cell, $cell); $bg.Dispose()
    $mem = @($gr.members | ForEach-Object { $id = $_; $all | Where-Object { $_.id -eq $id } })
    $cm = New-Object System.Drawing.Imaging.ColorMatrix
    $cm.Matrix33 = [single](1.0 / [Math]::Max(2, $mem.Count) + 0.15)
    $ia = New-Object System.Drawing.Imaging.ImageAttributes
    $ia.SetColorMatrix($cm)
    foreach ($mm in $mem) {
      $im = [System.Drawing.Bitmap]::FromFile($mm.path)
      $sc = [Math]::Min(($cell - 8) / $im.Width, ($cell - 8) / $im.Height)
      $dw = [int]($im.Width * $sc); $dh = [int]($im.Height * $sc)
      $dx = $cx0 + [int](($cell - $dw) / 2); $dy = $cy0 + [int](($cell - $dh) / 2)
      $rc = New-Object System.Drawing.Rectangle -ArgumentList $dx, $dy, $dw, $dh
      $g.DrawImage($im, $rc, 0, 0, $im.Width, $im.Height, [System.Drawing.GraphicsUnit]::Pixel, $ia)
      # 每格自己的腳底線（黃）與水平中心（青）：疊起來就看得出飄多少
      $bl = $dy + $dh - ($mm.metrics.bottom_pad * $dh)
      $pn2 = New-Object System.Drawing.Pen -ArgumentList ([System.Drawing.Color]::FromArgb(200,220,140,0)), 1
      $g.DrawLine($pn2, $dx, $bl, ($dx + $dw), $bl); $pn2.Dispose()
      $pn3 = New-Object System.Drawing.Pen -ArgumentList ([System.Drawing.Color]::FromArgb(160,0,160,200)), 1
      $g.DrawLine($pn3, ($dx + $mm.metrics.center_x * $dw), $dy, ($dx + $mm.metrics.center_x * $dw), ($dy + $dh)); $pn3.Dispose()
      $im.Dispose()
    }
    $ia.Dispose()
    $col = $(if ($gr.verdict -eq 'pass') { [System.Drawing.Color]::FromArgb(60,200,110) } elseif ($gr.verdict -eq 'warn') { [System.Drawing.Color]::FromArgb(240,180,40) } else { [System.Drawing.Color]::FromArgb(235,70,70) })
    $bb2 = New-Object System.Drawing.SolidBrush -ArgumentList $col
    $g.FillRectangle($bb2, $cx0, ($cy0 - $labelH), $cell, $labelH); $bb2.Dispose()
    $g.DrawString(("{0}  area x{1}  cx±{2:P1}  bot±{3:P1}" -f $gr.group, $gr.area_ratio, $gr.center_x_range, $gr.bottom_pad_range),
      $fnt, [System.Drawing.Brushes]::White, ($cx0 + 6), ($cy0 - $labelH + 4))
    $i++
  }
  $g.Dispose(); $fnt.Dispose()
  $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
  $ep = New-Object System.Drawing.Imaging.EncoderParameters(1)
  $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]88)
  $bmp.Save($out, $codec, $ep); $bmp.Dispose()
  return $true
}

$sheets = @()
if (-not $NoSheet) {
  $page = 0
  for ($s = 0; $s -lt $results.Count; $s += 12) {
    $page++
    $chunk = $results[$s..([Math]::Min($s + 11, $results.Count - 1))]
    $p = if ($results.Count -le 12) { $SheetOut } else { [IO.Path]::ChangeExtension($SheetOut, $null).TrimEnd('.') + ("_{0:d2}.jpg" -f $page) }
    New-ContactSheet $chunk $p
    $sheets += $p
    if (-not $Quiet) { Write-Host "SHEET $p" }
  }
  $onion = [IO.Path]::ChangeExtension($SheetOut, $null).TrimEnd('.') + '_onion.jpg'
  if (New-OnionSheet $groups $results $onion) {
    $sheets += $onion
    if (-not $Quiet) { Write-Host "SHEET $onion" }
  }
}

# ---------------------------------------------------------------- 報告
$nFail = @($results | Where-Object { $_.verdict -eq 'fail' }).Count
$nWarn = @($results | Where-Object { $_.verdict -eq 'warn' }).Count
$report = [pscustomobject]@{
  schema_version = 1
  ts      = (Get-Date).ToString('s')
  root    = $root
  palette = $PALETTE
  summary = [pscustomobject]@{ total = $results.Count; pass = ($results.Count - $nFail - $nWarn); warn = $nWarn; fail = $nFail }
  sheets  = $sheets
  assets  = $results
  groups  = $groups
  next_actions = $next
}
$report | ConvertTo-Json -Depth 10 | Out-File -FilePath $Json -Encoding utf8
if (-not $Quiet) { Write-Host ("`n報告：{0}  (pass {1} / warn {2} / fail {3})" -f $Json, $report.summary.pass, $nWarn, $nFail) }
if ($nFail -gt 0) { exit 1 } else { exit 0 }
