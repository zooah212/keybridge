// Daemon-only executor. Never include this in the Settings bundle.
#pragma once
#import <Foundation/Foundation.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

// root comes from the running daemon's executable, never from preferences.
// realpath is used only in memory; no resolved bootstrap path is persisted.
static NSString *KBRespringTrustedTool(NSString *root, NSArray<NSString *> *fixedNames) {
    if (!root.length) return nil;
    char rootPath[PATH_MAX];
    if (!realpath(root.fileSystemRepresentation, rootPath)) return nil;
    NSString *prefix = [@(rootPath) stringByAppendingString:strcmp(rootPath, "/") ? @"/" : @""];
    for (NSString *name in fixedNames) {
        char toolPath[PATH_MAX];
        NSString *candidate = [root stringByAppendingPathComponent:name];
        if (!realpath(candidate.fileSystemRepresentation, toolPath)) continue;
        NSString *resolved = @(toolPath);
        struct stat st;
        if (![resolved hasPrefix:prefix] || stat(toolPath, &st) != 0 || !S_ISREG(st.st_mode) ||
            st.st_uid != 0 || (st.st_mode & (S_IWGRP | S_IWOTH)) || access(toolPath, X_OK) != 0) continue;
        return resolved;
    }
    return nil;
}

static NSString *KBRespringTool(NSString *root, NSString **sbreload) {
    if (geteuid() != 0) return @"重载失败：后台不是 root 身份";
    *sbreload = KBRespringTrustedTool(root, @[@"usr/bin/sbreload"]);
    if (!*sbreload)
        return @"注销不可用：缺少可信的 sbreload（须由 root 所有且不可被组/其他用户写入）";
    return nil;
}

// No shell, PATH lookup, caller-provided arguments, service labels or paths.
// Uses the same sbreload entry as Dopamine respring, not reboot_userspace.
// Returns command acceptance only, not proof that the desktop has reloaded.
static BOOL KBRespringRunTool(NSString *tool, NSString **failure) {
    char *desktopArgs[] = {(char *)tool.fileSystemRepresentation, NULL};
    char *environment[] = {"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LANG=C", NULL};
    posix_spawn_file_actions_t actions;
    int error = posix_spawn_file_actions_init(&actions);
    if (error == 0) {
        error = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
        if (error == 0) error = posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
        if (error == 0) error = posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
        pid_t child = 0;
        if (error == 0) error = posix_spawn(&child, tool.fileSystemRepresentation, &actions, NULL,
                                           desktopArgs, environment);
        posix_spawn_file_actions_destroy(&actions);
        if (error == 0) {
            NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 8.0;
            int status = 0;
            for (;;) {
                pid_t waited = waitpid(child, &status, WNOHANG);
                if (waited == child) {
                    if (WIFEXITED(status) && WEXITSTATUS(status) == 0) return YES;
                    *failure = [NSString stringWithFormat:@"%@ 返回失败（%@ %d），未自动重试",
                        @"sbreload",
                        WIFEXITED(status) ? @"退出码" : @"信号",
                        WIFEXITED(status) ? WEXITSTATUS(status) : WTERMSIG(status)];
                    return NO;
                }
                if (waited < 0 && errno != EINTR) { error = errno; break; }
                if (NSProcessInfo.processInfo.systemUptime >= deadline) {
                    // Only our own child is stopped; never signal a service by PID.
                    kill(child, SIGKILL);
                    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
                    *failure = @"重载命令超时，已停止等待；系统可能已部分重载，未自动重试";
                    return NO;
                }
                usleep(50000);
            }
        }
    }
    *failure = [NSString stringWithFormat:@"无法执行重载命令（错误 %d）；请检查越狱权限，未自动重试", error];
    return NO;
}
