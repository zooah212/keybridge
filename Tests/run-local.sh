#!/bin/sh
# 仅使用项目临时目录，不接触安装中的插件或用户词库。
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d Tests/.local-run-XXXXXX)
trap 'rm -rf -- "${work:?}"' EXIT HUP INT TERM
clang -arch arm64e -mios-version-min=15.0 -O1 -fobjc-arc -fblocks -Wall -Wextra \
  Tests/LocalTests.m Injector/KeyBridgeCustom.m -framework Foundation -o "$work/local-tests"
ldid -STests/Tool.entitlements "$work/local-tests"
"./$work/local-tests" "$work"
