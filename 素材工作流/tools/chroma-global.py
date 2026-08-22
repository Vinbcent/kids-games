"""全域洋紅去背：把整張圖裡接近洋紅的像素全部打成透明（不限邊緣連通）。
用在「鏤空」素材（柵欄、輪圈、環狀物）——build.ps1 的邊緣 flood-fill 到不了被主體包住的縫隙。
用法: python chroma-global.py <遊戲資料夾> <ID> [容差=70]
   讀 pic/_tmp/ID.png（build.ps1 的中繼檔），寫回同檔 + 重新編碼 pic/opt/ID.webp
"""
import sys, subprocess, numpy as np
from PIL import Image
game, aid = sys.argv[1], sys.argv[2]
tol = int(sys.argv[3]) if len(sys.argv) > 3 else 70
p = f"{game}/pic/_tmp/{aid}.png"
im = Image.open(p).convert("RGBA"); a = np.array(im).astype(int)
r, g, b, al = a[..., 0], a[..., 1], a[..., 2], a[..., 3]
# 洋紅 = R 高、B 高、G 低；距離用 (R-255, G-0, B-255) 的最大分量差
# 「洋紅度」= min(R,B) - G：純洋紅 255、淡粉 ~70、奶油/黃/灰 都是負的或很小
m = np.minimum(r, b) - g
hi = 255 - tol          # 洋紅度高於這個 → 透明（tol=70 → 185）
lo = hi * 0.65          # 介於 lo~hi → 半透明並壓掉洋紅
mask = m >= hi
soft = (m >= lo) & (m < hi)
al2 = al.copy(); al2[mask] = 0
al2[soft] = (al[soft] * (1 - (m[soft] - lo) / (hi - lo))).astype(int)
g2 = g.copy(); g2[soft] = np.minimum(255, g[soft] + 60)   # 半透明邊緣壓掉洋紅感
out = np.stack([r, g2, b, al2], axis=-1).clip(0, 255).astype(np.uint8)
Image.fromarray(out, "RGBA").save(p)
webp = f"{game}/pic/opt/{aid}.webp"
subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", p, "-c:v", "libwebp", "-quality", "80", webp], check=True)
print(f"OK {aid}: 去掉 {int(mask.sum())} 個洋紅像素, 邊緣 {int(soft.sum())} -> {webp}")
