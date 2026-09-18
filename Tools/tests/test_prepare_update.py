"""Filesystem transaction tests; crypto/tool success is mocked, never claimed here."""
import importlib.util
import pathlib
import plistlib
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location('prepare_update', pathlib.Path(__file__).resolve().parents[1] / 'prepare_update.py')
prepare_update = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(prepare_update)


class PreparationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='kaito-prepare-transaction-')
        self.addCleanup(temporary.cleanup)
        self.root = pathlib.Path(temporary.name).resolve()
        self.app = self.root / 'KaitoFinder.app'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        (self.app / 'Contents/MacOS/KaitoFinder').write_bytes(b'project-owned test bundle')
        with (self.app / 'Contents/Info.plist').open('wb') as target:
            plistlib.dump({'CFBundleIdentifier': 'com.shunnag.KaitoFinder', 'CFBundleShortVersionString': '1.2.3',
                          'CFBundleVersion': '42', 'SUFeedURL': prepare_update.FEED,
                          'SURequireSignedFeed': True, 'SUVerifyUpdateBeforeExtraction': True,
                          'SUPublicEDKey': 'test-public-key'}, target)
        self.tools = self.root / 'tools'
        self.tools.mkdir()
        self.output = self.root / 'updates'
        self.notes = self.root / 'notes.md'
        self.notes.write_text('Project-owned release notes.\n')
        self.failure = None
        self.conflict = None
        self.visibility = []
        patcher = patch.object(prepare_update, 'run', self.tool)
        patcher.start()
        self.addCleanup(patcher.stop)

    def tool(self, *arguments):
        command = [str(value) for value in arguments]
        name = pathlib.Path(command[0]).name
        self.visibility.append(self.output.exists())
        if name == 'generate_keys':
            return 'test-public-key'
        if name in ('codesign', 'spctl', 'xcrun'):
            return ''
        if name == 'ditto':
            pathlib.Path(command[-1]).write_bytes(b'owned zip placeholder')
            self.fail_at('archive')
            return ''
        if name == 'generate_appcast':
            directory = pathlib.Path(command[-1])
            archive, = directory.glob('*.zip')
            prefix = command[command.index('--download-url-prefix') + 1]
            rss = ET.Element('rss')
            item = ET.SubElement(ET.SubElement(rss, 'channel'), 'item')
            ET.SubElement(item, prepare_update.SPARKLE + 'version').text = '42'
            ET.SubElement(item, 'enclosure', {'url': prefix + archive.name, 'length': str(archive.stat().st_size),
                                            prepare_update.SPARKLE + 'edSignature': 'mock-signature'})
            ET.ElementTree(rss).write(directory / 'appcast.xml')
            self.fail_at('appcast')
            return ''
        if name == 'sign_update':
            artifact = pathlib.Path(command[4])
            point = 'feed-signature' if artifact.name == 'appcast.xml' else 'archive-signature'
            self.fail_at(point)
            if point == 'archive-signature' and self.conflict:
                self.conflict()
            return ''
        raise AssertionError('Unexpected external tool: ' + repr(command))

    def fail_at(self, point):
        if self.failure == point:
            raise subprocess.CalledProcessError(1, point, stderr='simulated tool failure')
        if self.failure == 'interrupt' and point == 'archive-signature':
            raise KeyboardInterrupt()

    def prepare(self, notes=None):
        return prepare_update.prepare(self.app, self.tools, self.output, notes, 'test-account', test_only=True)

    def assert_no_staging(self):
        self.assertFalse([path.name for path in self.root.iterdir() if path.name.startswith('.kaitofinder-update-')])

    def test_late_failure_leaves_no_final_output_and_same_destination_can_retry(self):
        for phase in ('archive', 'appcast', 'feed-signature', 'archive-signature'):
            with self.subTest(phase=phase):
                self.failure = phase
                with self.assertRaises(subprocess.CalledProcessError):
                    self.prepare(self.notes)
                self.assertFalse(self.output.exists(), 'A failed generation must not look like a prepared release')
                self.assert_no_staging()
        self.failure = None
        archive, feed = self.prepare(self.notes)
        self.assertTrue(archive.is_file())
        self.assertTrue(feed.is_file())

    def test_success_exposes_complete_output_only_after_all_checks(self):
        archive, feed = self.prepare(self.notes)
        self.assertFalse(any(self.visibility), 'The final path must stay absent while external verification is running')
        self.assertEqual(archive, self.output / 'KaitoFinder-1.2.3.zip')
        self.assertEqual(feed, self.output / 'appcast.xml')
        self.assertEqual({item.name for item in self.output.iterdir()},
                         {'KaitoFinder-1.2.3.zip', 'KaitoFinder-1.2.3.md', 'appcast.xml', 'TEST-ONLY-DO-NOT-PUBLISH.txt'})
        self.assertEqual(archive.read_bytes(), b'owned zip placeholder')
        self.assertEqual(archive.with_suffix('.md').read_bytes(), self.notes.read_bytes())
        self.assert_no_staging()

    def test_invalid_or_missing_notes_leave_no_output(self):
        invalid = self.root / 'notes.rst'
        invalid.write_text('Unsupported notes format')
        for notes in [invalid, self.root / 'missing.md']:
            with self.subTest(notes=notes.name):
                with self.assertRaises((ValueError, OSError)):
                    self.prepare(notes)
                self.assertFalse(self.output.exists())
                self.assert_no_staging()

    def test_interrupt_cleans_incomplete_output(self):
        self.failure = 'interrupt'
        with self.assertRaises(KeyboardInterrupt):
            self.prepare(self.notes)
        self.assertFalse(self.output.exists())
        self.assert_no_staging()

    def test_existing_output_is_preserved(self):
        self.output.mkdir()
        sentinel = self.output / 'existing-appcast.xml'
        sentinel.write_bytes(b'existing signed feed')
        with self.assertRaises((ValueError, FileExistsError)):
            self.prepare()
        self.assertEqual(sentinel.read_bytes(), b'existing signed feed')
        self.assertEqual(list(self.output.iterdir()), [sentinel])

    def test_dangling_output_symlink_is_not_followed(self):
        other = self.root / 'symlink-target'
        self.output.symlink_to(other, target_is_directory=True)
        with self.assertRaises((ValueError, FileExistsError)):
            self.prepare()
        self.assertTrue(self.output.is_symlink())
        self.assertFalse(other.exists())

    def test_output_inside_source_app_is_rejected_without_changing_it(self):
        original = {str(p.relative_to(self.app)): p.read_bytes() for p in self.app.rglob('*') if p.is_file()}
        alias = self.root / 'app-alias'
        alias.symlink_to(self.app, target_is_directory=True)
        for app in [self.app, alias]:
            self.output = app / 'Contents/generated-updates'
            with self.subTest(app=app.name):
                with self.assertRaises(ValueError):
                    self.prepare()
                self.assertEqual({str(p.relative_to(self.app)): p.read_bytes() for p in self.app.rglob('*') if p.is_file()}, original)

    def test_concurrent_directory_created_before_publish_is_preserved(self):
        sentinel = self.output / 'other-job.txt'
        def conflict():
            self.output.mkdir(exist_ok=True)
            sentinel.write_text('other job')
        self.conflict = conflict
        with self.assertRaises(FileExistsError):
            self.prepare()
        self.assertEqual({p.name for p in self.output.iterdir()}, {'other-job.txt'})
        self.assertEqual(sentinel.read_text(), 'other job')
        self.assert_no_staging()

    def test_even_empty_concurrent_directory_is_not_replaced(self):
        self.conflict = lambda: self.output.mkdir(exist_ok=True)
        with self.assertRaises(FileExistsError):
            self.prepare()
        self.assertTrue(self.output.is_dir())
        self.assertEqual(list(self.output.iterdir()), [])
        self.assert_no_staging()


if __name__ == '__main__':
    unittest.main()
