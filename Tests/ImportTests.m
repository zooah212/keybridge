// 在项目临时目录运行实际导入函数，不访问设备词库、不启动守护进程。
#define main KBUnusedDaemonMain
#include "../Injector/KeyBridgeInjector.m"
#undef main
#include <zlib.h>

static void Check(BOOL ok, NSString *message) {
    if (!ok) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
    printf("PASS: %s\n", message.UTF8String);
}
static void Put(NSMutableData *data, uint32_t value, unsigned bytes) {
    for (unsigned i = 0; i < bytes; i++) { uint8_t b = value >> (8 * i); [data appendBytes:&b length:1]; }
}
static void MakeZip(NSString *path, NSString *text) {
    NSData *name = [@"test.dict.yaml" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *body = [text dataUsingEncoding:NSUTF8StringEncoding];
    uint32_t crc = (uint32_t)crc32(0, body.bytes, (uInt)body.length);
    NSMutableData *zip = [NSMutableData data];
    Put(zip, 0x04034b50, 4); Put(zip, 20, 2);
    for (int i = 0; i < 4; i++) Put(zip, 0, 2);
    Put(zip, crc, 4); Put(zip, (uint32_t)body.length, 4); Put(zip, (uint32_t)body.length, 4);
    Put(zip, (uint32_t)name.length, 2); Put(zip, 0, 2); [zip appendData:name]; [zip appendData:body];
    uint32_t central = (uint32_t)zip.length;
    Put(zip, 0x02014b50, 4); Put(zip, 20, 2); Put(zip, 20, 2);
    for (int i = 0; i < 4; i++) Put(zip, 0, 2);
    Put(zip, crc, 4); Put(zip, (uint32_t)body.length, 4); Put(zip, (uint32_t)body.length, 4);
    Put(zip, (uint32_t)name.length, 2);
    for (int i = 0; i < 4; i++) Put(zip, 0, 2);
    Put(zip, 0, 4); Put(zip, 0, 4); [zip appendData:name];
    uint32_t centralSize = (uint32_t)zip.length - central;
    Put(zip, 0x06054b50, 4); Put(zip, 0, 2); Put(zip, 0, 2); Put(zip, 1, 2); Put(zip, 1, 2);
    Put(zip, centralSize, 4); Put(zip, central, 4); Put(zip, 0, 2);
    Check([zip writeToFile:path atomically:YES], @"创建测试 ZIP");
}
static NSDictionary *ReadJSON(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
}
int main(int argc, char **argv) {
    @autoreleasepool {
        Check(argc == 2, @"指定隔离测试目录");
        NSString *root = [NSString stringWithUTF8String:argv[1]];
        Check([root hasPrefix:@"Tests/.run-"], @"测试路径限制在项目内");
        KBInjectorLog = os_log_create("com.wm0104.keybridge.tests", "import");
        NSString *keyboard = [root stringByAppendingPathComponent:@"keyboard"];
        KBEnsureDirectory(KBLibrariesDirectory(keyboard));
        NSString *source = [root stringByAppendingPathComponent:@"input.zip"];
        NSDictionary *prefs = @{@"commonOnly": @NO};
        NSMutableArray *trace = [NSMutableArray array];
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        MakeZip(source, @"---\nname: test\nversion: '1'\n...\n你好\tni hao\t100\n");
        double stamp = [NSDate date].timeIntervalSince1970;
        KBTaskBegin(keyboard, result, stamp);
        Check(KBInstallZip(keyboard, source, @"测试.zip", prefs, trace, result, YES), @"首次导入生成双索引并发布");
        NSString *library = [KBLibrariesDirectory(keyboard) stringByAppendingPathComponent:@"测试"];
        NSString *index = [library stringByAppendingPathComponent:@"index26.tsv"];
        NSData *original = [NSData dataWithContentsOfFile:index];
        Check(original.length > 0 && [KBReadActiveLibrary(keyboard) isEqualToString:@"测试"], @"成功后激活词库");
        KBWriteSummary(result, keyboard);
        Check([ReadJSON([keyboard stringByAppendingPathComponent:@"last-import.json"])[@"requestAt"] doubleValue] == stamp, @"请求标识往返一致");
        Check(![ReadJSON([keyboard stringByAppendingPathComponent:@"import-task.json"])[@"running"] boolValue], @"完成后停止心跳任务");
        [@"not a zip" writeToFile:source atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        Check(!KBInstallZip(keyboard, source, @"测试.zip", prefs, trace, result, YES), @"拒绝错误下载内容");
        Check([original isEqual:[NSData dataWithContentsOfFile:index]], @"坏包不破坏原索引");
        MakeZip(source, @"---\nname: test\n...\n");
        Check(!KBInstallZip(keyboard, source, @"测试.zip", prefs, trace, result, YES), @"拒绝无有效词条的 ZIP");
        Check([original isEqual:[NSData dataWithContentsOfFile:index]], @"转换失败保留旧索引");
        [@"无关词" writeToFile:[library stringByAppendingPathComponent:@"exclude.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        MakeZip(source, @"---\nname: test\nversion: '2'\n...\n修复\txiu fu\t100\n");
        Check(KBInstallZip(keyboard, source, @"测试.zip", prefs, trace, result, YES), @"同名词库原子替换成功");
        Check(![original isEqual:[NSData dataWithContentsOfFile:index]], @"替换后读取新索引");
        Check([[NSFileManager defaultManager] fileExistsAtPath:[library stringByAppendingPathComponent:@"exclude.txt"]], @"替换保留排除规则");
        Check([[[NSFileManager defaultManager] contentsOfDirectoryAtPath:KBLibrariesDirectory(keyboard) error:NULL] count] == 1, @"成功失败均无临时词库残留");
        NSString *scanZip = [KBLibrariesDirectory(keyboard) stringByAppendingPathComponent:@"扫描.zip"];
        MakeZip(scanZip, @"---\nname: test\n...\n扫描\tsao miao\t100\n");
        NSString *badZip = [KBLibrariesDirectory(keyboard) stringByAppendingPathComponent:@"错误.zip"];
        [@"bad zip" writeToFile:badZip atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        result = [NSMutableDictionary dictionary];
        KBScanLibraries(keyboard, prefs, result);
        Check([KBReadActiveLibrary(keyboard) isEqual:@"测试"], @"扫描不切换当前词库");
        Check([result[@"installed"] integerValue] == 1 && [result[@"failed"] integerValue] == 1 && ![result[@"ok"] boolValue], @"扫描如实汇总部分失败");
        KBWriteActiveLibrary(keyboard, nil);
        Check([[NSFileManager defaultManager] fileExistsAtPath:KBActivePath(keyboard)], @"空选择持久化，不能被启动恢复覆盖");
        MakeZip(scanZip, @"---\nname: test\n...\n扫描\tsao miao\t100\n");
        KBScanLibraries(keyboard, prefs, [NSMutableDictionary dictionary]);
        Check(KBReadActiveLibrary(keyboard).length == 0, @"扫描保留明确的空选择");
        NSString *manual = [KBLibrariesDirectory(keyboard) stringByAppendingPathComponent:@"手动词库"];
        KBEnsureDirectory(manual);
        [@"---\nname: test\n...\n测试\tce shi\t100\n" writeToFile:[manual stringByAppendingPathComponent:@"test.dict.yaml"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSString *blockedIndex = [manual stringByAppendingPathComponent:@"index9.tsv"];
        KBEnsureDirectory(blockedIndex);
        result = [NSMutableDictionary dictionary];
        KBScanLibraries(keyboard, prefs, result);
        Check(![result[@"ok"] boolValue] && [result[@"failed"] integerValue] == 1 && [result[@"converted"] integerValue] == 0, @"九宫格索引发布失败不能报转换成功");
        Check(![[NSFileManager defaultManager] fileExistsAtPath:[manual stringByAppendingPathComponent:@"index26.tsv"]], @"失败不留下会被误判完成的半份新索引");
        [[NSFileManager defaultManager] removeItemAtPath:blockedIndex error:NULL];
        result = [NSMutableDictionary dictionary];
        KBScanLibraries(keyboard, prefs, result);
        Check([result[@"ok"] boolValue] && [result[@"converted"] integerValue] == 1, @"移除阻挡文件后可重新扫描成功");
        puts("Import regression tests passed.");
    }
    return 0;
}
