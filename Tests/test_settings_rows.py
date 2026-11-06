"""Compile and execute the production pure-C row mapping, without UIKit/Foundation."""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

HARNESS = r'''
int main(void) {
    const KBSection categories[] = {KBSectionImport, KBSectionEntries, KBSectionDisplay, KBSectionFilters};
    const KBSection states[] = {KBSectionOptions, KBSectionImport, KBSectionEntries, KBSectionDisplay, KBSectionFilters};
    const NSInteger counts[] = {7, 3, 2, 3};
    assert(KBSettingsCategoryAtIndex(-1) == KBSectionOptions);
    assert(KBSettingsCategoryAtIndex(4) == KBSectionOptions);
    assert(KBSettingsCategoryRowCount(KBSectionOptions) == 0);
    for (NSInteger g = 0; g < 4; g++) {
        assert(KBSettingsCategoryAtIndex(g) == categories[g]);
        assert(KBSettingsCategoryRowCount(categories[g]) == counts[g]);
    }
    for (NSInteger s = 0; s < 5; s++) {
        KBSection state = states[s];
        NSInteger total = KBSettingsOptionRowCount(state);
        assert(total == 4 + (s ? counts[s - 1] : 0));
        NSInteger index = 0;
        for (NSInteger g = 0; g < 4; g++) {
            KBSettingsOptionRow header = KBSettingsOptionRowAtIndex(index, state);
            assert(header.section == categories[g] && header.item == -1);
            assert(KBSettingsOptionIndex(categories[g], -1, state) == index++);
            for (NSInteger item = 0; item < counts[g]; item++) {
                if (categories[g] != state) {
                    assert(KBSettingsOptionIndex(categories[g], item, state) == NSNotFound);
                    continue;
                }
                KBSettingsOptionRow row = KBSettingsOptionRowAtIndex(index, state);
                assert(row.section == categories[g] && row.item == item);
                assert(KBSettingsOptionIndex(categories[g], item, state) == index++);
            }
        }
        assert(index == total);
        assert(KBSettingsOptionRowAtIndex(-1, state).item == -2);
        assert(KBSettingsOptionRowAtIndex(total, state).item == -2);
        assert(KBSettingsOptionRowAtIndex(total + 100, state).item == -2);
        assert(KBSettingsOptionIndex(KBSectionOptions, -2, state) == NSNotFound);
        assert(KBSettingsOptionIndex(KBSectionImport, 100, state) == NSNotFound);
        // Simulate table batches: delete old content (old coordinates), then
        // insert new content (new coordinates); unchanged headers keep identity.
        for (NSInteger next = 0; next < 5; next++) {
            KBSettingsOptionRow rows[32];
            NSInteger length = 0;
            for (NSInteger i = 0; i < total; i++) {
                KBSettingsOptionRow row = KBSettingsOptionRowAtIndex(i, state);
                if (row.item == -1) rows[length++] = row;
            }
            assert(length == 4);
            NSInteger newTotal = KBSettingsOptionRowCount(states[next]);
            for (NSInteger i = 0; i < newTotal; i++) {
                KBSettingsOptionRow row = KBSettingsOptionRowAtIndex(i, states[next]);
                if (row.item < 0) continue;
                assert(i <= length);
                for (NSInteger j = length; j > i; j--) rows[j] = rows[j - 1];
                rows[i] = row;
                length++;
            }
            assert(length == newTotal);
            for (NSInteger i = 0; i < length; i++) {
                KBSettingsOptionRow expected = KBSettingsOptionRowAtIndex(i, states[next]);
                assert(rows[i].section == expected.section && rows[i].item == expected.item);
            }
        }
    }
    puts("Production row mapping: 5 states, 25 transitions, inverse anchors and boundaries passed.");
    return 0;
}
'''


class SettingsRowsTests(unittest.TestCase):
    def test_production_row_mapping_and_all_exclusive_transitions(self):
        compiler = shutil.which('cc') or shutil.which('clang')
        self.assertIsNotNone(compiler, 'A C compiler is required for the row mapping regression')
        model = (ROOT / 'ImportPreferences/KBSettingsModel.h').read_text()
        enum = re.search(r'typedef NS_ENUM\(NSInteger, KBSection\) \{(.*?)\};', model, re.S).group(1)
        functions = model.split('// BEGIN inline settings rows', 1)[1].split('\n', 1)[1]
        functions = functions.split('// END inline settings rows.', 1)[0]
        source = ('#include <assert.h>\n#include <limits.h>\n#include <stdio.h>\n'
                  'typedef long NSInteger;\n#define NSNotFound LONG_MAX\n'
                  'typedef enum {' + enum + '} KBSection;\n' + functions + HARNESS)
        with tempfile.TemporaryDirectory(prefix='keybridge-rows-') as tmp:
            path = Path(tmp)
            (path / 'rows.c').write_text(source)
            built = subprocess.run([compiler, '-std=c11', '-Wall', '-Wextra', '-Werror',
                                    str(path / 'rows.c'), '-o', str(path / 'rows')],
                                   capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stderr)
            result = subprocess.run([str(path / 'rows')], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('25 transitions', result.stdout)


if __name__ == '__main__':
    unittest.main()
