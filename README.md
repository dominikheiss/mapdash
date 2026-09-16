# MapDash

**Warcraft III: Reforged on macOS downloads custom maps at ~250 KB/s. MapDash fetches them before you join.**

The game's own map download on the Mac is stuck at a few hundred KB/s. The server is not the
bottleneck: the same map comes off Blizzard's map server at 30+ MB/s with any other client. And a
running in-game download cannot be cancelled.

MapDash sits in the menu bar while you browse the Custom Games list. It reads the list out of the
running game, downloads the maps you don't have straight from Blizzard's map server, and puts
them where the game looks for them. When you click *Join*, the map is already there and the game
skips its download.

> [!WARNING]
> MapDash reads the memory of the running game (read-only). That is very likely against
> Blizzard's terms of service, and Blizzard could act against your account. **Use it at your own
> risk.** MapDash is not affiliated with or endorsed by Blizzard Entertainment.

## Install

1. Download `MapDash-<version>.zip` from [Releases](../../releases) and unzip it.
2. Move `MapDash.app` to *Applications* and open it.
3. macOS blocks it the first time, because the app is not notarized by Apple (that needs a paid
   developer account). Open *System Settings → Privacy & Security*, scroll down to
   *"MapDash" was blocked…* and click **Open Anyway**. Confirm once more.
4. Read the notice, click *I understand*, allow notifications if you want them.
5. A box icon appears in the menu bar. Optional: *Settings → Start at login*.

Requirements: macOS 13 or later. Tested on Apple Silicon; the Intel build starts, but nobody has
tried it with the game on an Intel Mac yet.

## Use

Start Warcraft III and open the Custom Games list. That is all — maps up to the size limit
download on their own. The menu shows:

| Entry | Meaning |
|---|---|
| *N lobbies in the list* | MapDash can read the game |
| *Downloading* | with progress; the menu bar icon shows the total |
| *Large maps — click to download* | above your limit; one click fetches it |
| *Failed — click to retry* | with the reason |
| *Other version already on disk* | a different map with the same file name is in your folder. MapDash never replaces it; the game handles it |
| *Ready* | maps that are on disk |
| *Map folder: … MB* | size of the game's download folder |

### Settings

| Setting | Choices | Default |
|---|---|---|
| Download small maps automatically | on / off | on |
| Automatic up to | 25, 50, 100, 150, 250, 500 MB, no limit | 50 MB |
| Downloads at once | 1–3 | 2 |
| Speed limit per download | none, 5, 10, 20 MB/s | none |
| Notify when maps are ready | on / off | on |
| Start at login | on / off | off |

## What it does and doesn't do

- **Reads** the game's memory; never writes to it, never pauses it.
- **Downloads** from `ugc.cdn.warcraft3-prod.battle.net`, the same server the game uses, and only
  keeps a file whose SHA-1 matches the hash the lobby host advertised.
- **Never deletes or overwrites** a map. Your download folder grows over time; clean it up
  yourself if you want (*Open map folder*).
- If the same map is already on disk under another name, it is copied locally instead of
  downloaded again (the game looks maps up by file name).
- Closed lobbies can linger in the game's memory for a while, so MapDash may fetch a map for a
  lobby that just disappeared. Harmless.
- It cannot tell which lobby you have selected; it prepares all of them.

Files: settings in the app's preferences, state in `~/Library/Application Support/MapDash/`,
log in `~/Library/Logs/MapDash.log` (*Open log*).

## Troubleshooting

**"MapDash may not read the game"** — your macOS account is not an administrator. Click
*Grant access…* and enter an administrator's password once; it adds your account to the system
group *Developer Tools* (`_developer`), which is what allows reading the game.

**"No lobbies found"** while the Custom Games list is open — a game patch has probably changed
how the list is stored. Check for a MapDash update (the menu shows one when available) or open an
issue.

**No notifications** — *System Settings → Notifications → MapDash*.

## Uninstall

Quit MapDash from its menu and delete the app. Optionally delete
`~/Library/Application Support/MapDash` and `~/Library/Logs/MapDash.log`. Downloaded maps stay
in the game's folder.

## Build from source

Needs only the Command Line Tools (`xcode-select --install`), not Xcode.

```
scripts/build.sh      # -> build/MapDash.app and build/MapDash-<version>.zip
```

How it works, in short: `Sources/Scanner/scanner.c` finds the game, takes its task port
(`task_for_pid` — allowed without root because the game binary carries `get-task-allow` and
admin accounts belong to `_developer`) and scans for the lobby objects, which carry each lobby's
W3-encoded statstring with map path, host and the map's SHA-1. The Swift app turns that into
downloads from `https://ugc.cdn.warcraft3-prod.battle.net/W3-maps-user/<sha1>.map`.

## License

MIT — see [LICENSE](LICENSE).
