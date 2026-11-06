// 本地词库查询、词条编辑与保存；仅使用调用方指定的临时目录。
#import <Foundation/Foundation.h>
#import "../ImportPreferences/KBLibraryQuery.h"
#import "../Injector/KBCustomEntries.h"
#import "../Probe/KBExclusions.h"
#import "../ImportPreferences/KBSettingsModel.h"

static void KBCheck(BOOL ok, NSString *message) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
    printf("PASS: %s\n", message.UTF8String);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        for (NSArray *test in @[@[@0, @5], @[@(-1), @5], @[@1, @1], @[@4, @4],
                                @[@10, @10], @[@15, @15], @[@20, @20], @[@21, @5]]) {
            KBCheck(KBValidatedCandidateLimit([test[0] integerValue]) == [test[1] integerValue], @"候选数量边界与旧设置兼容");
        }
        KBCheck([KBCandidateLimitChoices() isEqual:(@[@5, @8, @10, @15, @20])], @"候选选择包含新增档位");
        for (NSArray *test in @[@[@0, @"0 条"], @[@103, @"103 条"], @[@9999, @"9999 条"],
                                @[@10000, @"10000 条"], @[@1938127, @"1938127 条"]]) {
            KBCheck([KBEntryCountText(test[0]) isEqual:test[1]], @"词库数量不换算或舍入");
        }
        KBCheck([KBEntryCountText(nil) isEqual:@"条数未记录"], @"缺少数量不冒充零条");
        KBCheck([KBSettingsSections() isEqual:(@[@(KBSectionSources), @(KBSectionLibraries), @(KBSectionOptions)])], @"主页面只保留本地开关、词库列表和功能分类");
        for (NSArray *test in @[@[@(KBSectionSources), @1], @[@(KBSectionOptions), @4],
                                @[@(KBSectionMessage), @1]]) {
            KBCheck(KBSectionRowCount([test[0] integerValue]) == [test[1] integerValue], @"初始功能区只显示四个收起的分类");
        }
        const KBSection categories[] = {KBSectionImport, KBSectionEntries, KBSectionDisplay, KBSectionFilters};
        const NSInteger counts[] = {7, 3, 2, 3};
        for (NSInteger group = 0; group < 4; group++) {
            KBSection expanded = categories[group];
            KBCheck(KBSettingsCategoryAtIndex(group) == expanded, @"分类顺序不变");
            KBCheck(KBSettingsCategoryRowCount(expanded) == counts[group], @"所有功能在分类内直接显示，位置操作不再嵌套");
            KBCheck(KBSettingsOptionRowCount(expanded) == 4 + counts[group], @"一次只展开一组");
            for (NSInteger i = 0; i < KBSettingsOptionRowCount(expanded); i++) {
                KBSettingsOptionRow row = KBSettingsOptionRowAtIndex(i, expanded);
                KBCheck(row.item == -1 || row.section == expanded, @"未选中的分类只有标题");
                KBCheck(KBSettingsOptionIndex(row.section, row.item, expanded) == i, @"展开后动作行及弹出位置映射一致");
            }
        }
        KBCheck(KBSettingsOptionRowAtIndex(-1, KBSectionOptions).item == -2, @"负行号无效");
        KBCheck(KBSettingsOptionRowAtIndex(4, KBSectionOptions).item == -2, @"收起后无第五行");
        KBCheck(KBSettingsOptionIndex(KBSectionDisplay, 1, KBSectionOptions) == NSNotFound, @"收起时没有隐藏的候选数量行");
        KBCheck(KBSectionRowCount(KBSectionLibraries) == 0, @"词库行数仍由已安装词库决定");
        KBCheck(argc == 2, @"指定隔离目录");
        NSString *root = [NSString stringWithUTF8String:argv[1]];
        KBCheck([root hasPrefix:@"Tests/.local-run-"], @"仅使用项目临时目录");
        NSString *index = [root stringByAppendingPathComponent:@"index26.tsv"];
        [@"ni\t你\t100\nni\t拟\t50\nnihao\t你好\t80\nzhong\t中\t20"
            writeToFile:index atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSString *failure = nil;
        NSArray *rows = KBLibraryQuery(index, @" NI ' ", 100, &failure);
        KBCheck(rows.count == 3 && !failure, @"大小写和分隔符规范化后的前缀查询");
        KBCheck([rows[0][@"word"] isEqual:@"你"] && [rows[2][@"pinyin"] isEqual:@"nihao"], @"显示索引词条及拼音");
        KBCheck(KBLibraryQuery(index, @"ni", 1, &failure).count == 1, @"限制返回数量");
        KBCheck(KBLibraryQuery(index, @"zhong", 100, &failure).count == 1, @"无末尾换行仍可查询");
        KBCheck(KBLibraryQuery(index, @"wo", 100, &failure).count == 0 && !failure, @"无命中与读取失败分开");
        KBCheck(KBLibraryQuery(index, @" ", 100, &failure) == nil && failure.length, @"空输入不匹配整库");
        KBCheck(KBLibraryQuery(index, @"你", 100, &failure) == nil && failure.length, @"拒绝非拼音输入");
        KBCheck(KBLibraryQuery([root stringByAppendingPathComponent:@"missing"], @"ni", 100, &failure) == nil && failure.length, @"缺少索引返回错误");
        KBCheck(KBLibraryQuery(index, @"ni", 100, &failure).count == 3 && !failure, @"成功查询不残留上次错误");

        NSArray *original = @[@{@"word": @"长大", @"pinyin": @"zhangda"}, @{@"word": @"长大", @"pinyin": @"changda"}];
        NSArray *edited = KBCustomEntriesByEditing(original, 0, @"桥接测试", @"qiao jie ce shi", &failure);
        KBCheck(edited.count == 2 && [edited[0][@"word"] isEqual:@"桥接测试"] && [edited[1] isEqual:original[1]], @"原位替换且不误删另一读音");
        KBCheck(KBCustomEntriesByEditing(original, 0, @" ", @"ni", &failure) == nil, @"空词不覆盖原条");
        KBCheck(KBCustomEntriesByEditing(original, 0, @"词", @"???", &failure) == nil, @"无有效编码不保存");
        KBCheck(KBCustomEntriesByEditing(original, 0, @"词\t条", @"ci", &failure) == nil, @"词条不能破坏 TSV 行结构");
        KBCheck(KBCustomEntriesByEditing(original, 2, @"新词", @"xin1ci", &failure).count == 3, @"新增保留旧数字编码兼容性");
        KBCheck([original[0][@"word"] isEqual:@"长大"], @"编辑不修改传入快照");
        NSString *(^JSON)(NSArray *) = ^NSString *(NSArray *entries) {
            return [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:entries options:0 error:NULL] encoding:NSUTF8StringEncoding];
        };
        NSUInteger count = 0;
        KBCheck(KBSaveCustomEntries(root, JSON(original), &count, &failure) && count == 2, @"首次保存双索引与 JSON");
        KBCheck(KBSaveCustomEntries(root, JSON(edited), &count, &failure), @"替换自定义词条");
        NSString *text = [NSString stringWithContentsOfFile:KBCustomFilePath(root, @"custom26.tsv") encoding:NSUTF8StringEncoding error:NULL];
        KBCheck([text containsString:@"qiaojieceshi\t桥接测试"] && ![text containsString:@"zhangda\t"], @"26 键索引移除旧拼音");
        text = [NSString stringWithContentsOfFile:KBCustomFilePath(root, @"custom9.tsv") encoding:NSUTF8StringEncoding error:NULL];
        KBCheck([text containsString:@"742654323744\t桥接测试"] && ![text containsString:@"9426432\t"], @"九宫格索引同步替换");
        NSData *saved = [NSData dataWithContentsOfFile:KBCustomFilePath(root, @"custom.json")];
        KBCheck(!KBSaveCustomEntries(root, @"not json", &count, &failure) && failure.length, @"坏数据不报保存成功");
        KBCheck([saved isEqual:[NSData dataWithContentsOfFile:KBCustomFilePath(root, @"custom.json")]], @"失败保留旧词条");
        NSString *blocked = [root stringByAppendingPathComponent:@"blocked"];
        [@"file" writeToFile:blocked atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        KBCheck(!KBSaveCustomEntries(blocked, JSON(edited), &count, &failure) && failure.length, @"无法创建暂存目录时报告失败");
        KBCheck(KBSaveCustomEntries(root, @"[]", &count, &failure) && count == 0, @"删除最后一条可发布空索引");
        KBCheck([[NSData dataWithContentsOfFile:KBCustomFilePath(root, @"custom26.tsv")] length] == 0, @"空列表不残留旧词");
        KBCheck(KBSaveCustomEntries(root, JSON(@[@{@"word": @"\t词\n", @"pinyin": @" ci "}]), &count, &failure), @"后台使用校验后的规范词条");
        text = [NSString stringWithContentsOfFile:KBCustomFilePath(root, @"custom26.tsv") encoding:NSUTF8StringEncoding error:NULL];
        KBCheck([text isEqual:@"ci\t词\t1000000\n"], @"首尾空白不能绕过校验破坏索引结构");
        NSString *global = [root stringByAppendingPathComponent:@"global-exclude.txt"];
        NSString *a = [root stringByAppendingPathComponent:@"a-exclude.txt"];
        NSString *b = [root stringByAppendingPathComponent:@"b-exclude.txt"];
        [@"全局词" writeToFile:global atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        [@"目标词\n简拼词@简" writeToFile:a atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        [@"另一个词" writeToFile:b atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSFileManager *manager = NSFileManager.defaultManager;
        [manager setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSince1970:100]} ofItemAtPath:global error:NULL];
        for (NSString *path in @[a, b]) [manager setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSince1970:90]} ofItemAtPath:path error:NULL];
        NSArray *identity = nil;
        NSSet *words = nil, *initials = nil;
        KBCheck(KBRefreshExclusions(@[global, a], &identity, &words, &initials) && [words containsObject:@"目标词"] && [initials containsObject:@"简拼词"], @"首次读取排除词及简拼规则");
        KBCheck(KBRefreshExclusions(@[global, b], &identity, &words, &initials) && ![words containsObject:@"目标词"] && [words containsObject:@"另一个词"] && [words containsObject:@"全局词"], @"全局时间更新时切库仍刷新排除规则");
        KBCheck(!KBRefreshExclusions(@[global, b], &identity, &words, &initials), @"文件未变时复用排除集合");
        [manager removeItemAtPath:b error:NULL];
        KBCheck(KBRefreshExclusions(@[global, b], &identity, &words, &initials) && ![words containsObject:@"另一个词"], @"删除库内规则不沿用旧集合");
    }
    return 0;
}
