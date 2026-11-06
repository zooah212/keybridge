// 诊断构建包含此文件：复用生产查询，独立 mmap，不改词库和键盘状态。
#ifdef KB_LOOKUP_STANDALONE
#define KB_LOOKUP_BENCHMARK 1
#define KB_NO_CONSTRUCTOR 1
#import "../Probe/KeyBridgeProbe.m"
#endif

static BOOL KBCheckLookup(KBIndex *index, NSString *input, NSUInteger limit, NSArray *expected,
                          NSUInteger *checks, NSMutableArray *failures, NSString *label) {
    NSArray *reference = KBLegacyCollect(index, input.UTF8String, strlen(input.UTF8String), limit, NULL);
    NSArray *actual = KBCollect(index, input.UTF8String, strlen(input.UTF8String), limit, NULL);
    (*checks)++;
    BOOL same = [reference isEqualToArray:actual] && (!expected || [actual isEqualToArray:expected]);
    if (!same && failures.count < 20) {
        [failures addObject:[NSString stringWithFormat:@"%@/%@/%lu", label, input, (unsigned long)limit]];
    }
    return same;
}

static void KBCheckFixture(NSString *label, NSString *text, NSString *input, NSArray *expected,
                           NSUInteger *checks, NSMutableArray *failures) {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    KBIndex index = {.fd = -1, .base = data.bytes, .size = data.length};
    for (NSNumber *limit in @[@1, @3, @5, @8, @10, @15, @20]) {
        KBCheckLookup(&index, input, limit.unsignedIntegerValue,
                      limit.unsignedIntegerValue == 5 ? expected : nil, checks, failures, label);
    }
}

@interface KBInputSourceFixture : NSObject
@property (nonatomic, copy) NSString *inputString;
@end
@implementation KBInputSourceFixture
@end

static void KBCheckInputSource(NSUInteger *checks, NSMutableArray *failures) {
    KBInputSourceFixture *manager = [KBInputSourceFixture new];
    manager.inputString = @"wo";
    BOOL nonempty = [KBInputForCandidateLookup(manager) isEqualToString:@"wo"];
    manager.inputString = @"";
    BOOL empty = [KBInputForCandidateLookup(manager) isEqualToString:@""];
    manager.inputString = nil;
    NSString *previous = [NSString stringWithUTF8String:KBLastInput];
    BOOL unavailable = [KBInputForCandidateLookup(manager) isEqualToString:previous];
    for (NSDictionary *check in @[@{@"name": @"active", @"pass": @(nonempty)},
                                  @{@"name": @"committed-empty", @"pass": @(empty)},
                                  @{@"name": @"unavailable", @"pass": @(unavailable)}]) {
        (*checks)++;
        if (![check[@"pass"] boolValue] && failures.count < 20) {
            [failures addObject:[@"input/" stringByAppendingString:check[@"name"]]];
        }
    }
}

// 独立目录、映射和 cache：不交换全局键盘映射，也不清理活跃按键缓存。
static void KBCheckCache(NSUInteger *checks, NSMutableArray *failures) {
    NSCache *cache = [NSCache new];
    cache.countLimit = 32;
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *ordinaryPath = [directory stringByAppendingPathComponent:@"index.tsv"];
    NSString *customPath = [directory stringByAppendingPathComponent:@"custom.tsv"];
    KBIndex ordinaryMap = {.fd = -1}, customMap = {.fd = -1};
    KBIndex *ordinary = &ordinaryMap, *custom = &customMap;
    void (^check)(BOOL, NSString *) = ^(BOOL pass, NSString *label) {
        (*checks)++;
        if (!pass && failures.count < 20) [failures addObject:[@"cache/" stringByAppendingString:label]];
    };
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES
                                                  attributes:nil error:NULL]) {
        check(NO, @"fixture-directory"); return;
    }
    BOOL (^write)(NSString *, NSString *) = ^BOOL(NSString *text, NSString *path) {
        BOOL ok = [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        check(ok, @"fixture-write"); return ok;
    };
    void (^query)(NSString *, NSUInteger, BOOL, BOOL, NSArray *, BOOL, NSString *) =
    ^(NSString *input, NSUInteger limit, BOOL digits, BOOL optimized, NSArray *expected, BOOL noScan, NSString *label) {
        NSUInteger scanned = 123;
        NSArray *actual = KBLookupCached(cache, ordinary, custom, input, limit, digits, optimized, &scanned);
        check([actual isEqualToArray:expected] && (noScan ? scanned == 0 : scanned > 0), label);
    };
    write(@"a\t阿\t100\na\t啊\t90\nab\t安\t80\nb\t不\t70\n", ordinaryPath);
    KBIndexPrepare(ordinary, ordinaryPath);
    KBIndexPrepare(custom, customPath);
    query(@"a", 3, NO, NO, (@[@"阿", @"啊", @"安"]), NO, @"legacy-miss");
    query(@"a", 3, NO, NO, (@[@"阿", @"啊", @"安"]), YES, @"repeat-hit");
    query(@" A ' ", 3, NO, NO, (@[@"阿", @"啊", @"安"]), YES, @"normalized-hit");
    query(@"ab", 3, NO, NO, (@[@"安"]), NO, @"input-miss");
    query(@"a", 3, NO, NO, (@[@"阿", @"啊", @"安"]), YES, @"backspace-hit");
    query(@"a", 1, NO, NO, (@[@"阿"]), NO, @"limit-miss");
    query(@"a", 3, YES, NO, (@[@"阿", @"啊", @"安"]), NO, @"mode-miss");
    query(@"a", 3, NO, YES, (@[@"阿", @"啊", @"安"]), NO, @"verified-algorithm-miss");
    query(@"a", 3, NO, YES, (@[@"阿", @"啊", @"安"]), YES, @"verified-hit");
    write(@"a\t自\t1\na\t阿\t0\n", customPath);
    KBIndexPrepare(custom, customPath);
    query(@"a", 3, NO, YES, (@[@"自", @"阿", @"啊"]), NO, @"custom-created-priority-dedup");
    query(@"a", 3, NO, YES, (@[@"自", @"阿", @"啊"]), YES, @"custom-hit");
    write(@"a\t新\t1\na\t阿\t0\n", customPath);
    KBIndexPrepare(custom, customPath);
    query(@"a", 3, NO, YES, (@[@"新", @"阿", @"啊"]), NO, @"custom-atomic-replace");
    [[NSFileManager defaultManager] removeItemAtPath:customPath error:NULL];
    KBIndexPrepare(custom, customPath);
    query(@"a", 3, NO, YES, (@[@"阿", @"啊", @"安"]), NO, @"custom-deleted");
    write(@"a\t另\t100\n", ordinaryPath);
    KBIndexPrepare(ordinary, ordinaryPath);
    query(@"a", 3, NO, YES, (@[@"另"]), NO, @"ordinary-remap");
    KBIndex snapshot = {.fd = -1};
    KBIndexPrepare(&snapshot, ordinaryPath);
    NSUInteger identityScanned = 0;
    NSArray *identityResult = KBLookupCached(cache, &snapshot, custom, @"a", 3, NO, YES, &identityScanned);
    check([identityResult isEqualToArray:@[@"另"]] && identityScanned > 0, @"index-identity-miss");
    KBIndexClose(&snapshot);
    query(@"a", 3, NO, YES, (@[@"另"]), YES, @"independent-close-keeps-hit");
    KBIndexClose(ordinary);
    query(@"a", 3, NO, YES, (@[]), YES, @"disabled-empty");
    KBIndexPrepare(ordinary, ordinaryPath);
    query(@"a", 3, NO, YES, (@[@"另"]), NO, @"reenabled-miss");
    KBIndexClose(ordinary);
    KBIndexClose(custom);
    [[NSFileManager defaultManager] removeItemAtPath:directory error:NULL];
}

static double KBMedian3(double *samples) {
    double a = samples[0], b = samples[1], c = samples[2];
    return MAX(MIN(a, b), MIN(MAX(a, b), c));
}

static NSDictionary *KBRunLookupBench(NSString *directory) {
    NSUInteger checks = 0;
    NSMutableArray *failures = [NSMutableArray array];
    KBCheckInputSource(&checks, failures);
    KBCheckCache(&checks, failures);
    NSMutableString *duplicates = [NSMutableString string];
    for (NSUInteger i = 0; i < 64; i++) [duplicates appendString:@"a\t阿\t1000\n"];
    [duplicates appendString:@"a\t啊\t900\na\t好\t800\na\t你\t700\na\t是\t600\na\t的\t500\n"];
    KBCheckFixture(@"many-duplicates", duplicates, @"a", @[@"阿", @"啊", @"好", @"你", @"是"], &checks, failures);
    KBCheckFixture(@"duplicate-score", @"aa\t阿\t1\naa\t啊\t90\naaa\t阿\t1000005\n",
                   @"aa", @[@"啊", @"阿"], &checks, failures);
    KBCheckFixture(@"unicode-ties", @"a\t𠀀\t10\na\t啊\t10\na\t阿\t10\na\t😀\t10\n",
                   @"a", nil, &checks, failures);
    KBCheckFixture(@"last-line", @"a\t阿\t10\na\t啊\t9", @"a", @[@"阿", @"啊"], &checks, failures);
    KBCheckFixture(@"empty", @"", @"a", @[], &checks, failures);
    KBCheckFixture(@"missing", @"a\t阿\t10\n", @"zz", @[], &checks, failures);
    KBCheckFixture(@"long-first-line", @"a\t一个很长的自定义词条\t1000000\nb\t乙\t1000000\n",
                   @"b", @[@"乙"], &checks, failures);
    KBCheckFixture(@"long-first-line-no-newline", @"a\t一个很长的自定义词条\t1000000\nb\t乙\t1000000",
                   @"b", @[@"乙"], &checks, failures);
    NSArray *ranked = @[@"一", @"二", @"三", @"四", @"五", @"六", @"七", @"八", @"九", @"十",
                         @"十一", @"十二", @"十三", @"十四", @"十五", @"十六", @"十七", @"十八", @"十九", @"二十", @"二十一"];
    NSMutableString *largeFixture = [NSMutableString string];
    for (NSUInteger i = 0; i < ranked.count; i++) {
        [largeFixture appendFormat:@"a\t%@\t%lu\n", ranked[i], (unsigned long)(1000 - i)];
    }
    [largeFixture appendString:@"a\t一\t1\n"];
    NSData *largeData = [largeFixture dataUsingEncoding:NSUTF8StringEncoding];
    KBIndex largeIndex = {.fd = -1, .base = largeData.bytes, .size = largeData.length};
    for (NSNumber *limit in @[@15, @20]) {
        KBCheckLookup(&largeIndex, @"a", limit.unsignedIntegerValue,
                      [ranked subarrayWithRange:NSMakeRange(0, limit.unsignedIntegerValue)],
                      &checks, failures, @"expanded-limit-dedup");
    }
    NSArray *words = @[@"阿", @"啊", @"安", @"爱", @"昂", @"好", @"你", @"是", @"的", @"我", @"𠀀"];
    NSMutableString *generated = [NSMutableString string];
    for (NSString *key in @[@"a", @"aa", @"aaa", @"aaaaaa", @"ab", @"ac"]) {
        for (NSUInteger i = 0; i < 80; i++) {
            [generated appendFormat:@"%@\t%@\t%lu\n", key, words[(i * 7 + key.length) % words.count],
                                    (unsigned long)((i * 97 + key.length * 29) % 113)];
        }
    }
    for (NSString *input in @[@"a", @"aa", @"ab", @"ac", @"zz"]) {
        KBCheckFixture(@"generated", generated, input, nil, &checks, failures);
    }

    NSMutableArray *samples = [NSMutableArray array];
    NSArray *groups = @[
        @[@"s", @"sh", @"shi", @"sui", @"suijishu", @"n", @"ni", @"lian", @"hao", @"zhongguo"],
        @[@"6", @"64", @"644", @"64426"]];
    BOOL mappedAll = YES;
    for (NSUInteger g = 0; g < groups.count; g++) {
        KBIndex snapshot = {.fd = -1};
        NSString *name = g ? @"index9.tsv" : @"index26.tsv";
        KBIndexPrepare(&snapshot, [directory stringByAppendingPathComponent:name]);
        if (!snapshot.base) { mappedAll = NO; continue; }
        for (NSString *input in groups[g]) {
            double oldTimes[3], newTimes[3];
            NSUInteger scanned = 0;
            NSArray *oldWords = nil, *newWords = nil;
            BOOL same = YES;
            for (NSUInteger run = 0; run < 3; run++) {
                // 交错顺序；计时包含临时对象释放，报告热缓存中位数，不冒充键到屏延迟。
                for (NSUInteger step = 0; step < 2; step++) {
                    BOOL optimized = ((run + step) % 2) != 0;
                    uint64_t start = KBNowNs();
                    @autoreleasepool {
                        if (optimized) {
                            scanned = 0;
                            newWords = KBCollect(&snapshot, input.UTF8String, strlen(input.UTF8String), 5, &scanned);
                        } else {
                            oldWords = KBLegacyCollect(&snapshot, input.UTF8String, strlen(input.UTF8String), 5, NULL);
                        }
                    }
                    double milliseconds = (double)(KBNowNs() - start) / 1e6;
                    if (optimized) newTimes[run] = milliseconds;
                    else oldTimes[run] = milliseconds;
                }
                if (![oldWords isEqualToArray:newWords]) same = NO;
            }
            for (NSNumber *limit in @[@1, @3, @5, @8, @10, @15, @20]) {
                if (!KBCheckLookup(&snapshot, input, limit.unsignedIntegerValue, nil, &checks, failures, name)) same = NO;
            }
            if (!same && failures.count < 20) {
                [failures addObject:[NSString stringWithFormat:@"timed/%@/%@", name, input]];
            }
            [samples addObject:@{@"input": input, @"index": name,
                                 @"referenceMedianMs": @(KBMedian3(oldTimes)),
                                 @"optimizedMedianMs": @(KBMedian3(newTimes)),
                                 @"scannedRows": @(scanned), @"same": @(same)}];
        }
        KBIndexClose(&snapshot);
    }
    BOOL verified = mappedAll && !failures.count && samples.count == 14;
    return @{@"buildID": @APELIN_BUILD_ID, @"scope": @"lookup-only, warm paired medians",
             @"checks": @(checks), @"failures": failures, @"verified": @(verified), @"samples": samples};
}

static void KBStartBench(NSString *directory) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            NSDictionary *report = KBRunLookupBench(directory);
            BOOL verified = [report[@"verified"] boolValue];
            dispatch_async(KBStatusQueue, ^{
                KBStatus[@"benchmark"] = report;
                KBStatus[@"optimizedLookupVerified"] = @(verified);
                KBStatus[@"perf"] = [NSMutableDictionary dictionary];
                atomic_store(&KBOptimizedLookupVerified, verified);
                KBFlushStatus();
            });
            os_log(KBLog, "lookup benchmark checks=%lu verified=%d build=%{public}s",
                   (unsigned long)[report[@"checks"] unsignedIntegerValue], verified, APELIN_BUILD_ID);
        }
    });
}

#ifdef KB_LOOKUP_STANDALONE
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2) { fprintf(stderr, "usage: lookup-bench LIBRARY_DIRECTORY\n"); return 2; }
        KBLog = os_log_create("com.wm0104.keybridge.probe", "benchmark");
        NSDictionary *report = KBRunLookupBench([NSString stringWithUTF8String:argv[1]]);
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:NULL];
        fwrite(json.bytes, 1, json.length, stdout);
        fputc('\n', stdout);
        return [report[@"verified"] boolValue] ? 0 : 1;
    }
}
#endif
