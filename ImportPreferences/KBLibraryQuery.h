#pragma once
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// 库内前缀检索，不混入自定义词，也不模拟键盘候选排序。
static inline NSArray<NSDictionary *> *KBLibraryQuery(NSString *path, NSString *input,
                                                       NSUInteger limit, NSString **failure) {
    if (failure) *failure = nil;
    NSMutableString *key = [NSMutableString string];
    NSString *lower = input.lowercaseString;
    for (NSUInteger i = 0; i < lower.length; i++) {
        unichar c = [lower characterAtIndex:i];
        if (c == '\'' || [NSCharacterSet.whitespaceAndNewlineCharacterSet characterIsMember:c]) continue;
        if (c == 0x00FC) c = 'v';
        if (c < 'a' || c > 'z') {
            if (failure) *failure = @"请输入拼音字母，ü 可写为 v。";
            return nil;
        }
        [key appendFormat:@"%C", c];
    }
    if (!key.length || !limit) {
        if (failure) *failure = @"请输入要查询的拼音。";
        return nil;
    }
    FILE *file = fopen(path.fileSystemRepresentation, "r");
    if (!file) {
        if (failure) *failure = @"无法读取词库索引，请返回后重新选择词库。";
        return nil;
    }
    const char *prefix = key.UTF8String;
    size_t prefixLength = strlen(prefix), capacity = 0;
    char *line = NULL;
    ssize_t length;
    NSMutableArray *rows = [NSMutableArray array];
    while (rows.count < limit && (length = getline(&line, &capacity, file)) > 0) {
        @autoreleasepool {
            char *tab = memchr(line, '\t', (size_t)length);
            if (!tab) continue;
            int order = strncmp(line, prefix, prefixLength);
            if (order > 0) break;
            if (order < 0 || (size_t)(tab - line) < prefixLength) continue;
            char *wordEnd = memchr(tab + 1, '\t', (size_t)(line + length - tab - 1));
            if (!wordEnd) continue;
            NSString *word = [[NSString alloc] initWithBytes:tab + 1 length:(NSUInteger)(wordEnd - tab - 1) encoding:NSUTF8StringEncoding];
            NSString *pinyin = [[NSString alloc] initWithBytes:line length:(NSUInteger)(tab - line) encoding:NSUTF8StringEncoding];
            if (!word.length || !pinyin.length) continue;
            [rows addObject:@{@"word": word, @"pinyin": pinyin}];
        }
    }
    BOOL ok = !ferror(file);
    free(line);
    fclose(file);
    if (!ok) {
        if (failure) *failure = @"读取词库失败，请重试。";
        return nil;
    }
    return rows;
}
