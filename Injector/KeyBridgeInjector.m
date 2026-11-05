// KeyBridge 注入守护进程：ellekit 不碰系统守护进程，kbd 要自己注入。
// 只做一件事：kbd 的 pid 变了就用 opainject 注入探针；不联网，不碰别的进程。

#import <Foundation/Foundation.h>
#import <os/log.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <stdio.h>

extern char **environ;

BOOL KBConvertDictionaries(NSString *incomingDirectory, NSString *destinationDirectory, void (^log)(NSString *));
void KBSetConvertOptions(BOOL keepTraditional, BOOL keepASCII);
static NSString *KBBootstrapRoot(void);

void KBGetConvertStats(NSUInteger *accepted, NSUInteger *droppedTraditional, NSUInteger *droppedASCII);
void KBSetExcludedWords(NSSet<NSString *> *words);
NSUInteger KBGetExcludedCount(void);
NSUInteger KBGetDroppedRareCount(void);
void KBSetDebugLog(void (^log)(NSString *));
void KBSetCommonOnly(BOOL on);

// 转换过程的调试痕迹：每个词典文件读出了多少条、认的哪个主词典、允许哪些表。
static void KBSetupDebugLog(NSString *keyboard) {
    NSString *path = [keyboard stringByAppendingPathComponent:@"convert-debug.log"];
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    KBSetDebugLog(^(NSString *message) {
        FILE *file = fopen(path.UTF8String, "a");
        if (!file) return;
        fprintf(file, "%s\n", message.UTF8String ?: "");
        fclose(file);
    });
}

// 每个词库目录里可以有一份 exclude.txt：每行一个词，# 开头是注释。
// 排除词：KeyBridge/exclude.txt 与每库一份，合并生效。
static NSSet<NSString *> *KBReadExcludedWordsFrom(NSString *path) {
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    if (!text.length) return nil;
    NSMutableSet<NSString *> *words = [NSMutableSet set];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *word = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        // 允许在词前加 # 或 - 当标记，也允许整行注释里写「# 说明」。
        while (word.length && ([word hasPrefix:@"#"] || [word hasPrefix:@"-"] || [word hasPrefix:@"＋"])) {
            word = [[word substringFromIndex:1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        }
        if (!word.length) continue;
        [words addObject:word];
    }
    return words.count ? words : nil;
}

static NSSet<NSString *> *KBReadExcludedWords(__unused NSString *keyboard, NSString *directory) {
    return KBReadExcludedWordsFrom([directory stringByAppendingPathComponent:@"exclude.txt"]);
}
NSUInteger KBExtractDictionaryZip(NSString *zipPath, NSString *destination, void (^log)(NSString *));

NSUInteger KBRebuildCustomIndexes(NSString *keyboard, void (^log)(NSString *));
static os_log_t KBInjectorLog;
static NSString *KBStatePath;
// 转换/重建放到后台队列：主循环每 2 秒的注入检查不能被一次一分钟的重建拖住。
static dispatch_queue_t KBCommandQueue;
static BOOL KBCommandRunning;
// 主循环只更新心跳；命令队列负责阶段和结果。
static NSMutableDictionary *KBTask;
static void KBTaskWrite(NSString *keyboard) {
    if (!KBTask) return;
    KBTask[@"updatedAt"] = @([NSDate date].timeIntervalSince1970);
    [[NSJSONSerialization dataWithJSONObject:KBTask options:0 error:NULL]
        writeToFile:[keyboard stringByAppendingPathComponent:@"import-task.json"] atomically:YES];
}
static void KBTaskBegin(NSString *keyboard, NSMutableDictionary *summary, double stamp) {
    summary[@"requestAt"] = @(stamp);
    @synchronized ([NSProcessInfo class]) {
        KBTask = [@{@"requestAt": @(stamp), @"phase": @"正在处理…", @"running": @YES} mutableCopy];
        KBTaskWrite(keyboard);
    }
}
static void KBTaskPhase(NSString *keyboard, NSString *phase) {
    @synchronized ([NSProcessInfo class]) {
        if (!KBTask) return;
        KBTask[@"phase"] = phase;
        KBTask[@"phaseAt"] = @([NSDate date].timeIntervalSince1970);
        KBTaskWrite(keyboard);
    }
}

// roothide 下守护进程看到的是 jbroot，真实根在 /rootfs。
static NSString *KBRealPath(NSString *path) {
    static BOOL hasRootfs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hasRootfs = [[NSFileManager defaultManager] fileExistsAtPath:@"/rootfs/private/var/mobile"];
    });
    return hasRootfs ? [@"/rootfs" stringByAppendingString:path] : path;
}

static void KBWriteState(NSDictionary *state) {
    if (!KBStatePath) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:state
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:NULL];
    // 守护进程的命名空间可能是 jbroot 也可能是真实根，逐个试，哪个写成功算哪个。
    for (NSString *path in @[@"/var/mobile/Library/Keyboard/KeyBridgeInjector.json",
                             @"/private/var/mobile/Library/Keyboard/KeyBridgeInjector.json",
                             @"/rootfs/private/var/mobile/Library/Keyboard/KeyBridgeInjector.json",
                             @"/private/var/tmp/KeyBridgeInjector.json",
                             @"/tmp/KeyBridgeInjector.json"]) {
        if ([data writeToFile:path atomically:YES]) return;
    }
}

// 设置在 bootstrap 的 var/mobile/Library/Preferences 里。
static NSString *KBPreferencesPath(void) {
    NSString *root = KBBootstrapRoot();
    if (root.length) {
        return [root stringByAppendingPathComponent:@"var/mobile/Library/Preferences/com.wm0104.keybridge.plist"];
    }
    return KBRealPath(@"/var/mobile/Library/Preferences/com.wm0104.keybridge.plist");
}

// 面板在沙盒里写不了 Keyboard 目录，所有指令都经这个偏好域传递。
static NSDictionary *KBReadPrefs(void) {
    return [NSDictionary dictionaryWithContentsOfFile:KBPreferencesPath()] ?: @{};
}

static NSString *KBHandledPath(NSString *keyboard) {
    return [keyboard stringByAppendingPathComponent:@".handled.json"];
}

static NSDictionary *KBReadHandled(NSString *keyboard) {
    NSData *data = [NSData dataWithContentsOfFile:KBHandledPath(keyboard)];
    if (!data) return @{};
    NSDictionary *handled = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [handled isKindOfClass:[NSDictionary class]] ? handled : @{};
}

static void KBWriteHandled(NSString *keyboard, NSDictionary *handled) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:handled options:0 error:NULL];
    [data writeToFile:KBHandledPath(keyboard) atomically:YES];
}

static void KBEnsureDirectory(NSString *path) {
    [[NSFileManager defaultManager] createDirectoryAtPath:path
                              withIntermediateDirectories:YES attributes:nil error:NULL];
}

static void KBWriteSummary(NSDictionary *summary, NSString *keyboard) {
    KBEnsureDirectory(keyboard);
    NSData *data = [NSJSONSerialization dataWithJSONObject:summary options:NSJSONWritingPrettyPrinted error:NULL];
    [data writeToFile:[keyboard stringByAppendingPathComponent:@"last-import.json"] atomically:YES];
    @synchronized ([NSProcessInfo class]) {
        if ([KBTask[@"requestAt"] doubleValue] == [summary[@"requestAt"] doubleValue]) {
            KBTask[@"running"] = @NO;
            KBTaskWrite(keyboard);
            KBTask = nil;
        }
    }
}

static NSString *KBLibrariesDirectory(NSString *keyboard) {
    return [keyboard stringByAppendingPathComponent:@"libs"];
}

// 库名取 ZIP 文件名，只留字母数字汉字与 -_。
static NSString *KBSanitizeLibraryName(NSString *name) {
    NSString *base = name.lastPathComponent;
    if ([base.lowercaseString hasSuffix:@".zip"]) {
        base = [base substringToIndex:base.length - 4];
    }
    NSMutableString *safe = [NSMutableString string];
    for (NSUInteger i = 0; i < base.length; i++) {
        unichar c = [base characterAtIndex:i];
        BOOL keep = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
                    (c == '-') || (c == '_') || (c >= 0x4E00 && c <= 0x9FFF);
        [safe appendFormat:@"%C", (unichar)(keep ? c : (unichar)'_')];
    }
    NSString *trimmed = [safe stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"_"]];
    return trimmed.length ? trimmed : @"词库";
}

static NSString *KBActivePath(NSString *keyboard) {
    return [keyboard stringByAppendingPathComponent:@"active"];
}

static NSString *KBReadActiveLibrary(NSString *keyboard) {
    NSString *name = [NSString stringWithContentsOfFile:KBActivePath(keyboard) encoding:NSUTF8StringEncoding error:NULL];
    return [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static void KBWriteActiveLibrary(NSString *keyboard, NSString *name) {
    NSString *path = KBActivePath(keyboard);
    if (name.length) {
        [name writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } else {
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    }
}

// 用保留的 ZIP 重放一份词库：解压 → 转换 → 写 meta.json。
// 三处转换完都要写同一份 meta.json：统计 + 来源 + 时间。
static void KBWriteMeta(NSString *directory, NSString *name, NSString *source) {
    NSUInteger accepted = 0, droppedTraditional = 0, droppedASCII = 0;
    KBGetConvertStats(&accepted, &droppedTraditional, &droppedASCII);
    NSDictionary *meta = @{@"name": name,
                           @"source": source,
                           @"accepted": @(accepted),
                           @"droppedTraditional": @(droppedTraditional),
                           @"droppedASCII": @(droppedASCII),
                           @"droppedRare": @(KBGetDroppedRareCount()),
                           @"excluded": @(KBGetExcludedCount()),
                           @"at": @([[NSDate date] timeIntervalSince1970])};
    [[NSJSONSerialization dataWithJSONObject:meta options:NSJSONWritingPrettyPrinted error:NULL]
        writeToFile:[directory stringByAppendingPathComponent:@"meta.json"] atomically:YES];
}

static BOOL KBRebuildLibrary(NSString *keyboard, NSString *directory, NSDictionary *prefs, NSMutableArray<NSString *> *trace) {
    BOOL commonOnly = prefs[@"commonOnly"] ? [prefs[@"commonOnly"] boolValue] : YES;
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *zipPath = [directory stringByAppendingPathComponent:@"source.zip"];
    if (![manager fileExistsAtPath:zipPath]) return NO;
    for (NSURL *old in [manager contentsOfDirectoryAtURL:[NSURL fileURLWithPath:directory isDirectory:YES]
                             includingPropertiesForKeys:nil options:0 error:NULL]) {
        NSString *name = old.lastPathComponent;
        if ([name isEqualToString:@"source.zip"] || [name isEqualToString:@"exclude.txt"]) continue;
        [manager removeItemAtURL:old error:NULL];
    }
    NSUInteger extracted = KBExtractDictionaryZip(zipPath, directory, ^(NSString *message) {
        os_log(KBInjectorLog, "unzip: %{public}@", message);
    });
    [trace addObject:[NSString stringWithFormat:@"reunzip:%lu", (unsigned long)extracted]];
    if (!extracted) return NO;
    KBSetConvertOptions([prefs[@"includeTraditional"] boolValue], [prefs[@"includeASCII"] boolValue]);
    KBSetCommonOnly(commonOnly);
    KBSetExcludedWords(KBReadExcludedWords(keyboard, directory));
    BOOL ok = KBConvertDictionaries(directory, directory, ^(NSString *message) {
        os_log(KBInjectorLog, "convert: %{public}@", message);
    });
    if (!ok) return NO;
    NSString *previous = [NSString stringWithContentsOfFile:[directory stringByAppendingPathComponent:@"meta.json"]
                                                   encoding:NSUTF8StringEncoding error:NULL];
    NSDictionary *old = previous ? [NSJSONSerialization JSONObjectWithData:[previous dataUsingEncoding:NSUTF8StringEncoding]
                                                                  options:0 error:NULL] : nil;
    NSString *sourceName = [old[@"source"] isKindOfClass:[NSString class]] ? old[@"source"] : @"source.zip";
    KBWriteMeta(directory, directory.lastPathComponent, sourceName);
    for (NSURL *item in [manager contentsOfDirectoryAtURL:[NSURL fileURLWithPath:directory isDirectory:YES]
                            includingPropertiesForKeys:nil options:0 error:NULL]) {
        NSString *name = item.lastPathComponent;
        if ([name isEqualToString:@"source.zip"] || [name isEqualToString:@"exclude.txt"] ||
            [name isEqualToString:@"index26.tsv"] || [name isEqualToString:@"index9.tsv"] ||
            [name isEqualToString:@"meta.json"]) continue;
        [manager removeItemAtURL:item error:NULL];
    }
    return YES;
}

// 没有 source.zip 的旧词库：直接过滤索引，删行不影响排序。
// 排除词先转成 C 字符串；逐行 UTF8String 会生成海量临时对象，进程会被杀掉。
static NSUInteger KBFilterIndexes(NSString *directory, NSSet<NSString *> *words, BOOL *ok) {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSUInteger removed = 0;
    *ok = YES;
    NSUInteger wordCount = words.count;
    char **needles = calloc(wordCount ? wordCount : 1, sizeof(char *));
    size_t *needleLengths = calloc(wordCount ? wordCount : 1, sizeof(size_t));
    NSUInteger needleCount = 0;
    for (NSString *word in words) {
        const char *bytes = word.UTF8String;
        if (!bytes || !*bytes) continue;
        needles[needleCount] = strdup(bytes);
        needleLengths[needleCount] = strlen(bytes);
        needleCount++;
    }
    for (NSString *name in @[@"index26.tsv", @"index9.tsv"]) {
        NSString *path = [directory stringByAppendingPathComponent:name];
        if (![manager fileExistsAtPath:path]) { *ok = NO; continue; }
        NSString *temporary = [path stringByAppendingPathExtension:@"tmp"];
        FILE *input = fopen(path.UTF8String, "r");
        FILE *output = fopen(temporary.UTF8String, "w");
        if (!input || !output) {
            if (input) fclose(input);
            if (output) fclose(output);
            *ok = NO;
            continue;
        }
        char *line = NULL;
        size_t capacity = 0;
        ssize_t length = 0;
        while ((length = getline(&line, &capacity, input)) > 0) {
            BOOL drop = NO;
            char *firstTab = memchr(line, '\t', (size_t)length);
            if (firstTab) {
                char *secondTab = memchr(firstTab + 1, '\t', (size_t)(line + length - firstTab - 1));
                if (secondTab) {
                    size_t wordLength = (size_t)(secondTab - firstTab - 1);
                    const char *wordStart = firstTab + 1;
                    for (NSUInteger i = 0; i < needleCount; i++) {
                        if (needleLengths[i] == wordLength &&
                            memcmp(needles[i], wordStart, wordLength) == 0) {
                            drop = YES;
                            break;
                        }
                    }
                }
            }
            if (drop) { removed++; continue; }
            fwrite(line, 1, (size_t)length, output);
        }
        free(line);
        fclose(input);
        if (fclose(output) != 0 || rename(temporary.UTF8String, path.UTF8String) != 0) {
            [manager removeItemAtPath:temporary error:NULL];
            *ok = NO;
        }
    }
    for (NSUInteger i = 0; i < needleCount; i++) free(needles[i]);
    free(needles);
    free(needleLengths);
    return removed;
}

// 执行面板指令：导入 / 切换 / 删除；面板写时间戳，这里记处理到哪。
// 把 ZIP 装成词库：拷贝 → 解压 → 转换 → 写 meta → 设为当前。
// 面板选文件与从链接下载都走这里，行为保持一致。
static void KBScanLibraries(NSString *keyboard, NSDictionary *prefs, NSMutableDictionary *summary);

static BOOL KBInstallZip(NSString *keyboard, NSString *sourcePath, NSString *displayName,
                         NSDictionary *prefs, NSMutableArray<NSString *> *trace, NSMutableDictionary *summary) {
    BOOL commonOnly = prefs[@"commonOnly"] ? [prefs[@"commonOnly"] boolValue] : YES;
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *libraryName = KBSanitizeLibraryName(displayName.length ? displayName : sourcePath.lastPathComponent);
    NSString *destination = [KBLibrariesDirectory(keyboard) stringByAppendingPathComponent:libraryName];
    NSString *directory = [KBLibrariesDirectory(keyboard) stringByAppendingPathComponent:
        [@".import-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    KBEnsureDirectory(directory);
    NSString *zipPath = [directory stringByAppendingPathComponent:@"source.zip"];
    BOOL copied = [manager copyItemAtPath:sourcePath toPath:zipPath error:NULL];
    [trace addObject:[NSString stringWithFormat:@"take:%@", copied ? @"ok" : @"missing"]];
    if (!copied) {
        [manager removeItemAtPath:directory error:NULL];
        summary[@"ok"] = @NO;
        summary[@"reason"] = @"读不到源文件或存储空间不足";
        summary[@"lib"] = libraryName;
        summary[@"trace"] = trace;
        return NO;
    }
    NSString *oldExclude = [destination stringByAppendingPathComponent:@"exclude.txt"];
    if ([manager fileExistsAtPath:oldExclude] &&
        ![manager copyItemAtPath:oldExclude toPath:[directory stringByAppendingPathComponent:@"exclude.txt"] error:NULL]) {
        [manager removeItemAtPath:directory error:NULL];
        summary[@"ok"] = @NO;
        summary[@"reason"] = @"无法保留排除词条，已取消导入";
        return NO;
    }
    KBTaskPhase(keyboard, @"正在解压词库…");
    NSUInteger extracted = KBExtractDictionaryZip(zipPath, directory, ^(NSString *message) {
        os_log(KBInjectorLog, "unzip: %{public}@", message);
    });
    [trace addObject:[NSString stringWithFormat:@"unzip:%@ files=%lu", extracted ? @"ok" : @"failed",
                      (unsigned long)extracted]];
    if (!extracted) {
        [manager removeItemAtPath:directory error:NULL];
        summary[@"ok"] = @NO;
        summary[@"reason"] = @"不是 ZIP 或里面没有词典";
        summary[@"lib"] = libraryName;
        summary[@"trace"] = trace;
        return NO;
    }
    os_log(KBInjectorLog, "converting %{public}@ (trad=%d ascii=%d)", libraryName,
           [prefs[@"includeTraditional"] boolValue], [prefs[@"includeASCII"] boolValue]);
    KBSetCommonOnly(commonOnly);
    KBSetConvertOptions([prefs[@"includeTraditional"] boolValue], [prefs[@"includeASCII"] boolValue]);
    KBSetExcludedWords(KBReadExcludedWords(keyboard, directory));
    KBTaskPhase(keyboard, @"正在生成索引…");
    BOOL ok = KBConvertDictionaries(directory, directory, ^(NSString *message) {
        os_log(KBInjectorLog, "convert: %{public}@", message);
    });
    if (ok) {
        KBWriteMeta(directory, libraryName, displayName.length ? displayName : sourcePath.lastPathComponent);
        for (NSString *name in @[@"index26.tsv", @"index9.tsv", @"meta.json"]) {
            if ([[manager attributesOfItemAtPath:[directory stringByAppendingPathComponent:name] error:NULL] fileSize] == 0) ok = NO;
        }
    }
    if (ok) {
        KBTaskPhase(keyboard, @"正在保存词库…");
        for (NSURL *item in [manager contentsOfDirectoryAtURL:[NSURL fileURLWithPath:directory isDirectory:YES]
                                includingPropertiesForKeys:nil options:0 error:NULL]) {
            NSString *name = item.lastPathComponent;
            if ([@[@"source.zip", @"exclude.txt", @"index26.tsv", @"index9.tsv", @"meta.json"] containsObject:name]) continue;
            [manager removeItemAtURL:item error:NULL];
        }
        // 同卷原子发布：失败时旧目录保持不动，成功后临时目录里是旧副本。
        BOOL exists = [manager fileExistsAtPath:destination];
        ok = (exists ? renamex_np(directory.fileSystemRepresentation, destination.fileSystemRepresentation, RENAME_SWAP)
                     : rename(directory.fileSystemRepresentation, destination.fileSystemRepresentation)) == 0;
        if (!ok) summary[@"reason"] = @"保存失败，原有词库未改动";
        if (ok) KBWriteActiveLibrary(keyboard, libraryName);
    } else {
        summary[@"reason"] = @"生成索引失败，原有词库未改动";
    }
    [manager removeItemAtPath:directory error:NULL];
    NSUInteger accepted = 0, droppedTraditional = 0, droppedASCII = 0;
    KBGetConvertStats(&accepted, &droppedTraditional, &droppedASCII);
    summary[@"ok"] = @(ok);
    summary[@"accepted"] = @(accepted);
    summary[@"droppedTraditional"] = @(droppedTraditional);
    summary[@"droppedASCII"] = @(droppedASCII);
    summary[@"lib"] = libraryName;
    summary[@"trace"] = trace;
    return ok;
}

static void KBConvertIfNeeded(NSString *keyboard, NSString *incoming) {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *libraries = KBLibrariesDirectory(keyboard);

    NSDictionary *prefs = KBReadPrefs();
    NSMutableDictionary *handled = [KBReadHandled(keyboard) mutableCopy];
    double zipAt = [prefs[@"pendingZipAt"] doubleValue];
    double switchAt = [prefs[@"switchAt"] doubleValue];
    double deleteAt = [prefs[@"deleteAt"] doubleValue];
    NSString *pendingZip = [prefs[@"pendingZipPath"] isKindOfClass:[NSString class]] ? prefs[@"pendingZipPath"] : nil;
    NSString *pendingZipName = [prefs[@"pendingZipName"] isKindOfClass:[NSString class]] ? prefs[@"pendingZipName"] : nil;
    NSString *switchTo = [prefs[@"switchTo"] isKindOfClass:[NSString class]] ? prefs[@"switchTo"] : nil;
    NSString *deleteLib = [prefs[@"deleteLib"] isKindOfClass:[NSString class]] ? prefs[@"deleteLib"] : nil;

    NSMutableArray<NSString *> *trace = [NSMutableArray array];
    NSMutableDictionary *summary = [@{@"requestAt": @([prefs[@"requestStamp"] doubleValue]),
                                      @"at": @([[NSDate date] timeIntervalSince1970])} mutableCopy];

    // 重命名：只改目录名（也就是面板上显示的名字），索引内容不动。
    double renameAt = [prefs[@"renameAt"] doubleValue];
    if (renameAt > [handled[@"renameAt"] doubleValue]) {
        KBTaskBegin(keyboard, summary, renameAt);
        NSString *from = [prefs[@"renameFrom"] isKindOfClass:[NSString class]] ? prefs[@"renameFrom"] : nil;
        NSString *to = [prefs[@"renameTo"] isKindOfClass:[NSString class]] ? prefs[@"renameTo"] : nil;
        NSString *target = KBSanitizeLibraryName(to ?: @"");
        NSString *source = [libraries stringByAppendingPathComponent:from ?: @""];
        NSString *destination = [libraries stringByAppendingPathComponent:target];
        if (from.length && target.length && ![target isEqualToString:from] &&
            [manager fileExistsAtPath:source] && ![manager fileExistsAtPath:destination]) {
            if ([manager moveItemAtPath:source toPath:destination error:NULL]) {
                if ([KBReadActiveLibrary(keyboard) isEqualToString:from]) KBWriteActiveLibrary(keyboard, target);
                summary[@"ok"] = @YES;
                summary[@"renamed"] = target;
            } else {
                summary[@"ok"] = @NO;
                summary[@"reason"] = @"改名失败";
            }
        } else {
            summary[@"ok"] = @NO;
            summary[@"reason"] = [manager fileExistsAtPath:destination] ? @"已有同名词库" : @"改名失败";
        }
        handled[@"renameAt"] = @(renameAt);
        KBWriteHandled(keyboard, handled);
        KBWriteSummary(summary, keyboard);
        return;
    }

    // 排除词条：面板把整份文本交过来，落盘后按它重建这一份词库的索引。
    double excludeAt = [prefs[@"excludeAt"] doubleValue];
    if (excludeAt > [handled[@"excludeAt"] doubleValue]) {
        KBTaskBegin(keyboard, summary, excludeAt);
        NSString *library = [prefs[@"excludeLib"] isKindOfClass:[NSString class]] ? prefs[@"excludeLib"] : nil;
        NSString *text = [prefs[@"excludeText"] isKindOfClass:[NSString class]] ? prefs[@"excludeText"] : @"";
        NSString *directory = library.length ? [libraries stringByAppendingPathComponent:library] : nil;
        NSString *zipPath = [directory stringByAppendingPathComponent:@"source.zip"];
        NSString *indexPath = [directory stringByAppendingPathComponent:@"index26.tsv"];
        if (directory && [manager fileExistsAtPath:indexPath]) {
            [text writeToFile:[directory stringByAppendingPathComponent:@"exclude.txt"]
                   atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            NSSet<NSString *> *words = KBReadExcludedWords(keyboard, directory);
            BOOL ok = NO;
            NSUInteger excluded = 0;
            BOOL filtered = NO;
            if ([manager fileExistsAtPath:zipPath]) {
                ok = KBRebuildLibrary(keyboard, directory, prefs, trace);
                excluded = KBGetExcludedCount();
                NSUInteger accepted = 0, droppedTraditional = 0, droppedASCII = 0;
                KBGetConvertStats(&accepted, &droppedTraditional, &droppedASCII);
                summary[@"accepted"] = @(accepted);
                summary[@"droppedTraditional"] = @(droppedTraditional);
                summary[@"droppedASCII"] = @(droppedASCII);
            } else {
                // 旧版迁移来的词库没有 ZIP：直接从索引里删词。
                excluded = KBFilterIndexes(directory, words, &filtered);
                ok = filtered;
                summary[@"filtered"] = @YES;
                [trace addObject:[NSString stringWithFormat:@"filter:%lu", (unsigned long)excluded]];
            }
            summary[@"ok"] = @(ok);
            summary[@"excluded"] = @(excluded);
            summary[@"lib"] = library;
            summary[@"trace"] = trace;
        } else {
            summary[@"ok"] = @NO;
            summary[@"reason"] = @"词库不存在";
        }
        handled[@"excludeAt"] = @(excludeAt);
        KBWriteHandled(keyboard, handled);
        KBWriteSummary(summary, keyboard);
        return;
    }

    // 自定义词条：面板把整份列表以 JSON 交过来，这里落盘并重建小索引。
    double customAt = [prefs[@"customAt"] doubleValue];
    if (customAt > [handled[@"customAt"] doubleValue]) {
        KBTaskBegin(keyboard, summary, customAt);
        NSString *json = [prefs[@"customJSON"] isKindOfClass:[NSString class]] ? prefs[@"customJSON"] : @"[]";
        [json writeToFile:[keyboard stringByAppendingPathComponent:@"custom.json"]
               atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSUInteger count = KBRebuildCustomIndexes(keyboard, ^(NSString *message) {
            os_log(KBInjectorLog, "custom: %{public}@", message);
        });
        summary[@"ok"] = @YES;
        summary[@"custom"] = @(count);
        handled[@"customAt"] = @(customAt);
        KBWriteHandled(keyboard, handled);
        KBWriteSummary(summary, keyboard);
        return;
    }

    if (deleteAt > [handled[@"deleteAt"] doubleValue] && deleteLib.length) {
        KBTaskBegin(keyboard, summary, deleteAt);
        NSString *directory = [libraries stringByAppendingPathComponent:deleteLib];
        [manager removeItemAtPath:directory error:NULL];
        if ([KBReadActiveLibrary(keyboard) isEqualToString:deleteLib]) KBWriteActiveLibrary(keyboard, nil);
        summary[@"ok"] = @YES;
        summary[@"deleted"] = deleteLib;
        handled[@"deleteAt"] = @(deleteAt);
        KBWriteHandled(keyboard, handled);
        KBWriteSummary(summary, keyboard);
        return;
    }

    // 停用：清空 active，词库文件不动，键盘回到苹果候选。
    double disableAt = [prefs[@"disableAt"] doubleValue];
    if (disableAt > [handled[@"disableAt"] doubleValue]) {
        KBTaskBegin(keyboard, summary, disableAt);
        KBWriteActiveLibrary(keyboard, nil);
        summary[@"ok"] = @YES;
        summary[@"disabled"] = @YES;
        handled[@"disableAt"] = @(disableAt);
        KBWriteHandled(keyboard, handled);
        KBWriteSummary(summary, keyboard);
        return;
    }

    if (switchAt > [handled[@"switchAt"] doubleValue] && switchTo.length) {
        KBTaskBegin(keyboard, summary, switchAt);
        NSString *index = [[libraries stringByAppendingPathComponent:switchTo]
                           stringByAppendingPathComponent:@"index26.tsv"];
        if ([manager fileExistsAtPath:index]) {
            KBWriteActiveLibrary(keyboard, switchTo);
            summary[@"ok"] = @YES;
            summary[@"switched"] = switchTo;
        } else {
            summary[@"ok"] = @NO;
            summary[@"reason"] = @"词库不存在";
        }
        handled[@"switchAt"] = @(switchAt);
        KBWriteHandled(keyboard, handled);
        KBWriteSummary(summary, keyboard);
        return;
    }

    // 改了「保留繁体/英文」开关：按保留的 ZIP 重新解压并转换当前启用的词库。
    double convertAt = [prefs[@"convertRequest"] doubleValue];
    if (convertAt > [handled[@"convertAt"] doubleValue]) {
        KBTaskBegin(keyboard, summary, convertAt);
        KBTaskPhase(keyboard, @"正在重新生成索引…");
        NSString *active = KBReadActiveLibrary(keyboard);
        NSString *directory = active.length ? [libraries stringByAppendingPathComponent:active] : nil;
        NSString *zipPath = directory ? [directory stringByAppendingPathComponent:@"source.zip"] : nil;
        if (zipPath && [manager fileExistsAtPath:zipPath]) {
            BOOL ok = KBRebuildLibrary(keyboard, directory, prefs, trace);
            NSUInteger accepted = 0, droppedTraditional = 0, droppedASCII = 0;
            KBGetConvertStats(&accepted, &droppedTraditional, &droppedASCII);
            summary[@"ok"] = @(ok);
            summary[@"accepted"] = @(accepted);
            summary[@"droppedTraditional"] = @(droppedTraditional);
            summary[@"droppedASCII"] = @(droppedASCII);
            summary[@"excluded"] = @(KBGetExcludedCount());
            summary[@"lib"] = active;
            summary[@"trace"] = trace;
        } else {
            summary[@"ok"] = @NO;
            summary[@"reason"] = @"没有已启用的词库";
        }
        handled[@"convertAt"] = @(convertAt);
        KBWriteHandled(keyboard, handled);
        KBWriteSummary(summary, keyboard);
        return;
    }

    if (zipAt > [handled[@"zipAt"] doubleValue] && pendingZip) {
        KBTaskBegin(keyboard, summary, zipAt);
        handled[@"zipAt"] = @(zipAt);
        KBInstallZip(keyboard, KBRealPath(pendingZip),
                     pendingZipName.length ? pendingZipName : pendingZip.lastPathComponent,
                     prefs, trace, summary);
        KBWriteHandled(keyboard, handled);
        KBWriteSummary(summary, keyboard);
        return;
    }

    // 下拉刷新：扫描用户手动放进 libs/ 的 ZIP 或词典目录。
    double scanAt = [prefs[@"scanAt"] doubleValue];
    if (scanAt > [handled[@"scanAt"] doubleValue]) {
        KBTaskBegin(keyboard, summary, scanAt);
        KBTaskPhase(keyboard, @"正在检查手动放入的文件…");
        handled[@"scanAt"] = @(scanAt);
        KBScanLibraries(keyboard, prefs, summary);
        KBWriteHandled(keyboard, handled);
        KBWriteSummary(summary, keyboard);
        return;
    }

    // 从链接导入：面板给一个 https 地址，这里下载下来再按普通导入装。
    double downloadAt = [prefs[@"downloadAt"] doubleValue];
    if (downloadAt > [handled[@"downloadAt"] doubleValue]) {
        KBTaskBegin(keyboard, summary, downloadAt);
        KBTaskPhase(keyboard, @"正在下载词库…");
        NSString *urlString = [prefs[@"downloadURL"] isKindOfClass:[NSString class]] ? prefs[@"downloadURL"] : nil;
        handled[@"downloadAt"] = @(downloadAt);
        NSURL *url = urlString.length ? [NSURL URLWithString:urlString] : nil;
        if (![url.scheme.lowercaseString isEqualToString:@"https"] || !url.host.length) {
            summary[@"ok"] = @NO;
            summary[@"reason"] = @"链接无效";
        } else {
            NSString *incomingDirectory = [keyboard stringByAppendingPathComponent:@"incoming"];
            [manager createDirectoryAtPath:incomingDirectory withIntermediateDirectories:YES attributes:nil error:NULL];
            NSString *fileName = url.lastPathComponent.length ? url.lastPathComponent : @"download.zip";
            NSString *target = [incomingDirectory stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
            NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
            configuration.timeoutIntervalForRequest = 60;
            configuration.timeoutIntervalForResource = 600;
            NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
            dispatch_semaphore_t finished = dispatch_semaphore_create(0);
            __block BOOL downloaded = NO;
            __block NSString *failure = nil;
            NSURLSessionDownloadTask *task = [session downloadTaskWithURL:url completionHandler:^(NSURL *temporary, NSURLResponse *response, NSError *error) {
                NSInteger status = [(NSHTTPURLResponse *)response statusCode];
                if (error) {
                    failure = error.code == NSURLErrorTimedOut ? @"下载超时，请检查网络后重试" : @"下载失败，请检查链接或网络";
                } else if (status < 200 || status >= 300) {
                    failure = [NSString stringWithFormat:@"服务器返回 HTTP %ld", (long)status];
                } else if (temporary) {
                    downloaded = [manager moveItemAtURL:temporary toURL:[NSURL fileURLWithPath:target] error:NULL];
                    if (!downloaded) failure = @"无法保存下载文件，请检查存储空间";
                }
                dispatch_semaphore_signal(finished);
            }];
            [task resume];
            // 只等待命令队列，注入检查和任务心跳继续运行。
            dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);
            [session finishTasksAndInvalidate];
            if (downloaded) {
                KBInstallZip(keyboard, target, fileName, prefs, trace, summary);
            } else {
                summary[@"ok"] = @NO;
                summary[@"reason"] = failure ?: @"下载内容为空";
            }
            [manager removeItemAtPath:target error:NULL];
        }
        summary[@"trace"] = trace;
        KBWriteHandled(keyboard, handled);
        KBWriteSummary(summary, keyboard);
        return;
    }
}

// 面板的「只用词库候选」开关：写一个小文件给探针读，省得探针去碰偏好域。
static void KBSyncSettings(NSString *keyboard) {
    NSDictionary *prefs = KBReadPrefs();
    // 「只用词库候选」：开着就写个空文件，关掉就删；探针每键读。
    BOOL on = [prefs[@"lexiconOnly"] boolValue];
    NSString *path = [keyboard stringByAppendingPathComponent:@"lexicon-only"];
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
    if (on && !exists) {
        [@"1" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } else if (!on && exists) {
        [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
    }
    // 候选数量：同样写文件。
    NSInteger limit = [prefs[@"candidateLimit"] integerValue];
    if (limit < 1 || limit > 10) limit = 5;
    NSString *limitPath = [keyboard stringByAppendingPathComponent:@"candidate-limit"];
    NSString *text = [NSString stringWithFormat:@"%ld", (long)limit];
    NSString *current = [NSString stringWithContentsOfFile:limitPath encoding:NSUTF8StringEncoding error:NULL];
    if (![text isEqualToString:current ?: @""]) {
        [text writeToFile:limitPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
}

// 手动放进 libs/ 的东西：ZIP 按导入装，带 *.dict.yaml 的目录就地转换。
static void KBScanLibraries(NSString *keyboard, NSDictionary *prefs, NSMutableDictionary *summary) {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *libraries = KBLibrariesDirectory(keyboard);
    NSMutableArray<NSString *> *trace = [NSMutableArray array];
    NSUInteger installed = 0, converted = 0;
    BOOL commonOnly = prefs[@"commonOnly"] ? [prefs[@"commonOnly"] boolValue] : YES;
    for (NSString *name in [manager contentsOfDirectoryAtPath:libraries error:NULL]) {
        if ([name hasPrefix:@"."]) continue;
        NSString *path = [libraries stringByAppendingPathComponent:name];
        BOOL isDirectory = NO;
        [manager fileExistsAtPath:path isDirectory:&isDirectory];
        if (!isDirectory) {
            if ([name.lowercaseString hasSuffix:@".zip"]) {
                if (KBInstallZip(keyboard, path, name, prefs, trace, summary)) {
                    installed++;
                    [manager removeItemAtPath:path error:NULL];
                } else {
                    // 装不进去就改名，免得每次下拉都重试一遍。
                    [manager moveItemAtPath:path toPath:[path stringByAppendingString:@".failed"] error:NULL];
                    [trace addObject:[NSString stringWithFormat:@"failed:%@", name]];
                }
            }
        }
        if ([manager fileExistsAtPath:[path stringByAppendingPathComponent:@"index26.tsv"]]) continue;
        BOOL hasDictionary = NO;
        for (NSString *relative in [manager enumeratorAtPath:path]) {
            if ([relative hasSuffix:@".dict.yaml"]) { hasDictionary = YES; break; }
        }
        if (!hasDictionary) continue;
        [trace addObject:[NSString stringWithFormat:@"convert:%@", name]];
        KBSetConvertOptions([prefs[@"includeTraditional"] boolValue], [prefs[@"includeASCII"] boolValue]);
        KBSetCommonOnly(commonOnly);
        KBSetExcludedWords(KBReadExcludedWords(keyboard, path));
        BOOL ok = KBConvertDictionaries(path, path, ^(NSString *message) {
            os_log(KBInjectorLog, "scan convert: %{public}@", message);
        });
        if (!ok) continue;
        KBWriteMeta(path, name, @"手动放入");
        converted++;
    }
    summary[@"ok"] = @YES;
    summary[@"scanned"] = @YES;
    summary[@"installed"] = @(installed);
    summary[@"converted"] = @(converted);
    summary[@"trace"] = trace;
}

static pid_t KBFindProcess(const char *name) {
    // 1) libproc：某些沙盒里比 sysctl 更宽松。SDK 没有公开头文件，用 dlsym 取。
    int (*listPids)(void *, int) = (int (*)(void *, int))dlsym(RTLD_DEFAULT, "proc_listallpids");
    int (*pidName)(int, void *, int) = (int (*)(int, void *, int))dlsym(RTLD_DEFAULT, "proc_name");
    if (listPids && pidName) {
        int capacity = listPids(NULL, 0);
        if (capacity > 0) {
            pid_t *pids = calloc((size_t)capacity + 32, sizeof(pid_t));
            if (pids) {
                int count = listPids(pids, (int)(((size_t)capacity + 32) * sizeof(pid_t)));
                for (int i = 0; i < count; i++) {
                    char buffer[64] = {0};
                    if (pidName(pids[i], buffer, sizeof(buffer)) > 0 && strcmp(buffer, name) == 0) {
                        pid_t found = pids[i];
                        free(pids);
                        return found;
                    }
                }
                free(pids);
            }
        }
    }

    // 2) launchd
    NSString *label = [NSString stringWithFormat:@"com.apple.TextInput.%s", name];
    for (NSString *tool in @[@"/usr/bin/launchctl", @"/bin/launchctl"]) {
        if (access(tool.UTF8String, X_OK) != 0) continue;
        FILE *pipe = popen(tool.UTF8String, "r");
        if (!pipe) continue;
        char line[512];
        pid_t found = 0;
        while (fgets(line, sizeof(line), pipe)) {
            if (!strstr(line, label.UTF8String)) continue;
            int pid = 0;
            if (sscanf(line, "%d", &pid) == 1 && pid > 0) found = pid;
            break;
        }
        pclose(pipe);
        if (found) return found;
    }
    return 0;
}

// 自己在 <bootstrap>/usr/libexec，往上三层是 bootstrap 根。
static NSString *KBBootstrapRoot(void) {
    char path[PATH_MAX];
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) != 0) return nil;
    NSString *executable = [NSString stringWithUTF8String:path];
    return executable.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
}

// 探针会在 kbd 里写状态；pid 对得上就不用再注入。
static BOOL KBAlreadyInjected(pid_t target) {
    for (NSString *path in @[@"/var/mobile/Library/Keyboard/KeyBridgeProbe-kbd.json",
                             @"/rootfs/private/var/mobile/Library/Keyboard/KeyBridgeProbe-kbd.json"]) {
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data) continue;
        NSDictionary *state = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if ([state isKindOfClass:[NSDictionary class]] && [state[@"pid"] intValue] == target) {
            return YES;
        }
    }
    return NO;
}

static BOOL KBInject(pid_t target, NSString *root) {
    NSString *tool = [root stringByAppendingPathComponent:@"usr/bin/opainject"];
    NSString *dylib = [root stringByAppendingPathComponent:@"Library/MobileSubstrate/DynamicLibraries/KeyBridgeProbe.dylib"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:tool] ||
        ![[NSFileManager defaultManager] fileExistsAtPath:dylib]) {
        os_log_error(KBInjectorLog, "missing tool or dylib under %{public}@", root);
        return NO;
    }
    char pidText[16];
    snprintf(pidText, sizeof(pidText), "%d", target);
    char *argv[] = {(char *)tool.UTF8String, pidText, (char *)dylib.UTF8String, NULL};
    pid_t child = 0;
    int status = posix_spawn(&child, argv[0], NULL, NULL, argv, environ);
    if (status != 0) {
        os_log_error(KBInjectorLog, "posix_spawn failed (%d)", status);
        return NO;
    }
    waitpid(child, &status, 0);
    BOOL ok = WIFEXITED(status) && WEXITSTATUS(status) == 0;
    os_log(KBInjectorLog, "inject pid=%d %{public}s", target, ok ? "ok" : "failed");
    return ok;
}

int main(void) {
    @autoreleasepool {
        KBInjectorLog = os_log_create("com.wm0104.keybridge.injector", "injector");
        NSString *root = KBBootstrapRoot();
        KBStatePath = KBRealPath(@"/var/mobile/Library/Keyboard/KeyBridgeInjector.json");
        KBWriteState(@{@"started": @YES, @"root": root ?: @"?", @"pid": @(getpid()),
                       @"at": @([[NSDate date] timeIntervalSince1970])});
        os_log(KBInjectorLog, "started root=%{public}@", root ?: @"?");
        if (!root.length) return 1;

        NSString *keyboard = KBRealPath(@"/var/mobile/Library/Keyboard/KeyBridge");
        // 旧布局（索引直接在 KeyBridge 下）迁移成一份词库，避免升级后候选突然没了。
        NSString *legacyIndex = [keyboard stringByAppendingPathComponent:@"index26.tsv"];
        NSString *activeName = KBReadActiveLibrary(keyboard);
        if (!activeName.length && [[NSFileManager defaultManager] fileExistsAtPath:legacyIndex]) {
            NSString *legacyDirectory = [KBLibrariesDirectory(keyboard) stringByAppendingPathComponent:@"已导入"];
            [[NSFileManager defaultManager] createDirectoryAtPath:legacyDirectory
                                      withIntermediateDirectories:YES attributes:nil error:NULL];
            for (NSString *name in @[@"index26.tsv", @"index9.tsv"]) {
                NSString *from = [keyboard stringByAppendingPathComponent:name];
                NSString *to = [legacyDirectory stringByAppendingPathComponent:name];
                [[NSFileManager defaultManager] removeItemAtPath:to error:NULL];
                [[NSFileManager defaultManager] moveItemAtPath:from toPath:to error:NULL];
            }
            os_log(KBInjectorLog, "migrated legacy indexes");
        }
        // 自愈：只有一份词库却没有 active，就把它设为当前启用。
        if (!KBReadActiveLibrary(keyboard).length) {
            NSArray<NSString *> *entries = [[NSFileManager defaultManager]
                contentsOfDirectoryAtPath:KBLibrariesDirectory(keyboard) error:NULL];
            NSMutableArray<NSString *> *libraries = [NSMutableArray array];
            for (NSString *name in entries) {
                if ([name hasPrefix:@"."]) continue;
                NSString *index = [[KBLibrariesDirectory(keyboard) stringByAppendingPathComponent:name]
                                   stringByAppendingPathComponent:@"index26.tsv"];
                if ([[NSFileManager defaultManager] fileExistsAtPath:index]) [libraries addObject:name];
            }
            if (libraries.count == 1) {
                KBWriteActiveLibrary(keyboard, libraries.firstObject);
                os_log(KBInjectorLog, "recovered active library %{public}@", libraries.firstObject);
            }
        }
        // 卸载会连目录一起删掉；启动时补回来，否则回执和索引都没地方写。
        KBEnsureDirectory(keyboard);
        KBEnsureDirectory(KBLibrariesDirectory(keyboard));
        NSString *incoming = [keyboard stringByAppendingPathComponent:@"incoming"];
        KBSetupDebugLog(keyboard);
        KBCommandQueue = dispatch_queue_create("com.wm0104.keybridge.commands", DISPATCH_QUEUE_SERIAL);
        // 放一个 .rebuild 文件就能让它立刻按现有 ZIP 重转一次，方便排查。
        NSString *rebuildMarker = [keyboard stringByAppendingPathComponent:@".rebuild"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:rebuildMarker]) {
            NSString *requested = [NSString stringWithContentsOfFile:rebuildMarker encoding:NSUTF8StringEncoding error:NULL];
            requested = [requested stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSString *activeName = requested.length ? requested : KBReadActiveLibrary(keyboard);
            NSString *directory = activeName.length ? [KBLibrariesDirectory(keyboard) stringByAppendingPathComponent:activeName] : nil;
            if (directory) {
            [[NSFileManager defaultManager] removeItemAtPath:rebuildMarker error:NULL];
                NSMutableArray<NSString *> *trace = [NSMutableArray array];
                BOOL ok = KBRebuildLibrary(keyboard, directory, KBReadPrefs(), trace);
                os_log(KBInjectorLog, "marker rebuild %{public}@ ok=%d %{public}@", activeName, ok, trace);
            }
        }
        pid_t injected = 0;
        int attempts = 0;
        for (;;) {
            @autoreleasepool {
                BOOL startCommand = NO;
                @synchronized ([NSProcessInfo class]) {
                    KBTaskWrite(keyboard);
                    if (!KBCommandRunning) {
                        KBCommandRunning = YES;
                        startCommand = YES;
                    }
                }
                if (startCommand) {
                    dispatch_async(KBCommandQueue, ^{
                        @autoreleasepool {
                            KBConvertIfNeeded(keyboard, incoming);
                            @synchronized ([NSProcessInfo class]) { KBCommandRunning = NO; }
                        }
                    });
                }
                KBSyncSettings(keyboard);
                pid_t kbd = KBFindProcess("kbd");
                NSMutableDictionary *state = [@{
                    @"pidSeen": @(kbd),
                    @"injected": @(injected),
                    @"attempts": @(attempts),
                    @"updatedAt": @([[NSDate date] timeIntervalSince1970])
                } mutableCopy];
                if (kbd <= 0) {
                    injected = 0;
                    attempts = 0;
                } else if (kbd != injected) {
                    if (KBAlreadyInjected(kbd)) {
                        os_log(KBInjectorLog, "kbd pid=%d already injected", kbd);
                        state[@"lastInject"] = @"already";
                        injected = kbd;
                        attempts = 0;
                    } else {
                        if (attempts == 0) os_log(KBInjectorLog, "kbd appeared pid=%d", kbd);
                        BOOL ok = KBInject(kbd, root);
                        state[@"lastInject"] = ok ? @"ok" : @"failed";
                        if (ok || ++attempts >= 3) {
                            injected = kbd;
                            attempts = 0;
                        }
                    }
                }
                KBWriteState(state);
                os_log(KBInjectorLog, "loop kbd=%d injected=%d attempts=%d in=%d idx=%d last=%{public}@",
                       kbd, injected, attempts,
                       [[NSFileManager defaultManager] fileExistsAtPath:incoming] ? 1 : 0,
                       [[NSFileManager defaultManager] fileExistsAtPath:[keyboard stringByAppendingPathComponent:@"index26.tsv"]] ? 1 : 0,
                       state[@"lastInject"] ?: @"-");
            }
            sleep(2);
        }
    }
}
