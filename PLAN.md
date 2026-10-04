# SystemDataLens plan

A free, open-source (MIT), native macOS app that shows what is actually inside the
"macOS" and "System Data" bars in System Settings > General > Storage, down to real
paths on disk, and can clean up known-safe targets the user selects.

## Constraints

- macOS 14+, Apple Silicon and Intel. SwiftUI app, Swift 5.9 language mode.
- Built with xcodegen (`project.yml`), bundle prefix `app.sklar`, team 5Y3S9Y6Z27,
  Developer ID signing, hardened runtime. Not sandboxed (a sandboxed app cannot reach
  the paths that matter and complicates the daemon).
- MIT license, public GitHub repo `xwrvnggp9n-star/SystemDataLens`. DMG release,
  notarized when the Apple agreement is renewed.

## Architecture

Two executables in one bundle.

1. `SystemDataLens.app` (runs as the user). UI, category engine, rules file,
   user-owned cleanup (Move to Trash, `xcrun simctl`), raw-disk browsing.
2. `SystemDataLensHelper` (runs as root via launchd). Registered with
   `SMAppService.daemon(plistName: "app.sklar.SystemDataLens.helper.plist")`.
   - Plist at `Contents/Library/LaunchDaemons/`, `BundleProgram =
     Contents/MacOS/SystemDataLensHelper`, `MachServices` =
     `app.sklar.SystemDataLens.helper`, `AssociatedBundleIdentifiers` = app ID.
   - User approves once in System Settings > Login Items; app calls
     `SMAppService.openSystemSettingsLoginItems()` when status is `.requiresApproval`.
   - Launched on demand; exits after 120 s idle with no connections.
   - Version handshake: app calls `helperVersion()`; on mismatch it unregisters and
     re-registers so an updated app never talks to a stale helper.

### XPC

- `NSXPCListener(machServiceName:)` in the helper. In `shouldAcceptNewConnection`
  call `connection.setCodeSigningRequirement(...)` (macOS 13+) with
  `anchor apple generic and identifier "app.sklar.SystemDataLens" and
  certificate leaf[subject.OU] = "5Y3S9Y6Z27"`. The app sets the mirror requirement
  on its side for the helper identifier.
- The helper derives the calling user from `connection.effectiveUserIdentifier`
  (`getpwuid`) and never trusts a home path sent by the app.
- Protocol (all replies are Codable payloads encoded as `Data`, so the protocol is a
  handful of `@objc` methods taking/returning `Data`):
  - `helperVersion() -> String`
  - `volumes() -> [APFSVolume]` from `/usr/sbin/diskutil apfs list -plist`, local
    snapshots from `/usr/bin/tmutil listlocalsnapshots`, swap from
    `sysctl vm.swapusage`, sleep image size.
  - `startScan(root) -> scanID` (root restricted to a fixed list: the Data volume
    `/System/Volumes/Data`, `/System/Volumes/Preboot`, `/System/Volumes/Recovery`
    if mounted, `/System/Volumes/VM`), `scanProgress(scanID)`,
    `children(scanID, nodeID) -> [Node]`, `cancelScan(scanID)`.
    The tree stays in the helper; the app pulls children lazily, so large trees
    never cross XPC whole.
  - `cleanupTargets() -> [Target]` (root-owned targets only, with current sizes) and
    `runCleanup(targetIDs) -> Report`. The app sends **target IDs, never paths**.

### Scanner

- `fts_open` with `FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR`, sizes from
  `st_blocks * 512` (allocated size, matches what the disk loses).
- Hard links counted once per (dev, inode).
- Scanning `/System/Volumes/Data` directly avoids firmlink double counting from `/`.
- APFS clones and sparse files can make scanned totals exceed APFS "consumed". The
  UI shows an **Unaccounted** row = APFS consumed - scanned, which can be negative,
  with a note explaining why.
- Unreadable entries (SIP-protected, dataless cloud files) are counted and listed
  rather than silently skipped.

### Category engine (app side)

Reconstructs System Settings' categories from rules in `Resources/rules.json`
(path globs relative to the Data volume, `~` = scanned user's home):

- macOS = System volume + Preboot + Recovery + `Data:/System`.
- Applications, Documents (home outside Library and hidden folders), Photos
  (`*.photoslibrary`), Messages, Mail, iCloud Drive (`~/Library/Mobile Documents`),
  Music, Developer (`~/Library/Developer`), Trash, Other Users & Shared.
- System Data = everything else on the Data volume + VM volume + snapshots +
  Unaccounted.
- The same rules file supplies a plain-English description and a safety rating
  (safe / app-rebuilds / user-data / system) for known paths, shown in the inspector.
- Apple does not publish its exact rules; the README says the app reconstructs them.

### UI

- `NavigationSplitView`: sidebar (Categories, Raw Disk, Cleanup), detail view, and
  an inspector for the selected item (path, size, description, safety, Reveal in
  Finder, Move to Trash for user-owned items).
- Detail toggles between an outline list with size bars and a squarified treemap
  (SwiftUI `Canvas`, click to zoom, breadcrumb to go back).
- Works without the helper in a limited mode (user-readable paths only) with a banner
  offering to install the helper.

### Cleanup

Panel lists every target with size and a checkbox; user deselects any, sees the total,
confirms. Targets are defined in code, not loaded from a file.

- User-owned, done by the app, moved to Trash where possible:
  `~/Library/Caches/*`, `~/.cache/*`, npm cache, pnpm store prune, Homebrew
  `brew cleanup`, Xcode DerivedData, Google DriveFS `canceled_uploads/*`, old Claude
  `local-agent-mode-sessions`, iOS simulator devices/runtimes (`xcrun simctl delete
  unavailable`, runtime delete), empty Trash.
- Root-owned, done by the helper: `/Library/Caches/*`, `/private/var/db/diagnostics`
  via `/usr/bin/log erase --all`, `/Library/Updates/*` leftovers.
- Helper deletion rules: resolve each target from its hardcoded allowlist, `lstat`
  every path, never follow symlinks, `realpath` must stay under the allowlisted
  prefix, refuse anything else. Report per-path result.

## Verification

- Unit tests for treemap layout, rule matching, size formatting, cleanup path
  validation (symlink escape, `..`, prefix tricks).
- On Sandy's Mac: compare per-volume totals to `diskutil`, compare category totals to
  System Settings, run cleanup against dummy targets before real ones.
- Code review by Codex and a Fable reviewer, with extra attention on the helper,
  XPC validation and deletion code.

## Revisions after Codex and Fable plan review (2026-10-04)

Both reviews are saved in `docs/reviews/`. Changes adopted:

1. **Admin only.** The helper rejects any connection whose effective UID is not in
   group `admin`. Root cleanup additionally requires an Authorization Services
   external form for `system.privilege.admin`, verified in the helper without UI.
2. **Stricter code requirement.** Helper accepts only Developer ID leaf
   (`field.1.2.840.113635.100.6.1.13`), team 5Y3S9Y6Z27, identifier
   `app.sklar.SystemDataLens`, and no `get-task-allow` entitlement.
   App connects with `.privileged` and checks the helper's requirement.
3. **Race-free deletion.** No path-based deletes anywhere. `SafeDeleter` opens the
   allowlisted root with `O_NOFOLLOW_ANY`, walks with `openat(O_NOFOLLOW)`, checks
   dev/inode after every open, never crosses devices, removes with `unlinkat`.
   Shared by helper and app.
4. **Scanner** uses `getattrlistbulk` with allocated size, private (unshared) size,
   link ID, ext flags (may-share-blocks, purgeable, sparse) and st_flags
   (`SF_DATALESS`). Dataless materialization is switched off process-wide with
   `setiopolicy_np` before any scan. Small files (< 1 MiB) in a directory are folded
   into one "smaller files" node. Tree is a flat preorder array encoded in binary,
   fetched by the app in chunks; the helper drops it after transfer.
5. **Smaller root surface.** Volumes, snapshots, swap: app side (no root).
   Helper scan roots limited to `/System/Volumes/Data` and `/System/Volumes/Preboot`.
   The app scans the sealed system volume `/` itself (it is world-readable).
   One scan at a time, state scoped to the connection, freed on invalidation, idle
   exit only when no connection and no scan.
6. **Upgrade.** Version mismatch: ask helper to exit, `register()` again. A manual
   "Reinstall helper" button does unregister/delay/register. Registration refused
   while running from `/Volumes` or App Translocation.
7. **Accounting language.** Sizes are "allocated"; subtree totals are upper bounds
   when clones exist; residual is labeled "Unexplained", never "reclaimable".
   Categories are presented as app-defined approximations of System Settings.
   Added categories: iOS backups, Books, Podcasts, TV, Music Creation.
8. **Cleanup list.** `/Library/Updates` dropped. `log erase` is opt-in and labeled.
   Time Machine local snapshots added (root, per snapshot, opt-in). User-side targets
   run in the app, delete contents not top directories, skip `com.apple.*` caches
   unless opted in. Risky targets (DriveFS canceled uploads, iOS backups, Claude
   sessions, Archives, user temp cache) default off. Every target shows exact
   items and its command before running.
9. **TCC.** Root does not bypass Full Disk Access. The app checks access to
   protected folders and walks the user through granting it.
