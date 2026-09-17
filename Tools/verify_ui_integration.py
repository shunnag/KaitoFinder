#!/usr/bin/env python3
"""Run real AppKit commands and recent-history relaunch checks in an isolated app."""

import argparse
import pathlib
import plistlib
import re
import subprocess
import tempfile
import uuid
import zipfile


def run(command, log, required_pass=None, suites=()):
    print(f"Running {log.stem}; log: {log}", flush=True)
    with log.open("w") as output:
        result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT)
    contents = log.read_text(errors="replace")
    missing_suite = any(not re.search(
        r"Test Suite '" + re.escape(suite) + r"' passed[^\n]*\n\s*Executed [1-9][0-9]* tests?, with 0 failures",
        contents) for suite in suites)
    if result.returncode or (required_pass and required_pass not in contents) or missing_suite:
        print("\n".join(contents.splitlines()[-60:]), flush=True)
        raise RuntimeError(f"Verification did not pass: {log}")


def configure_test_run(value, test_root, environment):
    """Keep __TESTROOT__ correct when saving the phase file beside its log."""
    if isinstance(value, str):
        return value.replace("__TESTROOT__", str(test_root))
    if isinstance(value, list):
        return [configure_test_run(item, test_root, environment) for item in value]
    if isinstance(value, dict):
        result = {key: configure_test_run(item, test_root, environment) for key, item in value.items()}
        if "TestBundlePath" in result:
            result.setdefault("EnvironmentVariables", {}).update(environment)
        return result
    return value


def main():
    repository = pathlib.Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--derived-data", type=pathlib.Path, default=repository / "build/UIIntegrationDerivedData")
    arguments = parser.parse_args()
    derived = arguments.derived_data.resolve()
    identifier = "com.shunnag.KaitoFinder.UIIntegrationVerification." + str(uuid.uuid4())
    output = repository / "build/UIIntegrationVerification" / identifier.rsplit(".", 1)[1]
    output.mkdir(parents=True)
    build = ["xcodebuild", "-project", str(repository / "KaitoFinder.xcodeproj"), "-scheme", "KaitoFinder",
             "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", str(derived),
             "PRODUCT_BUNDLE_IDENTIFIER=" + identifier, "build-for-testing"]
    run(build, output / "build.log", "** TEST BUILD SUCCEEDED **")
    products = derived / "Build/Products"
    candidates = list(products.glob("KaitoFinder_*.xctestrun"))
    if len(candidates) != 1:
        raise RuntimeError(f"Expected one test configuration, found: {candidates}")
    source = candidates[0]
    with source.open("rb") as file:
        template = plistlib.load(file)

    def test(name, selection, environment, passed):
        configuration = configure_test_run(template, source.parent, environment)
        path = output / (name + ".xctestrun")
        with path.open("wb") as file:
            plistlib.dump(configuration, file)
        command = ["xcodebuild", "test-without-building", "-xctestrun", str(path),
                   "-destination", "platform=macOS,arch=arm64"]
        command.extend("-only-testing:KaitoFinderTests/" + item for item in selection)
        run(command, output / (name + ".log"), passed, {item.split("/")[0] for item in selection})

    test("commands", ["ApplicationCommandIntegrationTests", "RecentDocumentsMenuTests",
         "ArchiveTabTests", "ArchiveDropIntegrationTests",
         "ArchivePasswordUITests/testPresentedSavePanelAnimatesEncryptionAndCancelsWithoutSaving",
         "ArchivePasswordUITests/testSavePanelSheetReversesAnimationAndCancelsDuringExpansion",
         "ArchivePasswordUITests/testSavePanelResizesWithoutSlidingContents",
         "ArchivePasswordUITests/testSavePanelReducedMotionChangesSizeWithoutAnimation",
         "ArchivePasswordUITests/testExpandedSavePanelRebasesAfterNativeResizeAndFitsTheScreen",
         "ArchiveDisplayTests/testWindowChromeAndFirstRowRemainReadableAtMinimumSizeInBothAppearances"], {},
         "** TEST EXECUTE SUCCEEDED **")
    with tempfile.TemporaryDirectory(prefix="kaitofinder-recent-history-") as temporary:
        archive = pathlib.Path(temporary) / ("persistent-" + str(uuid.uuid4()) + ".zip")
        with zipfile.ZipFile(archive, "w") as file:
            file.writestr("note.txt", "Recent-history integration fixture")
        for phase in ("record", "reopen", "clear", "verify-cleared"):
            test(phase, ["RecentDocumentsPersistenceTests/testHistoryAcrossLaunches"], {
                "KAITOFINDER_RECENTS_PHASE": phase,
                "KAITOFINDER_RECENTS_BUNDLE_ID": identifier,
                "KAITOFINDER_RECENTS_ARCHIVE": str(archive),
            }, "RecentDocumentsPersistenceTests testHistoryAcrossLaunches]' passed")
    print(f"UI commands and all four recent-history launches passed. Logs: {output}", flush=True)


if __name__ == "__main__":
    main()
