// 自定义词条：用户在设置面板里加的「词语 + 拼音」，不经过 ZIP，也不用碰文件。
// 守护进程把面板给的列表写成 custom.json，并生成两份小索引供探针优先查询。

#import "KBCustomEntries.h"
#include <stdio.h>

static char KBLetterDigit(char c) {
    if (c >= 'a' && c <= 'c') return '2';
    if (c >= 'd' && c <= 'f') return '3';
    if (c >= 'g' && c <= 'i') return '4';
    if (c >= 'j' && c <= 'l') return '5';
    if (c >= 'm' && c <= 'o') return '6';
    if (c >= 'p' && c <= 's') return '7';
    if (c >= 't' && c <= 'v') return '8';
    if (c >= 'w' && c <= 'z') return '9';
    return 0;
}

BOOL KBSaveCustomEntries(NSString *keyboard, NSString *json, NSUInteger *count, NSString **failure) {
    if (count) *count = 0;
    if (failure) *failure = nil;
    NSFileManager *manager = [NSFileManager defaultManager];
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    if (![parsed isKindOfClass:NSArray.class]) {
        if (failure) *failure = @"词条数据无效，原有词条未改动";
        return NO;
    }
    NSArray *entries = parsed;

    NSMutableArray<NSString *> *lines26 = [NSMutableArray array];
    NSMutableArray<NSString *> *lines9 = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *validatedEntries = [NSMutableArray array];
    for (id item in entries) {
        if (![item isKindOfClass:[NSDictionary class]]) {
            if (failure) *failure = @"词条数据无效，原有词条未改动";
            return NO;
        }
        NSString *word = [item[@"word"] isKindOfClass:[NSString class]] ? item[@"word"] : nil;
        NSString *pinyin = [item[@"pinyin"] isKindOfClass:[NSString class]] ? item[@"pinyin"] : nil;
        NSDictionary *entry = KBCustomEntriesByEditing(@[], 0, word, pinyin, failure).firstObject;
        if (!entry) return NO;
        [validatedEntries addObject:entry];
        word = entry[@"word"];
        NSString *key = KBNormalizeCustomPinyin(entry[@"pinyin"]);
        [lines26 addObject:[NSString stringWithFormat:@"%@\t%@\t1000000", key, word]];
        NSMutableString *digits = [NSMutableString string];
        for (NSUInteger i = 0; i < key.length; i++) {
            char digit = KBLetterDigit((char)[key characterAtIndex:i]);
            if (digit) [digits appendFormat:@"%c", digit];
        }
        if (digits.length) [lines9 addObject:[NSString stringWithFormat:@"%@\t%@\t1000000", digits, word]];
    }

    NSComparator compare = ^NSComparisonResult(NSString *a, NSString *b) { return [a compare:b]; };
    [lines26 sortUsingComparator:compare];
    [lines9 sortUsingComparator:compare];
    NSString *text26 = lines26.count ? [[lines26 componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"] : @"";
    NSString *text9 = lines9.count ? [[lines9 componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"] : @"";
    NSString *stage = [keyboard stringByAppendingPathComponent:[@".custom-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *destination = [keyboard stringByAppendingPathComponent:@"custom"];
    data = [NSJSONSerialization dataWithJSONObject:validatedEntries options:0 error:NULL];
    BOOL ok = [manager createDirectoryAtPath:stage withIntermediateDirectories:NO attributes:nil error:NULL] &&
        [data writeToFile:[stage stringByAppendingPathComponent:@"custom.json"] atomically:YES] &&
        [text26 writeToFile:[stage stringByAppendingPathComponent:@"custom26.tsv"] atomically:YES encoding:NSUTF8StringEncoding error:NULL] &&
        [text9 writeToFile:[stage stringByAppendingPathComponent:@"custom9.tsv"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    if (ok) {
        ok = ([manager fileExistsAtPath:destination]
            ? renamex_np(stage.fileSystemRepresentation, destination.fileSystemRepresentation, RENAME_SWAP)
            : rename(stage.fileSystemRepresentation, destination.fileSystemRepresentation)) == 0;
    }
    [manager removeItemAtPath:stage error:NULL];
    if (ok && count) *count = lines26.count;
    if (!ok && failure) *failure = @"保存失败，原有词条未改动";
    return ok;
}
