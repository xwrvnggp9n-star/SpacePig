# Code review triage, 2026-10-04

Reviewers: Codex CLI 0.155.1 (raw output in `codex-code-review.log`) and a Fable subagent. Both reviewed commit `Skip firmlinks when scanning the system volume`.

## Fixed

- Stop never reached the helper: `Task.sleep` threw before the cancel branch. The helper kept scanning as root and held the scan lock. (Fable)
- Records from getattrlistbulk were trusted without bounds checks. Every record and name now has to fit inside the buffer. (Codex)
- The scanner reopened directories by path with `O_NOFOLLOW`; now `O_NOFOLLOW_ANY`. (Codex)
- FlatTree decoding could overflow `off + n * size` and trap on huge `UInt64` counts. Now uses checked arithmetic and `Int(exactly:)`. (Codex)
- The helper's authorization check passed `.extendRights` against `system.privilege.admin`, which has `allow-root`. Now a custom right `app.sklar.SystemDataLens.cleanup` (admin group, `allow-root` false, not shared, timeout 0), checked without extending. Verified on device with `--selftest-auth`: an authorization without rights is refused. (Codex, Fable)
- User-side cleanups ran before the admin prompt, so cancelling the prompt left a half-done cleanup. Authorization now comes first. (Codex, Fable)
- `exitForUpgrade` could kill another connection's scan or cleanup. Now postponed while work is in flight. (Codex, Fable)
- Root cleanup validated IDs by walking `/Library/Caches` and running `tmutil` on every request. Now validated statically and de-duplicated. (Fable)
- The helper held the tree, the encoding and every chunk at once. Now holds only the encoding and slices chunks on demand. (Codex, Fable)
- The app cached a full size array per category visited. Now keeps one. (Fable)
- stderr was merged into stdout, so a diskutil warning broke plist parsing. Separate pipes. (Fable)
- Volume roles: a second macOS install in the container could supply the wrong System/Data numbers. Now matched by device. (Fable)
- `xcrun` was run on Macs without developer tools, which pops an install dialog. Now gated on `xcode-select -p`. (Fable)
- DriveFS account names were not run through `isSafeName`. (Codex)
- Home folders behind a symlink made every user target fail under `O_NOFOLLOW_ANY`. Home is resolved first. (Fable)
- Move to Trash showed the category-filtered size and acted on a possibly stale path. Now shows the whole item and refuses if the item's type changed since the scan. (Codex, Fable)
- Glob rules matched the synthetic "(N smaller files)" nodes. (Fable)
- Two quick clicks on Scan could start two scans. (Fable)
- Connection handlers could clear a newer connection. (Fable)

## Found in on-device testing

- APFS link IDs differ per hard link, so hard links were counted twice. Now deduplicated by file ID (unit test caught it).
- Firmlinks report the same device as the system volume, so scanning `/` walked the whole Data volume. Now excluded by path from `/usr/share/firmlinks`.
- Replacing the app while the helper ran left an old helper the new app refuses. The helper now exits when its executable changes, and the app restarts the helper once through launchd if it still can't connect. Both verified.
- Every build had the same build number, so a stale helper looked current. Build numbers are now timestamps.
- Purgeable files: System Settings leaves Messages attachments kept in iCloud out of Messages, but counts purgeable files elsewhere. Matched.
- Third-party app data in `~/Library/Application Support`, `Containers` and `Group Containers` counts as Applications in System Settings, not System Data. Matched.

## Not changed, with reasons

- Codex: "unlinkat after closing the directory can delete a replacement entry outside the inspected tree." Every unlinkat is relative to a directory descriptor that was verified by device and inode, so a replaced name is still inside that verified directory; at worst an empty directory someone else just created there is removed. Fable checked the same code and found no escape.
- Codex: "ATTR_CMN_ERROR is parsed out of bitmap order." getattrlistbulk(2) and Apple's sample code place it directly after the returned-attributes set; Fable confirmed. Records are now bounds-checked either way.
- Second hard links are dropped rather than shown as zero-byte rows. Simpler, and the bytes are counted once.
- Unreadable individual entries (ATTR_CMN_ERROR set) are skipped; unreadable directories are flagged.
- XPC calls have no timeout. The connection's error handler covers a dead helper; a hung helper is unlikely and visible.
