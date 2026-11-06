// 词库转换：*.dict.yaml → index26（全拼）/ index9（九宫格）；每行 key<TAB>词<TAB>词频，按 key 排序。

#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <sys/stat.h>
#include <CoreFoundation/CoreFoundation.h>

// 只要简体中文：纯 ASCII 的词（I、IBM、IC）丢掉；含繁体的词也丢掉。
static BOOL KBIsChineseWord(const char *word) {
    for (const unsigned char *p = (const unsigned char *)word; *p; p++) {
        if (*p >= 0x80) return YES;
    }
    return NO;
}

static NSMutableDictionary<NSNumber *, NSNumber *> *KBCharMap;

// 导入选项与统计，由调用方在转换前设置。
static BOOL KBKeepTraditional;
static BOOL KBKeepASCII;
static NSUInteger KBDroppedTraditional;
static NSUInteger KBDroppedASCII;
static NSUInteger KBAccepted;
// 常用字白名单（词库自带的 8105 表）：表外生僻字、方言字整条丢弃。
static unsigned char KBCommonBits[8192];
static NSUInteger KBDroppedRare;

void KBSetCommonCharacter(const char *utf8) {
    // 只收 BMP；表外一律不要。
    unsigned int cp = 0;
    for (const unsigned char *p = (const unsigned char *)utf8; *p; ) {
        if (*p < 0x80) { cp = *p; p += 1; }
        else if ((*p & 0xE0) == 0xC0) { cp = ((unsigned int)(p[0] & 0x1F) << 6) | (p[1] & 0x3F); p += 2; }
        else if ((*p & 0xF0) == 0xE0) { cp = ((unsigned int)(p[0] & 0x0F) << 12) | ((unsigned int)(p[1] & 0x3F) << 6) | (p[2] & 0x3F); p += 3; }
        else { p += 1; continue; }
        if (cp < 0x10000) KBCommonBits[cp >> 3] |= (unsigned char)(1 << (cp & 7));
    }
}

void KBResetCommonCharacters(void) {
    memset(KBCommonBits, 0, sizeof(KBCommonBits));
    KBDroppedRare = 0;
}

static BOOL KBHasCommonCharacters(void) {
    for (NSUInteger i = 0; i < sizeof(KBCommonBits); i++) if (KBCommonBits[i]) return YES;
    return NO;
}

static BOOL KBWordUsesCommonChars(const char *word) {
    for (const unsigned char *p = (const unsigned char *)word; *p; ) {
        unsigned int cp = 0;
        if (*p < 0x80) { return NO; }
        if ((*p & 0xE0) == 0xC0) { cp = ((unsigned int)(p[0] & 0x1F) << 6) | (p[1] & 0x3F); p += 2; }
        else if ((*p & 0xF0) == 0xE0) { cp = ((unsigned int)(p[0] & 0x0F) << 12) | ((unsigned int)(p[1] & 0x3F) << 6) | (p[2] & 0x3F); p += 3; }
        else { return NO; }
        if (cp >= 0x10000) return NO;
        if (!(KBCommonBits[cp >> 3] & (1 << (cp & 7)))) return NO;
    }
    return YES;
}


void KBSetConvertOptions(BOOL keepTraditional, BOOL keepASCII) {
    KBKeepTraditional = keepTraditional;
    KBKeepASCII = keepASCII;
    KBDroppedTraditional = 0;
    KBDroppedASCII = 0;
    KBAccepted = 0;
}

// 用户手动排除的词：按词条全文匹配，一份都不进索引。
static NSSet<NSString *> *KBExcludedWords;
static NSUInteger KBDroppedExcluded;

void KBSetExcludedWords(NSSet<NSString *> *words) {
    KBExcludedWords = words.count ? [words copy] : nil;
    KBDroppedExcluded = 0;
}

NSUInteger KBGetDroppedRareCount(void) {
    return KBDroppedRare;
}

NSUInteger KBGetExcludedCount(void) {
    return KBDroppedExcluded;
}

void KBGetConvertStats(NSUInteger *accepted, NSUInteger *droppedTraditional, NSUInteger *droppedASCII) {
    if (accepted) *accepted = KBAccepted;
    if (droppedTraditional) *droppedTraditional = KBDroppedTraditional;
    if (droppedASCII) *droppedASCII = KBDroppedASCII;
}

static BOOL KBHasTraditionalCharacter(NSString *word) {
    if (!KBCharMap) KBCharMap = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < word.length; i++) {
        unichar c = [word characterAtIndex:i];
        if (c < 0x80) continue;
        NSNumber *key = @(c);
        NSNumber *mapped = KBCharMap[key];
        if (!mapped) {
            NSString *single = [NSString stringWithCharacters:&c length:1];
            NSMutableString *converted = [single mutableCopy];
            CFStringTransform((__bridge CFMutableStringRef)converted, NULL, CFSTR("Traditional-Simplified"), false);
            unichar result = converted.length ? [converted characterAtIndex:0] : c;
            mapped = @(result);
            KBCharMap[key] = mapped;
        }
        if (mapped.unsignedShortValue != c) return YES;
    }
    return NO;
}


typedef struct {
    char *key;
    size_t keyLength;
    char *line;
    long weight;
} KBConvertEntry;

static int KBEntryCompare(const void *a, const void *b) {
    const KBConvertEntry *x = a, *y = b;
    int order = strcmp(x->key, y->key);
    if (order != 0) return order;
    // 同一 key 内按词频降序：探针只扫前缀区前几千行，高频词必须排在前面。
    if (x->weight != y->weight) return x->weight > y->weight ? -1 : 1;
    return strcmp(x->line, y->line);
}

// 去声调：nǐ hǎo、ni3 hao3 都还原成拼音字母，ü 记作 v。
// ü 还原成 v（Rime 的习惯，九宫格映射里 v 归 8）。
static char KBUnaccent(unsigned int cp) {
    if ((cp >= 0x00C0 && cp <= 0x00C5) || cp == 0x0100 || cp == 0x0102 || cp == 0x0104) return 'a';
    if ((cp >= 0x00C8 && cp <= 0x00CB) || cp == 0x0112 || cp == 0x0114 || cp == 0x0116 ||
        cp == 0x0118 || cp == 0x011A) return 'e';
    if ((cp >= 0x00CC && cp <= 0x00CF) || cp == 0x012A || cp == 0x012C || cp == 0x012E ||
        cp == 0x01D0) return 'i';
    if ((cp >= 0x00D2 && cp <= 0x00D6) || cp == 0x00D8 || cp == 0x014C || cp == 0x014E ||
        cp == 0x0150 || cp == 0x01D2) return 'o';
    if ((cp >= 0x00D9 && cp <= 0x00DB) || cp == 0x016A || cp == 0x016C || cp == 0x016E ||
        cp == 0x0170 || cp == 0x01D4) return 'u';
    if (cp == 0x00DC || (cp >= 0x01D5 && cp <= 0x01DC) || cp == 0x00FC) return 'v';
    if ((cp >= 0x00E0 && cp <= 0x00E5) || cp == 0x0101 || cp == 0x0103 || cp == 0x0105) return 'a';
    if ((cp >= 0x00E8 && cp <= 0x00EB) || cp == 0x0113 || cp == 0x0115 || cp == 0x0117 ||
        cp == 0x0119 || cp == 0x011B) return 'e';
    if ((cp >= 0x00EC && cp <= 0x00EF) || cp == 0x012B || cp == 0x012D || cp == 0x012F ||
        cp == 0x01D0) return 'i';
    if ((cp >= 0x00F2 && cp <= 0x00F6) || cp == 0x00F8 || cp == 0x014D || cp == 0x014F ||
        cp == 0x0151 || cp == 0x01D2) return 'o';
    if ((cp >= 0x00F9 && cp <= 0x00FB) || cp == 0x016B || cp == 0x016D || cp == 0x016F ||
        cp == 0x0171 || cp == 0x01D4) return 'u';
    if (cp == 0x0144 || cp == 0x0148) return 'n';
    if (cp == 0x1E3F || cp == 0x1E3E) return 'm';
    return 0;
}

static void KBStripKey(char *key) {
    char *write = key;
    for (unsigned char *read = (unsigned char *)key; *read; ) {
        unsigned char c = *read;
        if (c == ' ' || c == '\'' || c == '\t') { read++; continue; }
        if (c < 0x80) {
            // 声调数字（ni3 hao3）直接去掉。
            if (c >= '0' && c <= '9') { read++; continue; }
            *write++ = (char)((c >= 'A' && c <= 'Z') ? c - 'A' + 'a' : c);
            read++;
            continue;
        }
        if ((c & 0xE0) == 0xC0 && read[1]) {
            unsigned int cp = ((unsigned int)(c & 0x1F) << 6) | (read[1] & 0x3F);
            read += 2;
            char mapped = KBUnaccent(cp);
            if (mapped) *write++ = mapped;
            continue;
        }
        if ((c & 0xF0) == 0xE0) { read += 3; continue; }
        if ((c & 0xF8) == 0xF0) { read += 4; continue; }
        read++;
    }
    *write = '\0';
}

static char KBLetterToDigit(char c) {
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

// 只收主词典 import_tables 声明的表；旁边的繁体表、形码表、英文表都不要。
// 主词典：优先认正式入口（rime_ice / rime_frost / rime_mint），
// 否则挑 import_tables 最多的那份（英文表只有 2 条，正式入口几十条）。
static NSUInteger KBImportTableCount(NSString *path) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return 0;
    NSData *head = [handle readDataOfLength:262144];
    [handle closeFile];
    NSString *text = [[NSString alloc] initWithData:head encoding:NSUTF8StringEncoding];
    if (![text containsString:@"import_tables:"]) return 0;
    NSUInteger count = 0;
    BOOL inImports = NO;
    for (NSString *rawLine in [text componentsSeparatedByString:@"\n"]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([line hasPrefix:@"import_tables:"]) { inImports = YES; continue; }
        if (!inImports) continue;
        if ([line hasPrefix:@"#"]) continue;
        if (![line hasPrefix:@"-"]) break;
        count++;
    }
    return count;
}

static NSString *KBFindMainDictionary(NSString *directory) {
    NSFileManager *manager = [NSFileManager defaultManager];
    NSArray<NSString *> *names = [[manager contentsOfDirectoryAtPath:directory error:NULL]
        filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *name, NSDictionary *bindings) {
            return [name hasSuffix:@".dict.yaml"];
        }]];
    names = [names sortedArrayUsingSelector:@selector(compare:)];
    NSArray<NSString *> *preferred = @[@"rime_ice.dict.yaml", @"rime_frost.dict.yaml", @"rime_mint.dict.yaml"];
    for (NSString *wanted in preferred) {
        if (![names containsObject:wanted]) continue;
        if (KBImportTableCount([directory stringByAppendingPathComponent:wanted]) > 0) return wanted;
    }
    NSString *best = nil;
    NSUInteger bestCount = 0;
    for (NSString *name in names) {
        NSUInteger count = KBImportTableCount([directory stringByAppendingPathComponent:name]);
        if (count > bestCount) { bestCount = count; best = name; }
    }
    return best;
}

static NSSet<NSString *> *KBReadImports(NSString *rootDictionary) {
    NSString *text = [NSString stringWithContentsOfFile:rootDictionary encoding:NSUTF8StringEncoding error:NULL];
    if (!text) return nil;
    NSMutableSet<NSString *> *imports = [NSMutableSet set];
    BOOL inImports = NO;
    for (NSString *rawLine in [text componentsSeparatedByString:@"\n"]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (line.length == 0) continue;
        if ([line hasPrefix:@"import_tables:"]) { inImports = YES; continue; }
        if (inImports) {
            if ([line hasPrefix:@"#"]) continue; // 注释掉的表不算，也别因此停
            if (![line hasPrefix:@"-"]) break;
            NSString *name = [[line substringFromIndex:1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            name = [[name componentsSeparatedByString:@"#"] firstObject];
            name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (name.length) [imports addObject:name];
        }
    }
    return imports.count ? imports : nil;
}

static NSUInteger KBConvertFile(const char *path, FILE *out26, FILE *out9);

// 调试用：把每个词典文件读出来的条数写进日志，定位「为什么只进了英文」。
static void (^KBDebugLogBlock)(NSString *);

void KBSetDebugLog(void (^log)(NSString *)) {
    KBDebugLogBlock = [log copy];
}

static void KBDebugLog(NSString *message) {
    if (KBDebugLogBlock) KBDebugLogBlock(message);
}

static void KBWalk(const char *directory, const char *base, NSSet<NSString *> *allowed, NSString *mainName, FILE *out26, FILE *out9) {
    DIR *dir = opendir(directory);
    if (!dir) return;
    struct dirent *entry;
    while ((entry = readdir(dir))) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) continue;
        char path[PATH_MAX];
        snprintf(path, sizeof(path), "%s/%s", directory, entry->d_name);
        struct stat info;
        if (stat(path, &info) != 0) continue;
        if (S_ISDIR(info.st_mode)) {
            KBWalk(path, base, allowed, mainName, out26, out9);
            continue;
        }
        size_t length = strlen(entry->d_name);
        if (length <= 10 || strcmp(entry->d_name + length - 10, ".dict.yaml") != 0) continue;
        if (allowed) {
            size_t baseLength = strlen(base);
            const char *relative = path + (baseLength < strlen(path) ? baseLength : 0);
            if (*relative == '/') relative++;
            NSString *name = [NSString stringWithUTF8String:relative];
            if (name.length > 10) name = [name substringToIndex:name.length - 10];
            if (![allowed containsObject:name] && ![name isEqualToString:mainName ?: @"rime_ice"]) continue;
        }
        NSUInteger produced = KBConvertFile(path, out26, out9);
        KBDebugLog([NSString stringWithFormat:@"file=%s produced=%lu", path, (unsigned long)produced]);
    }
    closedir(dir);
}

static NSUInteger KBConvertFile(const char *path, FILE *out26, FILE *out9) {
    NSUInteger produced = 0;
    FILE *file = fopen(path, "r");
    if (!file) return 0;
    char *line = NULL;
    size_t capacity = 0;
    ssize_t length = 0;
    BOOL inBody = NO;
    while ((length = getline(&line, &capacity, file)) > 0) {
        while (length > 0 && (line[length - 1] == '\n' || line[length - 1] == '\r')) line[--length] = '\0';
        if (!inBody) {
            if (strcmp(line, "...") == 0) inBody = YES;
            continue;
        }
        if (length == 0) continue;
        if (line[0] == '#') continue;
        char *word = line;
        char *code = strchr(word, '\t');
        if (!code) continue;
        *code++ = '\0';
        char *weight = strchr(code, '\t');
        if (weight) *weight++ = '\0';
        if (*word == '\0' || *code == '\0') continue;
        KBStripKey(code);
        if (*code == '\0') continue;
        // 有的词表是「词<TAB>数字」两列，数字会被当成拼音；拼音只能是 a-z。
        BOOL validCode = YES;
        for (const char *p = code; *p; p++) {
            if (*p < 'a' || *p > 'z') { validCode = NO; break; }
        }
        if (!validCode) continue;
        if (!KBIsChineseWord(word)) {
            KBDroppedASCII++;
            if (!KBKeepASCII) continue;
        } else {
            NSString *wordString = [NSString stringWithUTF8String:word];
            if (!wordString.length) continue;
            if (KBHasTraditionalCharacter(wordString)) {
                KBDroppedTraditional++;
                if (!KBKeepTraditional) continue;
            }
            if (KBExcludedWords && [KBExcludedWords containsObject:wordString]) {
                KBDroppedExcluded++;
                continue;
            }
        }
        if (KBIsChineseWord(word) && KBHasCommonCharacters() && !KBWordUsesCommonChars(word)) {
            KBDroppedRare++;
            continue;
        }
        KBAccepted++;
        produced++;
        // 26 键索引
        fprintf(out26, "%s\t%s\t%s\n", code, word, weight ? weight : "0");
        // 九宫格索引
        char digits[128];
        size_t n = 0;
        for (const char *p = code; *p && n + 1 < sizeof(digits); p++) {
            char digit = KBLetterToDigit(*p);
            if (digit) digits[n++] = digit;
        }
        digits[n] = '\0';
        if (n > 0) fprintf(out9, "%s\t%s\t%s\n", digits, word, weight ? weight : "0");
    }
    free(line);
    fclose(file);
    return produced;
}

// 分桶排序：整份索引一次读进内存会被系统杀掉（几十 MB + 上百万条目），
// 所以先按首字符写到 37 个桶文件，再逐个桶排序写出，内存只跟最大的桶有关。
static BOOL KBSortAndWrite(FILE *source, NSString *destinationPath, NSString *bucketDirectory) {
    // 先写 .tmp 再改名：探针只会看到完整的旧索引或新索引。
    NSString *temporaryPath = [destinationPath stringByAppendingPathExtension:@"tmp"];
    fflush(source);
    rewind(source);
    enum { KBBucketCount = 37 };
    FILE *buckets[KBBucketCount];
    NSMutableArray<NSString *> *bucketPaths = [NSMutableArray array];
    for (int i = 0; i < KBBucketCount; i++) {
        NSString *path = [bucketDirectory stringByAppendingPathComponent:
                          [NSString stringWithFormat:@".bucket.%d", i]];
        [bucketPaths addObject:path];
        buckets[i] = fopen(path.UTF8String, "w+");
        if (!buckets[i]) {
            for (int j = 0; j < i; j++) fclose(buckets[j]);
            return NO;
        }
    }

    char *line = NULL;
    size_t capacity = 0;
    ssize_t length = 0;
    size_t total = 0;
    while ((length = getline(&line, &capacity, source)) > 0) {
        unsigned char first = (unsigned char)line[0];
        int bucket = KBBucketCount - 1;
        if (first >= '0' && first <= '9') bucket = first - '0';
        else if (first >= 'a' && first <= 'z') bucket = 10 + (first - 'a');
        fwrite(line, 1, (size_t)length, buckets[bucket]);
        total++;
    }
    free(line);
    if (total == 0) {
        for (int i = 0; i < KBBucketCount; i++) { fclose(buckets[i]); [[NSFileManager defaultManager] removeItemAtPath:bucketPaths[i] error:NULL]; }
        return NO;
    }

    FILE *output = fopen(temporaryPath.UTF8String, "w");
    if (!output) {
        for (int i = 0; i < KBBucketCount; i++) { fclose(buckets[i]); [[NSFileManager defaultManager] removeItemAtPath:bucketPaths[i] error:NULL]; }
        return NO;
    }
    for (int i = 0; i < KBBucketCount; i++) {
        FILE *bucket = buckets[i];
        fflush(bucket);
        long size = ftell(bucket);
        if (size <= 0) continue;
        rewind(bucket);
        char *data = malloc((size_t)size);
        if (!data) continue;
        if (fread(data, 1, (size_t)size, bucket) != (size_t)size) { free(data); continue; }
        size_t count = 0;
        for (long k = 0; k < size; k++) if (data[k] == '\n') count++;
        KBConvertEntry *entries = calloc(count ? count : 1, sizeof(KBConvertEntry));
        if (!entries) { free(data); continue; }
        size_t index = 0;
        char *cursor = data;
        char *end = data + size;
        while (cursor < end && index < count) {
            char *next = memchr(cursor, '\n', (size_t)(end - cursor));
            if (!next) break;
            *next = '\0';
            char *tab = strchr(cursor, '\t');
            if (tab) {
                *tab = '\0';
                entries[index].key = cursor;
                entries[index].keyLength = (size_t)(tab - cursor);
                entries[index].line = cursor;
                // 词频在最后一个 tab 之后。
                char *lastTab = strrchr(tab + 1, '\t');
                entries[index].weight = lastTab ? strtol(lastTab + 1, NULL, 10) : 0;
                index++;
            }
            cursor = next + 1;
        }
        qsort(entries, index, sizeof(KBConvertEntry), KBEntryCompare);
        for (size_t k = 0; k < index; k++) {
            entries[k].line[entries[k].keyLength] = '\t';
            fputs(entries[k].line, output);
            fputc('\n', output);
        }
        free(entries);
        free(data);
    }
    for (int i = 0; i < KBBucketCount; i++) {
        fclose(buckets[i]);
        [[NSFileManager defaultManager] removeItemAtPath:bucketPaths[i] error:NULL];
    }
    if (fclose(output) != 0) {
        [[NSFileManager defaultManager] removeItemAtPath:temporaryPath error:NULL];
        return NO;
    }
    if (rename(temporaryPath.UTF8String, destinationPath.UTF8String) != 0) {
        [[NSFileManager defaultManager] removeItemAtPath:temporaryPath error:NULL];
        return NO;
    }
    return YES;
}

// 找词库自带的「8105 通用规范汉字表」，拿它当常用字白名单；找不到就不过滤。
static NSString *KBFindCommonTable(NSString *root) {
    NSDirectoryEnumerator<NSString *> *walker = [[NSFileManager defaultManager] enumeratorAtPath:root];
    for (NSString *relative in walker) {
        if ([relative.lastPathComponent hasSuffix:@"8105.dict.yaml"]) {
            return [root stringByAppendingPathComponent:relative];
        }
    }
    return nil;
}

static BOOL KBCommonOnly = YES;

void KBSetCommonOnly(BOOL on) {
    KBCommonOnly = on;
}

static void KBLoadCommonTable(NSString *root) {
    KBResetCommonCharacters();
    if (!KBCommonOnly) return;
    NSString *path = KBFindCommonTable(root);
    if (!path) return;
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
    BOOL inBody = NO;
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (!inBody) { if ([line hasPrefix:@"..."]) inBody = YES; continue; }
        NSArray<NSString *> *fields = [line componentsSeparatedByString:@"\t"];
        NSString *word = fields.firstObject;
        if (word.length) KBSetCommonCharacter(word.UTF8String);
    }
    KBDebugLog([NSString stringWithFormat:@"common-table=%@", path.lastPathComponent]);
}

BOOL KBConvertDictionaries(NSString *incomingDirectory, NSString *destinationDirectory, void (^log)(NSString *)) {
    [[NSFileManager defaultManager] createDirectoryAtPath:destinationDirectory
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    KBLoadCommonTable(incomingDirectory);
    NSString *work26 = [destinationDirectory stringByAppendingPathComponent:@".work26"];
    NSString *work9 = [destinationDirectory stringByAppendingPathComponent:@".work9"];
    FILE *out26 = fopen(work26.UTF8String, "w+");
    FILE *out9 = fopen(work9.UTF8String, "w+");
    if (!out26 || !out9) {
        if (out26) fclose(out26);
        if (out9) fclose(out9);
        log(@"cannot open work files");
        return NO;
    }
    NSString *mainDictionary = KBFindMainDictionary(incomingDirectory);
    NSString *rootDictionary = mainDictionary ? [incomingDirectory stringByAppendingPathComponent:mainDictionary] : nil;
    NSSet<NSString *> *allowed = KBReadImports(rootDictionary);
    log([NSString stringWithFormat:@"imports=%@", allowed ? [[allowed allObjects] componentsJoinedByString:@","] : @"(all)"]);
    KBDebugLog([NSString stringWithFormat:@"main=%@ imports=%@", mainDictionary ?: @"(none)", allowed ? [[[allowed allObjects] sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","] : @"(all)"]);
    NSString *mainName = mainDictionary ? [mainDictionary substringToIndex:mainDictionary.length - 10] : nil;
    log([NSString stringWithFormat:@"main=%@", mainDictionary ?: @"(none)"]);
    KBWalk(incomingDirectory.UTF8String, incomingDirectory.UTF8String, allowed, mainName, out26, out9);
    long size26 = ftell(out26);
    long size9 = ftell(out9);
    if (size26 <= 0) {
        fclose(out26);
        fclose(out9);
        [[NSFileManager defaultManager] removeItemAtPath:work26 error:NULL];
        [[NSFileManager defaultManager] removeItemAtPath:work9 error:NULL];
        log(@"no entries");
        return NO;
    }
    NSString *index26 = [destinationDirectory stringByAppendingPathComponent:@"index26.tsv"];
    NSString *index9 = [destinationDirectory stringByAppendingPathComponent:@"index9.tsv"];
    BOOL ok26 = KBSortAndWrite(out26, index26, destinationDirectory);
    BOOL ok9 = KBSortAndWrite(out9, index9, destinationDirectory);
    fclose(out26);
    fclose(out9);
    [[NSFileManager defaultManager] removeItemAtPath:work26 error:NULL];
    [[NSFileManager defaultManager] removeItemAtPath:work9 error:NULL];
    log([NSString stringWithFormat:@"index26=%d(%.1f MB) index9=%d(%.1f MB)", ok26, size26 / 1048576.0, ok9, size9 / 1048576.0]);
    return ok26 && ok9;
}
