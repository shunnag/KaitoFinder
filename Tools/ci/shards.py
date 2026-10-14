#!/usr/bin/env python3
"""CI の shard・実行範囲を定め、列挙と実行結果の完全性を照合する。"""

import argparse
from collections import Counter
import json
import os
from pathlib import Path
import re
import subprocess
import sys


SKIP_CLASSES = (
    "ArchiveTabSpringLoadingTests",
    "ArchiveDropIntegrationTests",
    "ReadOnlyDropConversionUITests",
)
# 両 CI job 共通。厳密な保存パネル geometry は、アニメーションによる伸縮が収まる画面を前提とする。
# 1024x768 hosted VM では画面外補正が設計どおりパネルを動かすため、Mac mini の GUI runs で検証する。
CI_SKIP_METHODS = (
    "ArchivePasswordUITests/testSavePanelResizesWithoutSlidingContents",
    "ArchivePasswordUITests/testSplitSavePanelResizesWithoutSlidingContents",
)
# macOS 26 の非アクティブな test host では toolbar の visibleItems が揃わない。
# Mac mini (macOS 27) と xcode-27 job で検証する。
MACOS_26_SKIP_METHODS = (
    "ApplicationCommandIntegrationTests/testToolbarAndResponderChainApplyEditsAndRespectTextFocus",
)
X27_S1 = (
    "ApplicationCommandIntegrationTests",
    "ApplicationTerminationTests",
    "ArchiveAlertKeyboardTests",
    "ArchiveBatchExtractionTests",
    "ArchiveBatchExtractionUITests",
    "ArchiveColumnsTests",
    "ArchiveConflictUITests",
    "ArchiveCreationUITests",
    "ArchiveDisplayTests",
    "ArchiveEditScaleTests",
    "ArchiveEntryControlsTests",
    "ArchiveEntryDeleteTests",
    "ArchiveFinderInteractionTests",
    "ArchiveFolderNavigationTests",
    "ArchiveHeaderProbeTests",
    "ArchiveImportOpenCountTests",
    "ArchiveImportSafetyTests",
    "ArchiveImportTransactionVerificationTests",
    "ArchiveNewFolderEditTests",
    "ArchivePasswordEditingTests",
    "ArchivePasswordTests",
    "ArchivePasswordUITests",
    "ArchivePreferencesTests",
    "ArchivePreferencesUITests",
    "ArchivePreviewSidebarTests",
    "ArchivePublicationDiagnosticsTests",
    "ArchiveSaveAsTests",
    "ArchiveSingleCopyEditTests",
    "ArchiveSplitSaveAsTests",
    "ArchiveUndoStackTests",
    "ArchiveWriteProgressTests",
    "AsyncSearchFilterTests",
    "BatchImportExportProbeTests",
    "BatchImportTests",
    "CompressedTarDeferredSaveTests",
    "CompressedTarNonAPFSTests",
    "CompressionThreadPreferenceTests",
    "DecodePowerPolicyPreferenceTests",
    "DeferredOpeningTests",
    "DeferredSaveAttributeTests",
    "DeferredSaveModelTests",
    "DeferredSavePlanEquivalenceTests",
    "DeferredSaveUITests",
    "EntryNameMatcherTests",
    "EntryNameRuleTests",
    "ExtractionProgressSheetTests",
    "ExtractionTests",
    "ImmediateSplitInteropTests",
    "ImmediateSplitSaveTests",
    "LHAUpdateNonAPFSTests",
    "LargeArchiveTests",
    "MenuWordingTests",
    "ParallelExtractionTests",
    "PendingWorkRegistryTests",
    "QuickLookArrowNavigationTests",
    "QuickLookOpenTests",
    "RecentDocumentsMenuTests",
    "ScenarioNameTests",
    "ScenarioPathTests",
    "ScenarioScaleTests",
    "ScenarioServicesTests",
    "ScenarioShapeTests",
    "SevenZipUpdateDeferredSaveTests",
    "SevenZipUpdatePasswordTests",
    "SoftwareUpdateTests",
    "SplitCancellationFollowupTests",
    "SplitSaveDocumentUITests",
    "SplitSaveRecoveryUITests",
    "TarBackslashExtractionTests",
    "VerificationRecordTests",
    "VolumeSetPublisherTests",
    "WordingAcceptanceTests",
)

M26_S1 = (
    "ArchiveAlertKeyboardTests",
    "ArchiveConflictUITests",
    "ArchiveCreationTests",
    "ArchiveDisplayTests",
    "ArchiveEditPathTests",
    "ArchiveHiddenFilesTests",
    "ArchiveImportConflictTests",
    "ArchiveImportSafetyTests",
    "ArchiveImportSourceStampTests",
    "ArchiveMoveEditTests",
    "ArchivePasswordEditingTests",
    "ArchivePasswordPersistenceTests",
    "ArchivePasswordTests",
    "ArchivePasswordVerificationTests",
    "ArchivePublicationDiagnosticsTests",
    "ArchivePublicationTransformationTests",
    "ArchiveSaveAsTests",
    "ArchiveSplitVolumeTests",
    "ArchiveUndoStackTests",
    "ArchiveWriteProgressTests",
    "AutosaveIsolationTests",
    "ByteProgressIntegrationTests",
    "CompressedTarVerificationFailureTests",
    "DeferredSaveAttributeTests",
    "DeferredSaveLifecycleTests",
    "DeferredSaveStagingTests",
    "DeferredSplitSaveTests",
    "EditPlacementPreferencesTests",
    "EntryNameMatcherTests",
    "EntryTreeTests",
    "ExtractionProgressSheetTests",
    "LHAUpdateEditTests",
    "LHAUpdateFallbackTests",
    "NameIndexEquivalenceTests",
    "ScenarioConcurrencyTests",
    "ScenarioDiskTests",
    "ScenarioNestedTests",
    "ScenarioScaleTests",
    "ScenarioServicesTests",
    "SevenZipUpdateDeferredSaveTests",
    "SevenZipUpdateNonAPFSTests",
    "SevenZipUpdatePasswordTests",
    "SevenZipUpdateVerificationFailureTests",
    "SoftwareUpdateTests",
    "SplitCancellationFollowupTests",
    "SplitSaveDocumentUITests",
    "TarUpdateProjectionTests",
    "UISnapshotTests",
    "VolumePublishMountProbeTests",
)

M26_S2 = (
    "ApplicationTerminationTests",
    "ArchiveBatchExtractionTests",
    "ArchiveBatchExtractionUITests",
    "ArchiveCapabilityInspectionTests",
    "ArchiveControllerPreopeningTests",
    "ArchiveCreationUITests",
    "ArchiveDocumentOpeningTests",
    "ArchiveDragImageTests",
    "ArchiveEditScaleTests",
    "ArchiveErrorTextTests",
    "ArchiveHeaderProbeTests",
    "ArchiveImportOpenCountTests",
    "ArchiveNewFolderEditTests",
    "ArchivePasswordVaultTests",
    "ArchivePreferencesTests",
    "ArchiveReaderAdoptionTests",
    "ArchiveRewriteTests",
    "ArchiveSingleCopyEditTests",
    "ArchiveViewOptionsTests",
    "ArchiveWindowCascadeTests",
    "AsyncSearchFilterTests",
    "BatchImportExportProbeTests",
    "BatchImportTests",
    "CompressedTarDeferredSaveTests",
    "CompressionThreadPreferenceTests",
    "DecodePowerPolicyPreferenceTests",
    "DeferredOpeningTests",
    "DeferredPostSaveTests",
    "DeferredReservationTests",
    "DeferredSaveDocumentTests",
    "DeferredSaveExtractionTests",
    "DocumentTypesTests",
    "DragCopyOutTests",
    "ImmediateSplitSaveTests",
    "LHAUpdateNonAPFSTests",
    "LargeArchiveTests",
    "LayoutOverflowTests",
    "ParallelExtractionTests",
    "RecentDocumentsPersistenceTests",
    "ScenarioBatchTests",
    "ScenarioExternalChangeTests",
    "ScenarioPathTests",
    "SplitSavePassTests",
    "SplitSaveRecoveryUITests",
    "VolumePublishFaultInjectionTests",
    "VolumePublishRecoveryTests",
    "VolumePublishStagingLockTests",
    "WelcomeWindowTests",
    "WordingAcceptanceTests",
)

PLATFORM_SKIPS = {
    "xcode-27": SKIP_CLASSES + CI_SKIP_METHODS,
    "macos-26": SKIP_CLASSES + CI_SKIP_METHODS + MACOS_26_SKIP_METHODS,
}
EVERY_SHARD = ("ZZProcessHealthTests",)  # 各 shard の最後に実行し、その process の後始末を検査する。

# CI の 2026-10-14 の class 中央値で、PR の代表範囲と毎晩の全件の両方を均等にする。
# 最後は補集合にし、新規・改名 class も必ず実行する。ZZProcessHealthTests は全 shard に加える。
SHARDS = {"xcode-27": (X27_S1,), "macos-26": (M26_S1, M26_S2)}

# ja はソース言語、en は開発言語、de・fr は catalog 全体で訳文が最も長い欧州語、
# zh-Hans は CJK、th は字形が縦に高い言語。
REPRESENTATIVE_ENV = {
    "KAITOFINDER_TEST_LANGUAGES": "ja,en,de,fr,zh-Hans,th",
    "KAITOFINDER_TEST_MATRIX": "representative",
}
IDENTIFIER = re.compile(r"^KaitoFinderTests/[A-Za-z_][A-Za-z0-9_]*/[A-Za-z_][A-Za-z0-9_]*(\(\))?$")
TEST_CASE = re.compile(r"Test Case '-\[KaitoFinderTests\.(\w+) (\w+)\]' (?:passed|failed|skipped)")
EXECUTED = re.compile(r"Executed (\d+) tests?")
SIBLINGS = ("KaitoKit", "GyoshukuKit")


def scope_env(scope):
    if scope == "full":
        return {}
    if scope == "representative":
        return dict(REPRESENTATIVE_ENV)
    raise ValueError(f"実行範囲が不正です: {scope}")


def selectors(platform, shard, count):
    if platform not in SHARDS:
        raise ValueError(f"platform が不正です: {platform}")
    plan = SHARDS[platform]
    if count != len(plan) + 1 or not 1 <= shard <= count:
        raise ValueError(f"shard/count が不正です: {platform} {shard}/{count}")
    assigned = [name for group in plan for name in group]
    if len(set(assigned)) != len(assigned):
        raise ValueError(f"class の重複割り当てです: {platform}")
    if set(assigned) & (set(EVERY_SHARD) | set(SKIP_CLASSES)):
        raise ValueError(f"全 shard 共通または除外 class の割り当てです: {platform}")
    only = sorted(plan[shard - 1]) + list(EVERY_SHARD) if shard < count else []
    skip = list(PLATFORM_SKIPS[platform]) + (assigned if shard == count else [])
    return only, skip


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def identity():
    return {"sha": git("rev-parse", "HEAD"), "tree": git("rev-parse", "HEAD^{tree}")}


def sibling_checkouts():
    return {name: git("-C", "../" + name, "rev-parse", "HEAD") for name in SIBLINGS}


def write_json(path, data):
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n")


def enumeration(source, out):
    raw = json.loads(source.read_text())
    if raw["errors"]:
        raise ValueError(f"テスト列挙に失敗しました: {raw['errors']}")
    enabled, disabled = [], []
    for value in raw["values"]:
        for key, result in (("enabledTests", enabled), ("disabledTests", disabled)):
            for test in value[key]:
                identifier = test["identifier"]
                if not IDENTIFIER.fullmatch(identifier):
                    raise ValueError(f"テスト識別子が不正です: {identifier}")
                result.append(identifier[:-2] if identifier.endswith("()") else identifier)
    if disabled:
        raise ValueError("未加工の xctestrun に無効なテストがあります")
    if len(set(enabled)) < 1000:
        raise ValueError(f"有効なテストが 1000 件未満です: {len(set(enabled))}")
    data = dict(identity(), siblings=sibling_checkouts(), tests=sorted(set(enabled + disabled)))
    write_json(out, data)
    return data


def report(platform, shard, count, scope, log, out, siblings_checkout=False, siblings_manifest=None):
    selectors(platform, shard, count)
    scope_env(scope)
    text = log.read_text(errors="replace")
    executed = [f"KaitoFinderTests/{cls}/{method}" for cls, method in TEST_CASE.findall(text)]
    if not executed:
        raise ValueError("実行したテストがありません")
    if len(set(executed)) != len(executed):
        raise ValueError("テスト識別子の重複があります")
    counts = [int(value) for value in EXECUTED.findall(text)]
    if not counts or max(counts) != len(executed):
        raise ValueError(f"Executed 件数が一致しません: {counts} / {len(executed)}")
    if siblings_checkout == (siblings_manifest is not None):
        raise ValueError("兄弟 SHA の取得元を一つ指定してください")
    if siblings_checkout:
        siblings = sibling_checkouts()
    else:
        metadata = json.loads(siblings_manifest.read_text())
        siblings = {name: metadata["repos"][name]["sha"] for name in SIBLINGS}
    data = dict(identity(), platform=platform, shard=shard, count=count, scope=scope,
                siblings=siblings, executed=sorted(executed))
    write_json(out, data)
    return data


def test_class(identifier):
    if not isinstance(identifier, str) or not IDENTIFIER.fullmatch(identifier) or identifier.endswith("()"):
        raise ValueError(f"正規化したテスト識別子が不正です: {identifier}")
    return identifier.split("/")[1]


def selected(identifier, only, skip):
    relative = identifier.split("/", 1)[1]
    cls = test_class(identifier)
    return (not only or cls in only or relative in only) and cls not in skip and relative not in skip


def verify(enumeration_path, reports_dir, summary=None, record_out=None):
    enumerated = json.loads(enumeration_path.read_text())
    tests = enumerated["tests"]
    if not tests or len(set(tests)) != len(tests):
        raise ValueError("列挙結果が空または重複しています")
    classes = {test_class(identifier) for identifier in tests}
    for key in ("sha", "tree"):
        if not re.fullmatch(r"[0-9a-f]{40}", enumerated[key]):
            raise ValueError(f"列挙結果の {key} が不正です")
    if enumerated["tree"] != git("rev-parse", "HEAD^{tree}"):
        raise ValueError("列挙結果と checkout の tree が一致しません")
    reports = [json.loads(path.read_text()) for path in sorted(reports_dir.glob("*/shard-report*.json"))]
    grouped = {platform: {} for platform in SHARDS}
    for item in reports:
        platform, shard, count = item["platform"], item["shard"], item["count"]
        selectors(platform, shard, count)
        scope_env(item["scope"])
        if shard in grouped[platform]:
            raise ValueError(f"shard report の重複です: {platform} {shard}")
        if any(item[key] != enumerated[key] for key in ("sha", "tree")):
            raise ValueError("report と列挙結果の tree / sha が一致しません")
        grouped[platform][shard] = item
    lines = ["### shard の実行範囲の照合", "", "| 環境 | shard | class 数 | テスト数 |", "| --- | --- | ---: | ---: |"]
    counts = {}
    for platform, plan in SHARDS.items():
        count = len(plan) + 1
        if set(grouped[platform]) != set(range(1, count + 1)):
            raise ValueError(f"shard report が不足しています: {platform}")
        assigned = {cls for group in plan for cls in group}
        missing = (assigned | set(EVERY_SHARD)) - classes
        if missing:
            raise ValueError(f"古い shard class があります: {sorted(missing)}")
        expected = {identifier for identifier in tests if selected(identifier, [], PLATFORM_SKIPS[platform])}
        observed = Counter()
        counts[platform] = {}
        for shard in range(1, count + 1):
            item = grouped[platform][shard]
            executed = item["executed"]
            actual = set(executed)
            if len(actual) != len(executed):
                raise ValueError(f"report 内のテスト重複です: {platform} {shard}")
            only, skip = selectors(platform, shard, count)
            wanted = {identifier for identifier in expected if selected(identifier, only, skip)}
            if actual != wanted:
                raise ValueError(f"shard の実行範囲が一致しません: {platform} {shard}: "
                                 f"不足={sorted(wanted - actual)} 余分={sorted(actual - wanted)}")
            observed.update(executed)
            counts[platform][str(shard)] = len(executed)
            lines.append(f"| {platform} | {shard}/{count} | {len({test_class(i) for i in actual})} | {len(executed)} |")
        required = Counter({identifier: count if test_class(identifier) in EVERY_SHARD else 1
                            for identifier in expected})
        every_count = sum(test_class(identifier) in EVERY_SHARD for identifier in expected)
        if observed != required or sum(observed.values()) != len(expected) + (count - 1) * every_count:
            raise ValueError(f"全 shard の実行件数が一致しません: {platform}")
    siblings = enumerated.get("siblings")
    same_siblings = (isinstance(siblings, dict) and set(siblings) == set(SIBLINGS)
                     and all(isinstance(sha, str) and re.fullmatch(r"[0-9a-f]{40}", sha)
                             for sha in siblings.values())
                     and all(item.get("siblings") == siblings for item in reports))
    scopes = {item["scope"] for item in reports}
    record_name = ""
    if same_siblings and len(scopes) == 1:
        record_name = f"ci-tested-{enumerated['tree']}-{siblings['KaitoKit']}-{siblings['GyoshukuKit']}"
        if record_out:
            write_json(record_out, {"tree": enumerated["tree"], "sha": enumerated["sha"],
                                    "siblings": siblings, "scope": next(iter(scopes)),
                                    "event": os.environ.get("GITHUB_EVENT_NAME", ""),
                                    "run_id": os.environ.get("GITHUB_RUN_ID", ""), "counts": counts})
    else:
        lines.extend(["", "兄弟 SHA または実行範囲が一致しないため、この tree は push 時の省略に使わない。"])
        if record_out and record_out.exists():
            record_out.unlink()
    rendered = "\n".join(lines) + "\n"
    print(rendered, file=sys.stderr, end="")
    if summary:
        with summary.open("a") as stream:
            stream.write(rendered)
    print("record-name=" + record_name)
    return counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    args_parser = commands.add_parser("xcodebuild-args")
    report_parser = commands.add_parser("report")
    for command in (args_parser, report_parser):
        command.add_argument("--platform", required=True)
        command.add_argument("--shard", type=int, required=True)
        command.add_argument("--count", type=int, required=True)
    env_parser = commands.add_parser("scope-env")
    for command in (env_parser, report_parser):
        command.add_argument("--scope", required=True)
    enum_parser = commands.add_parser("enumeration")
    enum_parser.add_argument("--input", type=Path, required=True)
    enum_parser.add_argument("--out", type=Path, required=True)
    report_parser.add_argument("--log", type=Path, required=True)
    report_parser.add_argument("--out", type=Path, required=True)
    siblings = report_parser.add_mutually_exclusive_group(required=True)
    siblings.add_argument("--siblings-checkout", action="store_true")
    siblings.add_argument("--siblings-manifest", type=Path)
    verify_parser = commands.add_parser("verify")
    verify_parser.add_argument("--enumeration", type=Path, required=True)
    verify_parser.add_argument("--reports", type=Path, required=True)
    verify_parser.add_argument("--summary", type=Path)
    verify_parser.add_argument("--record-out", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "xcodebuild-args":
            only, skip = selectors(args.platform, args.shard, args.count)
            for flag, identifiers in (("only", only), ("skip", skip)):
                for identifier in identifiers:
                    print(f"-{flag}-testing:KaitoFinderTests/{identifier}")
        elif args.command == "scope-env":
            for key, value in scope_env(args.scope).items():
                print(f"{key}={value}")
        elif args.command == "enumeration":
            enumeration(args.input, args.out)
        elif args.command == "report":
            report(args.platform, args.shard, args.count, args.scope, args.log, args.out,
                   args.siblings_checkout, args.siblings_manifest)
        elif args.command == "verify":
            verify(args.enumeration, args.reports, args.summary, args.record_out)
    except (ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f"CI の照合に失敗しました: {error}\n")


if __name__ == "__main__":
    main()
