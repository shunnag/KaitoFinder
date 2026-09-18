#!/usr/bin/env python3
"""Measure the repository's actual conflict-folder counting code in an optimized build."""

import argparse
import hashlib
import pathlib
import subprocess
import tempfile


def main():
    repository = pathlib.Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=pathlib.Path,
                        default=repository / "KaitoFinder/Import/ArchiveImportConflict.swift")
    args = parser.parse_args()
    source = args.source.read_text()
    start = source.index("    static func descendantCount(")
    body = source.index("{", start)
    depth = 1
    end = body + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    method = source[start:end]
    print("source SHA256:", hashlib.sha256(source.encode()).hexdigest(), flush=True)
    # Compile the production method and production path parser, with no copied
    # implementation in the benchmark. Inputs and expected counts are independent.
    driver = """
import Darwin
import Foundation
enum Measured {
METHOD
}
@main struct Benchmark {
    static func main() {
        print("files,depth,descendants,median_ms")
        for (count, depth) in [(1000, 8), (4000, 8), (1000, 64), (4000, 64), (1000, 256)] {
            let prefix = (["root"] + (0..<depth).map { "folder-\\($0)" }).joined(separator: "/")
            let paths = (0..<count).map { prefix + "/file-\\($0)" }
            let expected = count + depth
            precondition(Measured.descendantCount(paths, below: "root") == expected)
            var samples: [Double] = []
            for _ in 0..<3 {
                let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                let result = Measured.descendantCount(paths, below: "root")
                let elapsed = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e6
                precondition(result == expected)
                samples.append(elapsed)
            }
            print("\\(count),\\(depth),\\(expected),\\(samples.sorted()[1])")
        }
    }
}
""".replace("METHOD", method)
    with tempfile.TemporaryDirectory(prefix="kaitofinder-conflict-benchmark-") as temporary:
        root = pathlib.Path(temporary)
        swift = root / "Benchmark.swift"
        swift.write_text(driver)
        executable = root / "benchmark"
        subprocess.run(["swiftc", "-O", "-parse-as-library", "-module-cache-path", str(root / "cache"),
                        str(repository / "KaitoFinder/Model/ArchivePath.swift"), str(swift), "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    main()
