#!/usr/bin/env python3
"""Profile native normal callbacks using freshly built Debug/testable products."""
# Copyright (C) 2026 Stephen de la Vega.
# SPDX-License-Identifier: GPL-3.0-or-later
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import plistlib
import shutil
import signal
import subprocess
import uuid


def run(arguments, log, timeout=180, env=None):
    with log.open('w') as stream:
        process = subprocess.Popen(arguments, stdout=stream, stderr=subprocess.STDOUT,
                                   env=env, start_new_session=True)
        try:
            result = process.wait(timeout=timeout)
        except BaseException:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise
        if result:
            raise RuntimeError(f'Command failed ({result}); see {log}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--products', type=Path, required=True)
    parser.add_argument('--results', type=Path, required=True, help='New output directory')
    parser.add_argument('--architecture', choices=('arm64', 'x86_64'), default=platform.machine())
    parser.add_argument('--iterations', type=int, default=50)
    parser.add_argument('--interval', type=float, default=0.2)
    parser.add_argument('--hardware', action='store_true', help='Also read GPU/VRAM and temperature/fan sources')
    args = parser.parse_args()
    if not 1 <= args.iterations <= 300 or not math.isfinite(args.interval) or not 0.2 <= args.interval <= 10:
        parser.error('iterations must be 1–300 and interval 0.2–10 finite seconds')
    products, output = args.products.resolve(), args.results.resolve()
    framework = products / 'XRGCore.framework'
    if not framework.is_dir():
        parser.error('missing XRGCore.framework; build Debug XRGTests with ENABLE_TESTABILITY=YES')
    output.mkdir(parents=True, exist_ok=False)
    copied = output / 'Frameworks/XRGCore.framework'
    copied.parent.mkdir()
    shutil.copytree(framework, copied, symlinks=True)
    run(['codesign', '--force', '--sign', '-', str(copied)], output / 'sign-framework.log')
    binary = output / 'XRGCollectorProfile'
    root = Path(__file__).resolve().parents[1]
    run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', '-Onone',
         '-target', args.architecture + '-apple-macos26.0', '-F', str(output / 'Frameworks'),
         '-framework', 'XRGCore', '-framework', 'AppKit', '-Xlinker', '-rpath', '-Xlinker',
         '@executable_path/Frameworks', str(root / 'Tools/CollectorProfile/main.swift'), '-o', str(binary)], output / 'compile.log')
    run(['codesign', '--force', '--sign', '-', str(binary)], output / 'sign-helper.log')
    domain = 'XRG.collector-profile.' + str(uuid.uuid4())
    (output / 'domain.txt').write_text(domain + '\n')
    environment = os.environ.copy()
    environment.update(XRG_PROFILE_DOMAIN=domain, XRG_PROFILE_ITERATIONS=str(args.iterations),
                       XRG_PROFILE_INTERVAL=str(args.interval), XRG_PROFILE_HARDWARE=str(int(args.hardware)),
                       XRG_PROFILE_REPORT=str(output / 'report.json'))
    try:
        run(['/usr/bin/arch', '-' + args.architecture, str(binary)], output / 'run.log',
            timeout=args.iterations * args.interval + 180, env=environment)
        report = json.loads((output / 'report.json').read_text())
        expected = {'normal/CPU', 'normal/Memory', 'normal/Network', 'normal/Disk', 'normal/Battery'}
        if args.hardware:
            expected |= {'normal/GPU', 'normal/VRAM', 'normal/Temperature', 'normal/Fans'}
        assert report['schema'] == 1 and report['architecture'] == args.architecture
        assert report['iterations'] == args.iterations and set(report['callbacks']) == expected
        report['frameworkSHA256'] = hashlib.sha256((copied / 'XRGCore').read_bytes()).hexdigest()
        report['helperSourceSHA256'] = hashlib.sha256((root / 'Tools/CollectorProfile/main.swift').read_bytes()).hexdigest()
        report['hostArchitecture'] = platform.machine()
        report['hardwareModel'] = subprocess.check_output(['/usr/sbin/sysctl', '-n', 'hw.model'], text=True).strip()
        for stats in [report['cycles'], *report['callbacks'].values()]:
            assert stats['count'] == args.iterations
            assert all(math.isfinite(stats[k]) and stats[k] >= 0 for k in ('minMs', 'medianMs', 'p95Ms', 'maxMs', 'totalMs'))
            assert stats['minMs'] <= stats['medianMs'] <= stats['p95Ms'] <= stats['maxMs']
        (output / 'report.json').write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    finally:
        # Only this invocation's generated UUID domain is eligible for removal.
        subprocess.run(['/usr/bin/defaults', 'delete', domain], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
        preferences = Path.home() / 'Library/Preferences' / (domain + '.plist')
        if preferences.exists():
            assert not preferences.is_symlink() and preferences.stat().st_uid == os.getuid()
            assert plistlib.loads(preferences.read_bytes()) == {}, 'Private profile preferences were not cleared'
            preferences.unlink()
        (output / 'cleanup.json').write_text(json.dumps({'domain': domain, 'preferencesRemoved': True}) + '\n')
    print(f'PROFILE_OK {args.architecture}: {len(expected)} callbacks × {args.iterations} samples; {output / "report.json"}')


if __name__ == '__main__':
    main()
