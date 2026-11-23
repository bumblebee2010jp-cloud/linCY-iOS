#!/usr/bin/env python3
"""Run the native XCTest suite on an available iPhone simulator (macOS + Xcode)."""
import json
import subprocess
from pathlib import Path
root = Path(__file__).resolve().parents[1]
info = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))
candidates = [device for runtime, devices in info['devices'].items() if '.iOS-' in runtime
              for device in devices if device.get('isAvailable') and device['name'].startswith('iPhone')]
if not candidates:
    raise SystemExit('No iPhone simulator is available. Install an iOS Simulator runtime in Xcode first.')
device = next((value for value in candidates if value['state'] == 'Booted'), candidates[0])
subprocess.run(['xcodebuild', 'test', '-project', 'linCY.xcodeproj', '-scheme', 'linCY',
                '-configuration', 'Debug', '-sdk', 'iphonesimulator', '-destination', 'id=' + device['udid'],
                '-derivedDataPath', 'build-tests', '-parallel-testing-enabled', 'NO',
                'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO'], cwd=root, check=True)
