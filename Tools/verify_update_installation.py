#!/usr/bin/env python3
"""Exercise Sparkle installation in UUID-labelled copies over a signed loopback feed."""

import argparse
import hashlib
import http.server
import json
import os
import pathlib
import plistlib
import shutil
import stat
import subprocess
import threading
import time
import urllib.parse
import uuid
import xml.etree.ElementTree as ET


PREFIX = 'com.shunnag.KaitoFinder.UpdateInstallVerification.'
SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'


def run(*command, timeout=120):
    result = subprocess.run([str(part) for part in command], capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'{command[0]} exited with {result.returncode}:\n{result.stdout}\n{result.stderr}')
    return result.stdout.strip()


def info(app):
    with (app / 'Contents/Info.plist').open('rb') as source:
        return plistlib.load(source)


def bundle_manifest(app):
    result = {}
    for item in sorted(app.rglob('*')):
        name = str(item.relative_to(app))
        if item.is_symlink():
            result[name] = {'symlink': os.readlink(item)}
        elif item.is_file():
            result[name] = {'sha256': hashlib.sha256(item.read_bytes()).hexdigest(),
                            'mode': stat.S_IMODE(item.stat().st_mode)}
    return result


def events(path):
    # A final JSON line may still be in flight while the app is running.
    return [json.loads(line) for line in path.read_text().splitlines(keepends=True) if line.endswith('\n')]


def clear_test_preferences(identifier):
    if not identifier.startswith(PREFIX):
        raise ValueError('Refusing to clear a non-test preference domain')
    uuid.UUID(identifier.removeprefix(PREFIX))
    subprocess.run(['defaults', 'delete', identifier], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    state = subprocess.run(['defaults', 'read', identifier], capture_output=True, text=True)
    # cfprefsd may retain an empty domain after deletion. Check remaining values,
    # not only the command's status or the existence of a preferences plist.
    if state.returncode == 0 and ''.join(state.stdout.split()) != '{}':
        raise RuntimeError('Test preference values remain after cleanup: ' + identifier)


def main():
    repository = pathlib.Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=pathlib.Path, required=True, help='Developer ID signed Release; read only')
    parser.add_argument('--sparkle-bin', type=pathlib.Path, required=True)
    parser.add_argument('--sparkle-framework', type=pathlib.Path)
    parser.add_argument('--identity', required=True, help='Existing Developer ID code-signing identity')
    parser.add_argument('--account', default='com.shunnag.KaitoFinder', help='Existing Sparkle keychain account')
    parser.add_argument('--output', type=pathlib.Path)
    parser.add_argument('--cases', nargs='+', choices=['manual', 'automatic', 'corrupt'],
                        default=['manual', 'automatic', 'corrupt'])
    parser.add_argument('--timeout', type=float, default=150)
    args = parser.parse_args()
    if args.timeout <= 0 or len(set(args.cases)) != len(args.cases):
        parser.error('Use a positive timeout and distinct cases')
    app = args.app.resolve(strict=True)
    app_info = info(app)
    if app.name != 'KaitoFinder.app' or app_info.get('CFBundleIdentifier') != 'com.shunnag.KaitoFinder':
        parser.error('Expected the real Release bundle as a read-only source')
    if not app_info.get('SURequireSignedFeed') or not app_info.get('SUVerifyUpdateBeforeExtraction'):
        parser.error('The source app must require signed feeds and pre-extraction verification')
    sparkle = args.sparkle_bin.resolve(strict=True)
    sdk = (args.sparkle_framework or app.parent / 'Sparkle.framework').resolve(strict=True)
    if run(sparkle / 'generate_keys', '--account', args.account, '-p') != app_info.get('SUPublicEDKey'):
        parser.error('The existing Sparkle signing account must match the source app')
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', app)
    original = bundle_manifest(app)
    output = (args.output or repository / 'build/UpdateInstallationVerification' / str(uuid.uuid4())).resolve()
    output.mkdir(parents=True, exist_ok=False)
    (output / 'TEST-ONLY-DO-NOT-PUBLISH.txt').write_text('UUID-labelled local installation verification. Not notarized for distribution.\n')
    root = output / ('kaitofinder-install-verify-' + str(uuid.uuid4()))
    root.mkdir(mode=0o700)
    driver, control = output / 'install-driver', output / 'control-test-app'
    run('xcrun', 'clang', '-fobjc-arc', '-mmacosx-version-min=26.0', '-F', sdk.parent,
        '-framework', 'AppKit', '-framework', 'Sparkle', '-Wl,-rpath,@executable_path/../Frameworks',
        repository / 'Tools/probe_update_installation.m', '-o', driver)
    run('xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6',
        repository / 'Tools/control_update_verification_app.swift', '-o', control)
    routes, requests = {}, []

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *arguments):
            pass

        def serve_file(self, body):
            path = urllib.parse.urlsplit(self.path).path
            source = routes.get(path)
            requests.append({'path': path, 'method': self.command, 'time': time.time()})
            if source is None:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header('Content-Type', 'application/rss+xml' if path.endswith('.xml') else 'application/octet-stream')
            self.send_header('Content-Length', str(source.stat().st_size))
            self.end_headers()
            if body:
                with source.open('rb') as content:
                    shutil.copyfileobj(content, self.wfile)

        def do_GET(self):
            self.serve_file(True)

        def do_HEAD(self):
            self.serve_file(False)

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    results, cleared_preferences = [], []

    def check(condition, message):
        if not condition:
            raise RuntimeError(message)

    def application(action, identifier, destination):
        return json.loads(run(control, action, identifier, destination, timeout=20))

    def resign(bundle):
        run('/usr/bin/codesign', '--force', '--sign', args.identity, '--options', 'runtime', '--timestamp=none', bundle)
        run('/usr/bin/codesign', '--verify', '--deep', '--strict', bundle)

    try:
        for mode in args.cases:
            print(f'Running {mode}; evidence: {output}', flush=True)
            case_root = root / mode
            case_root.mkdir()
            event_file = case_root / 'events.jsonl'
            event_file.touch(mode=0o600)
            identifier = PREFIX + str(uuid.uuid4())
            reference = case_root / 'reference/KaitoFinder.app'
            destination = case_root / 'installed/KaitoFinder.app'
            distribution = case_root / 'distribution'
            distribution.mkdir()
            feed_url = f'http://127.0.0.1:{server.server_port}/{mode}/appcast.xml'
            run('/usr/bin/ditto', app, reference)
            modified = dict(app_info, CFBundleIdentifier=identifier,
                            CFBundleName='KaitoFinder Update Verification', CFBundleDisplayName='KaitoFinder Update Verification',
                            SUFeedURL=feed_url, SUEnableAutomaticChecks=mode == 'automatic',
                            SUAutomaticallyUpdate=mode == 'automatic', SUAllowsAutomaticUpdates=True,
                            NSAppTransportSecurity={'NSAllowsLocalNetworking': True},
                            KaitoUpdateVerificationRoot=str(case_root), KaitoUpdateVerificationMode=mode)
            # Launching a test copy must not register archive handlers or Finder Services.
            for key in ['CFBundleDocumentTypes', 'CFBundleURLTypes', 'NSServices',
                        'UTImportedTypeDeclarations', 'UTExportedTypeDeclarations']:
                modified.pop(key, None)
            with (reference / 'Contents/Info.plist').open('wb') as target:
                plistlib.dump(modified, target)
            resign(reference)
            expected = bundle_manifest(reference)
            run('/usr/bin/ditto', reference, destination)
            old_info = dict(modified, CFBundleVersion='0', CFBundleShortVersionString='0.0.0')
            with (destination / 'Contents/Info.plist').open('wb') as target:
                plistlib.dump(old_info, target)
            executable = destination / 'Contents/MacOS' / app_info['CFBundleExecutable']
            shutil.copyfile(driver, executable)
            executable.chmod(0o755)
            resign(destination)
            before = bundle_manifest(destination)
            archive = distribution / 'KaitoFinder.zip'
            run('/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', reference, archive)
            prefix = f'http://127.0.0.1:{server.server_port}/{mode}/'
            run(sparkle / 'generate_appcast', '--account', args.account, '--maximum-deltas', '0',
                '--download-url-prefix', prefix, distribution)
            feed = distribution / 'appcast.xml'
            run(sparkle / 'sign_update', '--account', args.account, '--verify', feed)
            item = ET.parse(feed).find('./channel/item')
            check(item is not None and item.findtext(SPARKLE + 'version') == app_info['CFBundleVersion'], 'Wrong generated version')
            enclosure = item.find('enclosure')
            check(enclosure is not None and enclosure.get('url') == prefix + archive.name, 'Wrong download URL')
            check(int(enclosure.get('length', '0')) == archive.stat().st_size, 'Wrong download size')
            run(sparkle / 'sign_update', '--account', args.account, '--verify', archive,
                enclosure.attrib[SPARKLE + 'edSignature'])
            served = archive
            if mode == 'corrupt':
                served = distribution / 'modified.zip'
                payload = bytearray(archive.read_bytes())
                payload[len(payload) // 2] ^= 1
                served.write_bytes(payload)
            routes[f'/{mode}/appcast.xml'] = feed
            routes[f'/{mode}/{archive.name}'] = served
            run('defaults', 'write', identifier, 'ArchiveShowsWelcomeAtLaunch', '-bool', 'false')
            process = None
            running = []
            try:
                with (case_root / 'process.log').open('w') as log:
                    process = subprocess.Popen([str(executable)], stdout=log, stderr=subprocess.STDOUT)
                    deadline = time.monotonic() + args.timeout
                    while time.monotonic() < deadline:
                        rows = events(event_file)
                        failures = [row for row in rows if row['event'] == 'error']
                        if failures:
                            check(mode == 'corrupt', 'Unexpected updater error: ' + json.dumps(failures))
                            codes = {(error['domain'], error['code']) for row in failures for error in row['errors']}
                            check(any(domain == 'SUSparkleErrorDomain' and code in (3001, 3002) for domain, code in codes),
                                  'Modified archive failed for an unrelated reason: ' + json.dumps(failures))
                            process.wait(timeout=15)
                            check(bundle_manifest(destination) == before, 'Rejected update changed the installed bundle')
                            check(not any(row['event'] in ('ready-to-relaunch', 'ready-on-quit', 'will-install', 'installing', 'installed')
                                          for row in rows),
                                  'Modified archive reached installation')
                            break
                        check(not any(row['event'] in ('timeout', 'unexpected-user-interface', 'non-loopback-download-refused')
                                      for row in rows), 'Test driver rejected this update flow')
                        try:
                            installed = info(destination)['CFBundleVersion'] == app_info['CFBundleVersion']
                        except FileNotFoundError:
                            installed = False
                        if installed:
                            check(mode != 'corrupt', 'Modified archive was installed')
                            process.wait(timeout=15)
                            check(bundle_manifest(destination) == expected, 'Installed bundle differs from the signed update')
                            run('/usr/bin/codesign', '--verify', '--deep', '--strict', destination)
                            if mode == 'automatic':
                                check(any(row['event'] == 'ready-on-quit' for row in rows), 'Automatic update did not stage for quit')
                                check(not any(row['event'] == 'found' for row in rows), 'Automatic update prompted for manual installation')
                                quiet_until = time.monotonic() + 2
                                while time.monotonic() < quiet_until:
                                    check(not application('inspect', identifier, destination), 'Install on quit unexpectedly relaunched the app')
                                    time.sleep(0.2)
                                application('launch', identifier, destination)
                            else:
                                check(any(row['event'] == 'ready-to-relaunch' for row in rows), 'Manual update did not request relaunch')
                            while time.monotonic() < deadline:
                                running = application('inspect', identifier, destination)
                                if len(running) == 1 and running[0]['finishedLaunching'] and running[0]['pid'] != process.pid:
                                    break
                                time.sleep(0.2)
                            else:
                                raise RuntimeError('The installed KaitoFinder did not finish launching')
                            break
                        if process.poll() is not None and not any(row['event'] in ('will-relaunch', 'ready-on-quit') for row in rows):
                            raise RuntimeError('The test app exited before installation: ' + json.dumps(rows))
                        time.sleep(0.1)
                    else:
                        raise RuntimeError('Timed out waiting for update installation: ' + json.dumps(events(event_file)))
                result = {'mode': mode, 'identifier': identifier, 'passed': True,
                          'old_pid': process.pid, 'version': info(destination)['CFBundleVersion'],
                          'running_after_install': running,
                          'relaunch_kind': {'manual': 'sparkle', 'automatic': 'explicit-launch-after-quit', 'corrupt': 'none'}[mode],
                          'events': events(event_file), 'installed_manifest': bundle_manifest(destination)}
                (case_root / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
                results.append({key: result[key] for key in ['mode', 'identifier', 'passed', 'old_pid', 'version',
                                                           'running_after_install', 'relaunch_kind']})
                print(f'{mode}: passed', flush=True)
            finally:
                # Only the UUID-labelled app and preference domain are eligible for cleanup.
                application('terminate', identifier, destination)
                if process is not None and process.poll() is None:
                    process.wait(timeout=15)
                clear_test_preferences(identifier)
                cleared_preferences.append(identifier)
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
        (output / 'http-requests.json').write_text(json.dumps(requests, indent=2) + '\n')
        check(bundle_manifest(app) == original, 'The read-only source Release changed during verification')
    summary = {'source_app': str(app), 'source_version': app_info['CFBundleVersion'], 'source_manifest': original, 'results': results,
               'cleared_test_preferences': cleared_preferences,
               'limitations': 'Local Developer ID signed copies; not notarized, no GitHub publication, no standard update dialog interaction.'}
    (output / 'result.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(f'Installation verification passed. Evidence: {output}', flush=True)


if __name__ == '__main__':
    main()
