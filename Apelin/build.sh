#!/bin/sh
# 构建 KeyBridge 的 deb：设置面板、kbd 探针、注入守护进程，只产出一个包。
set -eu
: "${APELIN_PACKAGE_DIR:?run this through apelin_project_build}"
: "${APELIN_PROJECT_ROOT:?}"
: "${APELIN_BOOTSTRAP:?}"
: "${APELIN_ARCHITECTURE:?}"
: "${APELIN_BUILD_ID:?}"
: "${TMPDIR:?}"
: "${SDKROOT:?}"

cd "$APELIN_PROJECT_ROOT"

# 打包形态：rootless 的文件落在 /var/jb 前缀下（iOS 15 起用），roothide 的前缀为空
# （包内写真实根路径，装机时由 vroot 改写）。没显式给 KEYBRIDGE_SCHEME 时按 Apelin
# 传下的 APELIN_PREFIX 推断：空即 roothide，非空即 rootless。
# 单独成函数是为了 Tests/test_build_mode.py 能只跑这段派生逻辑，不碰编译器。
kb_resolve_scheme() {
  scheme="${KEYBRIDGE_SCHEME:-}"
  prefix="${APELIN_PREFIX:-}"
  if [ -z "$scheme" ]; then
    case "$prefix" in
      ""|"/") scheme=roothide ;;
      *) scheme=rootless ;;
    esac
  fi
  case "$scheme" in
    rootless)
      prefix="${prefix%/}"
      [ -n "$prefix" ] || prefix=/var/jb
      ;;
    roothide) prefix="" ;;
    *) echo "error: KEYBRIDGE_SCHEME must be rootless or roothide" >&2; return 1 ;;
  esac
  # 上界不再写死：和 SwipeDeck 一样只声明下限，iOS 15/16/17 都能装。
  min_ios="${KEYBRIDGE_MIN_IOS:-15.0}"
  version="${KEYBRIDGE_VERSION:-0.0.3}"
  firmware_dep="firmware (>= $min_ios)"
  # 一行一个字段：firmware 的值本身带空格，写成一行会被下游拆分切碎。
  printf 'scheme=%s\nprefix=%s\nmin_ios=%s\nversion=%s\nfirmware=%s\n' \
    "$scheme" "$prefix" "$min_ios" "$version" "$firmware_dep"
}
kb_resolve_scheme

# 只要解析结果、不编译：CI 用它读版本与形态，避免同一个版本号在脚本和 workflow 里各写一遍。
if [ "${KEYBRIDGE_PRINT_VARS_ONLY:-}" = "1" ]; then exit 0; fi

case "$APELIN_ARCHITECTURE" in
  iphoneos-arm64e) arches="arm64e" ;;
  iphoneos-arm64) arches="arm64 arm64e" ;;
  *) echo "error: unknown package architecture $APELIN_ARCHITECTURE" >&2; exit 1 ;;
esac
[ "$(uname -s)" = Darwin ] || { echo "error: this build runs only on the device" >&2; exit 1; }

need_tool() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: $1 is not available; install it in the bootstrap" >&2; exit 1; }
}
need_tool clang
need_tool ldid
need_tool dpkg-deb
[ "$arches" = arm64e ] || need_tool lipo

stage=$(mktemp -d "${TMPDIR:?}keybridge.XXXXXX")
trap 'rm -rf -- "${stage:?}"' EXIT HUP INT TERM
obj="$stage/obj"
bundle="$stage/KeyBridgePreferences.bundle"
mkdir -p "$obj" "$bundle"

# 面板源码
compile_objc() {
  arch=$1 out=$2
  for source in ImportPreferences/KBImportController.m; do
    name=$(basename "$source" .m)
    clang -arch "$arch" -isysroot "$SDKROOT" -mios-version-min="${KEYBRIDGE_MIN_IOS:-15.0}" -O2 \
      -fobjc-arc -fblocks -Wall -Wextra \
      -DAPELIN_BUILD_ID="\"$APELIN_BUILD_ID\"" \
      -I Importer -I Apelin/include \
      -c "$source" -o "$out/$name.o"
  done
}

link_bundle() {
  arch=$1 out=$2
  clang -arch "$arch" -isysroot "$SDKROOT" -mios-version-min="${KEYBRIDGE_MIN_IOS:-15.0}" -bundle -fobjc-arc \
    -o "$out/KeyBridgePreferences" "$out"/KBImportController.o \
    -F Apelin/stubs -framework Preferences \
    -framework Foundation -framework UIKit -framework UniformTypeIdentifiers -framework CoreGraphics
}

# 探针注入 kbd，候选顺序与过滤都在这里。
link_probe() {
  arch=$1 out=$2
  # Daily builds must not benchmark inside kbd while the user is typing.
  diagnostics=0
  case "${KEYBRIDGE_LOOKUP_BENCHMARK:-0}" in
    0) ;;
    1)
      if [ "${APELIN_CONFIGURATION:-debug}" = release ]; then
        echo "error: lookup benchmark is diagnostic-only; use a debug build" >&2
        exit 1
      fi
      diagnostics=1
      ;;
    *) echo "error: KEYBRIDGE_LOOKUP_BENCHMARK must be 0 or 1" >&2; exit 1 ;;
  esac
  trace=0
  case "${KEYBRIDGE_CANDIDATE_TRACE:-0}" in
    0) ;;
    1)
      if [ "${APELIN_CONFIGURATION:-debug}" = release ]; then
        echo "error: candidate trace is diagnostic-only; use a debug build" >&2
        exit 1
      fi
      trace=1
      ;;
    *) echo "error: KEYBRIDGE_CANDIDATE_TRACE must be 0 or 1" >&2; exit 1 ;;
  esac
  clang -arch "$arch" -isysroot "$SDKROOT" -mios-version-min="${KEYBRIDGE_MIN_IOS:-15.0}" -O2 \
    -fobjc-arc -fblocks -dynamiclib -DKB_LOOKUP_BENCHMARK="$diagnostics" \
    -DKB_CANDIDATE_TRACE="$trace" \
    -DAPELIN_BUILD_ID="\"$APELIN_BUILD_ID\"" \
    -o "$out/KeyBridgeProbe.dylib" Probe/KeyBridgeProbe.m \
    -framework Foundation
}

# 守护进程（root）：ellekit 不注入系统守护进程，由它把探针送进 kbd。
link_injector() {
  arch=$1 out=$2
  clang -arch "$arch" -isysroot "$SDKROOT" -mios-version-min="${KEYBRIDGE_MIN_IOS:-15.0}" -O2 \
    -fobjc-arc -DNOUNCRYPT -DMINIZIP_FOPEN_NO_64 -o "$out/keybridge-injector" Injector/KeyBridgeInjector.m Injector/KeyBridgeConvert.m Injector/KeyBridgeUnzip.m Injector/KeyBridgeCustom.m \
    Importer/vendor/minizip/unzip.c Importer/vendor/minizip/ioapi.c \
    -framework Foundation -lz -I Importer/vendor/minizip
}

for arch in $arches; do
  out="$obj/$arch"
  mkdir -p "$out"
  echo "compiling $arch"
  compile_objc "$arch" "$out"
  link_bundle "$arch" "$out"
  link_probe "$arch" "$out"
  link_injector "$arch" "$out"
done

if [ "$arches" = arm64e ]; then
  cp "$obj/arm64e/KeyBridgePreferences" "$bundle/KeyBridgePreferences"
  probe="$obj/arm64e/KeyBridgeProbe.dylib"
  injector="$obj/arm64e/keybridge-injector"
else
  lipo -create "$obj/arm64/KeyBridgePreferences" "$obj/arm64e/KeyBridgePreferences" \
    -output "$bundle/KeyBridgePreferences"
  probe="$obj/KeyBridgeProbe.dylib"
  lipo -create "$obj/arm64/KeyBridgeProbe.dylib" "$obj/arm64e/KeyBridgeProbe.dylib" -output "$probe"
  injector="$obj/keybridge-injector"
  lipo -create "$obj/arm64/keybridge-injector" "$obj/arm64e/keybridge-injector" -output "$injector"
fi
cp ImportPreferences/Resources/Info.plist "$bundle/Info.plist"
cp Assets/KeyBridge.png "${bundle:?}/KeyBridge.png"
for icon in icon.png icon@2x.png icon@3x.png; do
  cp "ImportPreferences/Resources/${icon:?}" "${bundle:?}/${icon:?}"
  chmod 0644 "${bundle:?}/${icon:?}"
done
chmod 0755 "$bundle/KeyBridgePreferences"
chmod 0644 "$bundle/Info.plist" "${bundle:?}/KeyBridge.png"
ldid -S "$bundle/KeyBridgePreferences"

# 包内路径相对 bootstrap：rootless 落在 /var/jb 下，roothide 前缀为空。
payload="$stage/root"
destination="$payload$prefix"
mkdir -p "$destination/Library/PreferenceBundles" \
  "$destination/Library/PreferenceLoader/Preferences" \
  "$destination/Library/MobileSubstrate/DynamicLibraries" \
  "$destination/usr/libexec" "$payload/DEBIAN"
cp -R "$bundle" "$destination/Library/PreferenceBundles/"
cp layout/Library/PreferenceLoader/Preferences/KeyBridge.plist \
  "$destination/Library/PreferenceLoader/Preferences/KeyBridge.plist"
cp "$probe" "$destination/Library/MobileSubstrate/DynamicLibraries/KeyBridgeProbe.dylib"
cp Probe/KeyBridgeProbe.plist \
  "$destination/Library/MobileSubstrate/DynamicLibraries/KeyBridgeProbe.plist"
chmod 0755 "$destination/Library/MobileSubstrate/DynamicLibraries/KeyBridgeProbe.dylib"
chmod 0644 "$destination/Library/MobileSubstrate/DynamicLibraries/KeyBridgeProbe.plist"
ldid -S "$destination/Library/MobileSubstrate/DynamicLibraries/KeyBridgeProbe.dylib"

cp "$injector" "$destination/usr/libexec/keybridge-injector"
chmod 0755 "$destination/usr/libexec/keybridge-injector"
ldid -SInjector/Injector.entitlements "$destination/usr/libexec/keybridge-injector"
# LaunchDaemon plist 不在包里预置，由 postinst 根据当前越狱形态现场生成：
# 安装环境里某个 dpkg/apt 环节可能把落盘 plist 转成 binary1，拿 sed 改它
# 会当场改坏（launchd 拒注册且不留日志），所以不给它任何被改坏的机会。
cp Injector/postinst "$payload/DEBIAN/postinst"
cp Injector/prerm "$payload/DEBIAN/prerm"
chmod 0755 "$payload/DEBIAN/postinst" "$payload/DEBIAN/prerm"

{
  printf 'Package: com.wm0104.keybridge\n'
  printf 'Name: 词库桥接\n'
  printf 'Version: %s\n' "$version"
  printf 'Architecture: %s\n' "$APELIN_ARCHITECTURE"
  printf 'Description: 为苹果原生中文键盘接入本地 Rime 词库，支持 26 键全拼与九宫格。兼容测试范围：iOS 15.0–16.x；目前仅在 iOS 16.3（roothide）真机验证。特别感谢 i_82（Apelin 作者）提供的开发支持。\n'
  printf 'Icon: https://raw.githubusercontent.com/wm0104/keybridge/main/Assets/KeyBridge.png\n'
  printf 'Maintainer: wm0104\n'
  printf 'Author: wm0104\n'
  printf 'Section: 键盘增强\n'
  printf 'Depends: mobilesubstrate, preferenceloader, %s\n' "$firmware_dep"
} > "$payload/DEBIAN/control"

deb="$APELIN_PACKAGE_DIR/KeyBridge_${version}_${APELIN_ARCHITECTURE}.deb"
rm -f -- "${deb:?}"
if ! dpkg-deb --build --root-owner-group "$payload" "$deb" 2>"$stage/dpkg.err"; then
  rm -f -- "${deb:?}"
  dpkg-deb --build "$payload" "$deb"
fi
echo "built $deb"
