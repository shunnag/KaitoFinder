#!/usr/bin/env python3
"""Xcode 27 の app-hosted tests を、再コンパイルせず macOS 26 へ運ぶ。"""

import argparse
from collections import deque
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import sys


SKIP_CLASSES = (
    "ArchiveTabSpringLoadingTests",
    "ArchiveDropIntegrationTests",
    "ReadOnlyDropConversionUITests",
)
# macOS 26 の非アクティブな test host では toolbar の visibleItems が揃わない。
# Mac mini (macOS 27) と xcode-27 job で検証する。
MACOS_26_SKIP_METHODS = (
    "ApplicationCommandIntegrationTests/testToolbarAndResponderChainApplyEditsAndRespectTextFocus",
)
EXECUTED = re.compile(r"Executed (\d+) tests?, with (\d+) failures")
STARTED = re.compile(r"Test Case '-\[|Test case '.+' (?:started|passed|failed|skipped)|Executed \d+ tests?")
MISSING_TOOLS = re.compile(r"Required fixture tool is unavailable|7zz is not installed", re.I)


def output(*args):
    return subprocess.check_output(args, text=True).strip()


def manifest(stage):
    return json.loads((stage / "ci-runtime/manifest.json").read_text())


def test_run(products):
    candidates = list(products.glob("KaitoFinder_*.xctestrun"))
    if len(candidates) != 1:
        raise RuntimeError(f"Expected exactly one xctestrun: {candidates}")
    source = candidates[0]
    data = plistlib.loads(source.read_bytes())
    if data["__xctestrun_metadata__"]["FormatVersion"] != 1:
        raise RuntimeError("Only xctestrun FormatVersion 1 is supported")
    tests = data["KaitoFinderTests"]
    if not tests["IsAppHostedTestBundle"] or tests["TestHostPath"] != "__TESTROOT__/Debug/KaitoFinder.app":
        raise RuntimeError("Unexpected app-hosted test layout")
    if tests["TestBundlePath"] != "__TESTHOST__/Contents/PlugIns/KaitoFinderTests.xctest":
        raise RuntimeError("Unexpected test bundle layout")
    return source, data


def system_path(path):
    return str(path).startswith(("/usr/lib/", "/System/Library/", "/Library/Apple/System/Library/"))


def package(dd, stage, helpers):
    if not output("xcodebuild", "-version").startswith("Xcode 27."):
        raise RuntimeError("Packaging requires Xcode 27")
    root = Path.cwd().resolve()
    dd = dd.resolve()
    products = dd / "Build/Products"
    test_run(products)
    if stage.exists():
        raise RuntimeError(f"Stage must be fresh: {stage}")
    runtime = stage / "ci-runtime"
    (runtime / "Frameworks").mkdir(parents=True)
    (runtime / "usr/lib").mkdir(parents=True)
    shutil.copytree(products, stage / "Products", symlinks=True)
    shutil.copytree(helpers, runtime / "bin", symlinks=True)
    developer = Path(output("xcode-select", "-p"))
    macos = developer / "Platforms/MacOSX.platform/Developer"
    search_paths = [
        macos / "Library/Frameworks", macos / "Library/PrivateFrameworks", macos / "usr/lib",
        macos / "usr/lib/swift/macosx", developer / "Library/Frameworks",
        developer / "Library/PrivateFrameworks", developer / "usr/lib", developer.parent / "SharedFrameworks",
        developer / "Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx",
        products / "Debug", products / "Debug/PackageFrameworks",
    ]
    app = products / "Debug/KaitoFinder.app"
    executable = app / "Contents/MacOS/KaitoFinder"
    queue = deque()
    copied = {}

    def copy_dependency(binary):
        binary = binary.resolve()
        framework = next((p for p in binary.parents if p.suffix == ".framework"), None)
        source = framework or binary
        target = runtime / ("Frameworks" if framework else "usr/lib") / source.name
        if target in copied and copied[target] != source:
            raise RuntimeError(f"Conflicting runtime dependency: {target}: {copied[target]} / {source}")
        if target not in copied:
            copied[target] = source
            if framework:
                shutil.copytree(source, target, symlinks=True)
            else:
                shutil.copy2(source, target)
            print(f"Runtime: {source} -> {target.relative_to(stage)}", flush=True)
        return binary

    # platform copy を優先し、SharedFrameworks の同名 XCTest を混ぜない。
    for folder in (macos / "Library/Frameworks", macos / "Library/PrivateFrameworks"):
        for framework in sorted(folder.glob("*.framework")):
            info = plistlib.loads((framework / "Resources/Info.plist").read_bytes())
            binary = copy_dependency(framework / info["CFBundleExecutable"])
            queue.append((binary, executable, []))
    for name in ("libXCTestBundleInject.dylib", "libXCTestSwiftSupport.dylib", "lib_TestingInterop.dylib"):
        binary = copy_dependency(macos / "usr/lib" / name)
        queue.append((binary, executable, []))
    checker = developer / "usr/lib/libMainThreadChecker.dylib"
    if checker.exists():
        queue.append((copy_dependency(checker), executable, []))

    # app / debug dylib / tests / package framework の strong dependency も検査する。
    for binary in products.rglob("*"):
        # fixture には古い arch の SFX もある。実行する製品だけを dependency root にする。
        if "Resources" in binary.parts or any(part.endswith(".dSYM") for part in binary.parts):
            continue
        if binary.is_file() and not binary.is_symlink():
            with binary.open("rb") as stream:
                magic = stream.read(4)
            if magic in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
                queue.append((binary, executable, []))
    visited = set()
    resolved_rpaths = {}

    def expand(value, binary, host):
        return Path(value.replace("@loader_path", str(binary.parent)).replace(
            "@executable_path", str(host.parent))).resolve()

    while queue:
        binary, host, inherited = queue.popleft()
        binary = binary.resolve()
        if binary in visited or system_path(binary):
            continue
        visited.add(binary)
        slices = output("lipo", "-archs", str(binary)).split()
        architecture = "arm64" if "arm64" in slices else "arm64e"
        if architecture not in slices:
            raise RuntimeError(f"No Apple Silicon slice: {binary}: {slices}")
        loads = output("otool", "-arch", architecture, "-l", str(binary))
        dependencies = output("otool", "-arch", architecture, "-L", str(binary))
        print(dependencies, flush=True)
        rpaths = [expand(m, binary, host) for m in re.findall(
            r"cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.*?) \(offset \d+\)", loads)]
        rpaths = list(dict.fromkeys([*rpaths, *inherited]))
        weak = set(re.findall(r"cmd LC_LOAD_WEAK_DYLIB\n\s+cmdsize \d+\n\s+name (.*?) \(offset \d+\)", loads))
        for name in re.findall(r"^\s+(.+?) \(compatibility version", dependencies, re.M):
            if name in weak:
                print(f"Skip weak dependency: {name}", flush=True)
                continue
            if system_path(name):
                continue
            if name.startswith("@rpath/"):
                suffix = name.removeprefix("@rpath/")
                candidates = [p / suffix for p in [*rpaths, *search_paths]]
                # XCTest が SharedFrameworks を LC_RPATH に持っていても platform を優先する。
                for preferred in reversed(search_paths[:2]):
                    candidates.insert(0, preferred / suffix)
                if name in resolved_rpaths:
                    candidates.insert(0, resolved_rpaths[name])
            else:
                candidates = [expand(name, binary, host)]
            dependency = next((p.resolve() for p in candidates if p.is_file()), None)
            if dependency is None:
                raise RuntimeError(f"Unresolved strong dependency {name} from {binary}")
            if dependency == binary or system_path(dependency):
                continue
            if name.startswith("@rpath/"):
                resolved_rpaths[name] = dependency
            if not dependency.is_relative_to(products):
                copy_dependency(dependency)
            queue.append((dependency, host, rpaths))

    repos = {}
    for name, path in (("KaitoFinder", root), ("KaitoKit", root.parent / "KaitoKit"),
                       ("GyoshukuKit", root.parent / "GyoshukuKit")):
        repos[name] = {"path": str(path.resolve()), "sha": output("git", "-C", str(path), "rev-parse", "HEAD")}
    metadata = {"repos": repos, "derived_data": str(dd), "runner_temp": os.environ.get("RUNNER_TEMP"),
                "xcode": output("xcodebuild", "-version"), "deployment_target": "26.0"}
    (runtime / "manifest.json").write_text(json.dumps(metadata, indent=2) + "\n")
    selectors = runtime / "selectors.json"
    selectors.write_text(json.dumps({"run": [], "skip": [
        f"KaitoFinderTests.{identifier}" for identifier in (*SKIP_CLASSES, *MACOS_26_SKIP_METHODS)
    ]}, indent=2) + "\n")
    bundle = app / "Contents/PlugIns/KaitoFinderTests.xctest"
    # 絶対 bundle path は restore 時の manifest 検査で一致を保証する。
    subprocess.run([str(helpers / "make-xctest-configuration"),
                    str(macos / "Library/PrivateFrameworks/XCTestCore.framework/XCTestCore"), str(bundle),
                    str(selectors), str(runtime / "direct.xctestconfiguration")], check=True)
    print(json.dumps(metadata, indent=2), flush=True)


def restore(stage, dd):
    metadata = manifest(stage)
    root = Path.cwd().resolve()
    if metadata["repos"]["KaitoFinder"] != {"path": str(root), "sha": output("git", "rev-parse", "HEAD")}:
        raise RuntimeError("KaitoFinder checkout path/SHA differs from build job")
    if metadata["derived_data"] != str(dd.resolve()) or metadata["runner_temp"] != os.environ["RUNNER_TEMP"]:
        raise RuntimeError("DerivedData / RUNNER_TEMP differs from build job; absolute LC_RPATH would be invalid")
    for name in ("KaitoKit", "GyoshukuKit"):
        recorded = metadata["repos"][name]
        path = root.parent / name
        if str(path.resolve()) != recorded["path"] or not re.fullmatch(r"[0-9a-f]{40}", recorded["sha"]):
            raise RuntimeError(f"Invalid sibling path/SHA: {name}: {recorded}")
        subprocess.run(["git", "clone", "--no-checkout", f"https://github.com/shunnag/{name}.git", str(path)], check=True)
        subprocess.run(["git", "-C", str(path), "checkout", "--detach", recorded["sha"]], check=True)
        if output("git", "-C", str(path), "rev-parse", "HEAD") != recorded["sha"]:
            raise RuntimeError(f"Sibling SHA differs: {name}")
        print(f"Verified {name}: {path}: {recorded['sha']}", flush=True)
    if (dd / "Build/Products").exists():
        raise RuntimeError("Refuse to mix with existing DerivedData products")
    (dd / "Build").mkdir(parents=True, exist_ok=True)
    shutil.move(str(stage / "Products"), str(dd / "Build/Products"))
    print(json.dumps(metadata, indent=2), flush=True)


def patch(products, runtime, only):
    source, data = test_run(products)
    tests = data["KaitoFinderTests"]
    environment = tests.setdefault("TestingEnvironmentVariables", {})
    environment["DYLD_FRAMEWORK_PATH"] = f"{runtime}/Frameworks:__TESTROOT__/Debug:__TESTROOT__/Debug/PackageFrameworks"
    environment["DYLD_LIBRARY_PATH"] = f"{runtime}/usr/lib:__TESTROOT__/Debug"
    # Xcode 26 の __DEVELOPERUSRLIB__ / __SHAREDFRAMEWORKS__ を使わない。
    # checker は Debug host の診断専用。Xcode 27 の copy があれば使う。
    inserts = [str(runtime / "usr/lib/libXCTestBundleInject.dylib")]
    if (runtime / "usr/lib/libMainThreadChecker.dylib").exists():
        inserts.append(str(runtime / "usr/lib/libMainThreadChecker.dylib"))
    inserts.append("/usr/lib/libRPAC.dylib")
    environment["DYLD_INSERT_LIBRARIES"] = ":".join(inserts)
    environment.update(CI="1", TEST_RUNNER_CI="1")
    # xcodebuild.xctestrun(5) の identifier は target 内の Class[/method]。
    tests["SkipTestIdentifiers"] = list(dict.fromkeys([
        *tests.get("SkipTestIdentifiers", []), *SKIP_CLASSES, *MACOS_26_SKIP_METHODS]))
    if only:
        tests["OnlyTestIdentifiers"] = only
    tests.update(TestTimeoutsEnabled=True, DefaultTestExecutionTimeAllowance=600,
                 MaximumTestExecutionTimeAllowance=600, InProcessParallelizationEnabled=False)
    # __TESTROOT__ は xctestrun の親なので Products 直下に書く。
    target = source.with_name("ci-macos-26.xctestrun")
    target.write_bytes(plistlib.dumps(data))
    subprocess.run(["plutil", "-p", str(target)], check=True)
    bundle = products / "Debug/KaitoFinder.app/Contents/PlugIns/KaitoFinderTests.xctest/Contents/MacOS/KaitoFinderTests"
    subprocess.run(["otool", "-L", str(bundle)], check=True)
    print(json.dumps(environment, indent=2), flush=True)


def guard(log):
    text = log.read_text(errors="replace")
    summaries = EXECUTED.findall(text)
    if not summaries or not any(int(count) > 0 for count, _ in summaries):
        raise RuntimeError("No positive XCTest execution summary")
    if any(int(failures) for _, failures in summaries):
        raise RuntimeError("XCTest reported failures")
    if MISSING_TOOLS.search(text):
        raise RuntimeError("Fixture tools silently skipped tests")
    print(f"Verified nonzero tests / zero failures / fixture tools: {log}")


def fallback_eligible(log, exit_code):
    text = log.read_text(errors="replace") if log.exists() else ""
    # 一件でも開始していれば assertion failure / timeout を fallback で隠さない。
    # Executed 0 tests の summary も primary の結果として保持し、再実行しない。
    return exit_code != 0 and not STARTED.search(text)


def direct(products, runtime, timeout):
    app = products / "Debug/KaitoFinder.app"
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(("KAITOFINDER_", "TEST_RUNNER_KAITOFINDER_", "XCTest", "DYLD_"))}
    environment.update(
        DYLD_INSERT_LIBRARIES=str(runtime / "usr/lib/libXCTestBundleInject.dylib"),
        DYLD_FRAMEWORK_PATH=f"{runtime}/Frameworks:{products}/Debug:{products}/Debug/PackageFrameworks",
        DYLD_LIBRARY_PATH=f"{runtime}/usr/lib:{products}/Debug",
        XCTestBundlePath=str(app / "Contents/PlugIns/KaitoFinderTests.xctest"),
        XCTestConfigurationFilePath=str(runtime / "direct.xctestconfiguration"), CI="1", TEST_RUNNER_CI="1")
    if not Path(environment["XCTestConfigurationFilePath"]).is_file():
        raise RuntimeError("Missing pre-generated XCTest configuration; refuse unfiltered execution")
    print(json.dumps({k: v for k, v in environment.items() if k.startswith(("DYLD_", "XCTest")) or k == "CI"}, indent=2), flush=True)
    command = [str(app / "Contents/MacOS/KaitoFinder")]
    print(f"Direct executable (no env/arch wrapper): {command}", flush=True)
    # Python sets env in posix_spawn/exec, after any SIP-protected parent has launched.
    # stdout は tee 側へ流し、プロセスグループは timeout / step cancel 時にも回収する。
    process = subprocess.Popen(command, env=environment, start_new_session=True)

    def cleanup(signum=None, frame=None):
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        if signum:
            raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, cleanup)
    signal.signal(signal.SIGINT, cleanup)
    try:
        code = process.wait(timeout=timeout)
        print(f"Direct host exit status: {code}", flush=True)
        if code != 0:
            raise RuntimeError(f"Direct test host failed: {code}")
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"Direct test host timed out after {timeout}s")
    finally:
        cleanup()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    package_parser = commands.add_parser("package")
    package_parser.add_argument("dd", type=Path)
    package_parser.add_argument("stage", type=Path)
    package_parser.add_argument("helpers", type=Path)
    restore_parser = commands.add_parser("restore")
    restore_parser.add_argument("stage", type=Path)
    restore_parser.add_argument("dd", type=Path)
    patch_parser = commands.add_parser("patch")
    patch_parser.add_argument("products", type=Path)
    patch_parser.add_argument("runtime", type=Path)
    patch_parser.add_argument("--only", action="append", default=[])
    guard_parser = commands.add_parser("guard")
    guard_parser.add_argument("log", type=Path)
    eligible = commands.add_parser("fallback-eligible")
    eligible.add_argument("log", type=Path)
    eligible.add_argument("exit_code", type=int)
    direct_parser = commands.add_parser("direct")
    direct_parser.add_argument("products", type=Path)
    direct_parser.add_argument("runtime", type=Path)
    direct_parser.add_argument("--timeout", type=int, default=13800)
    args = parser.parse_args()
    if args.command == "package":
        package(args.dd, args.stage, args.helpers)
    elif args.command == "restore":
        restore(args.stage, args.dd)
    elif args.command == "patch":
        patch(args.products.resolve(), args.runtime.resolve(), args.only)
    elif args.command == "guard":
        guard(args.log)
    elif args.command == "fallback-eligible":
        sys.exit(0 if fallback_eligible(args.log, args.exit_code) else 1)
    elif args.command == "direct":
        direct(args.products.resolve(), args.runtime.resolve(), args.timeout)


if __name__ == "__main__":
    main()
