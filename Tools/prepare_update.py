#!/usr/bin/env python3
"""Prepare a signed Sparkle update for GitHub Releases without uploading it."""

import argparse
import ctypes
import errno
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import tempfile
import urllib.parse
import xml.etree.ElementTree as ET


REPOSITORY = "https://github.com/shunnag/KaitoFinder"
FEED = REPOSITORY + "/releases/latest/download/appcast.xml"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def run(*command):
    return subprocess.run([str(item) for item in command], check=True, text=True, capture_output=True).stdout.strip()


def publish_directory(staging, output):
    # Darwin <sys/stdio.h>: RENAME_EXCL (0x4) rejects any existing destination,
    # including an empty directory created by another release job after preflight.
    rename = getattr(ctypes.CDLL(None, use_errno=True), 'renamex_np', None)
    if rename is None:
        raise OSError(errno.ENOTSUP, 'Exclusive update publication requires macOS')
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(staging), os.fsencode(output), 0x4) != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), str(output))


def numeric_version(value):
    if not value or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", value):
        raise ValueError("Previous appcast must contain numeric build and marketing versions.")
    parts = tuple(int(part) for part in value.split('.'))
    return parts + (0,) * (3 - len(parts))


def check_previous_appcast(path, build, version):
    items = []
    for item in ET.parse(path).findall('./channel/item'):
        enclosure = item.find('enclosure')
        def field(name):
            return item.findtext(SPARKLE + name) or (enclosure.get(SPARKLE + name) if enclosure is not None else None)
        items.append((numeric_version(field('version')), numeric_version(field('shortVersionString'))))
    if not items:
        raise ValueError("Previous appcast must contain at least one release item.")
    # Feed order and publication dates need not match Sparkle's numeric version order.
    previous_build, previous_version = max(items)
    if numeric_version(build) <= previous_build:
        raise ValueError("CFBundleVersion must be strictly greater than the newest previous appcast build.")
    if numeric_version(version) < previous_version:
        raise ValueError("CFBundleShortVersionString must not decrease from the newest previous appcast release.")


def prepare(app, tools, output, notes, account, test_only=False, previous_appcast=None):
    app, tools = app.resolve(), tools.resolve()
    if not output.name or output.name == '..':
        raise ValueError('Choose a new named output directory.')
    # Resolve parent aliases, but preserve the final component so even a dangling
    # output symlink counts as an existing destination and is never followed.
    output = output.parent.resolve() / output.name
    if os.path.lexists(output):
        raise ValueError("The output directory already exists; choose a new directory to preserve previous updates.")
    if output.is_relative_to(app):
        raise ValueError('The update output must be outside the source app bundle.')
    if notes:
        if notes.suffix not in ('.md', '.html', '.txt'):
            raise ValueError('Release notes must be .md, .html or .txt.')
        if not notes.is_file():
            raise ValueError('Release notes must point to an existing file.')
    with (app / "Contents/Info.plist").open("rb") as file:
        info = plistlib.load(file)
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    if not re.fullmatch(r"\d+(?:\.\d+){1,2}", version) or not re.fullmatch(r"\d+(?:\.\d+){0,2}", build):
        raise ValueError("Use numeric marketing and build versions before preparing a release.")
    if info.get("CFBundleIdentifier") != "com.shunnag.KaitoFinder" or app.name != "KaitoFinder.app":
        raise ValueError("Expected the distribution KaitoFinder.app bundle.")
    if info.get("SUFeedURL") != FEED or not info.get("SURequireSignedFeed") or not info.get("SUVerifyUpdateBeforeExtraction"):
        raise ValueError("The app must use the configured HTTPS feed and require Sparkle signatures.")
    if previous_appcast is not None:
        check_previous_appcast(previous_appcast, build, version)
    public_key = run(tools / "generate_keys", "--account", account, "-p")
    if public_key != info.get("SUPublicEDKey"):
        raise ValueError("The signing account does not match the app's Sparkle public key.")
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    if not test_only:
        run("/usr/sbin/spctl", "--assess", "--type", "execute", app)
        run("/usr/bin/xcrun", "stapler", "validate", app)
    output.parent.mkdir(parents=True, exist_ok=True)
    # Keep work on the same volume, and expose the final directory only after
    # signing and validation have succeeded. Exceptions and Ctrl-C clean staging.
    with tempfile.TemporaryDirectory(prefix='.kaitofinder-update-', dir=output.parent) as temporary:
        staging = pathlib.Path(temporary)
        if test_only:
            (staging / "TEST-ONLY-DO-NOT-PUBLISH.txt").write_text("Local verification only. This app has not passed notarization validation.\n")
        archive = staging / f"KaitoFinder-{version}.zip"
        run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive)
        if notes:
            shutil.copyfile(notes, archive.with_suffix(notes.suffix))
        prefix = REPOSITORY + "/releases/download/" + urllib.parse.quote("v" + version, safe="") + "/"
        run(tools / "generate_appcast", "--account", account, "--download-url-prefix", prefix,
            "--maximum-deltas", "0", "--embed-release-notes", "--full-release-notes-url", REPOSITORY + "/releases",
            "--link", REPOSITORY, staging)
        feed = staging / "appcast.xml"
        run(tools / "sign_update", "--account", account, "--verify", feed)
        item = ET.parse(feed).find("./channel/item")
        if item is None or item.findtext(SPARKLE + "version") != build:
            raise ValueError("The generated feed does not match the app's build version.")
        enclosure = item.find("enclosure")
        if enclosure is None or enclosure.get("url") != prefix + archive.name:
            raise ValueError("The generated download URL is incorrect.")
        if int(enclosure.get("length", "0")) != archive.stat().st_size:
            raise ValueError("The generated archive length is incorrect.")
        run(tools / "sign_update", "--account", account, "--verify", archive, enclosure.attrib[SPARKLE + "edSignature"])
        publish_directory(staging, output)
    return output / archive.name, output / feed.name


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=pathlib.Path, required=True, help="Signed, notarized and stapled KaitoFinder.app")
    parser.add_argument("--sparkle-bin", type=pathlib.Path, required=True, help="Sparkle distribution bin directory")
    parser.add_argument("--output", type=pathlib.Path, required=True, help="New output directory")
    parser.add_argument("--notes", type=pathlib.Path, help="Release notes to embed in the signed feed")
    parser.add_argument("--previous-appcast", type=pathlib.Path,
                        help="Local previous feed; require a higher build and a nondecreasing marketing version")
    parser.add_argument("--account", default="com.shunnag.KaitoFinder")
    parser.add_argument("--test-only", action="store_true", help="Allow a local ad-hoc build; never publish this output")
    args = parser.parse_args()
    try:
        archive, feed = prepare(args.app, args.sparkle_bin, args.output, args.notes, args.account, args.test_only, args.previous_appcast)
    except subprocess.CalledProcessError as error:
        parser.exit(1, (error.stderr or error.stdout or str(error)) + "\n")
    except (OSError, ValueError, KeyError, ET.ParseError) as error:
        parser.exit(1, str(error) + "\n")
    print("Verified signed update:", archive)
    print("Verified signed feed:", feed)
    print("No files were uploaded." if not args.test_only else "TEST ONLY: do not publish these files.")


if __name__ == "__main__":
    main()
