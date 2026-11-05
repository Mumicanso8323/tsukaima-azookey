#!/usr/bin/env python3
"""ipa の Assets.car に入っているアプリアイコン(1024 の Any 外観)が、期待する画像と同じかを調べる。
使い方: check_car_icon.py <Assets.car> <expected.png>   一致しなければ終了コード 1。
Assets.car の ISTC(レンディション)から azooKey1024x1024_UIAppearanceAny を探して LZFSE を展開する。
"""
import re, struct, sys
import liblzfse
from PIL import Image, ImageChops, ImageStat

car, expected = sys.argv[1], sys.argv[2]
d = open(car, "rb").read()
found = 0
worst = 0.0
for m in re.finditer(b"ISTC", d):
    o = m.start()
    h = d[o:o + 0xb8]
    w, hh = struct.unpack("<II", h[12:20])
    name = h[0x28:0xa8].split(b"\0")[0]
    if not (w == 1024 and hh == 1024 and name.startswith(b"azooKey1024x1024_UIAppearanceAny")):
        continue
    il = struct.unpack("<I", d[o + 0xa8:o + 0xac])[0]
    plen = struct.unpack("<I", d[o + 0xb4:o + 0xb8])[0]
    p = o + 0xb8 + il
    q, end, out = p + 16, p + plen, []
    while q < end - 8 and d[q:q + 4] == b"KCBC":
        usz, csz = struct.unpack("<2I", d[q + 12:q + 20])
        out.append(liblzfse.decompress(d[q + 20:q + 20 + csz]))
        q += 20 + csz
    raw = b"".join(out)
    if len(raw) != 1024 * 1024 * 4:
        continue
    im = Image.frombuffer("RGBA", (1024, 1024), raw, "raw", "BGRA", 0, 1).convert("RGB")
    diff = ImageChops.difference(im, Image.open(expected).convert("RGB"))
    mean = sum(ImageStat.Stat(diff).mean) / 3
    print(f"rendition at {o:#x}: mean abs diff = {mean:.2f}")
    found += 1
    worst = max(worst, mean)
if not found:
    print("アイコンのレンディションが見つからない"); sys.exit(1)
if worst > 6:
    print("アイコンが期待の画像と違う"); sys.exit(1)
print("アイコン一致")
