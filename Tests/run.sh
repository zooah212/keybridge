#!/bin/sh
# 只在项目临时目录测试，不修改已安装插件及用户词库。
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d Tests/.run-XXXXXX)
trap 'rm -rf -- "${work:?}"' EXIT HUP INT TERM
clang -arch arm64e -mios-version-min=16.3 -O1 -fobjc-arc -fblocks \
  -DNOUNCRYPT -DMINIZIP_FOPEN_NO_64 -I Importer/vendor/minizip \
  Tests/ImportTests.m Injector/KeyBridgeConvert.m Injector/KeyBridgeUnzip.m Injector/KeyBridgeCustom.m \
  Importer/vendor/minizip/unzip.c Importer/vendor/minizip/ioapi.c \
  -framework Foundation -lz -o "$work/import-tests"
ldid -STests/Tool.entitlements "$work/import-tests"
"./$work/import-tests" "$work"
