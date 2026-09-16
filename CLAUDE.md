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
- `task_for_pid` without root was proven from a fresh SSH session and against the real game.
- **Admin accounts only** (owner's decision, 2026-09-16): non-admin accounts are not supported;
  the old *Grant access* path was removed in 0.2.0. Do not bring it back.
- **No macOS notifications - MapDash shows its own banner (`Toast.swift`).** An ad-hoc signed app
  never gets permission: a fresh test app got "not allowed" without a prompt, the legacy
  `NSUserNotification` API was dropped silently too, and usernoted stored MapDash's notifications
  with style 0 (never shown). A self-signed certificate is refused by `codesign` unless the user
  trusts it. The osascript workaround showed them under Script Editor, and clicking one opened
  Script Editor - so do not go back to it.
- **`AppModel` has no `@Published`; `publish()` sends changes.** Every published change rebuilds
  the whole `MenuBarExtra` menu, and a rebuild closes an open submenu. `publish()` sends only when
  the visible snapshot changed and never between `NSMenu` begin/end tracking. Any new state the
  menu shows belongs in `Snapshot`, or it will not refresh.
- **No SwiftUI `List` in windows that refresh often.** It is an `NSTableView` and logged
  "reentrant operation in its NSTableView delegate" (announced to become an assert) every few
  seconds; `ScrollView` + `LazyVStack` is silent.
- With `maps` a plain stored property, `maps[k]?.x = … maps[k]?.y` is an exclusivity error - read
  into a local first.
- **Timers belong in `.common` run loop mode.** A `scheduledTimer` stops while an `NSAlert` is
  modal, which froze state saving behind an unanswered start window.
- A second copy (same bundle id) must not build a working model: `Instance.isDuplicate` gates the
  model, the menu bar item and the delegate. Test copies need their own bundle id; a redirected
  home works with `CFFIXED_USER_HOME=<dir>`.
- The start window is skipped for login launches. Detection (login-item Apple event, else login
  item enabled and console session younger than 120 s) is **not verified** with a real login.
- Open work and the list of known pitfalls for other users live on the brain page
  `private/projects/wc3-mapfetch`, not here.
- Release: bump `VERSION`, `scripts/build.sh`, `gh release create v<version> build/MapDash-<version>.zip`.
  The app checks `releases/latest` once a day.
