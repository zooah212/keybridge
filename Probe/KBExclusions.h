#pragma once
#import <Foundation/Foundation.h>
#include <sys/stat.h>

// 路径及两份独立文件身份共同失效；不能用较新的一个 mtime 遮住另一个变化。
static inline BOOL KBRefreshExclusions(NSArray<NSString *> *paths, NSArray *__strong *previous,
                                        NSSet *__strong *wordsOut, NSSet *__strong *initialsOut) {
    NSMutableArray *identity = [NSMutableArray array];
    for (NSString *path in paths) {
        struct stat info;
        [identity addObject:stat(path.fileSystemRepresentation, &info) == 0
            ? @[path, @(info.st_ino), @(info.st_size), @(info.st_mtimespec.tv_sec), @(info.st_mtimespec.tv_nsec)]
            : @[path]];
    }
    if ([*previous isEqual:identity]) return NO;
    NSMutableSet *words = [NSMutableSet set], *initials = [NSMutableSet set];
    for (NSString *path in paths) {
        NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
        for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            NSString *word = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            while (word.length && ([word hasPrefix:@"#"] || [word hasPrefix:@"-"])) {
                word = [[word substringFromIndex:1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            }
            if (!word.length) continue;
            if ([word hasSuffix:@"@简"]) {
                word = [[word substringToIndex:word.length - 2] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                if (word.length) [initials addObject:word];
            } else {
                [words addObject:word];
            }
        }
    }
    *previous = [identity copy];
    *wordsOut = [words copy];
    *initialsOut = [initials copy];
    return YES;
}
