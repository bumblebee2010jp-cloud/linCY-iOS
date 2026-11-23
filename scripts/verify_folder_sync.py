#!/usr/bin/env python3
"""Portable source/API contract checks; does not replace an Xcode compile or device test."""
from pathlib import Path
import re
import subprocess
import sys
root = Path(__file__).resolve().parents[1]
subprocess.run([sys.executable, str(root/'scripts/verify_project.py'), str(root/'linCY.xcodeproj')], check=True)
core = (root/'linCY/FolderSyncCore.swift').read_text(encoding='utf-8-sig')
manager = (root/'linCY/FolderSyncManager.swift').read_text(encoding='utf-8-sig')
server = (root/'linCY/Server.swift').read_text(encoding='utf-8-sig')
app = (root/'linCY/linCYApp.swift').read_text(encoding='utf-8-sig')
assert '[UTType.folder], asCopy: false' in core
for token in ['didPickDocumentsAt urls:', 'startAccessingSecurityScopedResource()', 'stopAccessingSecurityScopedResource()',
              'bookmarkData(options:', 'bookmarkDataIsStale:', 'NSFileCoordinator', 'withItemAt: sibling']:
    assert token in core, token
assert 'FolderSyncView(currentAddress:' in app
assert 'remote: remote' in manager and 'entry.size == previous.size' in manager
assert 'deleted: 0' in manager
for forbidden in ['api/sync/', 'upload-delete', 'x-vuio-delete', 'remove_dir', 'deleteUpload(']:
    assert forbidden not in core + manager, forbidden
assert '"path": parent, "conflict": "overwrite"' in core
assert '"api/files"' in core and '"api/download"' in core
assert '"Content-Length"' in server and 'receipt.size == size' in server
assert 'expectedSize' in core and 'response.statusCode == 200' in core
assert 'FolderBackupManager' not in ''.join(p.read_text(encoding='utf-8-sig') for p in (root/'linCY').glob('*.swift'))
tests = (root/'linCYTests/FolderSyncTests.swift').read_text(encoding='utf-8-sig')
print('PASS: native picker, bookmark/access balancing, old API contracts, no automatic delete, verified file replacement.')
print('XCTest cases supplied:', len(re.findall(r'func test\w+\(', tests)), '(run on macOS with scripts/run_ios_tests.py)')

view = (root/'linCY/FolderSyncView.swift').read_text(encoding='utf-8-sig')
assert '.fileImporter(isPresented: $picking, allowedContentTypes: [.folder]' in view
assert 'Task.detached(priority: .userInitiated)' in view
assert 'bookmarkData(options: .minimalBookmark' in core
callback = core[core.index('func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls:'):core.index('func documentPickerWasCancelled',core.index('final class Coordinator'))]
assert 'FolderAuthorization.capture' not in callback and 'resourceValues' not in callback and 'bookmarkData' not in callback
assert 'guard !completed' in callback and 'PickedFolder(url)' in callback
print('PASS: independent full-screen picker host, one-shot callback, retained scope, async authorization after dismissal.')
