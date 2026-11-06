#!/bin/sh
# rootless 包布局校验。GitHub Actions 与 CodeMagic 共用这一份，避免两边规则漂移。
#
# 用法: sh Tests/verify-rootless-deb.sh <deb 路径> [期望版本号]
#
# 不解析 dpkg-deb -c 的列布局：macOS 上是 bsdtar、Linux 上是 GNU tar，字段数不一样，
# 而且归档条目带 ./ 前缀（-c 的第 6 列在两种 tar 下分别指向日期和路径）。改成真正解包，
# 用解出来的文件系统相对路径判定，前缀和列布局两个坑一起消掉。
set -eu

deb=${1:?usage: verify-rootless-deb.sh <deb> [version]}
want_version=${2:-}

command -v dpkg-deb >/dev/null 2>&1 || { echo "error: dpkg-deb unavailable" >&2; exit 1; }
[ -f "$deb" ] || { echo "error: missing $deb" >&2; exit 1; }

dpkg-deb -f "$deb" Package Version Architecture Depends
if [ -n "$want_version" ]; then
  got=$(dpkg-deb -f "$deb" Version)
  if [ "$got" != "$want_version" ]; then
    echo "error: 包里的版本是 $got，期望 $want_version" >&2
    exit 1
  fi
fi

root=$(mktemp -d)
ctl=$(mktemp -d)
trap 'rm -rf "$root" "$ctl"' EXIT HUP INT TERM
dpkg-deb -x "$deb" "$root"
dpkg-deb --control "$deb" "$ctl"

# 只列非目录条目作为文件清单；var、var/jb 这些归档自带的祖先目录不参与文件判定，
# 不需要再靠白名单放行（旧规则就在这里误判过一次）。
list=$(cd "$root" && find . -mindepth 1 ! -type d | sed 's|^\./||' | sort)
if [ -z "$list" ]; then
  echo "error: 解包后一个文件都没有，dpkg-deb -x 可能读不了这个包" >&2
  exit 1
fi
echo "→ 包内文件清单:"
printf '%s\n' "$list"

bad=$(printf '%s\n' "$list" | grep -v '^var/jb/' || true)
if [ -n "$bad" ]; then
  printf '%s\n' "$bad" >&2
  echo "error: 有文件不在 /var/jb 前缀下（rootless 包必须是这套布局）" >&2
  exit 1
fi

# 目录只放行 var 与 var/jb 两个祖先，其它位置的空目录一样拦掉，口径不比旧规则松。
baddir=$(cd "$root" && find . -mindepth 1 -type d | sed 's|^\./||' \
  | grep -v -e '^var$' -e '^var/jb$' -e '^var/jb/' || true)
if [ -n "$baddir" ]; then
  printf '%s\n' "$baddir" >&2
  echo "error: 有目录不在 /var/jb 前缀下" >&2
  exit 1
fi

for path in \
  var/jb/Library/PreferenceBundles/KeyBridgePreferences.bundle/KeyBridgePreferences \
  var/jb/Library/PreferenceBundles/KeyBridgePreferences.bundle/Info.plist \
  var/jb/Library/PreferenceBundles/KeyBridgePreferences.bundle/icon.png \
  var/jb/Library/PreferenceLoader/Preferences/KeyBridge.plist \
  var/jb/Library/MobileSubstrate/DynamicLibraries/KeyBridgeProbe.dylib \
  var/jb/Library/MobileSubstrate/DynamicLibraries/KeyBridgeProbe.plist \
  var/jb/usr/libexec/keybridge-injector; do
  if ! printf '%s\n' "$list" | grep -qx "$path"; then
    echo "error: missing $path" >&2
    exit 1
  fi
done

# LaunchDaemon plist 必须由 Injector/postinst 现场生成，包里不许留模板。
if printf '%s\n' "$list" | grep -q 'injector\.plist\.in'; then
  echo "error: 旧的 plist 模板还在包里（应由 postinst 现场生成）" >&2
  exit 1
fi

# 维护脚本必须可执行且不带 CRLF：带 CR 的 #!/bin/sh 在设备上会被 dpkg 认不出。
# 用字节数差判定，不用 grep 匹配 CR：有些 grep 在文本模式下会吃掉行尾 CR，造成漏报。
for script in postinst prerm; do
  if [ ! -x "$ctl/$script" ]; then
    echo "error: DEBIAN/$script 缺失或不可执行" >&2
    exit 1
  fi
  total=$(wc -c < "$ctl/$script" | tr -d '[:space:]')
  nocr=$(tr -d '\r' < "$ctl/$script" | wc -c | tr -d '[:space:]')
  if [ "$total" -ne "$nocr" ]; then
    echo "error: DEBIAN/$script 带 CRLF，设备上不认这个 #!/bin/sh" >&2
    exit 1
  fi
done

echo "✓ rootless 布局校验通过"
