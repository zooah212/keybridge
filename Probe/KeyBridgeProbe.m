// KeyBridge 探针：把自建词库的候选插进苹果拼音的候选列表。
// 入口：TIKeyboardInputManagerChinese -candidateResultSetFromCandidates:proactiveTriggers:
// 索引：libs/<当前启用>/index26.tsv（全拼）、index9.tsv（九宫格），由守护进程生成。

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <dispatch/dispatch.h>
#import "../Injector/KBCustomEntries.h"
#import "KBCandidateTrace.h"
#import "KBExclusions.h"
#import "../ImportPreferences/KBSettingsModel.h"
#include <stdarg.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef APELIN_BUILD_ID
#define APELIN_BUILD_ID "unknown"
#endif

#include <dlfcn.h>
static os_log_t KBLog;
static void KBStatusSet(NSString *key, id value);

static uint64_t KBNowNs(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}



// ellekit 不一定在 kbd 里：自己 dlopen，再 dlsym 取 MSHookMessageEx。
static void (*KBHookMessage)(Class, SEL, IMP, IMP *);

static NSString *KBJBRoot(void) {
    Dl_info info;
    if (dladdr((void *)&KBHookMessage, &info) == 0 || !info.dli_fname) return nil;
    NSString *path = [NSString stringWithUTF8String:info.dli_fname];
    // dylib 往上四层就是 jbroot
    NSString *root = path;
    for (int i = 0; i < 4; i++) root = [root stringByDeletingLastPathComponent];
    return root;
}

static BOOL KBLoadSubstrate(void) {
    if (KBHookMessage) return YES;
    NSString *root = KBJBRoot();
    NSArray<NSString *> *candidates = @[
        root ? [root stringByAppendingPathComponent:@"usr/lib/libellekit.dylib"] : @"/usr/lib/libellekit.dylib",
        root ? [root stringByAppendingPathComponent:@"usr/lib/libsubstrate.dylib"] : @"/usr/lib/libsubstrate.dylib",
        @"/usr/lib/libellekit.dylib",
        @"/usr/lib/libsubstrate.dylib"];
    NSMutableString *trace = [NSMutableString stringWithFormat:@"root=%@", root ?: @"nil"];
    for (NSString *path in candidates) {
        void *handle = dlopen(path.UTF8String, RTLD_NOW);
        if (!handle) {
            [trace appendFormat:@" | %@: %s", path.lastPathComponent, dlerror() ?: "?"];
            continue;
        }
        KBHookMessage = (void (*)(Class, SEL, IMP, IMP *))dlsym(handle, "MSHookMessageEx");
        if (KBHookMessage) {
            os_log(KBLog, "substrate loaded from %{public}@", path);
            KBStatusSet(@"substrate", path.lastPathComponent);
            return YES;
        }
        [trace appendFormat:@" | %@: no symbol", path.lastPathComponent];
    }
    os_log_error(KBLog, "substrate unavailable");
    KBStatusSet(@"substrate", trace);
    return NO;
}


static char KBLastInput[64];
static BOOL KBHooksInstalled;
static BOOL KBLoggedCandidateShape;

static IMP KBOrigHandleInput;
static IMP KBOrigFound;
static IMP KBOrigCandidates;
static IMP KBOrigResults;
static IMP KBOrigFromCandidates;

static NSMutableDictionary *KBStatus;
static dispatch_queue_t KBStatusQueue;
static char KBDiscovery[2048];

#pragma mark - 状态文件

// 状态队列内合并写入，持续输入时最多每 0.5 秒落盘一次。
static uint64_t KBLastStatusFlush;
static BOOL KBStatusFlushPending;

static void KBFlushStatusNow(void) {
    @autoreleasepool {
        NSString *name = [NSString stringWithFormat:@"KeyBridgeProbe-%@.json", NSProcessInfo.processInfo.processName ?: @"unknown"];
        NSString *path = [@"/var/mobile/Library/Keyboard" stringByAppendingPathComponent:name];
        KBLastStatusFlush = KBNowNs();
        KBStatus[@"updatedAt"] = @([NSDate date].timeIntervalSince1970);
        KBStatus[@"statusWriteCount"] = @([KBStatus[@"statusWriteCount"] unsignedIntegerValue] + 1);
        NSData *data = [NSJSONSerialization dataWithJSONObject:KBStatus
                                                       options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                         error:NULL];
        [data writeToFile:path atomically:YES];
    }
}

static void KBFlushStatus(void) {
    if (KBStatusFlushPending) return;
    const uint64_t interval = NSEC_PER_SEC / 2;
    uint64_t elapsed = KBNowNs() - KBLastStatusFlush;
    if (!KBLastStatusFlush || elapsed >= interval) {
        KBFlushStatusNow();
        return;
    }
    KBStatusFlushPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval - elapsed)), KBStatusQueue, ^{
        KBStatusFlushPending = NO;
        KBFlushStatusNow();
    });
}

static void KBStatusInit(void) {
    KBStatusQueue = dispatch_queue_create("com.wm0104.keybridge.probe.status", DISPATCH_QUEUE_SERIAL);
    KBStatus = [@{@"pid": @(getpid()),
                  @"process": NSProcessInfo.processInfo.processName ?: @"?",
                  @"loaded": @YES,
                  @"buildID": @APELIN_BUILD_ID,
                  @"hooks": [NSMutableDictionary dictionary],
                  @"counts": [NSMutableDictionary dictionary]} mutableCopy];
}

static void KBStatusSet(NSString *key, id value) {
    dispatch_async(KBStatusQueue, ^{
        if ([value isKindOfClass:[NSNull class]]) {
            [KBStatus removeObjectForKey:key];
        } else {
            KBStatus[key] = value;
        }
        KBFlushStatus();
    });
}

// 一次按键的几个字段合并成一次写入。
static void KBStatusMerge(NSDictionary *values) {
    if (!values.count) return;
    dispatch_async(KBStatusQueue, ^{
        [KBStatus addEntriesFromDictionary:values];
        KBFlushStatus();
    });
}

// 查询耗时：只更新内存里的统计，跟下一次落盘一起写出去。
static void KBPerfRecord(double lookupMs, double hookMs, NSUInteger lines, NSString *input) {
    dispatch_async(KBStatusQueue, ^{
        NSMutableDictionary *perf = KBStatus[@"perf"];
        if (![perf isKindOfClass:[NSMutableDictionary class]]) {
            perf = [NSMutableDictionary dictionary];
            KBStatus[@"perf"] = perf;
        }
        NSNumber *maximum = perf[@"maxLookupMs"];
        if (!maximum || lookupMs > maximum.doubleValue) {
            perf[@"maxLookupMs"] = @(lookupMs);
            perf[@"maxLookupInput"] = input ?: @"-";
        }
        perf[@"lastLookupMs"] = @(lookupMs);
        perf[@"lastHookMs"] = @(hookMs);
        perf[@"maxHookMs"] = @(MAX([perf[@"maxHookMs"] doubleValue], hookMs));
        perf[@"lastLines"] = @(lines);
        NSUInteger calls = [perf[@"calls"] unsignedIntegerValue] + 1;
        double total = [perf[@"totalLookupMs"] doubleValue] + lookupMs;
        perf[@"calls"] = @(calls);
        perf[@"totalLookupMs"] = @(total);
        perf[@"meanLookupMs"] = @(total / calls);
        if (hookMs > 8) perf[@"hookOver8ms"] = @([perf[@"hookOver8ms"] unsignedIntegerValue] + 1);
    });
}

static void KBStatusBump(NSString *key) {
    dispatch_async(KBStatusQueue, ^{
        NSMutableDictionary *counts = KBStatus[@"counts"];
        counts[key] = @([counts[key] unsignedIntegerValue] + 1);
        KBStatus[@"lastInput"] = [NSString stringWithUTF8String:KBLastInput];
        KBFlushStatus();
    });
}

static volatile int KBHeartbeatTicks;
static volatile int KBHookFlags;
static volatile int KBCandidateCalls;
static volatile int KBFoundCalls;
static volatile int KBInputCalls;

static void KBStartHeartbeat(void) {
    // 加载后每 2 秒打一行，持续一分钟：状态文件写不进去时靠它证明"进来了没有"。
    dispatch_queue_t queue = dispatch_queue_create("com.wm0104.keybridge.probe.hb", DISPATCH_QUEUE_SERIAL);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
    dispatch_source_set_event_handler(timer, ^{
        if (KBHeartbeatTicks >= 300) {
            dispatch_source_cancel(timer);
            return;
        }
        KBHeartbeatTicks++;
        os_log(KBLog, "hb tick=%d pid=%d hooks=%d input=%d cand=%d found=%d last=%{public}s",
               KBHeartbeatTicks, getpid(), KBHookFlags, KBInputCalls, KBCandidateCalls, KBFoundCalls, KBLastInput);
        if (KBHeartbeatTicks % 5 == 1 && KBDiscovery[0]) {
            os_log(KBLog, "discovery:\n%{public}s", KBDiscovery);
        }
    });
    dispatch_resume(timer);
}

#pragma mark - 工具

static const char *KBSafeName(id object) {
    if (!object) return "nil";
    const char *name = class_getName([object class]);
    return name ? name : "unknown";
}

// 从 UIKeyboardInput / TIKeyboardInput 之类的对象里取用户当前打的字符串。
static NSString *KBStringFromInput(id object) {
    if (!object) return nil;
    for (NSString *key in @[@"string", @"inputString", @"text"]) {
        SEL sel = NSSelectorFromString(key);
        if (![object respondsToSelector:sel]) continue;
        @try {
            id value = ((id (*)(id, SEL))objc_msgSend)(object, sel);
            if ([value isKindOfClass:[NSString class]]) return value;
        } @catch (__unused NSException *exception) {
        }
    }
    return nil;
}

// 从输入管理器自身取"当前"输入串；KBLastInput 只是兜底，它会在退格后过期。
static NSString *KBCurrentInput(id manager) {
    for (NSString *key in @[@"inputString", @"string", @"input", @"rawInputString"]) {
        SEL sel = NSSelectorFromString(key);
        if (![manager respondsToSelector:sel]) continue;
        @try {
            id value = ((id (*)(id, SEL))objc_msgSend)(manager, sel);
            if ([value isKindOfClass:[NSString class]]) return value;
        } @catch (__unused NSException *exception) {
        }
    }
    return nil;
}

// A known empty composition must not reuse the last key: Apple owns next-word predictions.
static NSString *KBInputForCandidateLookup(id manager) {
    NSString *current = KBCurrentInput(manager);
    return current ?: [NSString stringWithUTF8String:KBLastInput];
}

// 索引在 libs/<当前启用>/，每行 key<TAB>词<TAB>词频，按 key 排序。
static NSString *const KBKeyboardDirectory = @"/var/mobile/Library/Keyboard/KeyBridge";

// 自定义词条的两份小索引，优先于词库查询。
static NSString *KBCustomPath(NSString *fileName) {
    return KBCustomFilePath(KBKeyboardDirectory, fileName);
}

// active 文件写当前词库名；切换/改名很少，按 mtime 缓存，别每键读文件。
static NSTimeInterval KBPathModificationTime(NSString *path);

static NSString *KBActiveLibraryName(void) {
    static NSString *cached;
    static struct stat previous;
    static BOOL hasPrevious;
    NSString *path = [KBKeyboardDirectory stringByAppendingPathComponent:@"active"];
    struct stat info;
    if (stat(path.fileSystemRepresentation, &info) != 0) {
        cached = nil;
        hasPrevious = NO;
        return nil;
    }
    if (!hasPrevious || info.st_ino != previous.st_ino || info.st_size != previous.st_size ||
        info.st_mtimespec.tv_sec != previous.st_mtimespec.tv_sec ||
        info.st_mtimespec.tv_nsec != previous.st_mtimespec.tv_nsec) {
        NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
        text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        cached = text.length ? [text copy] : nil;
        previous = info;
        hasPrevious = YES;
    }
    return cached;
}

static NSString *KBIndexPath(NSString *fileName) {
    NSString *active = KBActiveLibraryName();
    if (active.length) {
        return [[[KBKeyboardDirectory stringByAppendingPathComponent:@"libs"]
                 stringByAppendingPathComponent:active] stringByAppendingPathComponent:fileName];
    }
    return KBCustomFilePath(KBKeyboardDirectory, fileName);
}

typedef struct {
    int fd;
    const char *base;
    size_t size;
    time_t mtime;
    ino_t inode;
    uint64_t generation; // 每个映射独立失效；基准关闭自己的 mmap 不影响按键缓存。
} KBIndex;

static KBIndex KBIndex26 = {-1, NULL, 0, 0};
static KBIndex KBIndex9 = {-1, NULL, 0, 0};
static KBIndex KBCustom26 = {-1, NULL, 0, 0};
static KBIndex KBCustom9 = {-1, NULL, 0, 0};

static void KBIndexClose(KBIndex *index) {
    if (index->base || index->fd >= 0) index->generation++;
    if (index->base) munmap((void *)index->base, index->size);
    if (index->fd >= 0) close(index->fd);
    index->fd = -1;
    index->base = NULL;
    index->size = 0;
    index->mtime = 0;
    index->inode = 0;
}

static void KBIndexPrepare(KBIndex *index, NSString *path) {
    struct stat info;
    if (stat(path.UTF8String, &info) != 0) {
        KBIndexClose(index);
        return;
    }
    // 重建是 .tmp + 改名，mtime 只到秒：还要比 inode 和大小。
    if (index->base && info.st_mtime == index->mtime && info.st_ino == index->inode &&
        (size_t)info.st_size == index->size) return;
    KBIndexClose(index);
    int fd = open(path.UTF8String, O_RDONLY);
    if (fd < 0) return;
    // open 后再取大小，避免原子替换时拿旧文件大小去映射新文件。
    if (fstat(fd, &info) != 0 || info.st_size <= 0) { close(fd); return; }
    void *base = mmap(NULL, (size_t)info.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (base == MAP_FAILED) { close(fd); return; }
    index->fd = fd;
    index->base = base;
    index->size = (size_t)info.st_size;
    index->mtime = info.st_mtime;
    index->inode = info.st_ino;
    index->generation++;
    os_log(KBLog, "index mapped %{public}@ size=%zu", path.lastPathComponent, index->size);
}

// 索引文件只在词库切换或重建时变：按键时只做 stat + 重映射检查。
static void KBPrepareIndexes(void) {
    NSString *active = KBActiveLibraryName();
    NSString *base = active.length ? [[KBKeyboardDirectory stringByAppendingPathComponent:@"libs"]
                                      stringByAppendingPathComponent:active] : KBKeyboardDirectory;
    KBIndexPrepare(&KBIndex26, [base stringByAppendingPathComponent:@"index26.tsv"]);
    KBIndexPrepare(&KBIndex9, [base stringByAppendingPathComponent:@"index9.tsv"]);
    KBIndexPrepare(&KBCustom26, KBCustomPath(@"custom26.tsv"));
    KBIndexPrepare(&KBCustom9, KBCustomPath(@"custom9.tsv"));
}

// 从 offset 开始找到下一行的起点（含），返回行首下标；越界返回 size。
static size_t KBLineStart(KBIndex *index, size_t offset) {
    if (offset >= index->size) return index->size;
    const char *newline = memchr(index->base + offset, '\n', index->size - offset);
    return newline ? (size_t)(newline - index->base) + 1 : index->size;
}

// 比较行首 key 与目标 key；行内 key 以 '\t' 结尾。
static int KBCompareAt(KBIndex *index, size_t lineStart, const char *key, size_t keyLength) {
    const char *line = index->base + lineStart;
    const char *end = index->base + index->size;
    size_t i = 0;
    while (line + i < end && line[i] != '\t' && line[i] != '\n') {
        if (i >= keyLength) return 1; // 行 key 更长
        int order = (unsigned char)line[i] - (unsigned char)key[i];
        if (order != 0) return order;
        i++;
    }
    if (i < keyLength) return -1; // 行 key 是目标的前缀
    return 0;
}

// 找到 offset 所在行的行首。
static size_t KBLineStartBefore(KBIndex *index, size_t offset) {
    if (offset == 0) return 0;
    if (offset > index->size) offset = index->size;
    const char *p = index->base + offset;
    while (p > index->base && p[-1] != '\n') p--;
    return (size_t)(p - index->base);
}

// 二分找到第一个 >= key 的行首。
static size_t KBLowerBound(KBIndex *index, const char *key, size_t keyLength) {
    size_t lo = 0, hi = index->size, found = index->size;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        size_t lineStart = KBLineStartBefore(index, mid);
        int order = KBCompareAt(index, lineStart, key, keyLength);
        if (order < 0) {
            size_t next = KBLineStart(index, lineStart);
            if (next <= lineStart) break;
            lo = next;
        } else {
            found = lineStart;
            if (lineStart == 0) break;
            hi = lineStart;
        }
    }
    return found;
}

#if KB_LOOKUP_BENCHMARK
@interface KBLexEntry : NSObject
@property (nonatomic, copy) NSString *word;
@property (nonatomic) NSInteger weight;
@end

@implementation KBLexEntry
@end

static _Atomic(BOOL) KBOptimizedLookupVerified;
static void KBStartBench(NSString *directory);
#endif

// 排除词：KeyBridge/exclude.txt 与当前词库的 exclude.txt，按 mtime 缓存。
static NSSet<NSString *> *KBExcludedWords;      // 一律不显示
static NSSet<NSString *> *KBExcludedInitials;   // 只在简拼输入时不显示（行尾带 @简）
static NSArray *KBExcludedIdentity;

static NSTimeInterval KBPathModificationTime(NSString *path) {
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    return [attributes[NSFileModificationDate] timeIntervalSince1970];
}

static void KBLoadExcludedWords(void) {
    if (!KBKeyboardDirectory) return;
    // 排除词很少改：最多两秒检查一次，别让每个候选都去 stat 文件。
    static NSTimeInterval checkedAt;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (now - checkedAt < 2.0) return;
    checkedAt = now;
    NSString *globalPath = [KBKeyboardDirectory stringByAppendingPathComponent:@"exclude.txt"];
    NSString *ownPath = KBIndexPath(@"exclude.txt");
    if (!KBRefreshExclusions(@[globalPath, ownPath], &KBExcludedIdentity, &KBExcludedWords, &KBExcludedInitials)) return;
    os_log(KBLog, "excluded words loaded: %lu (+%lu initials only)",
           (unsigned long)KBExcludedWords.count, (unsigned long)KBExcludedInitials.count);
}

// 候选数量：KeyBridge/candidate-limit 里写着面板选的值，缺省 5。
static NSUInteger KBCandidateLimit(void) {
    static NSUInteger cached = 5;
    static NSTimeInterval stamp = -1;
    NSString *path = [KBKeyboardDirectory stringByAppendingPathComponent:@"candidate-limit"];
    NSTimeInterval modified = KBPathModificationTime(path);
    if (modified != stamp) {
        stamp = modified;
        NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
        NSInteger value = text.integerValue;
        cached = (NSUInteger)KBValidatedCandidateLimit(value);
    }
    return cached;
}

// Independent of active library selection. Missing settings preserve the old enabled default.
static BOOL KBLocalCandidatesEnabled(void) {
    static NSObject *lock;
    static dispatch_once_t once;
    static BOOL cached = YES, hasPrevious;
    static struct stat previous;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    @synchronized (lock) {
        NSString *path = [KBKeyboardDirectory stringByAppendingPathComponent:@"local-enabled"];
        struct stat info;
        if (stat(path.fileSystemRepresentation, &info) != 0) {
            hasPrevious = NO;
            return cached = YES;
        }
        if (!hasPrevious || info.st_ino != previous.st_ino || info.st_size != previous.st_size ||
            info.st_mtimespec.tv_sec != previous.st_mtimespec.tv_sec ||
            info.st_mtimespec.tv_nsec != previous.st_mtimespec.tv_nsec) {
            NSString *text = info.st_size > 0 && info.st_size <= 8
                ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL] : nil;
            text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            cached = ![text isEqualToString:@"0"];
            previous = info;
            hasPrevious = YES;
        }
        return cached;
    }
}

// 「只用词库候选」：KeyBridge/lexicon-only 存在就只给词库的词，否则苹果候选接在后面。
static BOOL KBLexiconOnly;
static NSTimeInterval KBLexiconOnlyStamp = -1;

static BOOL KBLexiconOnlyEnabled(void) {
    NSString *path = [KBKeyboardDirectory stringByAppendingPathComponent:@"lexicon-only"];
    NSTimeInterval stamp = KBPathModificationTime(path);
    if (stamp != KBLexiconOnlyStamp) {
        KBLexiconOnlyStamp = stamp;
        KBLexiconOnly = [[NSFileManager defaultManager] fileExistsAtPath:path];
    }
    return KBLexiconOnly;
}
// 输入像不像首字母简拼：没有元音就是。sjb → 简拼，shuangjianbao → 完整拼音。
static NSString *KBFlattenInput(NSString *input);
static BOOL KBInputLooksLikeInitials(NSString *input) {
    NSString *flat = [KBFlattenInput(input) lowercaseString];
    if (!flat.length) return NO;
    for (NSUInteger i = 0; i < flat.length; i++) {
        unichar c = [flat characterAtIndex:i];
        if (c == 'a' || c == 'e' || c == 'i' || c == 'o' || c == 'u' || c == 'v') return NO;
    }
    return YES;
}

static NSString *KBFlattenInput(NSString *input) {
    NSCharacterSet *drop = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSMutableString *flat = [NSMutableString stringWithCapacity:input.length];
    for (NSUInteger i = 0; i < input.length; i++) {
        unichar c = [input characterAtIndex:i];
        if (c == '\'' || [drop characterIsMember:c]) continue;
        [flat appendFormat:@"%C", c];
    }
    return [flat lowercaseString];
}

typedef struct {
    const char *bytes;
    uint32_t length;
    int64_t weight;
} KBLexRow;

static BOOL KBRowsSameWord(KBLexRow a, KBLexRow b) {
    return a.length == b.length && memcmp(a.bytes, b.bytes, a.length) == 0;
}

static int KBRowCompare(const void *left, const void *right) {
    const KBLexRow *a = left;
    const KBLexRow *b = right;
    if (a->weight != b->weight) return a->weight > b->weight ? -1 : 1;
    if (KBRowsSameWord(*a, *b)) return 0;
    // 同权重沿用旧实现的 NSString 排序，包括补充平面字符。
    NSString *wordA = [[NSString alloc] initWithBytes:a->bytes length:a->length encoding:NSUTF8StringEncoding];
    NSString *wordB = [[NSString alloc] initWithBytes:b->bytes length:b->length encoding:NSUTF8StringEncoding];
    return (int)[wordA compare:wordB];
}

// 始终保存前 capacity 个不同的词；同词只保留最高分，不靠额外名额猜重复数。
static void KBInsertRow(KBLexRow *rows, size_t *count, size_t capacity, KBLexRow row) {
    if (*count == capacity && KBRowCompare(&row, &rows[capacity - 1]) >= 0) return;
    for (size_t i = 0; i < *count; i++) {
        if (!KBRowsSameWord(row, rows[i])) continue;
        if (KBRowCompare(&row, &rows[i]) >= 0) return;
        memmove(rows + i, rows + i + 1, (*count - i - 1) * sizeof(*rows));
        (*count)--;
        break;
    }
    size_t position = *count;
    if (position == capacity) position--;
    else (*count)++;
    while (position > 0 && KBRowCompare(&row, &rows[position - 1]) < 0) {
        rows[position] = rows[position - 1];
        position--;
    }
    rows[position] = row;
}

// 扫描范围和分数沿用原实现，只为前 limit 个不同的词保留行指针。
static NSArray<NSString *> *KBCollect(KBIndex *index, const char *target, size_t length, NSUInteger limit,
                                      NSUInteger *scannedOut) {
    if (!index->base || !index->size || !length || !limit) return @[];
    size_t cursor = KBLowerBound(index, target, length);
    // 允许多长的 key：至少多 4 个字母，长输入再按 1.5 倍放宽。
    size_t allowance = length + 4;
    if (length + length / 2 > allowance) allowance = length + length / 2;

    size_t capacity = limit;
    KBLexRow *rows = calloc(capacity, sizeof(KBLexRow));
    if (!rows) return @[];
    size_t count = 0;
    NSUInteger scanned = 0;
    while (cursor < index->size && scanned < 400000) {
        scanned++;
        const char *line = index->base + cursor;
        const char *end = index->base + index->size;
        const char *tab = memchr(line, '\t', (size_t)(end - line));
        if (!tab) break;
        size_t keyLength = (size_t)(tab - line);
        if (keyLength < length || strncmp(line, target, length) != 0) break;
        const char *newline = memchr(tab, '\n', (size_t)(end - tab));
        const char *next = newline ? newline + 1 : end;
        if (keyLength <= allowance) {
            const char *wordStart = tab + 1;
            const char *wordEnd = memchr(wordStart, '\t', (size_t)(next - wordStart));
            if (wordEnd) {
                KBLexRow row;
                row.bytes = wordStart;
                row.length = (uint32_t)(wordEnd - wordStart);
                char weightText[64];
                size_t weightLength = MIN((size_t)((newline ?: end) - wordEnd - 1), sizeof(weightText) - 1);
                memcpy(weightText, wordEnd + 1, weightLength);
                weightText[weightLength] = '\0';
                // 保留原有的精确匹配加分，不改变候选规则。
                row.weight = strtoll(weightText, NULL, 10) + (keyLength == length ? 1000000 : 0);
                if (row.length) KBInsertRow(rows, &count, capacity, row);
            }
        }
        if (!newline) break;
        cursor = (size_t)(next - index->base);
    }
    NSMutableArray<NSString *> *words = [NSMutableArray arrayWithCapacity:count];
    for (size_t i = 0; i < count; i++) {
        NSString *word = [[NSString alloc] initWithBytes:rows[i].bytes length:rows[i].length encoding:NSUTF8StringEncoding];
        if (word.length) [words addObject:word];
    }
    free(rows);
    if (scannedOut) *scannedOut += scanned;
    return words;
}

#if KB_LOOKUP_BENCHMARK
// 基线保留原算法，供诊断构建对照，不进入发布包。
static NSArray<NSString *> *KBLegacyCollect(KBIndex *index, const char *target, size_t length, NSUInteger limit,
                                            NSUInteger *scannedOut) {
    size_t cursor = KBLowerBound(index, target, length);
    __unused BOOL hasExact = NO;
    for (size_t probe = cursor; probe < index->size; ) {
        const char *line = index->base + probe;
        const char *end = index->base + index->size;
        const char *tab = memchr(line, '\t', (size_t)(end - line));
        if (!tab) break;
        size_t keyLength = (size_t)(tab - line);
        if (keyLength < length || strncmp(line, target, length) != 0) break;
        if (keyLength == length) { hasExact = YES; break; }
        const char *newline = memchr(tab, '\n', (size_t)(end - tab));
        if (!newline) break;
        probe = (size_t)(newline - index->base) + 1;
    }
    NSMutableArray<KBLexEntry *> *entries = [NSMutableArray array];
    size_t allowance = length + 4;
    if (length + length / 2 > allowance) allowance = length + length / 2;
    NSUInteger scanned = 0;
    while (cursor < index->size && scanned < 400000) {
        scanned++;
        const char *line = index->base + cursor;
        const char *end = index->base + index->size;
        const char *tab = memchr(line, '\t', (size_t)(end - line));
        if (!tab) break;
        size_t keyLength = (size_t)(tab - line);
        if (keyLength < length || strncmp(line, target, length) != 0) break;
        if (keyLength > allowance) {
            const char *newline = memchr(line, '\n', (size_t)(end - line));
            if (!newline) break;
            cursor = (size_t)(newline - index->base) + 1;
            continue;
        }
        const char *wordStart = tab + 1;
        const char *wordEnd = memchr(wordStart, '\t', (size_t)(end - wordStart));
        if (!wordEnd) break;
        const char *weightEnd = memchr(wordEnd + 1, '\n', (size_t)(end - (wordEnd + 1)));
        if (!weightEnd) weightEnd = end;
        NSString *word = [[NSString alloc] initWithBytes:wordStart length:(NSUInteger)(wordEnd - wordStart) encoding:NSUTF8StringEncoding];
        NSInteger weight = [[[NSString alloc] initWithBytes:wordEnd + 1 length:(NSUInteger)(weightEnd - wordEnd - 1) encoding:NSUTF8StringEncoding] integerValue];
        if (word.length) {
            KBLexEntry *entry = [KBLexEntry new];
            entry.word = word;
            entry.weight = weight + (keyLength == length ? 1000000 : 0);
            [entries addObject:entry];
        }
        const char *newline = memchr(weightEnd, '\n', (size_t)(end - weightEnd));
        if (!newline) break;
        cursor = (size_t)(newline - index->base) + 1;
    }
    [entries sortUsingComparator:^NSComparisonResult(KBLexEntry *a, KBLexEntry *b) {
        if (a.weight == b.weight) return [a.word compare:b.word];
        return a.weight > b.weight ? NSOrderedAscending : NSOrderedDescending;
    }];
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (KBLexEntry *entry in entries) {
        if ([seen containsObject:entry.word]) continue;
        [seen addObject:entry.word];
        [words addObject:entry.word];
        if (words.count >= limit) break;
    }
    if (scannedOut) *scannedOut += scanned;
    return words;
}
#endif

static NSArray<NSString *> *KBCollectActive(KBIndex *index, const char *target, size_t length,
                                           NSUInteger limit, NSUInteger *scannedOut, __unused BOOL optimized) {
#if KB_LOOKUP_BENCHMARK
    if (!optimized) {
        return KBLegacyCollect(index, target, length, limit, scannedOut);
    }
#endif
    return KBCollect(index, target, length, limit, scannedOut);
}

// 同一 helper 用于生产及隔离 fixture；缓存只存拥有字符串的不可变结果。
static NSArray<NSString *> *KBLookupCached(NSCache *cache, KBIndex *index, KBIndex *custom,
                                          NSString *input, NSUInteger limit, BOOL digits,
                                          BOOL optimized, NSUInteger *scannedOut) {
    if (scannedOut) *scannedOut = 0;
    if (input.length == 0) return @[];
    NSString *key = [input lowercaseString];
    NSMutableString *flattened = [KBFlattenInput(key) mutableCopy];
    const char *target = flattened.UTF8String;
    if (!target || !*target) return @[];

    NSArray *cacheKey = @[[flattened copy], @(limit), @(digits), @(optimized),
                          [NSValue valueWithPointer:index], @(index->generation),
                          [NSValue valueWithPointer:custom], @(custom->generation)];
    NSArray *cached = [cache objectForKey:cacheKey];
    if (cached) return cached;
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    if (custom->base) {
        [words addObjectsFromArray:KBCollectActive(custom, target, strlen(target), 3, scannedOut, optimized)];
    }
    if (index->base) {
        [words addObjectsFromArray:KBCollectActive(index, target, strlen(target), limit, scannedOut, optimized)];
    }
    NSMutableArray<NSString *> *unique = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *word in words) {
        if ([seen containsObject:word]) continue;
        [seen addObject:word];
        [unique addObject:word];
        if (unique.count >= limit) break;
    }
    NSArray *result = [unique copy];
    [cache setObject:result forKey:cacheKey];
    return result;
}

static NSArray<NSString *> *KBIndexLookup(NSString *input, NSUInteger limit, NSUInteger *scannedOut) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; cache.countLimit = 32; });
    BOOL digits = YES;
    for (NSUInteger i = 0; i < input.length; i++) {
        unichar c = [input characterAtIndex:i];
        if (c < '0' || c > '9') { digits = NO; break; }
    }
    BOOL optimized = YES;
#if KB_LOOKUP_BENCHMARK
    optimized = atomic_load(&KBOptimizedLookupVerified);
#endif
    return KBLookupCached(cache, digits ? &KBIndex9 : &KBIndex26,
                          digits ? &KBCustom9 : &KBCustom26, input, limit, digits, optimized, scannedOut);
}

// 九宫格：按键送来的是 ➊➋➌➍➎➏➐➑➒ 这类字形，候选管线里看到的却是被猜成
// 字母的 "ni h"，拼不出完整拼音。所以自己把字形累积成数字串，用 index9 查。
static char KBLastDigits[64];

static int KBDigitForGlyph(unichar c) {
    // U+278A..U+2792 是 ➊..➒
    if (c >= 0x278A && c <= 0x2792) return (int)(c - 0x278A) + 1;
    if (c >= '0' && c <= '9') return (int)(c - '0');
    return -1;
}

static void KBUpdateDigitBuffer(NSString *text) {
    if (text.length == 0) {
        size_t length = strlen(KBLastDigits);
        if (length > 0) KBLastDigits[length - 1] = '\0';
        return;
    }
    if (text.length == 1) {
        int digit = KBDigitForGlyph([text characterAtIndex:0]);
        if (digit >= 0) {
            size_t length = strlen(KBLastDigits);
            if (length + 1 < sizeof(KBLastDigits)) {
                KBLastDigits[length] = (char)('0' + digit);
                KBLastDigits[length + 1] = '\0';
            }
            return;
        }
    }
    // 出现字母说明切回了 26 键，清空数字串。
    KBLastDigits[0] = '\0';
}


static BOOL KBShouldInject(NSString *input) {
    // 有输入才查词；空输入（联想栏）不动。
    return input.length > 0;
}

static id KBMakeCandidate(NSString *word, NSString *input) {
    Class cls = objc_getClass("TIKeyboardCandidateSingle");
    SEL sel = NSSelectorFromString(@"candidateWithCandidate:forInput:");
    if (!cls || !class_respondsToSelector(object_getClass(cls), sel)) {
        os_log_error(KBLog, "candidate factory missing (TIKeyboardCandidateSingle)");
        return nil;
    }
    id (*make)(id, SEL, NSString *, NSString *) = (id (*)(id, SEL, NSString *, NSString *))objc_msgSend;
    @try { return make((id)cls, sel, word, input); }
    @catch (__unused NSException *exception) {
        os_log_error(KBLog, "candidate factory failed; keeping baseline candidates");
        return nil;
    }
}

static id KBExistingCandidate(NSArray *candidates, NSString *word) {
    for (id candidate in candidates) {
        if (![candidate respondsToSelector:@selector(candidate)]) continue;
        @try {
            id value = ((id (*)(id, SEL))objc_msgSend)(candidate, @selector(candidate));
            if ([value isKindOfClass:NSString.class] && [value isEqualToString:word]) return candidate;
        } @catch (__unused NSException *exception) {}
    }
    return nil;
}

static void KBDiscoveryAppend(const char *format, ...) {
    size_t used = strlen(KBDiscovery);
    if (used >= sizeof(KBDiscovery) - 2) return;
    va_list args;
    va_start(args, format);
    vsnprintf(KBDiscovery + used, sizeof(KBDiscovery) - used, format, args);
    va_end(args);
    size_t length = strlen(KBDiscovery);
    if (length + 1 < sizeof(KBDiscovery)) {
        KBDiscovery[length] = '\n';
        KBDiscovery[length + 1] = '\0';
    }
}

static void KBDumpCandidateMethods(Class cls) {
    for (Class current = cls; current && current != [NSObject class]; current = class_getSuperclass(current)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(current, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *name = sel_getName(method_getName(methods[i]));
            if (!strstr(name, "candidat")) continue;
            os_log(KBLog, "api %{public}s %{public}s enc=%{public}s",
                   class_getName(current), name, method_getTypeEncoding(methods[i]) ?: "?");
            KBDiscoveryAppend("%s %s %s", class_getName(current), name, method_getTypeEncoding(methods[i]) ?: "?");
        }
        free(methods);
    }
}

// 运行时的类型编码带偏移（如 @16@0:8），写死的模板不会相等：
// 去掉数字再比，只比类型字母。
static BOOL KBEncodingMatches(const char *encoding, const char *expected) {
    if (!encoding) return NO;
    char a[64], b[64];
    size_t i = 0, j = 0;
    for (const char *p = encoding; *p && i + 1 < sizeof(a); p++) {
        if (*p >= '0' && *p <= '9') continue;
        a[i++] = *p;
    }
    a[i] = '\0';
    for (const char *p = expected; *p && j + 1 < sizeof(b); p++) {
        if (*p >= '0' && *p <= '9') continue;
        b[j++] = *p;
    }
    b[j] = '\0';
    return strcmp(a, b) == 0;
}

static BOOL KBInstall(Class cls, const char *selectorName, const char *expectedEncoding, IMP replacement, IMP *original) {
    SEL selector = sel_registerName(selectorName);
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    BOOL matches = KBEncodingMatches(encoding, expectedEncoding);
    os_log(KBLog, "hook %{public}s %{public}s enc=%{public}s expected=%{public}s %{public}s",
           cls ? class_getName(cls) : "?", selectorName, encoding ?: "missing", expectedEncoding,
           matches ? "installing" : "skipped");
    NSString *key = [NSString stringWithFormat:@"hook.%s", selectorName];
    if (!matches) {
        KBStatusSet(key, method ? @"encoding" : @"missing");
        KBDiscoveryAppend("hook %s %s", selectorName, method ? "encoding-mismatch" : "missing");
        return NO;
    }
    if (!KBLoadSubstrate()) return NO;
    KBHookMessage(cls, selector, replacement, original);
    KBStatusSet(key, *original != NULL ? @"installed" : @"failed");
    KBDiscoveryAppend("hook %s %s", selectorName, *original != NULL ? "installed" : "failed");
    if (*original != NULL) KBHookFlags++;
    return *original != NULL;
}

#pragma mark - Hook

static id KBHookedHandleInput(id self, SEL _cmd, id input) {
    @autoreleasepool {
        NSString *text = KBStringFromInput(input);
        if (text.length > 0 && text.length < (NSUInteger)sizeof(KBLastInput)) {
            strlcpy(KBLastInput, text.UTF8String ?: "", sizeof(KBLastInput));
        }
        KBStatusBump(@"handleKeyboardInput");
        KBInputCalls++;
        KBUpdateDigitBuffer(text);
    }
    return ((id (*)(id, SEL, id))KBOrigHandleInput)(self, _cmd, input);
}

// 某个词现在该不该隐藏：整词排除永远隐藏；@简 只在本轮输入像简拼时隐藏。
static BOOL KBShouldHideWord(NSString *word, BOOL initials) {
    if (!word.length) return NO;
    if ([KBExcludedWords containsObject:word]) return YES;
    return initials && [KBExcludedInitials containsObject:word];
}

static void KBHookedFound(id self, SEL _cmd, id candidates, id operation) {
    @autoreleasepool {
        KBStatusBump(@"wordSearchEngineDidFindCandidates");
        KBFoundCalls++;
        if (!KBLoggedCandidateShape) {
            KBLoggedCandidateShape = YES;
            KBStatusSet(@"foundShape", [NSString stringWithFormat:@"%s", KBSafeName(candidates)]);
        }
        KBLoadExcludedWords();
        BOOL initials = KBInputLooksLikeInitials([NSString stringWithUTF8String:KBLastInput]);
        // 简拼候选走这条路径：从内层可变数组里删掉被排除的词。
        id innerList = nil;
        if ([candidates respondsToSelector:@selector(candidates)]) {
            innerList = ((id (*)(id, SEL))objc_msgSend)(candidates, @selector(candidates));
        } else if ([candidates isKindOfClass:[NSArray class]]) {
            innerList = candidates;
        }
        if ([innerList isKindOfClass:[NSMutableArray class]]) {
            NSMutableArray *list = (NSMutableArray *)innerList;
            NSUInteger removed = 0;
            for (NSInteger i = (NSInteger)list.count - 1; i >= 0; i--) {
                id candidate = list[(NSUInteger)i];
                if (![candidate respondsToSelector:@selector(candidate)]) continue;
                id word = ((id (*)(id, SEL))objc_msgSend)(candidate, @selector(candidate));
                if ([word isKindOfClass:[NSString class]] && KBShouldHideWord(word, initials)) {
                    [list removeObjectAtIndex:(NSUInteger)i];
                    removed++;
                }
            }
            if (removed) KBStatusSet(@"excludedCandidates", @(removed));
        }
    }
    ((void (*)(id, SEL, id, id))KBOrigFound)(self, _cmd, candidates, operation);
}
static id KBHookedCandidates(id self, SEL _cmd) {
    id result = ((id (*)(id, SEL))KBOrigCandidates)(self, _cmd);
    @autoreleasepool {
        KBStatusBump(@"candidates");
        KBCandidateCalls++;
        static BOOL loggedShape;
        if (!loggedShape) {
            loggedShape = YES;
            KBStatusSet(@"resultSetClass", [NSString stringWithUTF8String:KBSafeName(result)]);
        }
        // 简拼那条路径给的数组不可变：这里筛一遍再用 KVC 塞回结果集。
        KBLoadExcludedWords();
        if (KBExcludedWords.count || KBExcludedInitials.count) {
            BOOL initials = KBInputLooksLikeInitials([NSString stringWithUTF8String:KBLastInput]);
            id inner = nil;
            if ([result respondsToSelector:@selector(candidates)]) {
                inner = ((id (*)(id, SEL))objc_msgSend)(result, @selector(candidates));
            }
            if ([inner isKindOfClass:[NSArray class]]) {
                NSMutableArray *kept = [NSMutableArray arrayWithCapacity:[(NSArray *)inner count]];
                for (id candidate in (NSArray *)inner) {
                    NSString *word = nil;
                    if ([candidate respondsToSelector:@selector(candidate)]) {
                        id value = ((id (*)(id, SEL))objc_msgSend)(candidate, @selector(candidate));
                        if ([value isKindOfClass:[NSString class]]) word = value;
                    }
                    if (word && KBShouldHideWord(word, initials)) continue;
                    [kept addObject:candidate];
                }
                if (kept.count != [(NSArray *)inner count]) {
                    @try {
                        [result setValue:kept forKey:@"candidates"];
                        KBStatusSet(@"excludedCandidates", @(1));
                    } @catch (__unused NSException *exception) {
                    }
                }
            }
        }
    }
    return result;
}

static id KBHookedResults(id self, SEL _cmd, BOOL wait) {
    return ((id (*)(id, SEL, BOOL))KBOrigResults)(self, _cmd, wait);
}

// 真正的候选入口：中文引擎把候选数组交给这个方法生成结果集。
static id KBHookedFromCandidates(id self, SEL _cmd, id candidates, id triggers) {
    uint64_t hookStart = KBNowNs();
    @autoreleasepool {
        KBCandidateCalls++;
        NSString *input = KBInputForCandidateLookup(self);
        NSMutableDictionary *report = [NSMutableDictionary dictionary];
        NSUInteger lines = 0;
        double lookupMs = 0;
        if (KBShouldInject(input) && [candidates isKindOfClass:[NSArray class]]) {
            uint64_t lookupStart = KBNowNs();
            // 用户排除的词：苹果自己的候选也一起挡掉，否则只是删了我们这边的一份。
            KBLoadExcludedWords();
            if (KBExcludedWords.count) {
                NSMutableArray *kept = [NSMutableArray arrayWithCapacity:[(NSArray *)candidates count]];
                for (id candidate in (NSArray *)candidates) {
                    SEL wordSelector = NSSelectorFromString(@"candidate");
                    NSString *word = nil;
                    if ([candidate respondsToSelector:wordSelector]) {
                        @try {
                            id value = ((id (*)(id, SEL))objc_msgSend)(candidate, wordSelector);
                            if ([value isKindOfClass:[NSString class]]) word = value;
                        } @catch (__unused NSException *exception) {
                        }
                    }
                    if (word && [KBExcludedWords containsObject:word]) continue;
                    [kept addObject:candidate];
                }
                if (kept.count != [(NSArray *)candidates count]) {
                    report[@"excludedCandidates"] =
                        @((NSUInteger)([(NSArray *)candidates count] - kept.count));
                    candidates = kept;
                }
            }
            NSUInteger limit = KBCandidateLimit();
            NSArray<NSString *> *words = @[];
            BOOL localEnabled = KBLocalCandidatesEnabled();
            report[@"localEnabled"] = @(localEnabled);
            report[@"localObservedAt"] = @(NSDate.date.timeIntervalSince1970);
            if (localEnabled) {
                KBPrepareIndexes();
                const char *digits = KBLastDigits;
                if (digits[0] && strlen(digits) >= 2) {
                    // 九宫格：用按键累积的数字串，长度跟随已猜出的字母数（处理退格）。
                    NSString *typed = [NSString stringWithUTF8String:digits];
                    if (typed.length > input.length) typed = [typed substringToIndex:input.length];
                    words = KBIndexLookup(typed, limit, &lines);
                } else {
                    words = KBIndexLookup(input, limit, &lines);
                }
            }
            lookupMs = (double)(KBNowNs() - lookupStart) / 1e6;
            report[@"lastLookup"] = [NSString stringWithFormat:@"%@ -> %lu (26=%d,9=%d)", input,
                                     (unsigned long)words.count, KBIndex26.base != NULL, KBIndex9.base != NULL];
            report[@"lastWords"] = words.count ? [[words subarrayWithRange:
                NSMakeRange(0, MIN(words.count, (NSUInteger)5))] componentsJoinedByString:@"|"] : @"-";
            NSMutableArray *remaining = [(NSArray *)candidates mutableCopy];
            NSMutableArray *front = [NSMutableArray array];
            for (NSString *word in words) {
                id candidate = KBExistingCandidate(remaining, word) ?: KBMakeCandidate(word, input);
                if (candidate) [front addObject:candidate];
            }
            for (id candidate in front) [remaining removeObjectIdenticalTo:candidate];
            NSUInteger placed = front.count;
            report[@"injectedInput"] = input ?: @"-";
            report[@"injectedCount"] = @(placed);
            report[@"droppedApple"] = @0;
            if (placed) {
                if (KBLexiconOnlyEnabled()) {
                    report[@"mode"] = @"lexicon-only";
                    report[@"droppedApple"] = @(remaining.count);
                } else {
                    [front addObjectsFromArray:remaining];
                    report[@"mode"] = @"merged";
                }
                candidates = front;
            } else {
                report[@"mode"] = @"none";
            }
        }
        double hookMs = (double)(KBNowNs() - hookStart) / 1e6;
        if (report[@"injectedCount"]) KBPerfRecord(lookupMs, hookMs, lines, input);
        KBStatusMerge(report);
    }
    return ((id (*)(id, SEL, id, id))KBOrigFromCandidates)(self, _cmd, candidates, triggers);
}

#pragma mark - 启动

#if KB_LOOKUP_BENCHMARK && !defined(KB_LOOKUP_STANDALONE)
#include "../Tests/LookupBench.m"
#endif

static void KBDumpClasses(void) {
    // 类可能晚加载，也可能名字和公开头文件不一致：把含 Pinyin/Candidate 的类打出来。
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return;
    Class *classes = (Class *)calloc((size_t)count, sizeof(Class));
    if (!classes) return;
    count = objc_getClassList(classes, count);
    int printed = 0;
    for (int i = 0; i < count && printed < 24; i++) {
        const char *name = class_getName(classes[i]);
        if (!name) continue;
        if (!strcasestr(name, "pinyin") && !strcasestr(name, "candidate") && !strcasestr(name, "wordsearch")) continue;
        os_log(KBLog, "class %{public}s image=%{public}s", name, class_getImageName(classes[i]) ?: "?");
        printed++;
    }
    free(classes);
    os_log(KBLog, "class dump done, total=%d printed=%d", count, printed);
    KBDiscoveryAppend("class dump total=%d printed=%d", count, printed);
}

static void KBInstallHooks(void) {
    static BOOL attempted;
    if (attempted && KBHooksInstalled) return;
    Class cls = objc_getClass("TIKeyboardInputManagerPinyin");
    if (!cls) {
        static BOOL dumped;
        os_log_error(KBLog, "TIKeyboardInputManagerPinyin not loaded yet");
        KBStatusSet(@"pinyinClass", @"missing");
        if (!dumped) { dumped = YES; KBDumpClasses(); }
        return;
    }
    if (attempted) return;
    attempted = YES;
    KBStatusSet(@"pinyinClass", @"present");
    KBStatusSet(@"superclass", [NSString stringWithUTF8String:class_getName(class_getSuperclass(cls))]);
    KBStatusSet(@"image", [NSString stringWithUTF8String:class_getImageName(cls) ?: "?"]);
    KBDiscoveryAppend("class present super=%s image=%s",
                      class_getName(class_getSuperclass(cls)), class_getImageName(cls) ?: "?");
    os_log(KBLog, "TIKeyboardInputManagerPinyin present, superclass=%{public}s image=%{public}s",
           class_getName(class_getSuperclass(cls)),
           class_getImageName(cls) ?: "?");

    KBDumpCandidateMethods(cls);
    // The optional trace needs the hook function too; ordinary hooks load it below.
    if (KBLoadSubstrate()) KBCandidateTraceInstall(KBHookMessage, cls);

    KBInstall(cls, "handleKeyboardInput:", "@@:@", (IMP)KBHookedHandleInput, &KBOrigHandleInput);
    KBInstall(cls, "wordSearchEngineDidFindCandidates:forOperation:", "v@:@@", (IMP)KBHookedFound, &KBOrigFound);
    KBInstall(cls, "candidateResultSetFromCandidates:proactiveTriggers:", "@@:@@", (IMP)KBHookedFromCandidates, &KBOrigFromCandidates);
    KBInstall(cls, "candidateResultSet", "@@:", (IMP)KBHookedCandidates, &KBOrigCandidates);
    KBInstall(cls, "candidateResultSetByWaitingForResults:", "@@:B", (IMP)KBHookedResults, &KBOrigResults);
    KBHooksInstalled = KBHookFlags > 0;

    // 加载时自检：直接把几个词查一遍写进状态文件，不用真机打字也能判断索引对不对。
    KBPrepareIndexes();
    NSArray<NSString *> *probe26 = KBIndexLookup(@"suijishu", 3, NULL);
    NSArray<NSString *> *probe9 = KBIndexLookup(@"64426", 3, NULL);
    KBStatusSet(@"selfTest26", [probe26 componentsJoinedByString:@","] ?: @"-");
    KBStatusSet(@"selfTest9", [probe9 componentsJoinedByString:@","] ?: @"-");

#if KB_LOOKUP_BENCHMARK
    NSString *active = KBActiveLibraryName();
    NSString *directory = active.length ? [[KBKeyboardDirectory stringByAppendingPathComponent:@"libs"]
                                           stringByAppendingPathComponent:active] : KBKeyboardDirectory;
    KBStartBench(directory);
#endif

    os_log(KBLog, "probe ready (input=%{public}s results=%{public}s candidates=%{public}s found=%{public}s)",
           KBOrigHandleInput ? "hooked" : "no", KBOrigResults ? "hooked" : "no",
           KBOrigCandidates ? "hooked" : "no", KBOrigFound ? "hooked" : "no");
}

#ifndef KB_NO_CONSTRUCTOR
__attribute__((constructor)) static void KBStart(void) {
    @autoreleasepool {
        KBLog = os_log_create("com.wm0104.keybridge.probe", "probe");
        KBStatusInit();
        KBStatusSet(@"loaded", @YES);
        os_log(KBLog, "ApelinLoaded %{public}s", APELIN_BUILD_ID);
        os_log(KBLog, "process=%{public}@ pid=%d", NSProcessInfo.processInfo.processName, getpid());

        KBInstallHooks();
        KBStartHeartbeat();
        if (KBHooksInstalled) {
            KBStatusSet(@"ready", @YES);
            return;
        }
        // TextInputCore 可能晚于本 dylib 加载：每 2 秒重试，持续一分钟。
        dispatch_queue_t queue = dispatch_queue_create("com.wm0104.keybridge.probe.retry", DISPATCH_QUEUE_SERIAL);
        dispatch_source_t retry = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        dispatch_source_set_timer(retry, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
        dispatch_source_set_event_handler(retry, ^{
            KBInstallHooks();
            if (KBHooksInstalled) {
                KBStatusSet(@"ready", @YES);
                dispatch_source_cancel(retry);
            }
        });
        dispatch_resume(retry);
    }
}
#endif
