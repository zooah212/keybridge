#!/bin/sh
# Syntax + source-structure guards only. Does not link, sign, run test binaries,
# execute a service command, change preferences, or generate a package.
set -eu
cd "$(dirname "$0")/.."
checks=0
require() {
    grep -Fq -- "$2" "$1" || { printf 'missing guard in %s: %s\n' "$1" "$2" >&2; exit 1; }
    checks=$((checks + 1))
}
reject() {
    if grep -Eq -- "$2" "$1"; then printf 'forbidden executor in %s\n' "$1" >&2; exit 1; fi
    checks=$((checks + 1))
}
ui=ImportPreferences/KBImportController.m
daemon=Injector/KeyBridgeInjector.m
protocol=Injector/KBRespring.h
executor=Injector/KBRespringExecutor.h
reject "$ui" 'KBRespringExecutor|posix_spawn|popen\(|system\(|setuid\(|kill\('
reject "$executor" 'posix_spawnp|popen\(|system\(|/bin/(ba)?sh|reboot\('
reject "$executor" 'TextInput.kbd|kickstart|reboot3|RB2_USERREBOOT'
require "$executor" 'char *desktopArgs[] = {(char *)tool.fileSystemRepresentation, NULL};'
require "$executor" 'st.st_uid != 0 || (st.st_mode & (S_IWGRP | S_IWOTH))'
require "$executor" 'NSProcessInfo.processInfo.systemUptime + 8.0'
require "$protocol" 'request.count != keys.count'
require "$protocol" 'now - createdAt > KBRespringRequestLifetime'
require "$protocol" 'uptime - issuedUptime > KBRespringChallengeLifetime'
require "$protocol" 'KBRespringActionReloadDesktop = 2'
require "$ui" 'notify_post(KBRespringNotification);'
require "$daemon" 'notify_register_dispatch(KBRespringNotification, &notificationToken,'
require "$daemon" 'dispatch_semaphore_wait(wakeup, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));'
require "$daemon" 'KBRespringSession = NSUUID.UUID.UUIDString;'
require "$daemon" 'KBRespringLastRequest = [prefs[KBRespringRequestKey] copy];'
require "$daemon" '[KBRespringSeenIDs containsObject:identifier]'
require "$daemon" 'KBRespringHasPendingLibraryCommand(KBReadPrefs(), KBReadHandled(keyboard))'
require "$ui" 'if (self.respringRequestID.length) return;'
require "$ui" 'NSProcessInfo.processInfo.systemUptime >= self.respringDeadline'
require "$ui" 'self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"注销"'
require "$ui" 'target:self action:@selector(requestRespring)];'
require "$ui" 'self.navigationItem.rightBarButtonItem.enabled = !self.busy && !self.respringRequestID.length;'
reject "$ui" 'confirmRespring|indexPath.section == 5|case 5: return 1|注销桌面（重载键盘）|重启 kbd 与 SpringBoard'
submission=$(sed -n '/^- (void)requestRespring {/,/^- (void)restoreRespringRequest {/p' "$ui")
case "$submission" in *'UIAlertController'*|*'UIAlertAction'*) echo 'respring must not require confirmation' >&2; exit 1;; esac
checks=$((checks + 1))
case "$submission" in
  *'KBRespringReadState(KBKeyboardDirectory)'*'respringProblemForState:state'*'if (problem)'*'state[@"nonce"]'*'setObject:request forKey:KBRespringRequestKey'*'[self restoreRespringRequest]'*) checks=$((checks + 1));;
  *) echo 'direct request validation/write ordering changed' >&2; exit 1;;
esac
for method in beginBusy restoreRespringRequest; do
    body=$(sed -n "/^- (void)${method}/,/^}/p" "$ui")
    case "$body" in *'self.navigationItem.rightBarButtonItem.enabled = NO;'*) checks=$((checks + 1));;
      *) echo "respring button stays enabled during $method" >&2; exit 1;; esac
done
finish=$(sed -n '/^- (void)finishRespring:/,/^}/p' "$ui")
case "$finish" in *'self.navigationItem.rightBarButtonItem.enabled = !self.busy;'*) checks=$((checks + 1));;
  *) echo 'respring button not restored after receipt' >&2; exit 1;; esac
admission=$(sed -n '/^static void KBRespringPoll(/,/^static void KBEnsureDirectory(/p' "$daemon")
case "$admission" in
  *'KBRespringRequestFailure(request'*'KBRespringNonce = nil;'*'KBCommandRunning = YES;'*'writeToFile:'*'if (!admitted) return;'*'dispatch_async(KBCommandQueue'*'KBRespringRunTool(checkedSbreload, &failure)'*) checks=$((checks + 1));;
  *) echo 'consume/publish/reserve/execute ordering changed' >&2; exit 1;;
esac
task=$(sed -n '/^static void KBTaskBegin(/,/^static void KBTaskPhase(/p' "$daemon")
case "$task" in *'KBRespringNonce = nil;'*'KBTaskWrite(keyboard);'*) checks=$((checks + 1));;
  *) echo 'import no longer invalidates a challenge immediately' >&2; exit 1;; esac
for arch in arm64 arm64e; do
    clang -arch "$arch" -mios-version-min=15.0 -fobjc-arc -fblocks -fsyntax-only \
        -Wall -Wextra -Werror=unguarded-availability-new -I Apelin/include -I Importer \
        "$ui" "$daemon" Tests/RespringTests.m
done
printf 'Static guards: %s passed; arm64/arm64e syntax checks passed. Runtime assertions were NOT executed.\n' "$checks"
