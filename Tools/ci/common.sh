#!/bin/bash
set -euo pipefail

ci_paths() {
  # RUNNER_TEMP の差は artifact の manifest で検出する。異なれば実行しない。
  export KF_DERIVED_DATA="$RUNNER_TEMP/kaitofinder-dd"
  export KF_STAGE="$RUNNER_TEMP/kaitofinder-transfer"
}

require_xcode_27() {
  local kf_xcode_version
  sw_vers
  kf_xcode_version="$(xcodebuild -version)"
  printf '%s\n' "$kf_xcode_version"
  xcrun swift --version
  test "$(uname -m)" = arm64
  grep -Eq '^Xcode 27([.]|$)' <<< "$kf_xcode_version"
}

clone_siblings() {
  git clone --depth 1 --branch main https://github.com/shunnag/KaitoKit.git ../KaitoKit
  git clone --depth 1 --branch main https://github.com/shunnag/GyoshukuKit.git ../GyoshukuKit
  for repo in . ../KaitoKit ../GyoshukuKit; do
    printf '%s: ' "$repo"
    git -C "$repo" rev-parse HEAD
  done
}

require_fixture_tools() {
  for tool in 7zz xz zstd; do test -x "/opt/homebrew/bin/$tool"; done
}

build_tests() {
  require_xcode_27
  # stale bundle を使わない。呼び出し側でも build && test/package を必ず連結する。
  test ! -e "$KF_DERIVED_DATA"
  xcodebuild -project KaitoFinder.xcodeproj -scheme KaitoFinder -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$KF_DERIVED_DATA" \
    -clonedSourcePackagesDirPath "$RUNNER_TEMP/kaitofinder-packages" \
    -resultBundlePath "$RUNNER_TEMP/build.xcresult" \
    -onlyUsePackageVersionsFromResolvedFile MACOSX_DEPLOYMENT_TARGET=26.0 \
    build-for-testing 2>&1 | tee "$RUNNER_TEMP/build.log"
}

build_helpers() {
  local output="$1"
  mkdir -p "$output"
  xcrun swiftc -target arm64-apple-macos26.0 Tools/ci/check-session.swift -o "$output/check-session"
  xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -framework Foundation \
    Tools/ci/make-xctest-configuration.m -o "$output/make-xctest-configuration"
}

check_session() {
  csrutil status
  "$1/check-session"
}

test_with_scheme() {
  export TEST_RUNNER_CI=1
  # 厳密な保存パネル geometry は、アニメーションによる伸縮が収まる画面を前提とする。
  # 1024x768 hosted VM では画面外補正が設計どおりパネルを動かすため、
  # この 2 method は Mac mini の GUI runs で検証する（runtime.py の CI_SKIP_METHODS と共通）。
  xcodebuild -project KaitoFinder.xcodeproj -scheme KaitoFinder -configuration Debug \
    -destination 'platform=macOS,arch=arm64' -derivedDataPath "$KF_DERIVED_DATA" \
    -clonedSourcePackagesDirPath "$RUNNER_TEMP/kaitofinder-packages" \
    -resultBundlePath "$RUNNER_TEMP/xcode-27.xcresult" \
    -parallel-testing-enabled NO -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 600 -maximum-test-execution-time-allowance 600 \
    -skip-testing:KaitoFinderTests/ArchiveTabSpringLoadingTests \
    -skip-testing:KaitoFinderTests/ArchiveDropIntegrationTests \
    -skip-testing:KaitoFinderTests/ReadOnlyDropConversionUITests \
    -skip-testing:KaitoFinderTests/ArchivePasswordUITests/testSavePanelResizesWithoutSlidingContents \
    -skip-testing:KaitoFinderTests/ArchivePasswordUITests/testSplitSavePanelResizesWithoutSlidingContents \
    test-without-building 2>&1 | tee "$RUNNER_TEMP/xcode-27-tests.log"
  python3 Tools/ci/runtime.py guard "$RUNNER_TEMP/xcode-27-tests.log"
}
