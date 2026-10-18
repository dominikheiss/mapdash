# Automatic Warcraft map rescue (experimental macOS feature)

**Automatic rescue runs while MapDash is open.** Once the menu-bar app is running, its background helper listens to Warcraft III's *local* WebSocket. The player still chooses **Download Map** in Warcraft, but does **not** need to arm MapDash first. The rescue helper picks up the modal event and independently retrieves and saves the verified map, even if the lobby closes or Warcraft discards its own download.

**This is not pre-click automatic downloading.** The lobby WebSocket contains map names and paths but no validated CDN content SHA-1 in the inspected schemas; the SHA-1 only becomes observable when Warcraft initiates a download. Do not claim V30 can download every missing map merely by opening the lobby list.

## Install / build on macOS 13+

Requires Apple Command Line Tools and `python3`. This contribution requires an independent native macOS build and smoke test before release. The app is not notarized.

1. Quit any old MapDash menu-bar app (only one instance may run).
2. From a checked-out copy of the repository:

```bash
cd ~/Downloads/mapdash-main
bash scripts/build.sh
open build/MapDash.app
```

Check the menu-bar box icon. Automatic rescue is **ON by default** in this beta, and can be disabled using **Automatically rescue Warcraft downloads**. It remembers this choice. The status should eventually say **Watching Warcraft downloads automatically** with the game's Custom Games browser open. A full read-only memory baseline is collected once when the helper connects; allow a few moments for it.

If the helper needs `python3`, install a system-compatible Python 3 and relaunch the app. The packaged `.app` includes its Python sources and universal native helpers, so it doesn't depend on keeping the extracted folder around.

## Fast live test

1. Keep MapDash running, with **Automatically rescue Warcraft downloads** turned on. Wait for **Watching Warcraft downloads automatically**.
2. In Warcraft III Custom Games, choose a map you **do not have**, right-click it, and click **Download Map** **once**. Don't press anything in MapDash. Don't start two different downloads simultaneously.
3. Return to the MapDash menu and watch the status. Expected: **Download detected**, **Rescuing map independently**, then **Rescued and installed: ...**.
4. Confirm the `.w3x` exists in `~/Library/Application Support/Blizzard/Warcraft III/Maps/Download/`. Try hosting the map or joining a new lobby using it.
5. The machine-readable status log is `~/Library/Logs/MapDash-v30-auto-rescue.log`. It contains sanitized statuses and map filenames, not WebSocket frames or session IDs. Send the tail of the log if the helper fails:

```bash
tail -n 60 ~/Library/Logs/MapDash-v30-auto-rescue.log
```

If Warcraft removes its installed copy, choose **Restore verified backups**. Maps are staged at `~/Library/Application Support/MapDash/Rescue/` and are independently SHA-1 verified.

## Why the rescue is conservative

- Only a native `ShowDownloadModal` event can initiate scanning for a new CDN identifier; **no downloads are initiated from just lobby titles or filenames**.
- Only an exact `W3-maps-user/<40-hex-sha1>.map` URL pattern is considered, and the digest must appear in **two consecutive scans** and not in the pre-click baseline. Multiple candidates or multiple overlapping download clicks cause a safe skip.
- Downloads come from the fixed official Blizzard CDN hostname. Content SHA-1 is checked against the candidate before publishing it. The lobby-to-hash association remains **temporal, not cryptographically proven**.
- A verified backup is saved separately from Warcraft's installed copy. Installation is an atomic *no-overwrite* copy (not a hard link); it never replaces a conflicting installed map.
- The helper only reads Warcraft memory, connects via `127.0.0.1`, and keeps its session identifier in-process; it never attaches a debugger, modifies Warcraft, or records private WebSocket payloads.
- It reconnects when Warcraft restarts or the lobby WebSocket disappears, while MapDash remains running.
- The helper reads up to 2 GiB of process memory when establishing a baseline and for scans triggered by a download; it does **not** continuously rescan while idle.
- Disable automatic rescue from the MapDash menu when desired. To stop MapDash itself, choose Quit MapDash.

Reading another process's memory may violate Blizzard's terms and could put a game account at risk. Use only with awareness of that risk. The app is not affiliated with Blizzard.

## Technical architecture

`MapDashApp.swift` → `RescueController.startAutomaticRescue()` → bundled `scripts/v30-auto-rescue.sh` → `V30AutoRescue.py` (WebSocket and single-download correlation) → proven `V28Rescue.py` (`fetch_verified`, `install_no_overwrite`) → verified staging folder and Warcraft's Maps/Download.

`V29LobbyBridge.py` remains the **read-only** live-game listing source. The original memory-based lobby decoder cannot provide verified lobbies for the user's Warcraft version and should not be treated as a download trigger.

## Offline checks, before making a public release

```bash
python3 -m unittest discover -s tests -p '*test.py'
bash -n scripts/build.sh scripts/v30-auto-rescue.sh
# On macOS, the actual build is the final gate:
bash scripts/build.sh
```

A public binary release still needs successful native builds for both architectures, a real background rescue test, a second sequential map test if practical, a restart/reconnect test, and suitable code-signing/notarization or clear unsigned-app instructions. Do not publish the present source archive as a pretested native binary.
