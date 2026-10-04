<img src="docs/icon.png" width="128" alt="">

# SpacePig

A free, open-source macOS app that shows what is inside the "macOS" and "System Data" bars in System Settings > General > Storage, down to the folders and files on disk. It can also clear caches, logs and other leftovers you pick from a list.

MIT license. Native SwiftUI. macOS 14 or later.

## What it shows

- **Categories.** The same buckets System Settings uses (macOS, System Data, Applications, Documents, Messages, Photos and the rest), each broken down into real folders. Click into any folder to keep going.
- **macOS.** The sealed system volume, the Preboot volume (Rosetta, the OS cryptex, staged updates), the Recovery volume, and the macOS files that live on the Data volume, such as downloaded Siri and Apple Intelligence assets.
- **System Data.** Everything else: your Library folder, hidden folders in your home, Homebrew, `/private/var`, `/Library`, swap files, and an "Unexplained" row for space APFS uses that no file accounts for (metadata, local snapshots, folders that could not be read).
- **Raw volumes.** Browse the Data volume, the system volume and Preboot as plain trees.
- A list with size bars or a treemap for every view, and an inspector that says what a folder is and whether it is safe to remove.

Apple does not publish how System Settings assigns files to categories. SpacePig reconstructs it from the rules in `App/Resources/rules.json`. On the Mac it was calibrated against, Messages, Photos, Mail and Other Users came within about 1 GB of System Settings. Expect differences of a few GB elsewhere.

## The helper

Most of the disk is readable by your account, but not all of it. The app installs a small helper that runs as root so it can measure other users' folders, `/private/var` and root-owned caches. You approve it once in System Settings > General > Login Items & Extensions.

- Only an administrator account can use the helper.
- The helper only answers this app, signed with this developer's Developer ID. It checks that on every message.
- It scans two places: the Data volume and the Preboot volume.
- It can delete three things: the contents of `/Library/Caches`, the unified log, and Time Machine local snapshots. The app sends the name of a target, never a path. Each cleanup asks for your administrator password.
- Deletion never follows symlinks and never crosses into another volume.
- The helper quits after two minutes of inactivity, and on its own when the app is updated.

macOS hides Mail, Messages, Safari and other app data from every app without Full Disk Access, even one running as root. Turn on Full Disk Access for SpacePig in System Settings > Privacy & Security. The helper inherits it.

## Cleanup

The Clean Up panel lists every target with its current size and a checkbox. Safe targets start checked; anything that could lose data starts unchecked. Details lists every folder and file a target will remove, with sizes and dates. Caches, logs, Xcode DerivedData and device support files can be limited to files not modified in 30, 60 or 90 days. Nothing is deleted until you confirm, and cancelling the administrator prompt cancels the whole cleanup.

Targets run as you: app caches, Apple app caches, command-line caches, app logs, Xcode DerivedData, device support files, archives, simulator caches, unavailable simulators, simulator runtimes, npm, pnpm and Homebrew caches, Google Drive cancelled uploads, old Claude agent sessions, iPhone backups, and the Trash.

Targets run by the helper: `/Library/Caches`, the unified log, and Time Machine local snapshots.

## Build

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```
scripts/build.sh            # Release build, signature checks, DMG in dist/
scripts/build.sh --install  # also copies the app to /Applications
```

The project signs with a Developer ID certificate. The helper refuses any client that is not Developer ID signed by the same team, so to build your own copy, change `DEVELOPMENT_TEAM` in `project.yml` and `teamID` in `Shared/HelperProtocol.swift` to your team.

Tests: `xcodebuild test -scheme SpacePig`.

Self-test of the helper's password check: `open -a SpacePig --args --selftest-auth`, then read `~/Library/Logs/SpacePig-selftest.log`.

## Status

Releases are signed with Developer ID and notarized by Apple.

Website: https://sklar.app/spacepig/

SpacePig is free and MIT-licensed. If it found you some space, [buy me a coffee](https://buymeacoffee.com/sandysklar).
