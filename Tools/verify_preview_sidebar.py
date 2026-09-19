#!/usr/bin/env python3
"""Build an isolated app, exercise the preview pane, and capture only its windows."""
import json
import argparse
import pathlib
import plistlib
import subprocess
import uuid

from verify_ui_integration import configure_test_run, require_unlocked_session, run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preview-only", action="store_true", help="Run only the preview pane tests and captures")
    arguments = parser.parse_args()
    repository = pathlib.Path(__file__).resolve().parents[1]
    identifier = "com.shunnag.KaitoFinder.PreviewVerification." + str(uuid.uuid4())
    output = repository / "build/PreviewVerification" / identifier.rsplit(".", 1)[1]
    output.mkdir(parents=True)
    derived = repository / "build/PreviewDerivedData"
    require_unlocked_session(repository, output)
    helper = output / "capture-preview"
    subprocess.run(["swiftc", "-parse-as-library", str(repository / "Tools/capture_preview_sidebar.swift"),
                    "-o", str(helper)], check=True)
    run(["xcodebuild", "-project", str(repository / "KaitoFinder.xcodeproj"), "-scheme", "KaitoFinder",
         "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", str(derived),
         "PRODUCT_BUNDLE_IDENTIFIER=" + identifier, "build-for-testing"], output / "build.log", "** TEST BUILD SUCCEEDED **")
    products = derived / "Build/Products"
    source = next(products.glob("KaitoFinder_*.xctestrun"))
    request = output / "capture-request.json"
    configuration = configure_test_run(plistlib.loads(source.read_bytes()), products, {
        "KAITOFINDER_PREVIEW_CAPTURE_REQUEST": str(request),
        "KAITOFINDER_SNAPSHOT_DIR": str(output / "snapshots"),
    })
    test_run = output / "preview.xctestrun"
    test_run.write_bytes(plistlib.dumps(configuration))

    def capture_requested_window():
        if request.exists():
            subprocess.run([str(helper), str(request)], check=True)
            request.unlink()
            request.with_suffix(".done").touch()

    suites = ["ArchivePreviewSidebarTests", "ArchiveDisplayTests", "QuickLookOpenTests", "ArchiveThumbnailTests",
              "ApplicationCommandIntegrationTests", "ArchiveTabTests", "LayoutOverflowTests"]
    if arguments.preview_only:
        suites = ["ArchivePreviewSidebarTests"]
    command = ["xcodebuild", "test-without-building", "-xctestrun", str(test_run),
               "-destination", "platform=macOS,arch=arm64", "-parallel-testing-enabled", "NO",
               "-resultBundlePath", str(output / "preview.xcresult")]
    command.extend("-only-testing:KaitoFinderTests/" + suite for suite in suites)
    try:
        run(command, output / "preview.log", "** TEST EXECUTE SUCCEEDED **", set(suites), capture_requested_window)
    finally:
        require_unlocked_session(repository, output)
    expected = {"preview-off", "preview-empty", "preview-image-light", "preview-image-dark", "preview-text",
                "preview-pdf", "preview-minimum", "preview-hidden", "preview-resized"}
    assert {path.stem for path in (output / "captures").glob("*.png")} == expected
    (output / "result.json").write_text(json.dumps({"bundle": identifier, "captures": sorted(expected)}, indent=2) + "\n")
    print("Preview sidebar verification passed:", output, flush=True)


if __name__ == "__main__":
    main()
