#pragma once
#import <Foundation/Foundation.h>

// 新保存采用整目录发布；升级前的根目录文件保持只读兼容。
static inline NSString *KBCustomFilePath(NSString *keyboard, NSString *name) {
    NSString *directory = [keyboard stringByAppendingPathComponent:@"custom"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:directory]) directory = keyboard;
    return [directory stringByAppendingPathComponent:name];
}

static inline NSString *KBNormalizeCustomPinyin(NSString *pinyin) {
    NSMutableString *key = [NSMutableString string];
    NSString *lower = pinyin.lowercaseString;
    for (NSUInteger i = 0; i < lower.length; i++) {
        unichar c = [lower characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) [key appendFormat:@"%C", c];
    }
    return key;
}

static inline NSArray *KBCustomEntriesByEditing(NSArray *entries, NSUInteger index,
                                                NSString *word, NSString *pinyin, NSString **failure) {
    if (failure) *failure = nil;
    word = [word stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    pinyin = [pinyin stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSCharacterSet *lineBreaks = [NSCharacterSet characterSetWithCharactersInString:@"\t\r\n"];
    if (!word.length || !KBNormalizeCustomPinyin(pinyin).length ||
        [word rangeOfCharacterFromSet:lineBreaks].location != NSNotFound || index > entries.count) {
        if (failure) *failure = @"请填写词语和有效拼音，词语不能包含换行或制表符。";
        return nil;
    }
    NSMutableArray *result = [entries mutableCopy];
    NSDictionary *entry = @{@"word": word, @"pinyin": pinyin};
    if (index == result.count) [result addObject:entry];
    else result[index] = entry;
    return result;
}

BOOL KBSaveCustomEntries(NSString *keyboard, NSString *json, NSUInteger *count, NSString **failure);
