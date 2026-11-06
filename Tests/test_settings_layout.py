"""Source guards, not a UIKit runtime or animation-performance test."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SettingsLayoutSourceTests(unittest.TestCase):
    def setUp(self):
        self.ui = (ROOT / 'ImportPreferences/KBImportController.m').read_text(encoding='utf-8')
        self.primary = self.ui.split('@implementation KBImportController', 1)[1].split('\n@end', 1)[0]
        self.model = (ROOT / 'ImportPreferences/KBSettingsModel.h').read_text(encoding='utf-8')

    def test_main_page_keeps_sources_libraries_and_options(self):
        sections = self.model.split('KBSettingsSections(void)', 1)[1].split('}', 1)[0]
        self.assertEqual(re.findall(r'@\((KBSection\w+)\)', sections),
                         ['KBSectionSources', 'KBSectionLibraries', 'KBSectionOptions'])

    def test_categories_expand_rows_not_popup_menus(self):
        for symbol in ('showsMenuAsPrimaryAction', 'settingsMenuForSection:',
                       'settingsMenuElementsForSection:', 'UIDeferredMenuElement'):
            self.assertNotIn(symbol, self.primary)
        self.assertIn('performBatchUpdates:', self.primary)
        self.assertIn('insertRowsAtIndexPaths:', self.primary)
        self.assertIn('deleteRowsAtIndexPaths:', self.primary)
        self.assertIn('KBSettingsOptionRowAtIndex', self.primary)
        self.assertIn('KBSettingsOptionRowCount', self.primary)
        self.assertIn('UIAccessibilityIsReduceMotionEnabled()', self.primary)

    def test_original_context_menus_still_exist(self):
        self.assertIn('contextMenuConfigurationForRowAtIndexPath:', self.primary)
        for title in ('@"重命名"', '@"删除"', '@"设为当前"'):
            self.assertIn(title, self.primary)

    def test_native_grouped_background_has_no_custom_masks(self):
        self.assertIn('UITableViewStyleInsetGrouped', self.ui)
        for symbol in ('cornerRadius', 'masksToBounds', 'maskView', 'UIBlurEffect'):
            self.assertNotIn(symbol, self.ui)
        self.assertIn('UIColor.labelColor', self.ui)
        self.assertNotIn('UIColor.systemBlueColor', self.ui)

    def test_switches_and_candidate_preferences_are_preserved(self):
        for symbol in ('self.lexiconOnlySwitch', 'self.traditionalSwitch',
                       'self.asciiSwitch', 'self.commonOnlySwitch', 'self.localCandidatesSwitch'):
            self.assertIn(symbol, self.primary)
        self.assertIn('[defaults setBool:!sender.isOn forKey:@"lexiconOnly"]', self.primary)
        self.assertIn('KBCandidateLimitChoices()', self.primary)
        self.assertIn('forKey:@"candidateLimit"', self.primary)

    def test_paths_are_actions_without_an_extra_chooser(self):
        self.assertNotIn('chooseFileManagerForPath:', self.primary)
        for symbol in ('scheme:@"filza"', 'scheme:@"fila"', '@"复制词库根目录"', 'UIPasteboard'):
            self.assertIn(symbol, self.primary)

    def test_sheet_anchors_follow_expanded_row_mapping(self):
        self.assertGreaterEqual(self.primary.count('KBSettingsOptionIndex('), 2)
        self.assertNotIn('KBSettingsMenuSections', self.ui + self.model)

    def test_all_internal_lists_share_cell_style_and_trailing_icons(self):
        for name in ('KBImportController', 'KBExcludeListController', 'KBCustomController', 'KBLibraryQueryController'):
            body = self.ui.split('@implementation ' + name, 1)[1].split('\n@end', 1)[0]
            self.assertIn('KBStyleSettingsCell(cell, content)', body, name)
            self.assertIn('KBSettingsAccessory(', body, name)
            self.assertIn('UIColor.systemGroupedBackgroundColor', body, name)
            self.assertNotIn('content.image =', body, name)
        self.assertIn('search.searchTextField.backgroundColor = KBSettingsRowColor();', self.ui)

    def test_every_app_alert_has_public_tint_without_changing_destructive_roles(self):
        alerts = list(re.finditer(r'UIAlertController \*(\w+) = \[UIAlertController alertControllerWithTitle:', self.ui))
        self.assertGreater(len(alerts), 8)
        for match in alerts:
            name = match.group(1)
            tail = self.ui[match.end():]
            before_present = tail.split('presentViewController:' + name, 1)[0]
            self.assertIn(name + '.view.tintColor = UIColor.labelColor;', before_present, name)
        self.assertIn('UIAlertActionStyleDestructive', self.ui)
        self.assertIn('UIMenuElementAttributesDestructive', self.ui)

    def test_refreshes_wait_for_expansion_before_changing_data_source(self):
        def method(name):
            return self.primary.split('- (void)' + name, 1)[1].split('\n- (', 1)[0]
        libraries = method('reloadLibraries')
        self.assertLess(libraries.index('if (self.updatingOptions)'), libraries.index('contentsOfDirectoryAtPath:'))
        status = method('reloadStatus')
        self.assertLess(status.index('if (self.updatingOptions)'), status.index('self.displayedStatus = visible'))
        refresh = method('refreshTable')
        self.assertLess(refresh.index('if (self.updatingOptions)'), refresh.index('[self.tableView reloadData]'))
        self.assertEqual(self.primary.count('[self.tableView reloadData]'), 1)
        self.assertIn('return self.displayedStatus ?', self.primary)
        toggle = method('toggleCategory:')
        self.assertIn('old == category ? KBSectionOptions : category', toggle)
        for flag in ('pendingLibrariesRefresh', 'pendingTableRefresh', 'pendingStatusRefresh'):
            self.assertIn(flag, toggle)
        self.assertIn('self.expandedCategory = KBSectionOptions;', self.primary)

    def test_no_extra_runtime_diagnostics(self):
        for symbol in ('KBRuntimeStatus', 'runtimeTimer', 'refreshRuntimeStatus', 'KBSectionDiagnostics'):
            self.assertNotIn(symbol, self.ui + self.model)

    def test_documentation_describes_inline_expansion_and_direct_paths(self):
        readme = (ROOT / 'README.md').read_text(encoding='utf-8')
        self.assertIn('原位展开', readme)
        self.assertIn('一次只展开一组', readme)
        self.assertIn('直接', readme)
        self.assertNotIn('点按打开原生菜单', readme)


if __name__ == '__main__':
    unittest.main()
