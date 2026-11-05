// 自定义词条：用户在设置面板里加的「词语 + 拼音」，不经过 ZIP，也不用碰文件。
// 守护进程把面板给的列表写成 custom.json，并生成两份小索引供探针优先查询。

#import <Foundation/Foundation.h>

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

// 拼音只留 a-z；空则丢弃。
static NSString *KBNormalizePinyin(NSString *pinyin) {
    NSMutableString *out = [NSMutableString string];
    NSString *lower = pinyin.lowercaseString;
    for (NSUInteger i = 0; i < lower.length; i++) {
        unichar c = [lower characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) [out appendFormat:@"%C", c];
    }
    return out;
}

NSUInteger KBRebuildCustomIndexes(NSString *keyboard, void (^log)(NSString *)) {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSString *jsonPath = [keyboard stringByAppendingPathComponent:@"custom.json"];
    NSData *data = [NSData dataWithContentsOfFile:jsonPath];
    NSArray *entries = nil;
    if (data) {
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if ([parsed isKindOfClass:[NSArray class]]) entries = parsed;
    }

    NSMutableArray<NSString *> *lines26 = [NSMutableArray array];
    NSMutableArray<NSString *> *lines9 = [NSMutableArray array];
    for (id item in entries) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *word = [item[@"word"] isKindOfClass:[NSString class]] ? item[@"word"] : nil;
        NSString *pinyin = [item[@"pinyin"] isKindOfClass:[NSString class]] ? item[@"pinyin"] : nil;
        NSString *key = KBNormalizePinyin(pinyin ?: @"");
        if (!word.length || !key.length) continue;
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
    [text26 writeToFile:[keyboard stringByAppendingPathComponent:@"custom26.tsv"]
             atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [text9 writeToFile:[keyboard stringByAppendingPathComponent:@"custom9.tsv"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    log([NSString stringWithFormat:@"custom entries=%lu", (unsigned long)lines26.count]);
    return lines26.count;
}
