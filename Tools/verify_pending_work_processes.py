#!/usr/bin/env python3
"""Exercise the real Swift ledger across processes in an isolated temporary directory."""

import json
import pathlib
import subprocess
import tempfile


PROBE = r'''
import Darwin
import Foundation

@main struct RegistryProbe {
    static func main() throws {
        let arguments = CommandLine.arguments
        let registry = PendingWorkRegistry(fileURL: URL(fileURLWithPath: arguments[2]))
        if arguments[1] == "sweep" {
            _ = try registry.sweep()
            return
        }
        let root = URL(fileURLWithPath: arguments[3], isDirectory: true)
        for index in 0..<50 {
            let directory = root.appendingPathComponent(".KaitoFinder-new-\(arguments[4])-\(index)")
            try registry.register(directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try registry.recordIdentity(directory)
        }
        // Keep the owner alive while another process sweeps the ledger.
        try FileHandle.standardOutput.write(contentsOf: Data("ready\n".utf8))
        _ = readLine()
    }
}
'''


def main():
    repository = pathlib.Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="kaitofinder-ledger-processes-") as temporary:
        root = pathlib.Path(temporary)
        probe = root / "RegistryProbe.swift"
        probe.write_text(PROBE)
        executable = root / "registry-probe"
        subprocess.run(
            ["xcrun", "swiftc", "-swift-version", "6", "-module-cache-path", str(root / "modules"),
             str(repository / "KaitoFinder/Persistence/PendingWorkRegistry.swift"), str(probe),
             "-o", str(executable)],
            check=True,
        )
        work = root / "work"
        work.mkdir()
        ledger = root / "support/pending.json"
        owners = []
        try:
            for number in range(4):
                owners.append(subprocess.Popen(
                    [str(executable), "register", str(ledger), str(work), str(number)],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
                ))
            for owner in owners:
                assert owner.stdout.readline().strip() == "ready", "Owner exited before registering its work"

            expected = {str(work / f".KaitoFinder-new-{owner}-{index}") for owner in range(4) for index in range(50)}
            entries = json.loads(ledger.read_text())
            actual = {entry["path"] for entry in entries}
            print(f"Registrations retained: {len(actual)} / {len(expected)}", flush=True)
            assert actual == expected, f"Lost {len(expected - actual)} concurrent registrations"
            assert all("device" in entry and "inode" in entry for entry in entries), "Identity update was lost"

            subprocess.run([str(executable), "sweep", str(ledger)], check=True)
            assert {entry["path"] for entry in json.loads(ledger.read_text())} == expected
            assert {str(path) for path in work.iterdir()} == expected, "Sweep removed live work"
            print("Sweep preserved all 200 live work directories and registrations", flush=True)
        finally:
            for owner in owners:
                if owner.poll() is None:
                    owner.stdin.close()
                owner.wait(timeout=15)
            for owner in owners:
                assert owner.returncode == 0, f"Owner failed: {owner.returncode}"

        subprocess.run([str(executable), "sweep", str(ledger)], check=True)
        assert json.loads(ledger.read_text()) == []
        assert list(work.iterdir()) == [], "Sweep left work from an exited owner"
        print("Sweep recovered all work after the four owners exited", flush=True)


if __name__ == "__main__":
    main()
