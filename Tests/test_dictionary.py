"""Validate the downloadable sample, not the device converter or keyboard UI."""
from pathlib import Path
import re
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SAMPLE = ROOT / 'Tests'
DOWNLOAD = 'https://raw.githubusercontent.com/wm0104/keybridge/main/Tests/test.zip'
MARKERS = {('桥', 'dan'), ('蓝猫', 'ceshi'), ('红猫到家', 'bendiciku')}


class DictionaryTests(unittest.TestCase):
    def test_archive_matches_editable_source(self):
        with zipfile.ZipFile(SAMPLE / 'test.zip') as archive:
            self.assertIsNone(archive.testzip())
            self.assertEqual(archive.namelist(), ['test.dict.yaml'])
            self.assertEqual(archive.read('test.dict.yaml').decode('utf-8').replace('\r\n', '\n'),
                             (SAMPLE / 'test.dict.yaml').read_text(encoding='utf-8'))

    def test_records_are_valid_and_unique(self):
        text = (SAMPLE / 'test.dict.yaml').read_text(encoding='utf-8')
        rows = [line.split('\t') for line in text.split('\n...\n', 1)[1].splitlines() if line and not line.startswith('#')]
        self.assertEqual(len(rows), 902)
        self.assertEqual(len({(row[0], row[1]) for row in rows}), 902)
        for word, code, weight in rows:
            self.assertRegex(word, r'^[\u4e00-\u9fff]+$')
            self.assertRegex(code, r'^[a-z]+(?: [a-z]+)*$')
            if (word, code.replace(' ', '')) not in MARKERS:
                self.assertEqual(len(word), len(code.split()), word)
            self.assertGreaterEqual(int(weight), 0)
        pairs = {(word, code.replace(' ', '')) for word, code, _ in rows}
        for pair in [('你好', 'nihao'), ('测试', 'ceshi'), ('本地词库', 'bendiciku'),
                     ('蓝猫在测试词库', 'lanmaozaiceshiciku')]:
            self.assertIn(pair, pairs)
        self.assertTrue(MARKERS.issubset(pairs))
        digits = str.maketrans('abcdefghijklmnopqrstuvwxyz', '22233344455566677778889999')
        for marker, code in MARKERS:
            # Fixture ranking only, not the production converter or keyboard result.
            for nine in (False, True):
                key = code.translate(digits) if nine else code
                matches = [(word, int(weight)) for word, spelling, weight in rows
                           if (spelling.replace(' ', '').translate(digits) if nine
                               else spelling.replace(' ', '')).startswith(key)]
                self.assertEqual(max(matches, key=lambda pair: pair[1])[0], marker)
        self.assertEqual(sum(len(word) == 1 and code == 'shi' for word, code, _ in rows), 38)

    def test_readme_examples_and_local_links(self):
        readme = (ROOT / 'README.md').read_text(encoding='utf-8')
        digits = str.maketrans('abcdefghijklmnopqrstuvwxyz', '22233344455566677778889999')
        for code, keys in [('dan', '326'), ('ceshi', '23744'), ('bendiciku', '236342458')]:
            self.assertEqual(code.translate(digits), keys)
            self.assertIn(code, readme)
            self.assertIn(keys, readme)
        for target in re.findall(r'\]\(([^)]+)\)', readme):
            if not target.startswith(('https://', 'http://')):
                self.assertTrue((ROOT / target.split('?', 1)[0]).is_file(), target)
        self.assertNotIn('测试/测试说明.png', readme)
        self.assertFalse((SAMPLE / '测试说明.png').exists())
        self.assertIn('](' + DOWNLOAD + ')', readme)
        self.assertIn('```text\n' + DOWNLOAD + '\n```', readme)


if __name__ == '__main__':
    unittest.main()
