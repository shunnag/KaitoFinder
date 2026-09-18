#!/usr/bin/env python3
"""Probe a prepared feed with real Sparkle using isolated bundles and a loopback server."""

import argparse
import functools
import http.server
import json
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import threading
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=pathlib.Path, required=True)
    parser.add_argument("--prepared-update", type=pathlib.Path, required=True)
    parser.add_argument("--sparkle-framework", type=pathlib.Path, help="Unstripped Sparkle.framework SDK (defaults to the app's build products directory)")
    args = parser.parse_args()
    repository = pathlib.Path(__file__).resolve().parents[1]
    with (args.app / "Contents/Info.plist").open("rb") as file:
        app_info = plistlib.load(file)
    with tempfile.TemporaryDirectory(prefix="kaitofinder-update-probe-") as directory:
        root = pathlib.Path(directory)
        feed = args.prepared_update / "appcast.xml"
        shutil.copyfile(feed, root / "appcast.xml")
        (root / "tampered.xml").write_bytes(feed.read_bytes().replace(b"<title>", b"<title>Modified ", 1))
        class Handler(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *args):
                pass
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=root))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        binary = root / "probe"
        frameworks = args.app.resolve() / "Contents/Frameworks"
        sdk = args.sparkle_framework or args.app.resolve().parent / "Sparkle.framework"
        if not (sdk / "Modules/module.modulemap").exists():
            parser.error("Specify --sparkle-framework with a Sparkle.framework containing headers and modules.")
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                        "-module-cache-path", str(root / "modules"), "-F", str(sdk.resolve().parent), "-framework", "Sparkle",
                        "-Xlinker", "-rpath", "-Xlinker", str(frameworks),
                        str(repository / "Tools/probe_software_update.swift"), "-o", str(binary)], check=True)
        def probe(version, filename):
            identifier = "com.shunnag.KaitoFinder.UpdateProbe." + str(uuid.uuid4())
            bundle = root / (identifier + ".app")
            contents = bundle / "Contents"
            (contents / "MacOS").mkdir(parents=True)
            shutil.copyfile(binary, contents / "MacOS/probe")
            (contents / "MacOS/probe").chmod(0o755)
            info = dict(app_info, CFBundleIdentifier=identifier, CFBundleExecutable="probe", CFBundleVersion=version,
                        SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False,
                        SUFeedURL=f"http://127.0.0.1:{server.server_port}/{filename}",
                        NSAppTransportSecurity={"NSAllowsLocalNetworking": True})
            with (contents / "Info.plist").open("wb") as file:
                plistlib.dump(info, file)
            try:
                result = subprocess.run([str(contents / "MacOS/probe"), str(bundle)],
                                        check=True, text=True, capture_output=True, timeout=30)
                data = json.loads(result.stdout.splitlines()[-1])
                print(filename, "from", version, json.dumps(data), flush=True)
                return data
            finally:
                # Only this random test domain is removed, never the application's settings.
                subprocess.run(["defaults", "delete", identifier], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            available = probe("0", "appcast.xml")
            assert available["finished"] and available["version"] == app_info["CFBundleVersion"] and available["errorCode"] == 0
            current = probe(app_info["CFBundleVersion"], "appcast.xml")
            assert current["finished"] and current["version"] == "" and current["errorCode"] == 1001  # SUNoUpdateError
            tampered = probe("0", "tampered.xml")
            assert tampered["finished"] and tampered["version"] == ""
            assert tampered["errorDomain"] == "SUSparkleErrorDomain" and tampered["errorCode"] == 1000  # SUAppcastParseError
            print("Sparkle detected the update, reported the current version, and rejected the modified signed feed.")
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    main()
