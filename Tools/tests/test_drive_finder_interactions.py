"""Build the native input driver and test key translation without posting events."""
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == 'darwin', 'Requires macOS keyboard layouts and XCTest')
class FinderInteractionDriverTests(unittest.TestCase):
    def test_keyboard_translation(self):
        tools = pathlib.Path(__file__).resolve().parents[1]
        sdk = subprocess.check_output(['xcrun', '--show-sdk-path'], text=True).strip()
        developer = pathlib.Path(subprocess.check_output(['xcrun', '--show-sdk-platform-path'], text=True).strip()) / 'Developer'
        with tempfile.TemporaryDirectory(prefix='kaito-keyboard-tests-') as temporary:
            output = pathlib.Path(temporary)
            common = ['xcrun', 'swiftc', '-sdk', sdk, '-parse-as-library',
                      '-module-cache-path', str(output / 'ModuleCache'), str(tools / 'drive_finder_interactions.swift')]
            subprocess.run(common + ['-o', str(output / 'drive-finder-interactions')], check=True)
            bundle = output / 'FinderInteractionKeyboardTests.xctest'
            contents = bundle / 'Contents'
            (contents / 'MacOS').mkdir(parents=True)
            (contents / 'Info.plist').write_bytes(plistlib.dumps({
                'CFBundleIdentifier': 'com.shunnag.KaitoFinder.FinderInteractionKeyboardTests',
                'CFBundleExecutable': 'FinderInteractionKeyboardTests', 'CFBundlePackageType': 'BNDL',
            }))
            frameworks, libraries = developer / 'Library/Frameworks', developer / 'usr/lib'
            subprocess.run(common + [
                '-D', 'FINDER_INTERACTION_DRIVER_TESTS', '-emit-library', '-module-name', 'FinderInteractionKeyboardTests',
                '-F', str(frameworks), '-I', str(libraries), '-L', str(libraries), '-lXCTestSwiftSupport',
                '-Xlinker', '-rpath', '-Xlinker', str(frameworks),
                '-Xlinker', '-rpath', '-Xlinker', str(libraries),
                str(tools / 'tests/drive_finder_interactions_tests.swift'),
                '-o', str(contents / 'MacOS/FinderInteractionKeyboardTests'),
            ], check=True)
            subprocess.run(['xcrun', 'xctest', str(bundle)], check=True)


if __name__ == '__main__':
    unittest.main()
