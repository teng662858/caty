#!/usr/bin/env bash
# fetch-mpvkit.sh —— 下载 libmpv 播放内核（MPVKit 预编译二进制包，LGPL 版）
#
# 为什么要脚本而不是 SwiftPM：MPVKit 是 ~28 个 .xcframework 二进制包，
# Xcode 的 SwiftPM 并发下载会稳定报 "already exists in file system"（实测两次都失败），
# 所以改成"我们自己按清单下载 + sha256 校验 + 解压"，完全确定性。
#
# 清单来源：mpvkit/MPVKit 的 Package.swift（LGPL 目标 _MPVKit + _FFmpeg），版本已钉死。
# 用法：bash ios/scripts/fetch-mpvkit.sh   → 产物在 ios/Frameworks/mpvkit/（已 gitignore）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="$ROOT/ios/Frameworks/mpvkit"
CACHE="${MPVKIT_CACHE:-/tmp/mpvkit-cache}"
mkdir -p "$DEST" "$CACHE"

fetch() { # name url sha256
  local name="$1" url="$2" sha="$3"
  local xc="$DEST/$name.xcframework"
  if [ -d "$xc" ]; then echo "· $name 已就位"; return 0; fi
  local zip="$CACHE/$name.zip"
  if [ ! -f "$zip" ] || [ "$(shasum -a 256 "$zip" | awk '{print $1}')" != "$sha" ]; then
    echo "↓ $name"
    curl -L --fail --retry 3 --retry-delay 2 -o "$zip" "$url"
  fi
  echo "$sha  $zip" | shasum -a 256 -c - >/dev/null
  unzip -q -o "$zip" -d "$DEST"
  echo "✓ $name"
}

fetch "Libmpv" "https://github.com/mpvkit/MPVKit/releases/download/1.1.0-n9.0.2/Libmpv.xcframework.zip" "1d8651bebfe467bd5408751647de692cdacb1d19ba825e11785d770bc88c3225"
fetch "Libuchardet" "https://github.com/mpvkit/libuchardet-build/releases/download/0.0.8/Libuchardet.xcframework.zip" "ea4f548a230a755e059144657cc9e2ff563c1cdeae03974c38f8b6e1a40303fb"
fetch "Libbluray" "https://github.com/mpvkit/libbluray-build/releases/download/1.4.0/Libbluray.xcframework.zip" "bc037d34e2b0b5ab7f202fb371f5fb298136cc66fdf406c2172185d06f53f18d"
fetch "Libavcodec" "https://github.com/mpvkit/MPVKit/releases/download/1.1.0-n9.0.2/Libavcodec.xcframework.zip" "d516e904490c711c2875dd238d7d8d9f4f46e335829cb8ee7e0e1623e952e372"
fetch "Libavdevice" "https://github.com/mpvkit/MPVKit/releases/download/1.1.0-n9.0.2/Libavdevice.xcframework.zip" "f29bde9d8f788337996f8b2759645a6e22e9056e4bc1e3494458193405f50a5d"
fetch "Libavfilter" "https://github.com/mpvkit/MPVKit/releases/download/1.1.0-n9.0.2/Libavfilter.xcframework.zip" "e764dc3b3d36abb26d6d0ae2f0c6a1de0b80a453f3ca4bf2bb6596c0f6464b19"
fetch "Libavformat" "https://github.com/mpvkit/MPVKit/releases/download/1.1.0-n9.0.2/Libavformat.xcframework.zip" "0a840424d7a2d971687d6e96d995e21420cce1b27dae74687ff4f5f31dc36e73"
fetch "Libavutil" "https://github.com/mpvkit/MPVKit/releases/download/1.1.0-n9.0.2/Libavutil.xcframework.zip" "0ca518d2a3eab22763310d8bcdc977494ddb3daf3dc3b73a2ed84c5eefc13f75"
fetch "Libswresample" "https://github.com/mpvkit/MPVKit/releases/download/1.1.0-n9.0.2/Libswresample.xcframework.zip" "49edabb3c2e7fb97e6458f2e6a2fea66ab567b55258141e598fecfcd29cd9eeb"
fetch "Libswscale" "https://github.com/mpvkit/MPVKit/releases/download/1.1.0-n9.0.2/Libswscale.xcframework.zip" "5aebc8107219d518d8e89f0af97365ff9758f91b3096a7d5c1a16e092745de39"
fetch "Libssl" "https://github.com/mpvkit/openssl-build/releases/download/3.3.5/Libssl.xcframework.zip" "ff5ffd43d015d7285fd37e4a3145b25cbd8d2842740bd629a711c299a20e226a"
fetch "Libcrypto" "https://github.com/mpvkit/openssl-build/releases/download/3.3.5/Libcrypto.xcframework.zip" "593283be2a90f7fd66f6e6ed331b2f099cf403e0926fe3b4ac09a7062b793965"
fetch "Libass" "https://github.com/mpvkit/libass-build/releases/download/0.17.5/Libass.xcframework.zip" "3f4c576d2818ceb4544aa2a20e1f55846511c5e706fd19adc3ea9fd842270498"
fetch "Libfreetype" "https://github.com/mpvkit/libass-build/releases/download/0.17.5/Libfreetype.xcframework.zip" "496ca62488530e14b1e4624d20ee2b237c0bd675cd70c19da578a5768302d02d"
fetch "Libfribidi" "https://github.com/mpvkit/libass-build/releases/download/0.17.5/Libfribidi.xcframework.zip" "bc15e097b892f2f90424e4a27ba287070cc2f98a74a4da10e6d2481d15cf5ff9"
fetch "Libharfbuzz" "https://github.com/mpvkit/libass-build/releases/download/0.17.5/Libharfbuzz.xcframework.zip" "aa8e0b9ca0387dac74e3e93c86e34d11982bb013b28022d0e6966a8427a35b2e"
fetch "MoltenVK" "https://github.com/mpvkit/moltenvk-build/releases/download/1.4.2/MoltenVK.xcframework.zip" "aee189c54ad7c62bf734a3dc51eb4cfad5685d1d63b0ec519ecd1b437c332418"
fetch "Libshaderc_combined" "https://github.com/mpvkit/libshaderc-build/releases/download/2025.5.0/Libshaderc_combined.xcframework.zip" "758047b615708575b580eb960a2d083f760a29dc462d6eaa360416c946ce433b"
fetch "lcms2" "https://github.com/mpvkit/lcms2-build/releases/download/2.17.0/lcms2.xcframework.zip" "dc0dce0606f6ab6841a8ec5a6bd4448e2f3ef00661a050460f806c9393dc6982"
fetch "Libplacebo" "https://github.com/mpvkit/libplacebo-build/releases/download/7.360.1/Libplacebo.xcframework.zip" "2fa3d54cb81f302d6f11c7b2f509af30944381c3b11ee9d35096eb4637a6e2dd"
fetch "Libdovi" "https://github.com/mpvkit/libdovi-build/releases/download/3.3.2/Libdovi.xcframework.zip" "e693e239808350868e79c5448ef9f02e2716bc822dd8632a41a368a1eae5ca7d"
fetch "Libunibreak" "https://github.com/mpvkit/libass-build/releases/download/0.17.5/Libunibreak.xcframework.zip" "940d9833cf4477d0a260d9f2b4066125bc0ff7bbc111ac3c90e774765b77a559"
fetch "gmp" "https://github.com/mpvkit/gnutls-build/releases/download/3.8.11/gmp.xcframework.zip" "ad33c7a08f4cdcb9924c8f0e6d9a054dad33d7794b97667bf8b6fb2b236ae585"
fetch "nettle" "https://github.com/mpvkit/gnutls-build/releases/download/3.8.11/nettle.xcframework.zip" "0fdf3ebf8bd7b8bc8eee837cf27261cb4c52ae520b6576a2f468656aa1691e02"
fetch "hogweed" "https://github.com/mpvkit/gnutls-build/releases/download/3.8.11/hogweed.xcframework.zip" "25727c9fa67287fa0a4f4722f88bb8be669b23cd7e837e2d00870eb8a25d3f27"
fetch "gnutls" "https://github.com/mpvkit/gnutls-build/releases/download/3.8.11/gnutls.xcframework.zip" "3dbec5809339189bf9679e218c6cff387ebf8fb72745927835afc2678f5c9f4d"
fetch "Libdav1d" "https://github.com/mpvkit/libdav1d-build/releases/download/1.5.3/Libdav1d.xcframework.zip" "d1a32ae6a1f0193e9f05c44c9176844af7f6d2a58cb33843f6f1b8dfd9224083"
fetch "Libuavs3d" "https://github.com/mpvkit/libuavs3d-build/releases/download/1.2.1-fix/Libuavs3d.xcframework.zip" "bd5256081486d16c51c868d755bf70266c424b54c895269580de44ec6707f789"

echo "libmpv 组件全部就位：$(ls -d "$DEST"/*.xcframework | wc -l | tr -d " ") 个"
