#!/usr/bin/env python3
"""Measure the actual sibling LHA writer without retaining a whole input in the driver."""

import argparse
import hashlib
import pathlib
import subprocess
import tempfile


def main():
    repository = pathlib.Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--writer", type=pathlib.Path, default=repository.parent / "GyoshukuKit")
    parser.add_argument("--sizes", type=int, nargs="+", default=[16, 64, 256], help="Input sizes in MiB")
    parser.add_argument("--max-rss-mib", type=int, help="Fail if any measured process exceeds this peak RSS")
    args = parser.parse_args()
    if any(size <= 0 or size > 512 for size in args.sizes):
        parser.error("Use sizes between 1 and 512 MiB.")
    if args.max_rss_mib is not None and args.max_rss_mib <= 0:
        parser.error("The peak RSS bound must be positive.")
    sources = [args.writer / "Sources/GyoshukuKit" / (name + ".swift") for name in
               ["WriterOptions", "ZipRecords", "LHARecords", "LHACRC16", "LH5Encoder", "LHAWriter"]]
    print("source SHA256:", hashlib.sha256(b"".join(path.read_bytes() for path in sources)).hexdigest(), flush=True)
    driver = r'''
private import Darwin
import Foundation
@main struct Benchmark {
    static func main() throws {
        let size = Int(CommandLine.arguments[1])! * 1_024 * 1_024
        let random = CommandLine.arguments[2] == "random"
        let url = URL(fileURLWithPath: CommandLine.arguments[3])
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var stat = stat()
        guard fstat(descriptor, &stat) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let writer = LHAWriter(output: handle, url: url, identity: (stat.st_dev, stat.st_ino))
        var remaining = size, state: UInt64 = 0x4c48_4120_2026
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        try writer.add(name: "payload.bin", mode: 0o100644, size: UInt64(size),
                       date: Date(timeIntervalSince1970: 1_700_000_000)) { requested in
            let count = min(requested, remaining)
            remaining -= count
            guard random else { return Data(repeating: 65, count: count) }
            return Data((0..<count).map { _ in
                state ^= state << 13; state ^= state >> 7; state ^= state << 17
                return UInt8(truncatingIfNeeded: state)
            })
        }
        try writer.finish()
        let seconds = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e9
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw CocoaError(.fileReadUnknown) }
        let packed = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber
        print("\(size),\(random ? "random" : "repeat"),\(seconds),\(usage.ru_maxrss),\(packed)")
    }
}
'''
    with tempfile.TemporaryDirectory(prefix="kaitofinder-lha-benchmark-") as temporary:
        root = pathlib.Path(temporary)
        swift = root / "Benchmark.swift"
        swift.write_text(driver)
        binary = root / "benchmark"
        subprocess.run(["swiftc", "-O", "-parse-as-library", "-module-cache-path", str(root / "cache"),
                        *map(str, sources), str(swift), "-o", str(binary)], check=True)
        print("input_bytes,pattern,seconds,peak_rss_bytes,archive_bytes", flush=True)
        for pattern in ["repeat", "random"]:
            for size in args.sizes:
                archive = root / f"{pattern}-{size}.lzh"
                result = subprocess.run([str(binary), str(size), pattern, str(archive)],
                                        check=True, capture_output=True, text=True)
                print(result.stdout.strip(), flush=True)
                peak = int(result.stdout.strip().split(",")[3])
                if args.max_rss_mib is not None and peak > args.max_rss_mib * 1_024 * 1_024:
                    raise RuntimeError(f"LHA peak RSS {peak} bytes exceeds {args.max_rss_mib} MiB")
                subprocess.run(["/opt/homebrew/bin/lha", "t", str(archive)], check=True,
                               stdout=subprocess.DEVNULL)
                archive.unlink()


if __name__ == "__main__":
    main()
