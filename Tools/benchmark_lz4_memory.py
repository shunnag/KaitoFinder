#!/usr/bin/env python3
"""Measure KaitoKit's streaming LZ4 reader with fixed-size blocks and increasing input."""
import argparse
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kaito', type=pathlib.Path, required=True, help='Built KaitoKit CLI to measure')
    parser.add_argument('--sizes-mib', type=int, nargs='+', default=[16, 64, 256])
    parser.add_argument('--max-rss-mib', type=float, default=128)
    parser.add_argument('--frame-format', choices=['modern', 'legacy', 'all'], default='modern')
    arguments = parser.parse_args()
    if any(size <= 0 for size in arguments.sizes_mib) or arguments.max_rss_mib <= 0:
        parser.error('Sizes and RSS limit must be positive')
    binary = arguments.kaito.resolve(strict=True)
    lz4 = shutil.which('lz4')
    if not lz4:
        parser.error('The independent LZ4 CLI is required')
    print(json.dumps({'binary': str(binary), 'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
                      'note': 'Peak RSS for each separate CLI process; input and reference encoding are outside that process.'}), flush=True)
    pattern = bytes(((i * 73 + i // 31) * 41) & 255 for i in range(4093))
    block = (pattern * ((1024 * 1024 + len(pattern) - 1) // len(pattern)))[:1024 * 1024]
    modes = []
    if arguments.frame_format in ('modern', 'all'):
        modes.extend((mode, 4, ['-B7', mode, '-BX', '--content-size']) for mode in ['-BI', '-BD'])
    if arguments.frame_format in ('legacy', 'all'):
        modes.append(('legacy', 8, ['-l']))
    with tempfile.TemporaryDirectory(prefix='kaito-lz4-memory-') as temporary:
        root = pathlib.Path(temporary)
        source, archive = root / 'payload.bin', root / 'payload.bin.lz4'
        for size in arguments.sizes_mib:
            digest = hashlib.sha256()
            with source.open('wb') as output:
                for _ in range(size):
                    output.write(block)
                    digest.update(block)
            for mode, block_size, options in modes:
                subprocess.run([lz4, '-q', '-f', '-T1', *options, str(source), str(archive)], check=True)
                result = subprocess.run(['/usr/bin/time', '-l', str(binary), 'sha', str(archive)],
                                        capture_output=True, text=True, timeout=300)
                if result.returncode:
                    raise RuntimeError(f'Streaming reader exited with {result.returncode}:\n'
                                       f'{result.stdout}\n{result.stderr}')
                if digest.hexdigest() not in result.stdout:
                    raise RuntimeError('Streaming SHA-256 does not match the original input')
                match = re.search(r'(\d+)\s+maximum resident set size', result.stderr)
                if not match:
                    raise RuntimeError('Peak RSS missing from time(1) output: ' + result.stderr)
                rss = int(match[1]) / (1024 * 1024)
                row = {'input_mib': size, 'block_size_mib': block_size, 'mode': mode, 'archive_bytes': archive.stat().st_size,
                       'max_rss_mib': rss, 'sha256': digest.hexdigest()}
                print(json.dumps(row), flush=True)
                if rss > arguments.max_rss_mib:
                    raise RuntimeError(f'Peak RSS {rss:.2f} MiB exceeds {arguments.max_rss_mib:.2f} MiB')


if __name__ == '__main__':
    main()
