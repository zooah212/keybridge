// 设置面板：词库、导入、自定义词条与开关。面板写不了 Keyboard 目录，动作都交给守护进程。

#import <Preferences/PSViewController.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>
#import <CommonCrypto/CommonDigest.h>

static NSString *const KBDefaultsSuite = @"com.wm0104.keybridge";
static NSString *const KBKeyTraditional = @"includeTraditional";
static NSString *const KBKeyASCII = @"includeASCII";
static NSString *const KBKeyboardDirectory = @"/var/mobile/Library/Keyboard/KeyBridge";

#pragma mark - 数据

@interface KBLibrary : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) NSInteger accepted;
@property (nonatomic) NSInteger droppedTraditional;
@property (nonatomic) NSInteger droppedASCII;
@property (nonatomic) NSInteger excluded;
@property (nonatomic) NSInteger droppedRare;
@property (nonatomic) BOOL active;
@end

@implementation KBLibrary
@end

#pragma mark - 排除词条
// 每行一个排除词；保存后守护进程写 exclude.txt 并重建这份词库。
@interface KBExcludeListController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSString *libraryName;
@property (nonatomic, copy) NSArray<NSString *> *entries;
@property (nonatomic, copy) void (^onSave)(NSArray<NSString *> *entries);
@property (nonatomic, strong) UITableView *tableView;
@end
// 每行一个词条，最后一列是「添加」；长按删除。
@interface KBCustomController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSArray<NSDictionary *> *entries;
@property (nonatomic, copy) void (^onSave)(NSArray<NSDictionary *> *entries);
@property (nonatomic, strong) UITableView *tableView;
@end

@interface KBImportController : PSViewController <UIDocumentPickerDelegate, UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<KBLibrary *> *libraries;
@property (nonatomic, strong) UISwitch *traditionalSwitch;
@property (nonatomic, strong) UISwitch *asciiSwitch;
@property (nonatomic, strong) UISwitch *lexiconOnlySwitch;
@property (nonatomic, strong) UISwitch *commonOnlySwitch;
@property (nonatomic, copy) NSString *statusText;
@property (nonatomic) BOOL busy;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, strong) NSTimer *statusTimer;
@property (nonatomic, strong) NSArray<NSDictionary *> *customEntries;
@property (nonatomic) NSInteger candidateLimit;
@property (nonatomic) NSTimeInterval requestTime;
@end

@implementation KBImportController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"词库桥接";
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]]];

    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:KBDefaultsSuite];
    self.traditionalSwitch = [UISwitch new];
    self.traditionalSwitch.on = [defaults boolForKey:KBKeyTraditional];
    [self.traditionalSwitch addTarget:self action:@selector(optionChanged:) forControlEvents:UIControlEventValueChanged];
    self.asciiSwitch = [UISwitch new];
    self.asciiSwitch.on = [defaults boolForKey:KBKeyASCII];
    [self.asciiSwitch addTarget:self action:@selector(optionChanged:) forControlEvents:UIControlEventValueChanged];
    NSInteger limit = [defaults integerForKey:@"candidateLimit"];
    self.candidateLimit = (limit >= 1 && limit <= 10) ? limit : 5;
    self.lexiconOnlySwitch = [UISwitch new];
    self.commonOnlySwitch = [UISwitch new];
    self.commonOnlySwitch.on = [defaults objectForKey:@"commonOnly"] ? [defaults boolForKey:@"commonOnly"] : YES;
    [self.commonOnlySwitch addTarget:self action:@selector(optionChanged:) forControlEvents:UIControlEventValueChanged];
    self.lexiconOnlySwitch.on = [defaults boolForKey:@"lexiconOnly"];
    [self.lexiconOnlySwitch addTarget:self action:@selector(optionChanged:) forControlEvents:UIControlEventValueChanged];

    UIRefreshControl *refresh = [UIRefreshControl new];
    [refresh addTarget:self action:@selector(refreshPulled:) forControlEvents:UIControlEventValueChanged];
    self.tableView.refreshControl = refresh;

    [self reloadLibraries];
}

- (void)refreshPulled:(UIRefreshControl *)control {
    if (self.busy) {
        [control endRefreshing];
        [self pollOnce];
        return;
    }
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:KBDefaultsSuite];
    NSTimeInterval stamp = [NSDate date].timeIntervalSince1970;
    [defaults setDouble:stamp forKey:@"scanAt"];
    [defaults setDouble:stamp forKey:@"requestStamp"];
    [defaults synchronize];
    [self reloadLibraries];
    [control endRefreshing];
    [self beginBusy:@"正在检查手动放入的文件…" stamp:stamp];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:KBDefaultsSuite];
    NSTimeInterval pending = [defaults doubleForKey:@"uiPendingRequest"];
    if (pending > 0) {
        [self beginBusy:@"正在检查导入进度…" stamp:pending];
        [self pollOnce];
    } else if (!self.busy) {
        self.statusText = nil;
    }
    [self reloadLibraries];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.pollTimer invalidate];
    self.pollTimer = nil;
}

#pragma mark - 数据加载

- (NSString *)activeLibraryName {
    NSString *name = [NSString stringWithContentsOfFile:[KBKeyboardDirectory stringByAppendingPathComponent:@"active"]
                                              encoding:NSUTF8StringEncoding error:NULL];
    return [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

- (NSString *)activeLibraryPath {
    NSString *active = [self activeLibraryName];
    if (!active.length) return nil;
    return [[KBKeyboardDirectory stringByAppendingPathComponent:@"libs"] stringByAppendingPathComponent:active];
}

// 自定义词条：custom.json 里的「词 + 拼音」，优先级高于词库。
- (void)reloadCustomEntries {
    NSData *data = [NSData dataWithContentsOfFile:
                    [KBKeyboardDirectory stringByAppendingPathComponent:@"custom.json"]];
    id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    if ([parsed isKindOfClass:[NSArray class]]) {
        for (id item in parsed) {
            if ([item isKindOfClass:[NSDictionary class]] &&
                [item[@"word"] isKindOfClass:[NSString class]]) {
                [entries addObject:item];
            }
        }
    }
    self.customEntries = entries;
}

- (void)reloadLibraries {
    NSString *librariesPath = [KBKeyboardDirectory stringByAppendingPathComponent:@"libs"];
    NSArray<NSString *> *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:librariesPath error:NULL];
    names = [names sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    NSString *active = [self activeLibraryName];
    NSMutableArray<KBLibrary *> *libraries = [NSMutableArray array];
    for (NSString *name in names) {
        if ([name hasPrefix:@"."]) continue;
        NSString *directory = [librariesPath stringByAppendingPathComponent:name];
        if (![[NSFileManager defaultManager] fileExistsAtPath:[directory stringByAppendingPathComponent:@"index26.tsv"]]) continue;
        KBLibrary *library = [KBLibrary new];
        library.name = name;
        library.active = [name isEqualToString:active];
        NSData *meta = [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"meta.json"]];
        if (meta) {
            NSDictionary *info = [NSJSONSerialization JSONObjectWithData:meta options:0 error:NULL];
            library.accepted = [info[@"accepted"] integerValue];
            library.droppedTraditional = [info[@"droppedTraditional"] integerValue];
            library.droppedASCII = [info[@"droppedASCII"] integerValue];
            library.excluded = [info[@"excluded"] integerValue];
            library.droppedRare = [info[@"droppedRare"] integerValue];
        }
        [libraries addObject:library];
    }
    self.libraries = libraries;
    [self reloadCustomEntries];
    [self.tableView reloadData];
}

#pragma mark - 表格

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return 5;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return MAX((NSInteger)self.libraries.count + ([self activeLibraryName].length ? 1 : 0), 1);
        case 1: return 3;
        case 2: return 5;
        case 3: return 2;
        default: return self.statusText.length || self.busy ? 1 : 0;
    }
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"词库";
        case 1: return nil;
        case 2: return @"导入选项";
        case 3: return nil;
        default: return nil;
    }
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"点按切换；长按可重命名、删除。";
        case 1: return @"只读取词典文件，不改动苹果词库。";
        case 2: return @"前两项改动会重新生成当前词库的索引。";
        case 3: return @"词条优先于词库。";
        default: return nil;
    }
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    UIListContentConfiguration *content = [cell defaultContentConfiguration];

    if (indexPath.section == 0) {
        if (self.libraries.count == 0) {
            content.text = @"还没有导入词库";
            content.secondaryText = @"先导入一份 Rime 词库";
            cell.contentConfiguration = content;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }
        if (indexPath.row >= (NSInteger)self.libraries.count) {
            content.text = @"停用词库";
            content.secondaryText = @"回到苹果原生候选，词库保留";
            content.image = [UIImage systemImageNamed:@"pause.circle"];
            cell.contentConfiguration = content;
            cell.textLabel.textColor = UIColor.systemBlueColor;
            return cell;
        }

        KBLibrary *library = self.libraries[indexPath.row];
        content.text = library.name;
        if (library.accepted > 0) {
            NSMutableString *detail = [NSMutableString stringWithFormat:@"%.1f 万条", library.accepted / 10000.0];
            if (library.droppedRare > 0) [detail appendFormat:@" · 生僻 %ld", (long)library.droppedRare];
            if (library.droppedTraditional > 0) [detail appendFormat:@" · 繁体 %ld", (long)library.droppedTraditional];
            if (library.droppedASCII > 0) [detail appendFormat:@" · 英文 %ld", (long)library.droppedASCII];
            content.secondaryText = detail;
        }
        content.image = [UIImage systemImageNamed:@"character.book.closed"];
        cell.contentConfiguration = content;
        if (library.active) {
            cell.accessoryType = UITableViewCellAccessoryCheckmark;
            cell.tintColor = UIColor.systemBlueColor;
        }
        return cell;
    }

    if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            content.text = @"导入词库 ZIP…";
            content.image = [UIImage systemImageNamed:@"square.and.arrow.down"];
            cell.contentConfiguration = content;
            cell.textLabel.textColor = UIColor.systemBlueColor;
            return cell;
        }
        if (indexPath.row == 1) {
            content.text = @"从链接导入…";
            content.secondaryText = @"粘贴 https 链接";
            content.image = [UIImage systemImageNamed:@"link"];
            cell.contentConfiguration = content;
            cell.textLabel.textColor = UIColor.systemBlueColor;
            return cell;
        }
        content.text = @"词库存放位置";
        content.secondaryText = self.activeLibraryName.length ? [[KBKeyboardDirectory stringByAppendingPathComponent:@"libs"] stringByAppendingPathComponent:self.activeLibraryName] : [KBKeyboardDirectory stringByAppendingPathComponent:@"libs"];
        content.image = [UIImage systemImageNamed:@"folder"];
        cell.contentConfiguration = content;
        cell.textLabel.textColor = UIColor.secondaryLabelColor;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    if (indexPath.section == 2) {
        if (indexPath.row == 4) {
            content.text = @"候选数量";
            content.secondaryText = [NSString stringWithFormat:@"每次最多 %ld 条", (long)self.candidateLimit];
            content.image = [UIImage systemImageNamed:@"list.number"];
            cell.contentConfiguration = content;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
        if (indexPath.row == 2) {
            content.text = @"只用词库候选";
            content.secondaryText = @"候选栏只放词库的词；关掉后苹果候选接在后面";
            content.image = [UIImage systemImageNamed:@"text.badge.xmark"];
            cell.contentConfiguration = content;
            cell.accessoryView = self.lexiconOnlySwitch;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }
        if (indexPath.row == 3) {
            content.text = @"过滤生僻字";
            content.secondaryText = @"按 8105 常用字表丢掉表外字（生僻字、方言字）";
            content.image = [UIImage systemImageNamed:@"checkmark.seal"];
            cell.contentConfiguration = content;
            cell.accessoryView = self.commonOnlySwitch;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }
        BOOL traditional = indexPath.row == 0;
        content.text = traditional ? @"保留繁体词条" : @"保留英文词条";
        content.secondaryText = traditional ? @"含繁体字的词条也收进索引" : @"字母、英文单词也收进索引";
        cell.contentConfiguration = content;
        cell.accessoryView = traditional ? self.traditionalSwitch : self.asciiSwitch;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    if (indexPath.section == 3) {
        if (indexPath.row == 1) {
            NSInteger count = [self excludedWordCount];
            content.text = @"排除词条";
            content.secondaryText = count ? [NSString stringWithFormat:@"%ld 条", (long)count] : @"没有排除词";
            content.image = [UIImage systemImageNamed:@"nosign"];
            cell.contentConfiguration = content;
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
        content.text = @"自定义词条";
        content.secondaryText = self.customEntries.count
            ? [NSString stringWithFormat:@"%lu 条 · 词条优先于词库", (unsigned long)self.customEntries.count]
            : @"没有词条";
        content.image = [UIImage systemImageNamed:@"text.badge.plus"];
        cell.contentConfiguration = content;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return cell;
    }

    content.text = self.statusText ?: @"正在处理…";
    content.image = nil;
    cell.contentConfiguration = content;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (self.busy) {
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [spinner startAnimating];
        cell.accessoryView = spinner;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 2) {
        if (indexPath.row == 4) [self chooseCandidateLimit];
        return;
    }
    if (indexPath.section == 1) {
        if (indexPath.row == 0) [self chooseDictionary];
        else if (indexPath.row == 1) [self importFromLink];
        else [self chooseFileManagerForPath:[self activeLibraryPath] ?: [KBKeyboardDirectory stringByAppendingPathComponent:@"libs"] title:@"词库存放位置"];
        return;
    }
    if (indexPath.section == 3) {
        if (indexPath.row == 0) [self openCustomEntries];
        else [self editExclusionsForLibrary:self.activeLibraryName];
        return;
    }
    if (indexPath.section == 0 && indexPath.row >= (NSInteger)self.libraries.count) {
        [self disableActiveLibrary];
        return;
    }

    if (indexPath.section != 0 || self.libraries.count == 0 || self.busy) return;
    KBLibrary *library = self.libraries[indexPath.row];
    if (library.active) return;
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:KBDefaultsSuite];
    NSTimeInterval stamp = [NSDate date].timeIntervalSince1970;
    [defaults setObject:library.name forKey:@"switchTo"];
    [defaults setDouble:stamp forKey:@"switchAt"];
    [defaults setDouble:stamp forKey:@"requestStamp"];
    [defaults synchronize];
    [self beginBusy:[NSString stringWithFormat:@"正在切换到「%@」…", library.name] stamp:stamp];
}

- (UIContextMenuConfiguration *)tableView:(__unused UITableView *)tableView
        contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
                                             point:(__unused CGPoint)point {
    __weak typeof(self) weakSelf = self;
    if (indexPath.section == 1) {
        if (indexPath.row != 1) return nil;
        NSString *path = [KBKeyboardDirectory stringByAppendingPathComponent:@"libs"];
        return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                       previewProvider:nil
                                                        actionProvider:^UIMenu * _Nullable(__unused NSArray<UIMenuElement *> *suggestedActions) {
            return [UIMenu menuWithTitle:@"词库存放位置" children:@[
                [UIAction actionWithTitle:@"复制路径"
                                    image:[UIImage systemImageNamed:@"doc.on.doc"]
                               identifier:nil
                                  handler:^(__unused UIAction *action) {
                    [UIPasteboard generalPasteboard].string = path;
                    weakSelf.statusText = [NSString stringWithFormat:@"已复制：%@", path];
                    [weakSelf.tableView reloadData];
                    [weakSelf scheduleStatusClear];
                }]]];
        }];
    }
    if (indexPath.section != 0 || self.libraries.count == 0) return nil;
    KBLibrary *library = self.libraries[indexPath.row];
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                   previewProvider:nil
                                                    actionProvider:^UIMenu * _Nullable(__unused NSArray<UIMenuElement *> *suggestedActions) {
        NSMutableArray<UIAction *> *actions = [NSMutableArray array];
        if (!library.active) {
            [actions addObject:[UIAction actionWithTitle:@"设为当前"
                                                   image:[UIImage systemImageNamed:@"checkmark.circle"]
                                              identifier:nil
                                                 handler:^(__unused UIAction *action) {
                [weakSelf switchToLibrary:library.name];
            }]];
        }
        [actions addObject:[UIAction actionWithTitle:@"重命名"
                                               image:[UIImage systemImageNamed:@"pencil"]
                                          identifier:nil
                                             handler:^(__unused UIAction *action) {
            [weakSelf renameLibrary:library.name];
        }]];
        UIAction *delete = [UIAction actionWithTitle:@"删除"
                                               image:[UIImage systemImageNamed:@"trash"]
                                          identifier:nil
                                             handler:^(__unused UIAction *action) {
            [weakSelf deleteLibrary:library.name];
        }];
        delete.attributes = UIMenuElementAttributesDestructive;
        [actions addObject:delete];
        return [UIMenu menuWithTitle:library.name children:actions];
    }];
}

- (void)chooseCandidateLimit {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"候选数量"
                                                                  message:@"每次最多插入几条词库候选"
                                                           preferredStyle:UIAlertControllerStyleActionSheet];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:KBDefaultsSuite];
    __weak typeof(self) weakSelf = self;
    for (NSNumber *value in @[@3, @4, @5, @6, @7, @8]) {
        NSString *title = [NSString stringWithFormat:@"%@ 条", value];
        UIAlertAction *action = [UIAlertAction actionWithTitle:title
                                                         style:UIAlertActionStyleDefault
                                                       handler:^(__unused UIAlertAction *selected) {
            weakSelf.candidateLimit = value.integerValue;
            [defaults setInteger:value.integerValue forKey:@"candidateLimit"];
            [defaults synchronize];
            [weakSelf.tableView reloadData];
        }];
        if (value.integerValue == self.candidateLimit) {
            [action setValue:[UIImage systemImageNamed:@"checkmark"] forKey:@"image"];
        }
        [sheet addAction:action];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds),
                                                               CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

// 停用：清空 active，词库文件都留着，键盘回到苹果候选。
- (void)disableActiveLibrary {
    if (self.busy) return;
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:KBDefaultsSuite];
    NSTimeInterval stamp = [NSDate date].timeIntervalSince1970;
    [defaults setDouble:stamp forKey:@"disableAt"];
    [defaults setDouble:stamp forKey:@"requestStamp"];
    [defaults synchronize];
    [self beginBusy:@"正在停用词库…" stamp:stamp];
}

- (void)openCustomEntries {
    KBCustomController *controller = [KBCustomController new];
    controller.entries = self.customEntries ?: @[];
    __weak typeof(self) weakSelf = self;
    controller.onSave = ^(NSArray<NSDictionary *> *entries) {
        weakSelf.customEntries = entries;
        [weakSelf saveCustomEntries];
    };
    [self.navigationController pushViewController:controller animated:YES];
}

- (void)saveCustomEntries {
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.customEntries ?: @[] options:0 error:NULL];
    NSString *json = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"[]";
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:KBDefaultsSuite];
    NSTimeInterval stamp = [NSDate date].timeIntervalSince1970;
    [defaults setObject:json ?: @"[]" forKey:@"customJSON"];
    [defaults setDouble:stamp forKey:@"customAt"];
    [defaults setDouble:stamp forKey:@"requestStamp"];
    [defaults synchronize];
    [self beginBusy:@"正在保存词条…" stamp:stamp];
}
- (void)renameLibrary:(NSString *)name {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重命名词库"
                                                                   message:@"改的是显示名称，不影响内容。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = name;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *newName = alert.textFields.firstObject.text;
        if (!newName.length) return;
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:KBDefaultsSuite];
        NSTimeInterval stamp = [NSDate date].timeIntervalSince1970;
        [defaults setObject:name forKey:@"renameFrom"];
        [defaults setObject:newName forKey:@"renameTo"];
        [defaults setDouble:stamp forKey:@"renameAt"];
        [defaults setDouble:stamp forKey:@"requestStamp"];
        [defaults synchronize];
        [weakSelf beginBusy:@"正在重命名…" stamp:stamp];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

// 紧凑弹窗：保留完整路径与文件管理器选择。
- (void)chooseFileManagerForPath:(NSString *)path title:(NSString *)title {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                  message:path
                                                           preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"用 Filza 打开" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [weakSelf openFolder:path scheme:@"filza"];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"用 Fila 打开" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [weakSelf openFolder:path scheme:@"fila"];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"复制路径" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [UIPasteboard generalPasteboard].string = path;
        weakSelf.statusText = [NSString stringWithFormat:@"已复制：%@", path];
        [weakSelf.tableView reloadData];
        [weakSelf scheduleStatusClear];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)openFolder:(NSString *)path scheme:(NSString *)scheme {
    NSString *trimmed = [path hasPrefix:@"/"] ? [path substringFromIndex:1] : path;
    NSString *encoded = [trimmed stringByAddingPercentEncodingWithAllowedCharacters:
                         [NSCharacterSet URLPathAllowedCharacterSet]] ?: trimmed;
    NSArray<NSString *> *candidates = @[
        [NSString stringWithFormat:@"%@://view/%@", scheme, encoded],
        [NSString stringWithFormat:@"%@:///%@", scheme, encoded],
    ];
    [self tryOpenFolder:candidates index:0 path:path];
}

- (void)tryOpenFolder:(NSArray<NSString *> *)candidates index:(NSUInteger)index path:(NSString *)path {
    if (index >= candidates.count) {
        [self showMissingFileManagerForPath:path];
        return;
    }
    NSURL *url = [NSURL URLWithString:candidates[index]];
    if (!url) {
        [self tryOpenFolder:candidates index:index + 1 path:path];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL success) {
        if (success) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf tryOpenFolder:candidates index:index + 1 path:path];
        });
    }];
}

- (void)showMissingFileManagerForPath:(NSString *)path {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"打不开文件管理器"
                                                                   message:[NSString stringWithFormat:@"这个应用没有响应，可能没装或版本不支持这个地址。可以复制路径，用别的工具打开：\n%@", path]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"复制路径" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [UIPasteboard generalPasteboard].string = path;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}


- (NSString *)excludePathForLibrary:(NSString *)name {
    if (!name.length) return nil;
    return [[[KBKeyboardDirectory stringByAppendingPathComponent:@"libs"]
             stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"exclude.txt"];
}

- (NSInteger)excludedWordCount {
    NSString *text = [NSString stringWithContentsOfFile:[self excludePathForLibrary:self.activeLibraryName]
                                              encoding:NSUTF8StringEncoding error:NULL];
    if (!text.length) return 0;
    NSInteger count = 0;
    for (NSString *line in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        if ([line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].length) count++;
    }
    return count;
}

- (void)editExclusionsForLibrary:(NSString *)name {
    if (!name.length) return;
    NSString *text = [NSString stringWithContentsOfFile:[self excludePathForLibrary:name]
                                              encoding:NSUTF8StringEncoding error:NULL] ?: @"";
    NSMutableArray<NSString *> *entries = [NSMutableArray array];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *word = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (word.length) [entries addObject:word];
    }
    KBExcludeListController *controller = [KBExcludeListController new];
    controller.libraryName = name;
    controller.entries = entries;
    __weak typeof(self) weakSelf = self;
    controller.onSave = ^(NSArray<NSString *> *list) {
        [weakSelf saveExclusions:list forLibrary:name];
    };
    [self.navigationController pushViewController:controller animated:YES];
}

- (void)saveExclusions:(NSArray<NSString *> *)entries forLibrary:(NSString *)name {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:KBDefaultsSuite];
    NSTimeInterval stamp = [NSDate date].timeIntervalSince1970;
    [defaults setObject:name forKey:@"excludeLib"];
    [defaults setObject:[entries componentsJoinedByString:@"\n"] forKey:@"excludeText"];
    [defaults setDouble:stamp forKey:@"excludeAt"];
    [defaults setDouble:stamp forKey:@"requestStamp"];
    [defaults synchronize];
    [self beginBusy:[NSString stringWithFormat:@"正在按排除词重建「%@」…", name] stamp:stamp];
}

- (void)deleteLibrary:(NSString *)name {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"删除词库"
                                                                   message:[NSString stringWithFormat:@"「%@」将被删除，无法恢复。", name]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:KBDefaultsSuite];
        NSTimeInterval stamp = [NSDate date].timeIntervalSince1970;
        [defaults setObject:name forKey:@"deleteLib"];
        [defaults setDouble:stamp forKey:@"deleteAt"];
        [defaults setDouble:stamp forKey:@"requestStamp"];
        [defaults synchronize];
        [weakSelf beginBusy:[NSString stringWithFormat:@"正在删除「%@」…", name] stamp:stamp];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)importFromLink {
    if (self.busy) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"从链接导入"
                                                                   message:@"粘贴 ZIP 的 https 地址，下载完会自动解压并设为当前词库。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"https://…";
        field.keyboardType = UIKeyboardTypeURL;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"下载" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        if (!weakSelf || weakSelf.busy) return;
        NSString *url = [alert.textFields.firstObject.text
                         stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (![url.lowercaseString hasPrefix:@"https://"]) {
            UIAlertController *warn = [UIAlertController alertControllerWithTitle:@"只支持 https"
                                                                          message:@"http 链接会被系统的传输安全策略拦掉，请用 https 地址。"
                                                                   preferredStyle:UIAlertControllerStyleAlert];
            [warn addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
            [weakSelf presentViewController:warn animated:YES completion:nil];
            return;
        }
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:KBDefaultsSuite];
        NSTimeInterval stamp = [NSDate date].timeIntervalSince1970;
        [defaults setObject:url forKey:@"downloadURL"];
        [defaults setDouble:stamp forKey:@"downloadAt"];
        [defaults setDouble:stamp forKey:@"requestStamp"];
        [defaults synchronize];
        [weakSelf beginBusy:@"正在下载词库…" stamp:stamp];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)chooseDictionary {
    if (self.busy || self.presentedViewController) return;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeZIP]
                                                                                                        asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(__unused UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (self.busy || urls.count != 1) return;
    NSURL *source = urls.firstObject;

    // 先按内容比对：改名过的同一份 ZIP 不该再存一份、再转一遍。
    NSString *pickedHash = [self sha256OfFile:source.path];
    NSString *duplicate = nil;
    if (pickedHash) {
        for (KBLibrary *library in self.libraries) {
            NSString *zip = [[[KBKeyboardDirectory stringByAppendingPathComponent:@"libs"]
                              stringByAppendingPathComponent:library.name]
                             stringByAppendingPathComponent:@"source.zip"];
            if ([pickedHash isEqualToString:[self sha256OfFile:zip] ?: @""]) {
                duplicate = library.name;
                break;
            }
        }
    }
    if (duplicate) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"这份 ZIP 已经导入过"
                                                                       message:[NSString stringWithFormat:@"它和已有的「%@」是同一个文件。", duplicate]
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        __weak typeof(self) weakSelf = self;
        [alert addAction:[UIAlertAction actionWithTitle:@"仍然另存一份" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [weakSelf importZipAt:source];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"设为当前" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [weakSelf switchToLibrary:duplicate];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    NSString *name = [self libraryNameForZip:source.lastPathComponent];
    NSString *existing = [KBKeyboardDirectory stringByAppendingPathComponent:
                          [@"libs" stringByAppendingPathComponent:name]];
    if ([[NSFileManager defaultManager] fileExistsAtPath:existing]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"已有同名词库"
                                                                       message:[NSString stringWithFormat:@"「%@」已存在，继续导入会把它替换成这份新的。", name]
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        __weak typeof(self) weakSelf = self;
        [alert addAction:[UIAlertAction actionWithTitle:@"替换" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
            [weakSelf importZipAt:source];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    [self importZipAt:source];
}

- (NSString *)sha256OfFile:(NSString *)path {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];
    if (!data.length) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

- (void)switchToLibrary:(NSString *)name {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:KBDefaultsSuite];
    NSTimeInterval stamp = [NSDate date].timeIntervalSince1970;
    [defaults setObject:name forKey:@"switchTo"];
    [defaults setDouble:stamp forKey:@"switchAt"];
    [defaults setDouble:stamp forKey:@"requestStamp"];
    [defaults synchronize];
    [self beginBusy:[NSString stringWithFormat:@"正在切换到「%@」…", name] stamp:stamp];
}

// 与守护进程一致的命名规则：ZIP 文件名去掉 .zip，只保留字母数字汉字与 -_。
- (NSString *)libraryNameForZip:(NSString *)fileName {
    NSString *base = fileName;
    if ([base.lowercaseString hasSuffix:@".zip"]) base = [base substringToIndex:base.length - 4];
    NSMutableString *safe = [NSMutableString string];
    for (NSUInteger i = 0; i < base.length; i++) {
        unichar c = [base characterAtIndex:i];
        BOOL keep = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
                    (c == '-') || (c == '_') || (c >= 0x4E00 && c <= 0x9FFF);
        [safe appendFormat:@"%C", (unichar)(keep ? c : (unichar)'_')];
    }
    NSString *trimmed = [safe stringByTrimmingCharactersInSet:
                         [NSCharacterSet characterSetWithCharactersInString:@"_"]];
    return trimmed.length ? trimmed : @"词库";
}

- (void)importZipAt:(NSURL *)source {
    [self beginBusy:@"正在接收词库文件…" stamp:0];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL scoped = [source startAccessingSecurityScopedResource];
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:KBDefaultsSuite];
        NSTimeInterval stamp = [NSDate date].timeIntervalSince1970;
        [defaults setObject:source.path forKey:@"pendingZipPath"];
        [defaults setObject:source.lastPathComponent forKey:@"pendingZipName"];
        [defaults setDouble:stamp forKey:@"pendingZipAt"];
        [defaults setDouble:stamp forKey:@"requestStamp"];
        [defaults synchronize];
        if (scoped) [source stopAccessingSecurityScopedResource];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self beginBusy:@"正在解压并生成索引…" stamp:stamp];
        });
    });
}

- (void)optionChanged:(UISwitch *)sender {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:KBDefaultsSuite];
    if (self.busy) {
        self.traditionalSwitch.on = [defaults boolForKey:KBKeyTraditional];
        self.asciiSwitch.on = [defaults boolForKey:KBKeyASCII];
        self.commonOnlySwitch.on = [defaults objectForKey:@"commonOnly"] ? [defaults boolForKey:@"commonOnly"] : YES;
        self.lexiconOnlySwitch.on = [defaults boolForKey:@"lexiconOnly"];
        return;
    }
    if (sender == self.lexiconOnlySwitch) {
        // 这个开关不碰索引，守护进程下一轮就同步给探针；提示只留几秒。
        [defaults setBool:sender.isOn forKey:@"lexiconOnly"];
        [defaults synchronize];
        self.statusText = sender.isOn ? @"已开启：候选栏只显示词库的词" : @"已关闭：苹果的候选接在后面";
        [self.tableView reloadData];
        [self scheduleStatusClear];
        return;
    }
    [defaults setBool:self.traditionalSwitch.isOn forKey:KBKeyTraditional];
    [defaults setBool:self.asciiSwitch.isOn forKey:KBKeyASCII];
    [defaults setBool:self.commonOnlySwitch.isOn forKey:@"commonOnly"];
    NSTimeInterval stamp = [NSDate date].timeIntervalSince1970;
    [defaults setDouble:stamp forKey:@"convertRequest"];
    [defaults setDouble:stamp forKey:@"requestStamp"];
    [defaults synchronize];
    [self beginBusy:@"正在按新设置重新生成索引…" stamp:stamp];
}

#pragma mark - 状态

- (void)beginBusy:(NSString *)status stamp:(NSTimeInterval)stamp {
    [self.statusTimer invalidate];
    self.statusTimer = nil;
    self.busy = YES;
    self.statusText = status;
    self.requestTime = stamp;
    [self.tableView reloadData];
    [self.pollTimer invalidate];
    if (stamp > 0) {
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:KBDefaultsSuite];
        [defaults setDouble:stamp forKey:@"uiPendingRequest"];
        [defaults synchronize];
        self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(pollOnce) userInfo:nil repeats:YES];
    }
}

- (void)finishBusy:(NSString *)status {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:KBDefaultsSuite];
    if ([defaults doubleForKey:@"uiPendingRequest"] == self.requestTime) {
        [defaults removeObjectForKey:@"uiPendingRequest"];
        [defaults synchronize];
    }
    self.requestTime = 0;
    self.busy = NO;
    self.statusText = status;
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    [self reloadLibraries];
    [self scheduleStatusClear];
}

// 完成提示只留几秒：不留着占地方，离开这一页也会清掉。
- (void)scheduleStatusClear {
    [self.statusTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.statusTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:NO block:^(__unused NSTimer *timer) {
        weakSelf.statusText = nil;
        [weakSelf.tableView reloadData];
    }];
}

- (void)pollOnce {
    if (self.requestTime <= 0) return;
    NSString *path = [KBKeyboardDirectory stringByAppendingPathComponent:@"last-import.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data) {
        NSDictionary *summary = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if ([summary isKindOfClass:[NSDictionary class]] && [summary[@"requestAt"] doubleValue] == self.requestTime) {
            if (![summary[@"ok"] boolValue]) {
                [self finishBusy:[summary[@"reason"] isKindOfClass:[NSString class]] ? summary[@"reason"] : @"操作失败，请重试"];
            } else if ([summary[@"deleted"] isKindOfClass:[NSString class]]) {
                [self finishBusy:[NSString stringWithFormat:@"已删除「%@」", summary[@"deleted"]]];
            } else if ([summary[@"switched"] isKindOfClass:[NSString class]]) {
                [self finishBusy:[NSString stringWithFormat:@"已切换到「%@」", summary[@"switched"]]];
            } else if ([summary[@"disabled"] boolValue]) {
                [self finishBusy:@"已停用词库，回到苹果候选"];
            } else if ([summary[@"renamed"] isKindOfClass:[NSString class]]) {
                [self finishBusy:[NSString stringWithFormat:@"已改名为「%@」", summary[@"renamed"]]];
            } else if ([summary[@"scanned"] boolValue]) {
                NSUInteger added = [summary[@"installed"] integerValue];
                NSUInteger converted = [summary[@"converted"] integerValue];
                if (added + converted == 0) [self finishBusy:@"没有发现新词库"];
                else [self finishBusy:[NSString stringWithFormat:@"已装 %lu 个、转换 %lu 个", (unsigned long)added, (unsigned long)converted]];
            } else if (summary[@"custom"] != nil) {
                [self finishBusy:[NSString stringWithFormat:@"已保存 %@ 条自定义词条", summary[@"custom"]]];
            } else if ([summary[@"filtered"] boolValue]) {
                [self finishBusy:[NSString stringWithFormat:@"已从索引排除 %@ 条", summary[@"excluded"]]];
            } else if ([summary[@"ok"] boolValue]) {
                NSString *message = summary[@"accepted"] ? [NSString stringWithFormat:@"完成：%@ 条，过滤繁体 %@、英文 %@",
                                     summary[@"accepted"], summary[@"droppedTraditional"] ?: @0, summary[@"droppedASCII"] ?: @0] : @"操作完成";
                if ([summary[@"excluded"] integerValue] > 0) {
                    message = [message stringByAppendingFormat:@"，排除 %@", summary[@"excluded"]];
                }
                [self finishBusy:message];
            } else {
                [self finishBusy:@"操作失败，原有词库未改动"];
            }
            return;
        }
    }
    NSData *taskData = [NSData dataWithContentsOfFile:[KBKeyboardDirectory stringByAppendingPathComponent:@"import-task.json"]];
    NSDictionary *task = taskData ? [NSJSONSerialization JSONObjectWithData:taskData options:0 error:NULL] : nil;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSString *status = nil;
    if ([task isKindOfClass:[NSDictionary class]] && [task[@"requestAt"] doubleValue] == self.requestTime) {
        if (now - [task[@"updatedAt"] doubleValue] > 30) {
            status = @"后台状态暂未更新，仍在等待结果…";
        } else if ([task[@"phase"] isKindOfClass:[NSString class]]) {
            status = task[@"phase"];
        }
    } else if (now - self.requestTime > 30) {
        status = @"等待后台接收任务，请确认插件正在运行…";
    }
    if (status && ![self.statusText isEqualToString:status]) {
        self.statusText = status;
        [self.tableView reloadData];
    }
}

@end

#pragma mark - 排除词条

@implementation KBExcludeListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"排除词条";
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]]];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView { return 1; }

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    return (NSInteger)self.entries.count + 2;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(__unused NSInteger)section {
    return @"整词匹配；行尾加 @简 只在 26 键简拼时隐藏。改动会重建词库。";
}

- (UITableViewCell *)tableView:(__unused UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    UIListContentConfiguration *content = [cell defaultContentConfiguration];
    if (indexPath.row == (NSInteger)self.entries.count + 1) {
        content.text = @"从剪贴板添加…";
        content.secondaryText = @"每行一个，直接读剪贴板";
        content.image = [UIImage systemImageNamed:@"square.and.pencil"];
        cell.contentConfiguration = content;
        cell.textLabel.textColor = UIColor.systemBlueColor;
        return cell;
    }
    if (indexPath.row >= (NSInteger)self.entries.count) {
        content.text = @"添加排除词…";
        content.image = [UIImage systemImageNamed:@"plus.circle"];
        cell.contentConfiguration = content;
        cell.textLabel.textColor = UIColor.systemBlueColor;
        return cell;
    }
    content.text = self.entries[indexPath.row];
    cell.contentConfiguration = content;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row == (NSInteger)self.entries.count + 1) { [self addBatch]; return; }
    if (indexPath.row >= (NSInteger)self.entries.count) [self addEntry];
}

- (UIContextMenuConfiguration *)tableView:(__unused UITableView *)tableView
        contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
                                             point:(__unused CGPoint)point {
    if (indexPath.row >= (NSInteger)self.entries.count) return nil;
    NSString *word = self.entries[indexPath.row];
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                   previewProvider:nil
                                                    actionProvider:^UIMenu * _Nullable(__unused NSArray<UIMenuElement *> *suggested) {
        UIAction *delete = [UIAction actionWithTitle:@"删除"
                                               image:[UIImage systemImageNamed:@"trash"]
                                          identifier:nil
                                             handler:^(__unused UIAction *action) {
            NSMutableArray<NSString *> *entries = [weakSelf.entries mutableCopy];
            [entries removeObject:word];
            weakSelf.entries = entries;
            [weakSelf.tableView reloadData];
            if (weakSelf.onSave) weakSelf.onSave(entries);
        }];
        delete.attributes = UIMenuElementAttributesDestructive;
        return [UIMenu menuWithTitle:word children:@[delete]];
    }];
}

// 剪贴板里一行一个词，一次全部加进来；重复的跳过。
- (void)addBatch {
    NSString *text = UIPasteboard.generalPasteboard.string;
    if (!text.length) {
        UIAlertController *empty = [UIAlertController alertControllerWithTitle:@"剪贴板是空的"
                                                                       message:@"先复制几行词，每行一个。"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [empty addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:empty animated:YES completion:nil];
        return;
    }
    NSMutableArray<NSString *> *entries = [self.entries mutableCopy] ?: [NSMutableArray array];
    NSUInteger added = 0;
    for (NSString *line in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *word = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!word.length || [entries containsObject:word]) continue;
        [entries addObject:word];
        added++;
    }
    if (!added) {
        UIAlertController *none = [UIAlertController alertControllerWithTitle:@"没有新词"
                                                                      message:@"剪贴板里的词都已经在列表里了。"
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [none addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:none animated:YES completion:nil];
        return;
    }
    self.entries = entries;
    [self.tableView reloadData];
    if (self.onSave) self.onSave(entries);
}

- (void)addEntry {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"排除词条"
                                                                   message:@"整词匹配；行尾加 @简 只在 26 键简拼时隐藏。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"例如 修复 或 双肩包@简";
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *word = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!word.length) return;
        NSMutableArray<NSString *> *entries = [weakSelf.entries mutableCopy] ?: [NSMutableArray array];
        [entries addObject:word];
        weakSelf.entries = entries;
        [weakSelf.tableView reloadData];
        if (weakSelf.onSave) weakSelf.onSave(entries);
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
#pragma mark - 自定义词条页

@implementation KBCustomController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"自定义词条";
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.view addSubview:self.tableView];
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]]];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    return (NSInteger)self.entries.count + 1;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(__unused NSInteger)section {
    return @"词条优先于词库，拼音只填字母；长按可删除。";
}

- (UITableViewCell *)tableView:(__unused UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    UIListContentConfiguration *content = [cell defaultContentConfiguration];
    if (indexPath.row >= (NSInteger)self.entries.count) {
        content.text = @"添加词条…";
        content.image = [UIImage systemImageNamed:@"plus.circle"];
        cell.contentConfiguration = content;
        cell.textLabel.textColor = UIColor.systemBlueColor;
        return cell;
    }
    NSDictionary *entry = self.entries[indexPath.row];
    content.text = entry[@"word"];
    content.secondaryText = entry[@"pinyin"];
    cell.contentConfiguration = content;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row >= (NSInteger)self.entries.count) [self addEntry];
}

- (UIContextMenuConfiguration *)tableView:(__unused UITableView *)tableView
        contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
                                             point:(__unused CGPoint)point {
    if (indexPath.row >= (NSInteger)self.entries.count) return nil;
    NSDictionary *entry = self.entries[indexPath.row];
    __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                   previewProvider:nil
                                                    actionProvider:^UIMenu * _Nullable(__unused NSArray<UIMenuElement *> *suggested) {
        UIAction *delete = [UIAction actionWithTitle:@"删除"
                                               image:[UIImage systemImageNamed:@"trash"]
                                          identifier:nil
                                             handler:^(__unused UIAction *action) {
            NSMutableArray<NSDictionary *> *entries = [weakSelf.entries mutableCopy];
            [entries removeObject:entry];
            weakSelf.entries = entries;
            [weakSelf.tableView reloadData];
            if (weakSelf.onSave) weakSelf.onSave(entries);
        }];
        delete.attributes = UIMenuElementAttributesDestructive;
        return [UIMenu menuWithTitle:entry[@"word"] children:@[delete]];
    }];
}

- (void)addEntry {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"添加词条"
                                                                   message:@"词条优先于词库；拼音只填字母。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"词条，例如 右滑";
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"拼音，例如 youhua";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *word = [alert.textFields[0].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *pinyin = [alert.textFields[1].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!word.length || !pinyin.length) return;
        NSMutableArray<NSDictionary *> *entries = [weakSelf.entries mutableCopy] ?: [NSMutableArray array];
        [entries addObject:@{@"word": word, @"pinyin": pinyin}];
        weakSelf.entries = entries;
        [weakSelf.tableView reloadData];
        if (weakSelf.onSave) weakSelf.onSave(entries);
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
