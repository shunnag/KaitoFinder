#!/usr/bin/env python3
"""Measure the production compressed-tar stream without retaining a whole input."""

import argparse
import hashlib
import pathlib
import subprocess
import tarfile
import tempfile


def main():
    repository = pathlib.Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--writer", type=pathlib.Path, default=repository.parent / "GyoshukuKit")
    parser.add_argument("--sizes", type=int, nargs="+", default=[16, 64, 256], help="Input sizes in MiB")
    parser.add_argument("--max-rss-mib", type=int, help="Fail if a writer exceeds this peak RSS")
    args = parser.parse_args()
    if any(size <= 0 or size > 512 for size in args.sizes):
        parser.error("Use sizes between 1 and 512 MiB.")
    if args.max_rss_mib is not None and args.max_rss_mib <= 0:
        parser.error("The peak RSS bound must be positive.")
    sources = [args.writer / "Sources/GyoshukuKit" / (name + ".swift") for name in
               ["WriterOptions", "ZipRecords", "TarRecords", "TarWriter", "TarCompressor",
                "XZCompressor", "Bzip2Compressor"]]
    print("source SHA256:", hashlib.sha256(b"".join(path.read_bytes() for path in sources)).hexdigest(), flush=True)
    driver = r'''
private import Darwin
import CryptoKit
import Foundation
@main struct Benchmark {
    static func main() throws {
        let size = Int(CommandLine.arguments[1])! * 1_024 * 1_024
        let random = CommandLine.arguments[2] == "random"
        let format = CommandLine.arguments[3]
        let url = URL(fileURLWithPath: CommandLine.arguments[4])
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var stat = stat()
        guard fstat(descriptor, &stat) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let compressor: any TarCompressor = format == "xz" ? try XZCompressor() : try Bzip2Compressor(level: 9)
        let writer = TarWriter(output: handle, url: url, identity: (stat.st_dev, stat.st_ino), compressor: compressor)
        var remaining = size, state: UInt64 = 0x5441_5220_2026, hash = SHA256()
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        try writer.add(name: "payload.bin", mode: 0o100644, size: UInt64(size),
                       date: Date(timeIntervalSince1970: 1_700_000_000), owners: nil, hardLink: nil) { requested in
            let count = min(requested, remaining)
            remaining -= count
            let data: Data
            if random {
                data = Data((0..<count).map { _ in
                    state ^= state << 13; state ^= state >> 7; state ^= state << 17
                    return UInt8(truncatingIfNeeded: state)
                })
            } else { data = Data(repeating: 65, count: count) }
            hash.update(data: data)
            return data
        }
        try writer.finish()
        let seconds = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e9
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw CocoaError(.fileReadUnknown) }
        let packed = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        print("\(format),\(size),\(random ? "random" : "repeat"),\(seconds),\(usage.ru_maxrss),\(packed),\(digest)")
    }
}
'''
    with tempfile.TemporaryDirectory(prefix="kaitofinder-tar-benchmark-") as temporary:
        root = pathlib.Path(temporary)
        swift = root / "Benchmark.swift"
        swift.write_text(driver)
        binary = root / "benchmark"
        subprocess.run(["swiftc", "-O", "-parse-as-library", "-module-cache-path", str(root / "cache"),
                        "-I", str(args.writer / "Sources/CGyoshukuBzip2"),
                        *map(str, sources), str(swift), "-o", str(binary)], check=True)
        print("format,input_bytes,pattern,seconds,peak_rss_bytes,archive_bytes,input_sha256", flush=True)
        for kind in ["xz", "bz2"]:
            for pattern in ["repeat", "random"]:
                for size in args.sizes:
                    archive = root / f"{pattern}-{size}.tar.{kind}"
                    result = subprocess.run([str(binary), str(size), pattern, kind, str(archive)],
                                            check=True, capture_output=True, text=True)
                    row = result.stdout.strip().split(",")
                    print(result.stdout.strip(), flush=True)
                    if args.max_rss_mib is not None and int(row[4]) > args.max_rss_mib * 1_024 * 1_024:
                        raise RuntimeError(f"{kind} peak RSS {row[4]} bytes exceeds {args.max_rss_mib} MiB")
                    with tarfile.open(archive, "r|*") as tar:
                        member = tar.next()
                        assert member.name == "payload.bin" and member.size == size * 1_024 * 1_024
                        digest = hashlib.sha256()
                        with tar.extractfile(member) as stream:
                            while block := stream.read(262_144):
                                digest.update(block)
                        assert digest.hexdigest() == row[6]
                        assert tar.next() is None
                    subprocess.run(["/opt/homebrew/bin/7zz", "t", str(archive)], check=True,
                                   stdout=subprocess.DEVNULL)
                    archive.unlink()


if __name__ == "__main__":
    main()
