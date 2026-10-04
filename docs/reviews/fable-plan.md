# Fable plan review (2026-10-04)

Findings, tagged BLOCKER/SHOULD/NIT. All BLOCKERs and most SHOULDs adopted; see PLAN.md "Revisions".

1. BLOCKER. Path-based delete is a TOCTOU; delete fd-relative with openat/unlinkat, O_NOFOLLOW(_ANY), dev/ino checks.
2. BLOCKER. Any local user can drive the root helper; require admin group membership.
3. SHOULD. Requirement accepts Development builds with get-task-allow; require Developer ID leaf OID and reject get-task-allow.
4. SHOULD. Move volumes/snapshots/swap queries out of the helper.
5. SHOULD. Spawn root commands with absolute paths, empty env, timeout.
6. SHOULD. App must connect with NSXPCConnection.Options.privileged.
7. SHOULD. Treat XPC payloads as untrusted; bounds-check IDs; serialize cleanup.
8. NIT. Log accepted/rejected connections.
9. BLOCKER. Refuse registration from /Volumes or App Translocation.
10. SHOULD. Avoid unregister/register on version mismatch; ask helper to exit, then register.
11. SHOULD. Pin launchd plist details; embed helper Info.plist with -sectcreate.
12. SHOULD. Idle exit must consider held scan trees.
13. NIT. Document Gatekeeper behaviour until notarized.
14. BLOCKER. Disable dataless materialization (setiopolicy_np) before scanning; flag SF_DATALESS.
15. SHOULD. Use getattrlistbulk with ALLOCSIZE, LINKID, CLONEID, EXT_FLAGS.
16. SHOULD. Flat array tree, interned names; ship to app and drop in helper.
17. SHOULD. Clones: label totals as upper bounds.
18. SHOULD. Snapshots: list via diskutil apfs listSnapshots; aggregate only.
19. NIT. Keep purgeable out of category bars.
20. NIT. Label .fseventsd, .Spotlight-V100, .DocumentRevisions-V100.
21. SHOULD. Do not hardcode the macOS category; tune against real numbers.
22. SHOULD. Add iOS Files, Books, Podcasts, TV, Music Creation.
23. NIT. Explain that hidden home folders count as System Data.
24. BLOCKER. Drop /Library/Updates; staged updates live elsewhere.
25. SHOULD. log erase off by default, clearly labeled.
26. SHOULD. Delete cache contents, skip com.apple.* unless opted in.
27. SHOULD. Add TM local snapshots, DeviceSupport, Archives, CoreSimulator caches, MobileSync backups, ~/Library/Logs, DARWIN_USER_CACHE_DIR.
28. SHOULD. brew/pnpm/npm/simctl run as the user from the app.
29. NIT. Empty Trash by deleting ~/.Trash contents; say so.
30. NIT. Put Claude sessions under a generic developer-leftovers group.
31. SHOULD. Make limited (no helper) mode first-class.
32. NIT. Do not raw-scan Preboot/Recovery as root (partly adopted: Preboot kept, Recovery dropped).
33. NIT. Never load rules from a user-writable path.
34. NIT. Hostile-machine tests: symlink swap mid-walk, mount point, hard links, dataless files, XPC rejection.
