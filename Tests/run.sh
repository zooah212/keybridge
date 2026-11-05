#!/bin/sh
# 只在项目临时目录测试，不修改已安装插件及用户词库。
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d Tests/.run-XXXXXX)
trap 'rm -rf -- "${work:?}"' EXIT HUP INT TERM
# 架构与最低系统随设备变：A11 及更早的 rootless 机器没有 arm64e，用 KB_TEST_ARCH=arm64 跑。
clang -arch "${KB_TEST_ARCH:-arm64e}" -mios-version-min="${KEYBRIDGE_MIN_IOS:-15.0}" -O1 -fobjc-arc -fblocks \
  -DNOUNCRYPT -DMINIZIP_FOPEN_NO_64 -I Importer/vendor/minizip \
  Tests/ImportTests.m Injector/KeyBridgeConvert.m Injector/KeyBridgeUnzip.m Injector/KeyBridgeCustom.m \
  Importer/vendor/minizip/unzip.c Importer/vendor/minizip/ioapi.c \
  -framework Foundation -lz -o "$work/import-tests"
ldid -STests/Tool.entitlements "$work/import-tests"
"./$work/import-tests" "$work"
