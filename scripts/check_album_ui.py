"""Source wiring checks only; does not compile Swift or emulate iOS."""
from pathlib import Path
import plistlib

root = Path(__file__).resolve().parents[1]
app = (root / 'linCY/linCYApp.swift').read_text(encoding='utf-8')
browser = (root / 'linCY/AlbumBrowser.swift').read_text(encoding='utf-8')
backup = (root / 'linCY/BackupManager.swift').read_text(encoding='utf-8')
project = (root / 'linCY.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
plist = plistlib.loads((root / 'linCY/Info.plist').read_bytes())

assert 'path = AlbumBrowser.swift;' in project
assert 'files = (200000000000000000000002,' in project
assert plist['CFBundleShortVersionString'] == '0.2.16'
assert 'MARKETING_VERSION = 0.2.16;' in project

# Both actions stay in the same HStack, with independent info buttons.
summary = app.split('private var summarySection:', 1)[1].split('private var sourceSection:', 1)[0]
assert summary.index('HStack(spacing: 12)') < summary.index('Button("开始备份")')
assert summary.index('Button("开始备份")') < summary.index('"检查同名大小")')
assert summary.count('AlbumInfoButton(') == 2
assert '.buttonStyle(.borderless)' in summary
assert 'footer:' not in summary

# Selection remains on albums, never on photos in a preview.
assert 'localSelectionButton(album)' in app and 'remoteSelectionButton(name)' in app
assert 'LocalAlbumBrowser(album: album)' in app
assert 'RemoteAlbumBrowser(album: name, address: address, wifiOnly: wifiOnly)' in app
assert 'checkmark.circle' not in browser
assert 'selected.contains($0.id)' in backup
assert 'syncRequest = .albums(remoteSyncTargets)' in app
assert 'syncRequest = .albums(visibleRemoteAlbums)' in app
assert 'targets.filter { allowed.contains($0) }' in app
assert 'server: address' in app and 'selectedRemote.remove(name)' in app
assert '!hidden.contains($0.id)' in backup

# Browsing does not write to PhotoKit, upload files, or delete media.
for forbidden in ['performChanges', 'uploadFile(', 'uploadRequest(', 'deleteUpload(', 'UIImageWriteToSavedPhotosAlbum']:
    assert forbidden not in browser, forbidden
for required in ['case list, small, medium, large', 'PHAsset.fetchAssets', 'requestPlayerItem',
                 'api/album/thumbnail', 'api/album/photo', 'fullScreenCover', 'nextOffset',
                 'cancelImageRequest', 'dismantleUIView']:
    assert required in browser, required
assert 'if model.hasMore && !model.loading && model.error.isEmpty' not in browser
assert 'if model.hasMore && model.error.isEmpty' in browser
print('PASS: project/version, adjacent actions and info, album-only selection, hidden-album filtering, read-only preview wiring')
print('These are static checks; Swift compilation and device UI/behavior remain unverified.')
