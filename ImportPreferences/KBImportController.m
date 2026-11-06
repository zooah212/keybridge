// 设置面板：词库、导入、自定义词条与开关。面板写不了 Keyboard 目录，动作都交给守护进程。

#import <Preferences/PSViewController.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <CommonCrypto/CommonDigest.h>
#import "../Injector/KBCustomEntries.h"
#import "KBLibraryQuery.h"
#import "../Injector/KBRespring.h"
#import "KBSettingsModel.h"
#include <notify.h>

static NSString *const KBDefaultsSuite = @"com.wm0104.keybridge";
static NSString *const KBKeyTraditional = @"includeTraditional";
static NSString *const KBKeyASCII = @"includeASCII";
static NSString *const KBKeyLocalCandidates = @"localCandidates";
static NSString *const KBKeyboardDirectory = @"/var/mobile/Library/Keyboard/KeyBridge";

// 借鉴 Fila 的简洁风格，统一主页面与功能页的视觉呈现。
static UIColor *KBSettingsRowColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? UIColor.secondarySystemGroupedBackgroundColor : [UIColor colorWithWhite:0.96 alpha:1.0];
    }];
}

// Accessory views keep icons trailing without changing the table's grouped corners.
static UIView *KBSettingsAccessory(NSString *symbol, UIView *control) {
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
    icon.tintColor = UIColor.labelColor;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.isAccessibilityElement = NO;
    [icon.widthAnchor constraintEqualToConstant:24].active = YES;
    [icon.heightAnchor constraintEqualToConstant:24].active = YES;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:control ? @[icon, control] : @[icon]];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 12;
    stack.frame = CGRectMake(0, 0, 24 + (control ? 12 + control.intrinsicContentSize.width : 0),
                             MAX(24, control ? control.intrinsicContentSize.height : 0));
    return stack;
}

static void KBStyleSettingsCell(UITableViewCell *cell, UIListContentConfiguration *content) {
    cell.backgroundColor = KBSettingsRowColor();
    cell.tintColor = UIColor.labelColor;
    content.textProperties.color = UIColor.labelColor;
    content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
    content.secondaryTextProperties.numberOfLines = 0;
}

#pragma mark - 数据

@interface KBLibrary : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) NSNumber *accepted;
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
// 点按编辑，最后一行添加；长按删除。
@interface KBCustomController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, copy) NSArray<NSDictionary *> *entries;
@property (nonatomic, copy) void (^onSave)(NSArray<NSDictionary *> *entries, void (^completion)(BOOL, NSString *));
@property (nonatomic) BOOL saving;
@property (nonatomic, strong) UITableView *tableView;
@end

@interface KBLibraryQueryController : UITableViewController <UISearchBarDelegate>
@property (nonatomic, copy) NSString *libraryName;
@property (nonatomic, copy) NSString *indexPath;
@property (nonatomic, strong) NSArray<NSDictionary *> *rows;
@property (nonatomic, copy) NSString *queryStatus;
@property (nonatomic) NSUInteger queryGeneration;
@property (nonatomic, strong) NSOperationQueue *queryQueue;
@end

@interface KBImportController : PSViewController <UIDocumentPickerDelegate, UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray<KBLibrary *> *libraries;
@property (nonatomic, strong) UISwitch *traditionalSwitch;
@property (nonatomic, strong) UISwitch *asciiSwitch;
@property (nonatomic, strong) UISwitch *lexiconOnlySwitch;
@property (nonatomic, strong) UISwitch *commonOnlySwitch;
@property (nonatomic, strong) UISwitch *localCandidatesSwitch;
@property (nonatomic, copy) NSString *statusText;
@property (nonatomic) BOOL busy;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, strong) NSTimer *statusTimer;
@property (nonatomic, strong) NSArray<NSDictionary *> *customEntries;
@property (nonatomic, copy) void (^customCompletion)(BOOL, NSString *);
@property (nonatomic) NSInteger candidateLimit;
@property (nonatomic) NSTimeInterval requestTime;
@property (nonatomic, copy) NSString *respringRequestID;
@property (nonatomic, copy) NSString *respringSession;
@property (nonatomic) NSTimeInterval respringDeadline;
@property (nonatomic, strong) NSTimer *respringTimer;
@property (nonatomic) KBSection expandedCategory;
@property (nonatomic) BOOL updatingOptions;
@property (nonatomic) BOOL displayedStatus;
@property (nonatomic) BOOL pendingLibrariesRefresh;
@property (nonatomic) BOOL pendingTableRefresh;
@property (nonatomic) BOOL pendingStatusRefresh;
- (NSArray<NSNumber *> *)visibleSections;
- (KBSection)sectionAtIndex:(NSInteger)index;
@end

@implementation KBImportController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.expandedCategory = KBSectionOptions;
    self.title = @"词库桥接";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"注销"
        style:UIBarButtonItemStylePlain target:self action:@selector(requestRespring)];
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
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
    self.candidateLimit = KBValidatedCandidateLimit(limit);
    self.lexiconOnlySwitch = [UISwitch new];
    self.commonOnlySwitch = [UISwitch new];
    self.commonOnlySwitch.on = [defaults objectForKey:@"commonOnly"] ? [defaults boolForKey:@"commonOnly"] : YES;
    [self.commonOnlySwitch addTarget:self action:@selector(optionChanged:) forControlEvents:UIControlEventValueChanged];
    self.lexiconOnlySwitch.on = ![defaults boolForKey:@"lexiconOnly"];
    [self.lexiconOnlySwitch addTarget:self action:@selector(optionChanged:) forControlEvents:UIControlEventValueChanged];
    self.localCandidatesSwitch = [UISwitch new];
    self.localCandidatesSwitch.on = [defaults objectForKey:KBKeyLocalCandidates] ? [defaults boolForKey:KBKeyLocalCandidates] : YES;
    [self.localCandidatesSwitch addTarget:self action:@selector(localCandidatesChanged:) forControlEvents:UIControlEventValueChanged];
    [self reloadLibraries];
}

- (void)scanLibraryFiles {
    if (self.busy || self.respringRequestID.length) return;
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:KBDefaultsSuite];
    NSTimeInterval stamp = [NSDate date].timeIntervalSince1970;
    [defaults setDouble:stamp forKey:@"scanAt"];
    [defaults setDouble:stamp forKey:@"requestStamp"];
    [defaults synchronize];
    [self beginBusy:@"正在扫描词库文件…" stamp:stamp];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:KBDefaultsSuite];
    self.localCandidatesSwitch.on = [defaults objectForKey:KBKeyLocalCandidates] ? [defaults boolForKey:KBKeyLocalCandidates] : YES;
    self.traditionalSwitch.on = [defaults boolForKey:KBKeyTraditional];
    self.asciiSwitch.on = [defaults boolForKey:KBKeyASCII];
    self.commonOnlySwitch.on = [defaults objectForKey:@"commonOnly"] ? [defaults boolForKey:@"commonOnly"] : YES;
    self.lexiconOnlySwitch.on = ![defaults boolForKey:@"lexiconOnly"];
    self.candidateLimit = KBValidatedCandidateLimit([defaults integerForKey:@"candidateLimit"]);
    NSTimeInterval pending = [defaults doubleForKey:@"uiPendingRequest"];
    if (pending > 0) {
        [self beginBusy:@"正在检查导入进度…" stamp:pending];
        [self pollOnce];
    } else if (self.busy && self.requestTime > 0) {
        // Another page may have consumed the receipt during a cancelled back swipe.
        // A zero-stamp file copy is still local work and must remain busy.
        [self pollOnce];
        if (self.busy) {
            if (self.customCompletion) {
                void (^completion)(BOOL, NSString *) = self.customCompletion;
                self.customCompletion = nil;
                completion(NO, @"任务状态已变化，请重新打开词条列表确认。");
            }
            [self finishBusy:nil];
        }
    } else if (!self.busy) {
        self.statusText = nil;
    }
    [self restoreRespringRequest];
    [self reloadLibraries];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.pollTimer invalidate];
    self.pollTimer = nil;
    [self.respringTimer invalidate];
    self.respringTimer = nil;
}

#pragma mark - 数据加载

- (NSString *)activeLibraryName {
    NSString *name = [NSString stringWithContentsOfFile:[KBKeyboardDirectory stringByAppendingPathComponent:@"active"]
                                              encoding:NSUTF8StringEncoding error:NULL];
    return [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// 自定义词条：custom.json 里的「词 + 拼音」，优先级高于词库。
- (void)reloadCustomEntries {
    NSData *data = [NSData dataWithContentsOfFile:
                    KBCustomFilePath(KBKeyboardDirectory, @"custom.json")];
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
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self reloadLibraries]; });
        return;
    }
    if (self.updatingOptions) { self.pendingLibrariesRefresh = YES; return; }
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
            id info = [NSJSONSerialization JSONObjectWithData:meta options:0 error:NULL];
            id count = [info isKindOfClass:NSDictionary.class] ? info[@"accepted"] : nil;
            if ([count isKindOfClass:NSNumber.class]) library.accepted = count;
        }
        [libraries addObject:library];
    }
    self.libraries = libraries;
    [self reloadCustomEntries];
    self.navigationItem.rightBarButtonItem.enabled = !self.busy && !self.respringRequestID.length;
    [self refreshTable];
}

#pragma mark - 原位分类展开

- (NSString *)displayedActiveLibraryName {
    for (KBLibrary *library in self.libraries) if (library.active) return library.name;
    return nil;
}

- (NSString *)displayedLibraryPath {
    NSString *root = [KBKeyboardDirectory stringByAppendingPathComponent:@"libs"];
    NSString *name = [self displayedActiveLibraryName];
    return name.length ? [root stringByAppendingPathComponent:name] : root;
}

- (void)updateInteractionState {
    BOOL unlocked = !self.updatingOptions && !self.respringRequestID.length;
    self.tableView.userInteractionEnabled = unlocked;
    self.navigationItem.rightBarButtonItem.enabled = unlocked && !self.busy;
    for (UISwitch *control in @[self.localCandidatesSwitch, self.lexiconOnlySwitch,
                               self.traditionalSwitch, self.asciiSwitch, self.commonOnlySwitch]) {
        control.enabled = unlocked && !self.busy;
    }
}

- (void)refreshTable {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self refreshTable]; });
        return;
    }
    if (self.updatingOptions) { self.pendingTableRefresh = YES; return; }
    self.displayedStatus = self.statusText.length || self.busy;
    [self updateInteractionState];
    [self.tableView reloadData];
}

- (void)configureCategoryHeader:(UITableViewCell *)cell section:(KBSection)section {
    BOOL expanded = self.expandedCategory == section;
    NSString *symbol = nil;
    switch (section) {
        case KBSectionImport: symbol = @"square.and.arrow.down"; break;
        case KBSectionEntries: symbol = @"text.badge.plus"; break;
        case KBSectionDisplay: symbol = @"list.bullet"; break;
        case KBSectionFilters: symbol = @"line.3.horizontal.decrease.circle"; break;
        default: return;
    }
    UIImageView *arrow = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:expanded ? @"chevron.up" : @"chevron.down"]];
    arrow.tintColor = UIColor.labelColor;
    arrow.isAccessibilityElement = NO;
    cell.accessoryView = KBSettingsAccessory(symbol, arrow);
    cell.accessibilityTraits = UIAccessibilityTraitButton;
    cell.accessibilityValue = expanded ? @"已展开" : @"已折叠";
    cell.accessibilityHint = expanded ? @"轻点折叠分类" : @"轻点展开分类";
}

- (void)toggleCategory:(KBSection)category {
    if (self.updatingOptions || self.busy || self.respringRequestID.length) return;
    KBSection old = self.expandedCategory;
    KBSection next = old == category ? KBSectionOptions : category;
    NSInteger section = [self.visibleSections indexOfObject:@(KBSectionOptions)];
    NSMutableArray<NSIndexPath *> *deleted = [NSMutableArray array];
    NSMutableArray<NSIndexPath *> *inserted = [NSMutableArray array];
    for (NSInteger item = 0; item < KBSettingsCategoryRowCount(old); item++)
        [deleted addObject:[NSIndexPath indexPathForRow:KBSettingsOptionIndex(old, item, old) inSection:section]];
    for (NSInteger item = 0; item < KBSettingsCategoryRowCount(next); item++)
        [inserted addObject:[NSIndexPath indexPathForRow:KBSettingsOptionIndex(next, item, next) inSection:section]];
    NSMutableDictionary<NSNumber *, UITableViewCell *> *headers = [NSMutableDictionary dictionary];
    for (NSInteger index = 0; index < 4; index++) {
        KBSection header = KBSettingsCategoryAtIndex(index);
        NSIndexPath *path = [NSIndexPath indexPathForRow:KBSettingsOptionIndex(header, -1, old) inSection:section];
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:path];
        if (cell) headers[@(header)] = cell;
    }
    self.updatingOptions = YES;
    [self updateInteractionState];
    void (^updates)(void) = ^{
        [self.tableView performBatchUpdates:^{
            self.expandedCategory = next;
            [self.tableView deleteRowsAtIndexPaths:deleted withRowAnimation:UITableViewRowAnimationAutomatic];
            [self.tableView insertRowsAtIndexPaths:inserted withRowAnimation:UITableViewRowAnimationAutomatic];
            // Headers survive the batch; update their state without reloading them.
            for (NSNumber *header in headers)
                [self configureCategoryHeader:headers[header] section:(KBSection)header.integerValue];
        } completion:^(__unused BOOL finished) {
            self.updatingOptions = NO;
            BOOL libraries = self.pendingLibrariesRefresh;
            BOOL table = self.pendingTableRefresh;
            BOOL status = self.pendingStatusRefresh;
            self.pendingLibrariesRefresh = NO;
            self.pendingTableRefresh = NO;
            self.pendingStatusRefresh = NO;
            if (libraries) [self reloadLibraries];
            else if (table) [self refreshTable];
            else if (status) [self reloadStatus];
            [self updateInteractionState];
        }];
    };
    if (UIAccessibilityIsReduceMotionEnabled()) [UIView performWithoutAnimation:updates];
    else updates();
}

- (void)anchorSheet:(UIAlertController *)sheet category:(KBSection)category item:(NSInteger)item {
    NSInteger row = KBSettingsOptionIndex(category, item, self.expandedCategory);
    if (row == NSNotFound) row = KBSettingsOptionIndex(category, -1, self.expandedCategory);
    sheet.popoverPresentationController.sourceView = self.tableView;
    sheet.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:
        [NSIndexPath indexPathForRow:row inSection:[self.visibleSections indexOfObject:@(KBSectionOptions)]]];
}

- (void)chooseCandidateLimit {
    if (self.busy || self.respringRequestID.length || self.updatingOptions) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"候选数量"
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (NSNumber *value in KBCandidateLimitChoices()) {
        NSString *title = [NSString stringWithFormat:@"%@ 条%@", value,
            value.integerValue == self.candidateLimit ? @"（当前）" : @""];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            if (!weakSelf || weakSelf.busy || weakSelf.respringRequestID.length) return;
            weakSelf.candidateLimit = KBValidatedCandidateLimit(value.integerValue);
            NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:KBDefaultsSuite];
            [defaults setInteger:weakSelf.candidateLimit forKey:@"candidateLimit"];
            [defaults synchronize];
            [weakSelf refreshTable];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self anchorSheet:sheet category:KBSectionDisplay item:1];
    sheet.view.tintColor = UIColor.labelColor;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)selectOption:(KBSettingsOptionRow)option {
    if (option.item == -1) { [self toggleCategory:option.section]; return; }
    switch (option.section) {
        case KBSectionImport:
            switch (option.item) {
                case 0: [self chooseDictionary]; break;
                case 1: [self importFromLink]; break;
                case 2: [self scanLibraryFiles]; break;
                case 3: [self openFolder:[self displayedLibraryPath] scheme:@"filza"]; break;
                case 4: [self openFolder:[self displayedLibraryPath] scheme:@"fila"]; break;
                case 5:
                case 6: {
                    NSString *path = option.item == 5 ? [self displayedLibraryPath] : [KBKeyboardDirectory stringByAppendingPathComponent:@"libs"];
                    UIPasteboard.generalPasteboard.string = path;
                    self.statusText = [NSString stringWithFormat:@"已复制：%@", path];
                    [self reloadStatus];
                    [self scheduleStatusClear];
                    break;
                }
            }
            break;
        case KBSectionEntries:
            if (option.item == 0) [self openCustomEntries];
            else if (option.item == 1) [self editExclusionsForLibrary:[self displayedActiveLibraryName]];
            else if (option.item == 2) [self chooseQueryLibrary];
            break;
        case KBSectionDisplay:
            if (option.item == 1) [self chooseCandidateLimit];
            break;
        default: break;
    }
}

#pragma mark - 表格

- (NSArray<NSNumber *> *)visibleSections {
    NSArray *sections = KBSettingsSections();
    return self.displayedStatus ? [sections arrayByAddingObject:@(KBSectionMessage)] : sections;
}

- (KBSection)sectionAtIndex:(NSInteger)index {
    return (KBSection)[self.visibleSections[index] integerValue];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return self.visibleSections.count;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    KBSection group = [self sectionAtIndex:section];
    switch (group) {
        case KBSectionLibraries: return MAX((NSInteger)self.libraries.count + ([self displayedActiveLibraryName].length ? 1 : 0), 1);
        case KBSectionOptions: return KBSettingsOptionRowCount(self.expandedCategory);
        default: return KBSectionRowCount(group);
    }
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch ([self sectionAtIndex:section]) {
        case KBSectionLibraries: return @"词库";
        case KBSectionOptions: return @"功能设置";
        default: return nil;
    }
}
- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch ([self sectionAtIndex:section]) {
        case KBSectionLibraries: return @"点按切换；长按重命名或删除。";
        case KBSectionOptions: return @"点按分类原位展开，再次点按收起；过滤修改后会重新处理当前词库，本地无匹配时仍保留系统候选。";
        default: return nil;
    }
}
- (UITableViewCell *)tableView:(__unused UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    UIListContentConfiguration *content = [cell defaultContentConfiguration];
    KBStyleSettingsCell(cell, content);
    KBSection section = [self sectionAtIndex:indexPath.section];
    NSInteger row = indexPath.row;
    NSString *symbol = nil;
    UIView *control = nil;
    if (section == KBSectionLibraries) {
        if (self.libraries.count == 0) {
            content.text = @"还没有导入词库";
            content.secondaryText = @"先导入一份 Rime 词库";
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        } else if (row >= (NSInteger)self.libraries.count) {
            content.text = @"取消选择";
            content.secondaryText = @"不影响自定义词条";
            symbol = @"pause.circle";
        } else {
            KBLibrary *library = self.libraries[row];
            content.text = library.name;
            content.secondaryText = KBEntryCountText(library.accepted);
            symbol = @"character.book.closed";
            if (library.active) {
                UIImageView *mark = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark"]];
                mark.tintColor = UIColor.labelColor;
                mark.isAccessibilityElement = NO;
                control = mark;
                cell.accessibilityTraits |= UIAccessibilityTraitSelected;
                cell.accessibilityValue = @"当前词库";
            }
        }
    } else if (section == KBSectionOptions) {
        KBSettingsOptionRow option = KBSettingsOptionRowAtIndex(row, self.expandedCategory);
        if (option.item == -1) {
            switch (option.section) {
                case KBSectionImport: content.text = @"导入与管理"; break;
                case KBSectionEntries: content.text = @"词条管理"; break;
                case KBSectionDisplay: content.text = @"候选显示"; break;
                case KBSectionFilters: content.text = @"词库过滤"; break;
                default: break;
            }
            [self configureCategoryHeader:cell section:option.section];
        } else {
            NSInteger item = option.item;
            switch (option.section) {
                case KBSectionImport:
                    content.text = @[@"导入词库 zip…", @"从链接导入…", @"扫描词库文件",
                        @"用 Filza 打开当前位置", @"用 Fila 打开当前位置", @"复制当前词库路径", @"复制词库根目录"][item];
                    symbol = @[@"square.and.arrow.down", @"link", @"arrow.clockwise", @"folder", @"folder", @"doc.on.doc", @"doc.on.doc"][item];
                    if (item == 3 || item == 6) content.secondaryText = item == 6
                        ? [KBKeyboardDirectory stringByAppendingPathComponent:@"libs"] : [self displayedLibraryPath];
                    break;
                case KBSectionEntries:
                    content.text = @[@"自定义词条", @"排除词条", @"查询词库"][item];
                    symbol = @[@"text.badge.plus", @"nosign", @"magnifyingglass"][item];
                    control = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
                    control.tintColor = UIColor.labelColor;
                    control.isAccessibilityElement = NO;
                    if (item == 1 && ![self displayedActiveLibraryName].length) {
                        content.secondaryText = @"请先选择一份词库";
                        cell.userInteractionEnabled = NO;
                        cell.accessibilityTraits |= UIAccessibilityTraitNotEnabled;
                    }
                    break;
                case KBSectionDisplay:
                    content.text = item == 0 ? @"保留系统候选" : @"候选数量";
                    symbol = item == 0 ? @"list.bullet" : @"list.number";
                    if (item == 0) control = self.lexiconOnlySwitch;
                    else content.secondaryText = [NSString stringWithFormat:@"%ld 条", (long)self.candidateLimit];
                    break;
                case KBSectionFilters:
                    content.text = @[@"保留繁体词条", @"保留英文词条", @"过滤生僻字"][item];
                    symbol = @[@"character", @"textformat.abc", @"checkmark.seal"][item];
                    control = @[self.traditionalSwitch, self.asciiSwitch, self.commonOnlySwitch][item];
                    break;
                default: break;
            }
            if (![control isKindOfClass:UISwitch.class]) cell.accessibilityTraits |= UIAccessibilityTraitButton;
        }
    } else if (section == KBSectionSources) {
        content.text = @"启用本地词库";
        symbol = @"character.book.closed";
        control = self.localCandidatesSwitch;
    } else {
        content.text = self.statusText ?: @"正在处理…";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        if (self.busy) {
            UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
            [spinner startAnimating];
            cell.accessoryView = spinner;
        }
    }
    if ([control isKindOfClass:UISwitch.class]) {
        control.accessibilityLabel = content.text;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.isAccessibilityElement = NO;
        cell.accessibilityElements = @[control];
    }
    if (symbol) cell.accessoryView = KBSettingsAccessory(symbol, control);
    cell.contentConfiguration = content;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.respringRequestID.length || self.busy || self.updatingOptions) return;
    KBSection section = [self sectionAtIndex:indexPath.section];
    NSInteger row = indexPath.row;
    if (section == KBSectionOptions) {
        [self selectOption:KBSettingsOptionRowAtIndex(row, self.expandedCategory)];
        return;
    }
    if (section == KBSectionLibraries && self.libraries.count && row >= (NSInteger)self.libraries.count) {
        [self disableActiveLibrary];
        return;
    }

    if (section != KBSectionLibraries || self.libraries.count == 0 || self.busy) return;
    KBLibrary *library = self.libraries[row];
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
    KBSection section = [self sectionAtIndex:indexPath.section];
    NSInteger row = indexPath.row;
    __weak typeof(self) weakSelf = self;
    if (self.busy || self.respringRequestID.length || self.updatingOptions ||
        section != KBSectionLibraries || row >= (NSInteger)self.libraries.count) return nil;
    KBLibrary *library = self.libraries[row];
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

// 停用仅清空 active，保留词库文件；不暂停自定义词。
- (void)disableActiveLibrary {
    if (self.busy) return;
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:KBDefaultsSuite];
    NSTimeInterval stamp = [NSDate date].timeIntervalSince1970;
    [defaults setDouble:stamp forKey:@"disableAt"];
    [defaults setDouble:stamp forKey:@"requestStamp"];
    [defaults synchronize];
    [self beginBusy:@"正在取消选择…" stamp:stamp];
}

- (void)openCustomEntries {
    if (self.busy || self.respringRequestID.length) return;
    KBCustomController *controller = [KBCustomController new];
    controller.entries = self.customEntries ?: @[];
    __weak typeof(self) weakSelf = self;
    controller.onSave = ^(NSArray<NSDictionary *> *entries, void (^completion)(BOOL, NSString *)) {
        if (!weakSelf || weakSelf.busy || weakSelf.respringRequestID.length) {
            completion(NO, @"后台正在处理任务，请稍后重试。");
            return;
        }
        weakSelf.customCompletion = completion;
        [weakSelf saveCustomEntries:entries];
    };
    [self.navigationController pushViewController:controller animated:YES];
}

- (void)chooseQueryLibrary {
    if (self.busy || self.respringRequestID.length) return;
    // 使用主页面快照，不因展开或查询选择器重新扫描。
    if (!self.libraries.count) {
        self.statusText = @"请先导入一份词库。";
        [self reloadStatus];
        [self scheduleStatusClear];
        return;
    }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"查询哪份词库？"
        message:@"不会切换键盘正在使用的词库。" preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (KBLibrary *library in self.libraries) {
        [sheet addAction:[UIAlertAction actionWithTitle:library.name style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            KBLibraryQueryController *controller = [[KBLibraryQueryController alloc] initWithStyle:UITableViewStyleInsetGrouped];
            controller.libraryName = library.name;
            controller.indexPath = [[[KBKeyboardDirectory stringByAppendingPathComponent:@"libs"]
                stringByAppendingPathComponent:library.name] stringByAppendingPathComponent:@"index26.tsv"];
            [weakSelf.navigationController pushViewController:controller animated:YES];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self anchorSheet:sheet category:KBSectionEntries item:2];
    sheet.view.tintColor = UIColor.labelColor;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)saveCustomEntries:(NSArray<NSDictionary *> *)entries {
    NSData *data = [NSJSONSerialization dataWithJSONObject:entries ?: @[] options:0 error:NULL];
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
    alert.view.tintColor = UIColor.labelColor;
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
    alert.view.tintColor = UIColor.labelColor;
    [self presentViewController:alert animated:YES completion:nil];
}


- (NSString *)excludePathForLibrary:(NSString *)name {
    if (!name.length) return nil;
    return [[[KBKeyboardDirectory stringByAppendingPathComponent:@"libs"]
             stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"exclude.txt"];
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
    alert.view.tintColor = UIColor.labelColor;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)importFromLink {
    if (self.busy) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"从链接导入"
                                                                   message:@"粘贴 zip 的 https 地址，下载完会自动解压并设为当前词库。"
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
            warn.view.tintColor = UIColor.labelColor;
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
    alert.view.tintColor = UIColor.labelColor;
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
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"这份 zip 已经导入过"
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
        alert.view.tintColor = UIColor.labelColor;
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
        alert.view.tintColor = UIColor.labelColor;
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

- (void)localCandidatesChanged:(UISwitch *)sender {
    // 只改候选来源，不清除词库选择，不发重建请求。
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:KBDefaultsSuite];
    [defaults setBool:sender.isOn forKey:KBKeyLocalCandidates];
    [defaults setDouble:NSDate.date.timeIntervalSince1970 forKey:@"localCandidatesRevision"];
    [defaults synchronize];
}

- (void)optionChanged:(UISwitch *)sender {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:KBDefaultsSuite];
    if (self.busy) {
        self.traditionalSwitch.on = [defaults boolForKey:KBKeyTraditional];
        self.asciiSwitch.on = [defaults boolForKey:KBKeyASCII];
        self.commonOnlySwitch.on = [defaults objectForKey:@"commonOnly"] ? [defaults boolForKey:@"commonOnly"] : YES;
        self.lexiconOnlySwitch.on = ![defaults boolForKey:@"lexiconOnly"];
        return;
    }
    if (sender == self.lexiconOnlySwitch) {
        // 正向文案，仍兼容旧的反向偏好值；不重建索引。
        [defaults setBool:!sender.isOn forKey:@"lexiconOnly"];
        [defaults synchronize];
        self.statusText = @"候选显示已保存，等待后台读取";
        [self reloadStatus];
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

#pragma mark - 一次性重载请求（面板仅写固定数据）

- (NSString *)respringProblemForState:(NSDictionary *)state {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:KBDefaultsSuite];
    if (self.busy || [defaults doubleForKey:@"uiPendingRequest"] > 0)
        return @"正在导入或转换，请完成后再重载";
    if (self.respringRequestID.length) return @"已有重载请求正在等待结果，请勿重复点按";
    return KBRespringStateFailure(state, NSDate.date.timeIntervalSince1970);
}

- (void)showRespringProblem:(NSString *)message {
    self.statusText = message;
    [self refreshTable];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"暂时无法重载"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    alert.view.tintColor = UIColor.labelColor;
    if (!self.presentedViewController) [self presentViewController:alert animated:YES completion:nil];
}

- (void)requestRespring {
    if (self.presentedViewController) return;
    NSDictionary *state = KBRespringReadState(KBKeyboardDirectory);
    NSString *problem = [self respringProblemForState:state];
    if (problem) { [self showRespringProblem:problem]; return; }
    NSDictionary *request = @{@"version": @1, @"action": @(KBRespringActionReloadDesktop),
        @"id": NSUUID.UUID.UUIDString, @"session": state[@"session"], @"nonce": state[@"nonce"],
        @"createdAt": @(NSDate.date.timeIntervalSince1970)};
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:KBDefaultsSuite];
    [defaults setObject:request forKey:KBRespringRequestKey];
    BOOL saved = [defaults synchronize];
    notify_post(KBRespringNotification);
    [self restoreRespringRequest];
    if (!saved && self.respringRequestID.length) {
        self.statusText = @"请求保存尚未确认，正在等待回执；不会自动重试…";
        [self refreshTable];
    }
}

- (void)restoreRespringRequest {
    if (!self.respringRequestID.length) {
        NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:KBDefaultsSuite];
        id request = [defaults objectForKey:KBRespringRequestKey];
        if (![request isKindOfClass:NSDictionary.class] || !KBRespringUUID(request[@"id"]) ||
            !KBRespringUUID(request[@"session"]) || !KBRespringNumber(request[@"createdAt"])) return;
        NSTimeInterval age = NSDate.date.timeIntervalSince1970 - [request[@"createdAt"] doubleValue];
        if (age < 0 || age > 35.0) return;
        self.respringRequestID = request[@"id"];
        self.respringSession = request[@"session"];
        self.respringDeadline = NSProcessInfo.processInfo.systemUptime + 35.0 - age;
    }
    [self.statusTimer invalidate];
    self.statusTimer = nil;
    self.tableView.userInteractionEnabled = NO;
    self.navigationItem.rightBarButtonItem.enabled = NO;
    self.statusText = @"正在等待注销回执…";
    [self.respringTimer invalidate];
    self.respringTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self
        selector:@selector(pollRespring) userInfo:nil repeats:YES];
    [self pollRespring];
    [self refreshTable];
}

- (void)finishRespring:(NSString *)message {
    [self.respringTimer invalidate];
    self.respringTimer = nil;
    self.respringRequestID = nil;
    self.respringSession = nil;
    self.respringDeadline = 0;
    self.tableView.userInteractionEnabled = !self.updatingOptions;
    self.navigationItem.rightBarButtonItem.enabled = !self.busy;
    self.statusText = message;
    [self refreshTable];
}

- (void)pollRespring {
    if (!self.respringRequestID.length) return;
    NSDictionary *state = KBRespringReadState(KBKeyboardDirectory);
    if (KBRespringUUID(state[@"session"]) && ![state[@"session"] isEqual:self.respringSession]) {
        [self finishRespring:@"后台会话已变化，旧请求不会重放；实际是否已部分重载请观察设备。"];
        return;
    }
    id result = state[@"result"];
    if ([result isKindOfClass:NSDictionary.class] && [result[@"id"] isEqual:self.respringRequestID] &&
        [result[@"message"] isKindOfClass:NSString.class]) {
        if ([@[@"failed", @"rejected", @"submitted"] containsObject:result[@"status"] ?: @""]) {
            [self finishRespring:result[@"message"]];
            return;
        }
        if ([result[@"status"] isEqual:@"running"]) self.statusText = result[@"message"];
    }
    if (NSProcessInfo.processInfo.systemUptime >= self.respringDeadline) {
        [self finishRespring:@"未收到最终重载回执，可能未执行或已部分重载；不会自动重试。请检查后台与越狱权限。"];
        return;
    }
    [self refreshTable];
}

#pragma mark - 状态

// Freeze section membership until the option-row batch completes.
- (void)reloadStatus {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self reloadStatus]; });
        return;
    }
    if (self.updatingOptions) { self.pendingStatusRefresh = YES; return; }
    BOOL wasVisible = self.displayedStatus;
    BOOL visible = self.statusText.length || self.busy;
    self.displayedStatus = visible;
    [self updateInteractionState];
    NSIndexSet *section = [NSIndexSet indexSetWithIndex:KBSettingsSections().count];
    [UIView performWithoutAnimation:^{
        if (wasVisible && visible) {
            [self.tableView reloadSections:section withRowAnimation:UITableViewRowAnimationNone];
        } else if (visible) {
            [self.tableView insertSections:section withRowAnimation:UITableViewRowAnimationNone];
        } else if (wasVisible) {
            [self.tableView deleteSections:section withRowAnimation:UITableViewRowAnimationNone];
        }
    }];
}

- (void)beginBusy:(NSString *)status stamp:(NSTimeInterval)stamp {
    [self.statusTimer invalidate];
    self.statusTimer = nil;
    self.busy = YES;
    self.navigationItem.rightBarButtonItem.enabled = NO;
    self.statusText = status;
    self.requestTime = stamp;
    [self reloadStatus];
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
        [weakSelf reloadStatus];
    }];
}

- (void)pollOnce {
    if (self.requestTime <= 0) return;
    NSString *path = [KBKeyboardDirectory stringByAppendingPathComponent:@"last-import.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data) {
        NSDictionary *summary = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if ([summary isKindOfClass:[NSDictionary class]] && [summary[@"requestAt"] doubleValue] == self.requestTime) {
            if (self.customCompletion) {
                void (^completion)(BOOL, NSString *) = self.customCompletion;
                self.customCompletion = nil;
                completion([summary[@"ok"] boolValue], summary[@"reason"] ?: @"保存失败，请重试。");
            }
            if ([summary[@"scanned"] boolValue]) {
                NSUInteger added = [summary[@"installed"] unsignedIntegerValue] + [summary[@"converted"] unsignedIntegerValue];
                NSUInteger failed = [summary[@"failed"] unsignedIntegerValue];
                NSString *message = (added || failed) ? [NSString stringWithFormat:@"处理成功 %lu 个，失败 %lu 个；当前词库未切换。", (unsigned long)added, (unsigned long)failed] : @"没有发现需要处理的新文件；当前词库未切换。";
                [self finishBusy:message];
                if (failed) {
                    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"扫描结果"
                        message:[message stringByAppendingFormat:@"\n%@", summary[@"reason"] ?: @""] preferredStyle:UIAlertControllerStyleAlert];
                    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                    alert.view.tintColor = UIColor.labelColor;
                    [self presentViewController:alert animated:YES completion:nil];
                }
            } else if (![summary[@"ok"] boolValue]) {
                [self finishBusy:[summary[@"reason"] isKindOfClass:[NSString class]] ? summary[@"reason"] : @"操作失败，请重试"];
            } else if ([summary[@"deleted"] isKindOfClass:[NSString class]]) {
                [self finishBusy:[NSString stringWithFormat:@"已删除「%@」", summary[@"deleted"]]];
            } else if ([summary[@"switched"] isKindOfClass:[NSString class]]) {
                [self finishBusy:[NSString stringWithFormat:@"已切换到「%@」", summary[@"switched"]]];
            } else if ([summary[@"disabled"] boolValue]) {
                [self finishBusy:@"已取消当前词库选择，自定义词条不变"];
            } else if ([summary[@"renamed"] isKindOfClass:[NSString class]]) {
                [self finishBusy:[NSString stringWithFormat:@"已改名为「%@」", summary[@"renamed"]]];
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
        [self reloadStatus];
    }
}

@end

#pragma mark - 排除词条

@implementation KBExcludeListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.title = @"排除词条";
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
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
    KBStyleSettingsCell(cell, content);
    if (indexPath.row == (NSInteger)self.entries.count + 1) {
        content.text = @"从剪贴板添加…";
        content.secondaryText = @"每行一个，直接读剪贴板";
        cell.accessoryView = KBSettingsAccessory(@"square.and.pencil", nil);
        cell.contentConfiguration = content;
        return cell;
    }
    if (indexPath.row >= (NSInteger)self.entries.count) {
        content.text = @"添加排除词…";
        cell.accessoryView = KBSettingsAccessory(@"plus.circle", nil);
        cell.contentConfiguration = content;
        return cell;
    }
    cell.accessoryView = KBSettingsAccessory(@"nosign", nil);
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
        empty.view.tintColor = UIColor.labelColor;
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
        none.view.tintColor = UIColor.labelColor;
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
    alert.view.tintColor = UIColor.labelColor;
    [self presentViewController:alert animated:YES completion:nil];
}

@end
#pragma mark - 词库查询

@implementation KBLibraryQueryController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.title = @"查询词库";
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.queryStatus = @"输入拼音后点查询。";
    self.queryQueue = [NSOperationQueue new];
    self.queryQueue.maxConcurrentOperationCount = 1;
    self.queryQueue.qualityOfService = NSQualityOfServiceUserInitiated;
    UISearchBar *search = [UISearchBar new];
    search.delegate = self;
    search.tintColor = UIColor.labelColor;
    search.barTintColor = UIColor.systemGroupedBackgroundColor;
    search.searchTextField.backgroundColor = KBSettingsRowColor();
    search.searchTextField.textColor = UIColor.labelColor;
    search.searchTextField.leftView.tintColor = UIColor.labelColor;
    search.placeholder = @"拼音，例如 nihao 或 ni";
    search.autocapitalizationType = UITextAutocapitalizationTypeNone;
    search.autocorrectionType = UITextAutocorrectionTypeNo;
    search.returnKeyType = UIReturnKeySearch;
    [search sizeToFit];
    self.tableView.tableHeaderView = search;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    self.queryGeneration++;
    [self.queryQueue cancelAllOperations];
}

- (void)searchBar:(__unused UISearchBar *)searchBar textDidChange:(__unused NSString *)searchText {
    self.queryGeneration++;
    [self.queryQueue cancelAllOperations];
    self.rows = @[];
    self.queryStatus = @"输入拼音后点查询。";
    [self.tableView reloadData];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    NSUInteger generation = ++self.queryGeneration;
    [self.queryQueue cancelAllOperations];
    self.rows = @[];
    self.queryStatus = @"正在查询…";
    [self.tableView reloadData];
    NSString *input = [searchBar.text copy];
    NSString *path = [self.indexPath copy];
    __weak typeof(self) weakSelf = self;
    [self.queryQueue addOperationWithBlock:^{
        @autoreleasepool {
            NSString *failure = nil;
            NSArray *rows = KBLibraryQuery(path, input, 100, &failure);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!weakSelf || weakSelf.queryGeneration != generation) return;
                weakSelf.rows = rows ?: @[];
                weakSelf.queryStatus = failure ?: (rows.count
                    ? [NSString stringWithFormat:@"显示 %lu 条匹配记录%@", (unsigned long)rows.count, rows.count == 100 ? @"（达到显示上限）" : @""]
                    : @"未找到匹配词条。");
                [weakSelf.tableView reloadData];
            });
        }
    }];
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    return (NSInteger)self.rows.count;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(__unused NSInteger)section {
    return self.libraryName;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(__unused NSInteger)section {
    return [NSString stringWithFormat:@"%@\n按拼音前缀查本库，最多显示索引顺序前 100 条；不含自定义词，不代表键盘候选或上屏结果。", self.queryStatus ?: @""];
}

- (UITableViewCell *)tableView:(__unused UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    UIListContentConfiguration *content = [cell defaultContentConfiguration];
    KBStyleSettingsCell(cell, content);
    cell.accessoryView = KBSettingsAccessory(@"character.book.closed", nil);
    content.text = self.rows[indexPath.row][@"word"];
    content.secondaryText = self.rows[indexPath.row][@"pinyin"];
    cell.contentConfiguration = content;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

@end

#pragma mark - 自定义词条页

@implementation KBCustomController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.title = @"自定义词条";
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
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
    return @"词条优先于词库；点按编辑，长按删除。";
}

- (UITableViewCell *)tableView:(__unused UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    UIListContentConfiguration *content = [cell defaultContentConfiguration];
    KBStyleSettingsCell(cell, content);
    if (indexPath.row >= (NSInteger)self.entries.count) {
        content.text = @"添加词条…";
        cell.accessoryView = KBSettingsAccessory(@"plus.circle", nil);
        cell.contentConfiguration = content;
        return cell;
    }
    NSDictionary *entry = self.entries[indexPath.row];
    content.text = entry[@"word"];
    content.secondaryText = entry[@"pinyin"];
    cell.contentConfiguration = content;
    UIImageView *arrow = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    arrow.tintColor = UIColor.labelColor;
    arrow.isAccessibilityElement = NO;
    cell.accessoryView = KBSettingsAccessory(@"pencil", arrow);
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!self.saving) [self editEntryAtIndex:(NSUInteger)indexPath.row];
}

- (UIContextMenuConfiguration *)tableView:(__unused UITableView *)tableView
        contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
                                             point:(__unused CGPoint)point {
    if (self.saving || indexPath.row >= (NSInteger)self.entries.count) return nil;
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
            [entries removeObjectAtIndex:(NSUInteger)indexPath.row];
            [weakSelf submitEntries:entries];
        }];
        delete.attributes = UIMenuElementAttributesDestructive;
        return [UIMenu menuWithTitle:entry[@"word"] children:@[delete]];
    }];
}

- (void)submitEntries:(NSArray<NSDictionary *> *)entries {
    if (self.saving || !self.onSave) return;
    self.saving = YES;
    self.title = @"正在保存…";
    self.tableView.userInteractionEnabled = NO;
    __weak typeof(self) weakSelf = self;
    self.onSave(entries, ^(BOOL ok, NSString *message) {
        if (!weakSelf) return;
        weakSelf.saving = NO;
        weakSelf.title = @"自定义词条";
        weakSelf.tableView.userInteractionEnabled = YES;
        if (ok) weakSelf.entries = entries;
        [weakSelf.tableView reloadData];
        if (!ok) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"未保存" message:message preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            alert.view.tintColor = UIColor.labelColor;
            [weakSelf presentViewController:alert animated:YES completion:nil];
        }
    });
}

- (void)editEntryAtIndex:(NSUInteger)index {
    BOOL editing = index < self.entries.count;
    NSDictionary *entry = editing ? self.entries[index] : nil;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:editing ? @"编辑词条" : @"添加词条"
                                                                   message:@"词条优先于词库；拼音只填字母。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = entry[@"word"];
        field.placeholder = @"词条，例如 右滑";
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = entry[@"pinyin"];
        field.placeholder = @"拼音，例如 youhua";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:editing ? @"保存" : @"添加" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *word = [alert.textFields[0].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *pinyin = [alert.textFields[1].text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *failure = nil;
        NSArray *entries = KBCustomEntriesByEditing(weakSelf.entries ?: @[], index, word, pinyin, &failure);
        if (!entries) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertController *problem = [UIAlertController alertControllerWithTitle:@"未保存" message:failure preferredStyle:UIAlertControllerStyleAlert];
                [problem addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
                problem.view.tintColor = UIColor.labelColor;
                [weakSelf presentViewController:problem animated:YES completion:nil];
            });
            return;
        }
        [weakSelf submitEntries:entries];
    }]];
    alert.view.tintColor = UIColor.labelColor;
    [self presentViewController:alert animated:YES completion:nil];
}

@end
