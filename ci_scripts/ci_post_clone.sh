#!/bin/bash
# Xcode Cloud: クローン直後に、GitHub Actions(build.yml)と同じ下ごしらえをする。
# ①絵文字辞書の submodule ②zenz の重み ③IDevice.xcframework(固定 sha256)と idevice.h の包み直し
# アイコンは非公開の差し替えをしない(コミット済みのまま)。
set -euo pipefail
cd "${CI_PRIMARY_REPOSITORY_PATH:-$(dirname "$0")/..}"

git submodule update --init azooKey_emoji_dictionary_storage
for m in "zenz-v3.2-small-gguf:c67e03e07d215c869f591b274c1631170d3e11fe" "zenz-v3.2-xsmall-gguf:4f5423f0fad41a73b1242eb96fe5c12ae4fdca83"; do
  name=${m%%:*}; rev=${m##*:}
  mkdir -p "$name"
  curl -fsSL --retry 3 -o "$name/ggml-model-Q5_K_M.gguf" \
    "https://huggingface.co/Miwa-Keita/$name/resolve/$rev/ggml-model-Q5_K_M.gguf"
done

mkdir -p MainApp/Vendor
curl -fsSL --retry 3 -o /tmp/idevice.zip \
  "https://github.com/Mumicanso8323/idevice/releases/download/v0.1.68-tsukaima1/idevice-xcframework-v0.1.68-tsukaima1.zip"
echo "4973a451d575983844d33be8e858cbd353ed7cd3e843906badf6b06acc50ed2d  /tmp/idevice.zip" | shasum -a 256 -c -
rm -rf /tmp/idevice && unzip -q -o /tmp/idevice.zip -d /tmp/idevice
XCF=$(find /tmp/idevice -maxdepth 3 -name 'IDevice.xcframework' -type d | head -1)
test -n "$XCF"
rm -rf MainApp/Vendor/IDevice.xcframework && cp -R "$XCF" MainApp/Vendor/
H=$(find /tmp/idevice -maxdepth 3 -name 'idevice.h' | head -1); [ -n "$H" ] && cp "$H" MainApp/Vendor/ || true
python3 - <<'PY'
import glob, re
# idevice.h は ObjC++ 相互運用で C++ として読まれる。(1) cbindgen 部分に extern "C" が無く名前が
# マングルされてリンクで落ちる (2) libplist 部分は extern "C" の内側で <stdint.h> 等を include して
# モジュール衝突する。→ 全ての <...> include を先頭へ出し、残り全体を extern "C" で包む。
for h in glob.glob("MainApp/Vendor/IDevice.xcframework/*/Headers/idevice.h") + glob.glob("MainApp/Vendor/idevice.h"):
    lines = open(h).read().split("\n")
    moved = []
    for i, l in enumerate(lines):
        if re.match(r'\s*#include <[^>]+>\s*$', l):
            moved.append(l.strip()); lines[i] = "/* hoisted: " + l.strip() + " */"
    # Windows 専用(#ifdef _WIN32 の中)の include は Apple では不要なので捨てる
    moved = [m for m in moved if "winsock" not in m and "ws2tcpip" not in m and "windows.h" not in m]
    head = sorted(set(moved)) + ["#ifdef __cplusplus", 'extern "C" {', "#endif"]
    tail = ["#ifdef __cplusplus", "}", "#endif"]
    open(h, "w").write("\n".join(head + lines + tail) + "\n")
    print(h, "wrapped; hoisted", sorted(set(moved)))
PY
ls -la MainApp/Vendor
