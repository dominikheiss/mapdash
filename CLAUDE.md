# MapDash

Public repo (GitHub `dominikheiss/mapdash`). Everything in it is English. Background and the
measurements behind every design choice: GBrain `private/systems/wc3-reforged-mac-map-download-langsam`
and `private/projects/wc3-mapfetch`. Predecessor (SwiftBar + Python + root daemon, retired):
`private_projects/wc3_mapfetch/`.

- **The game process is only ever read** (`task_for_pid` + `mach_vm_read`). No debugger, no
  suspending, no network tricks - an lldb attach once dropped the Battle.net session.
- **Never delete or overwrite a map file.** Files are placed with `FileManager.linkItem`, which
  fails with `CocoaError.fileWriteFileExists` instead of replacing (verified).
- **Maps are keyed by sha1 + file name**, not sha1: the game looks maps up by name, and hosts
  share one map under several names. Keying by sha1 alone left the second name missing.
- **No SwiftUI `@State` / `@Observable`**: the Command Line Tools lack the SwiftUI macro plugin,
  so the build fails. Use `ObservableObject` + `@Published`.
- **UserDefaults defaults must be registered before any property initialiser reads them** -
  property initialisers run before `init`'s body; getting this wrong shipped auto-download off.
- The fast scan reads only small untagged rw regions; every 15th round a full scan cross-checks,
  and only what neither the fast scan before nor after it saw is logged as a miss (a lobby opened
  between two scans is not one).
- `task_for_pid` without root was proven from a fresh SSH session and against the real game. The
  *Grant access* path (non-admin accounts) is **untested** - no non-admin account was available.
- Release: bump `VERSION`, `scripts/build.sh`, `gh release create v<version> build/MapDash-<version>.zip`.
  The app checks `releases/latest` once a day.
