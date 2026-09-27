from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import sys
import tarfile

repo = Path('~/Github/KaitoFinder').expanduser()
root = repo / 'build/s41-p7a-correction-2-items'
previous = repo / 'build/P10S36Verification'
isolated = root
previous_isolated = previous / 'layout'
root.mkdir(parents=True, exist_ok=True)
isolated.mkdir(parents=True, exist_ok=True)

if '--prepare' in sys.argv:
    commits = {
        'KaitoFinder': '0e770d4',
        'GyoshukuKit': '8e35eba',
        'KaitoKit': '823ad46',
    }
    checks = {}
    for name, commit in commits.items():
        archive = root / (name + '.tar')
        source = repo if name == 'KaitoFinder' else repo.parent / name
        command = ['git', '-C', str(source), 'archive', '--format=tar', commit]
        with archive.open('wb') as output:
            subprocess.run(command, stdout=output, check=True)
        target = isolated / name
        target.mkdir(parents=True, exist_ok=True)
        subprocess.run(['tar', '-xf', str(archive), '-C', str(target)], check=True)
        with tarfile.open(archive) as contents:
            files = [item for item in contents if item.isfile() and item.name.startswith('Sources/')]
            mismatches = [item.name for item in files
                          if contents.extractfile(item).read() != (target / item.name).read_bytes()]
        checks[name] = {'commit': commit, 'archive_command': command,
                        'source_files': len(files), 'mismatches': mismatches}
        assert not mismatches, checks[name]
    (root / 'archive-checks.json').write_text(json.dumps(checks, indent=2) + '\n')
    print('Prepared pinned git archives in ' + str(isolated), flush=True)

if '--sync' in sys.argv:
    for folder in ['KaitoFinder', 'KaitoFinderTests', 'Tools', 'KaitoFinder.xcodeproj']:
        shutil.copytree(repo / folder, isolated / 'KaitoFinder' / folder, dirs_exist_ok=True)

hashes = {}
for name in ['KaitoKit', 'GyoshukuKit', 'app', 'test']:
    sources = (isolated / name / 'Sources' / name if name in ['KaitoKit', 'GyoshukuKit']
               else isolated / 'KaitoFinder' / ('KaitoFinder' if name == 'app' else 'KaitoFinderTests'))
    hashes[name] = {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in sorted(sources.rglob('*.swift'))}
(root / 'compiled-sources.json').write_text(json.dumps(hashes, indent=2) + '\n')

names = [name for name in sys.argv[1:] if not name.startswith('--')] or ['KaitoKit', 'GyoshukuKit', 'app', 'test']
for name in names:
    old = json.loads((previous / (name + '-command.json')).read_text())
    command = [arg.replace(str(previous_isolated), str(isolated)).replace(str(previous), str(root))
               for arg in old if not arg.endswith('.swift')]
    # Only Sparkle uses the prior framework directory; Swift modules come from this build.
    prior_products = str(repo / 'build/Review0924Opt/Build/Products/Debug')
    command = [arg for i, arg in enumerate(command)
               if not (arg == '-I' and i + 1 < len(command) and command[i + 1] == prior_products)
               and not (arg == prior_products and i > 0 and command[i - 1] == '-I')]
    command = [arg for arg in command if arg not in ['-Onone', '-O', '-Osize', '-Ounchecked', '-whole-module-optimization']]
    command += ['-O', '-whole-module-optimization', '-target', 'arm64-apple-macos26.0']
    command += list(hashes[name])
    if name == 'test':
        bundle = root / 'P1dAS33Tests.xctest/Contents'
        (bundle / 'MacOS').mkdir(parents=True, exist_ok=True)
        shutil.copy2(previous / 'P1dAS33Tests.xctest/Contents/Info.plist', bundle / 'Info.plist')
    (root / (name + '-command.json')).write_text(json.dumps(command, indent=2) + '\n')
    print('Compiling ' + name + ': ' + str(len(hashes[name])) + ' Swift files', flush=True)
    with (root / (name + '-build.log')).open('w') as log:
        result = subprocess.run(command, cwd=repo, stdout=log, stderr=subprocess.STDOUT)
    history_path = root / 'build-runs.json'
    history = json.loads(history_path.read_text()) if history_path.exists() else []
    history.append({'name': name, 'command': command, 'exit': result.returncode})
    history_path.write_text(json.dumps(history, indent=2) + '\n')
    print(name + ': exit ' + str(result.returncode), flush=True)
    if result.returncode:
        print((root / (name + '-build.log')).read_text()[-10000:])
        sys.exit(result.returncode)
