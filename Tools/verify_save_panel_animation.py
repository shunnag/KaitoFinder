#!/usr/bin/env python3
"""Record native save-panel transitions in an isolated app for visual regression review.

Requires Screen Recording permission for the invoking process. Does not request it.
The regular UI test also runs without this tool or any recording permission.
"""

import argparse
import json
import pathlib
import plistlib
import subprocess
import time
import uuid

from verify_ui_integration import configure_test_run, run


def main():
    repository = pathlib.Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--derived-data", type=pathlib.Path, default=repository / "build/SavePanelVerificationDerivedData")
    arguments = parser.parse_args()
    identifier = "com.shunnag.KaitoFinder.SavePanelVerification." + str(uuid.uuid4())
    output = repository / "build/SavePanelAnimationVerification" / identifier.rsplit(".", 1)[1]
    output.mkdir(parents=True)
    recorder = output / "recorder"
    subprocess.run(["swiftc", "-parse-as-library", "-module-cache-path", str(output / "ModuleCache"),
                    str(repository / "Tools/record_save_panel.swift"), "-o", str(recorder)], check=True)
    subprocess.run([str(recorder), "--check-permission"], check=True)
    derived = arguments.derived_data.resolve()
    run(["xcodebuild", "-project", str(repository / "KaitoFinder.xcodeproj"), "-scheme", "KaitoFinder",
         "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", str(derived),
         "PRODUCT_BUNDLE_IDENTIFIER=" + identifier, "build-for-testing"], output / "build.log", "** TEST BUILD SUCCEEDED **")
    candidates = list((derived / "Build/Products").glob("KaitoFinder_*.xctestrun"))
    if len(candidates) != 1:
        raise RuntimeError(f"Expected one test configuration: {candidates}")
    source = candidates[0]
    with source.open("rb") as file:
        configuration = configure_test_run(plistlib.load(file), source.parent,
            {"KAITOFINDER_SAVE_PANEL_CAPTURE_DIRECTORY": str(output)})
    test_run = output / "capture.xctestrun"
    with test_run.open("wb") as file:
        plistlib.dump(configuration, file)
    command = ["xcodebuild", "test-without-building", "-xctestrun", str(test_run),
               "-destination", "platform=macOS,arch=arm64",
               "-only-testing:KaitoFinderTests/ArchivePasswordUITests/testSavePanelResizesWithoutSlidingContents"]
    recorded = set()
    log = output / "capture.log"
    print(f"Recording save-panel transitions. Logs and videos: {output}", flush=True)
    with log.open("w") as file:
        process = subprocess.Popen(command, stdout=file, stderr=subprocess.STDOUT)
        try:
            while process.poll() is None:
                request = output / "request.json"
                if request.exists():
                    value = json.loads(request.read_text())
                    window = value["window"]
                    if window not in recorded:
                        folder = pathlib.Path(value["folder"]).resolve()
                        if not folder.is_relative_to(output):
                            raise RuntimeError("Recording path is outside this verification run")
                        subprocess.run([str(recorder), window, str(folder), identifier], check=True)
                        recorded.add(window)
                time.sleep(0.05)
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=20)
    if process.returncode or "** TEST EXECUTE SUCCEEDED **" not in log.read_text() or len(recorded) != 4:
        raise RuntimeError(f"Save-panel verification failed. Inspect {log}")
    print(f"All four native-panel cases passed. Review capture.mov in each folder: {output}", flush=True)


if __name__ == "__main__":
    main()
