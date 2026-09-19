#!/usr/bin/env python3
"""Exercise Finder-style input with real mouse events in an isolated test app."""
import argparse
import json
import pathlib
import plistlib
import subprocess
import uuid

from verify_ui_integration import configure_test_run, require_unlocked_session, run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--focused', action='store_true', help='Run only the Finder interaction tests')
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[1]
    output = root / 'build/FinderInteractionVerification' / str(uuid.uuid4())
    output.mkdir(parents=True)
    identifier = 'com.shunnag.KaitoFinder.FinderInteractionVerification.' + output.name
    derived = root / 'build/FinderInteractionDerivedData'
    require_unlocked_session(root, output)
    helper = output / 'drive-finder-interactions'
    subprocess.run(['swiftc', '-parse-as-library', str(root / 'Tools/drive_finder_interactions.swift'), '-o', str(helper)], check=True)
    run(['xcodebuild', '-project', str(root / 'KaitoFinder.xcodeproj'), '-scheme', 'KaitoFinder',
         '-destination', 'platform=macOS,arch=arm64', '-derivedDataPath', str(derived),
         'PRODUCT_BUNDLE_IDENTIFIER=' + identifier, 'build-for-testing'], output / 'build.log', '** TEST BUILD SUCCEEDED **')
    products = derived / 'Build/Products'
    source = next(products.glob('KaitoFinder_*.xctestrun'))
    request = output / 'input-request.json'
    configuration = configure_test_run(plistlib.loads(source.read_bytes()), products, {
        'KAITOFINDER_FINDER_INPUT_REQUEST': str(request), 'KAITOFINDER_SNAPSHOT_DIR': str(output / 'snapshots')})
    path = output / 'finder.xctestrun'
    path.write_bytes(plistlib.dumps(configuration))

    def input_requested():
        if request.exists():
            subprocess.run([str(helper), str(request)], check=True)
            request.unlink()
            request.with_suffix('.done').touch()

    suites = ['ArchiveFinderInteractionTests']
    if not args.focused:
        suites += ['ArchiveEntryControlsTests', 'ArchivePreferencesTests', 'ArchivePreferencesUITests',
                   'ApplicationCommandIntegrationTests', 'ArchiveDropIntegrationTests', 'ArchiveTabSpringLoadingTests',
                   'ArchivePreviewSidebarTests', 'LayoutOverflowTests', 'QuickLookOpenTests']
    command = ['xcodebuild', 'test-without-building', '-xctestrun', str(path), '-destination', 'platform=macOS,arch=arm64',
               '-parallel-testing-enabled', 'NO', '-resultBundlePath', str(output / 'finder.xcresult')]
    command += ['-only-testing:KaitoFinderTests/' + suite for suite in suites]
    try:
        run(command, output / 'finder.log', '** TEST EXECUTE SUCCEEDED **', set(suites), input_requested)
    finally:
        require_unlocked_session(root, output)
    (output / 'result.json').write_text(json.dumps({'bundle': identifier, 'suites': suites}, indent=2) + '\n')
    print('Finder interaction verification passed:', output, flush=True)


if __name__ == '__main__':
    main()
