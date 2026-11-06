#pragma once
#import <Foundation/Foundation.h>

// Foundation-only settings shared by the pane, daemon and probe.
static inline NSInteger KBValidatedCandidateLimit(NSInteger value) {
    return value >= 1 && value <= 20 ? value : 5;
}

static inline NSArray<NSNumber *> *KBCandidateLimitChoices(void) {
    return @[@5, @8, @10, @15, @20];
}

static inline NSString *KBEntryCountText(id value) {
    if (![value isKindOfClass:NSNumber.class] || [value longLongValue] < 0) return @"条数未记录";
    return [NSString stringWithFormat:@"%lld 条", [value longLongValue]];
}

typedef NS_ENUM(NSInteger, KBSection) {
    KBSectionSources, KBSectionDisplay, KBSectionLibraries, KBSectionImport,
    KBSectionFilters, KBSectionEntries, KBSectionOptions, KBSectionMessage
};

// BEGIN inline settings rows (pure row mapping, also exercised by host tests).
static inline KBSection KBSettingsCategoryAtIndex(NSInteger index) {
    const KBSection categories[] = {KBSectionImport, KBSectionEntries, KBSectionDisplay, KBSectionFilters};
    return index >= 0 && index < 4 ? categories[index] : KBSectionOptions;
}

static inline NSInteger KBSettingsCategoryRowCount(KBSection section) {
    switch (section) {
        case KBSectionImport: return 7;
        case KBSectionEntries: return 3;
        case KBSectionDisplay: return 2;
        case KBSectionFilters: return 3;
        default: return 0;
    }
}

static inline NSInteger KBSettingsOptionRowCount(KBSection expanded) {
    return 4 + KBSettingsCategoryRowCount(expanded);
}

typedef struct {
    KBSection section;
    NSInteger item; // -1 is the category header; nonnegative values are its actions.
} KBSettingsOptionRow;

static inline KBSettingsOptionRow KBSettingsOptionRowAtIndex(NSInteger index, KBSection expanded) {
    for (NSInteger group = 0; group < 4 && index >= 0; group++) {
        KBSection category = KBSettingsCategoryAtIndex(group);
        if (index == 0) return (KBSettingsOptionRow){category, -1};
        index--;
        NSInteger count = category == expanded ? KBSettingsCategoryRowCount(category) : 0;
        if (index < count) return (KBSettingsOptionRow){category, index};
        index -= count;
    }
    return (KBSettingsOptionRow){KBSectionOptions, -2};
}

static inline NSInteger KBSettingsOptionIndex(KBSection category, NSInteger item, KBSection expanded) {
    for (NSInteger index = 0; index < KBSettingsOptionRowCount(expanded); index++) {
        KBSettingsOptionRow row = KBSettingsOptionRowAtIndex(index, expanded);
        if (row.section == category && row.item == item) return index;
    }
    return NSNotFound;
}
// END inline settings rows.

static inline NSArray<NSNumber *> *KBSettingsSections(void) {
    return @[@(KBSectionSources), @(KBSectionLibraries), @(KBSectionOptions)];
}

static inline NSInteger KBSectionRowCount(KBSection section) {
    switch (section) {
        case KBSectionSources: return 1;
        case KBSectionOptions: return KBSettingsOptionRowCount(KBSectionOptions);
        case KBSectionMessage: return 1;
        default: return 0;
    }
}
