# Claude Reset Notifier

[![CI](https://github.com/Davie521/claude-reset-notifier/actions/workflows/ci.yml/badge.svg)](https://github.com/Davie521/claude-reset-notifier/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

**[中文文档](README.zh-CN.md)**

A macOS menu bar widget that answers one question at a glance: *how much Claude quota is
left, and when does it reset* — for every Claude Code account on the machine, discovered
automatically.

No backend, no dependencies, no package manager. One Swift file compiled into a single
binary that runs as a LaunchAgent.

> Unofficial. Not affiliated with or endorsed by Anthropic. It reads the same
> `/api/oauth/usage` endpoint the Claude Code CLI uses — an undocumented internal API that
> can change or disappear without notice. See [Caveats](#caveats).

## What it shows

Information density first, with time as the headline. The menu bar title renders one
concentric ring plus a reset countdown per account — something like `◔ 5d  ◑ 21h` (the
rings are drawn, those two characters are just an illustration):

- **Outer ring = weekly all-model limit remaining. Inner ring = Fable weekly capacity
  remaining.** Fill ratio *is* the remaining percentage. An account whose plan doesn't
  include Fable (Pro) gets the outer ring only.
- The rings are monochrome throughout — they follow `labelColor`, so they stay legible on
  light and dark menu bars and on wallpaper-tinted ones. There is deliberately no
  orange/red warning state: quota is meant to be spent, so "not much left" is the normal
  case, not an incident. The ring is a fuel gauge, not an alarm.
- Accounts go left to right: A, B, C, ….
- Once a reset time passes, the account switches to "restored": ring full, countdown
  replaced by ✓.

Click for one row per account. Hover a row for the account's directory, the absolute reset
time, the 5-hour window's reset time, the plan, data age, and error detail. A failing account gets a small ⚠ next to its letter and **keeps showing its
last good numbers**:

```
● A⚠   5小时 剩59%   Fable 剩97%   周 剩97%       6天后重置
● B    5小时 剩93%   Fable 剩45%   周 剩64%    20时47分后重置
● C    5小时 剩54%   Fable  不含   周 剩93%      2天4时后重置
        │              │              │                │
        │              │              │                └─ time until reset
        │              │              └─ weekly all-model limit remaining
        │              └─ Fable weekly capacity remaining (不含 = not in this plan)
        └─ 5-hour window remaining
```

The 5-hour window is shown only here, not in the menu bar: it turns over every few hours
while polling is lazy (below), so the number can be over an hour old — hover for its age,
or use Claude Code's own status line for a live figure.

The account currently in use gets a solid dot and full-brightness text; the idle one gets
a translucent dot and grey text. "Quit" really quits — the LaunchAgent only relaunches on
a crash, and starts the app at login.

> **The in-app UI is currently Chinese-only.** Every string lives in one file
> (`menubar/ClaudeReset.swift`) and is not localized yet; an English localization is a
> welcome contribution. The README, code comments and install script explain everything
> the UI says.

## How it works

- Reads the Claude Code OAuth token for each account from the macOS Keychain,
  **read-only**, along with the plan type stored next to it (`subscriptionType`). It never refreshes or writes a token, so it can't knock the Claude Code
  CLI out of its session. Nothing is sent anywhere except `api.anthropic.com`.
- Background polling is deliberately lazy: one call to `api.anthropic.com/api/oauth/usage`
  every 30 minutes, fetching **one account per tick**, in rotation — so with N accounts,
  **one request per account every N×30 minutes** (90 minutes for three). This endpoint is rate-limited hard: a sustained 1 request/minute
  still earns a 429.
- The weekly limit comes from the `limits[]` entry with `kind=weekly_all`; the Fable
  bucket from `kind=weekly_scoped` whose `scope.model.display_name` matches "Fable". If no
  bucket matches by name it is left empty rather than borrowing some other model's bucket.
  The 5-hour window comes from `kind=session` (falling back to the top-level `five_hour`).
- Scheduling rotates on *last attempt time* regardless of success, so one persistently
  failing account (an idle account with an expired token, say) can never starve the other
  account's refresh.
- Three gates decide when a request actually goes out: a **5 minute** minimum interval per
  account; opening the menu only triggers a fetch if the selected account's data is more
  than **25 minutes** old; manual refresh is throttled to once per **5 minutes** (it hits every account, so with more
  than three accounts the gap grows by 100 seconds per account, and a 429 stops the batch).
- Failures back off per account: 5 → 10 → 20 … minutes, capped at 1 hour. A 429 takes the
  larger of that and the server's `Retry-After`, and adds a 60 second global cooldown. One
  account being rate-limited does not gate the other.
- **Refresh now** respects the server's 429 window and the global cooldown — mashing it
  can't punch through — but does skip the soft backoff we added ourselves for local
  errors, so you can re-run `claude` to refresh a token and verify immediately. When a
  gate blocks it, the menu item greys out and says how long is left, instead of doing
  nothing when clicked.
- While a fetch is failing the last successful numbers stay on screen with a ⚠ next to the
  account letter. Nothing is cleared.
- The snapshot, backoff window, last error and last attempt time are all persisted to
  `state.json`: data is on screen immediately after a restart, a still-valid `Retry-After`
  is not ignored, and a failed account's stale numbers are never dressed up as fresh.

## Design trade-offs

A handful of constraints that aren't obvious and are easy to break while editing. Each has
a long comment at the corresponding place in `menubar/ClaudeReset.swift` explaining the
history; only the conclusions are listed here.

- **Empty data must never overwrite the cache.** The emptiness check lands on the
  percentage the UI actually displays, not merely on whether a bucket exists — a hollow
  bucket carrying only `resets_at` would otherwise sail down the success path and paint
  over good numbers. A renamed field, a value that turned into a string, a JSON boolean,
  or a previously populated bucket vanishing entirely all count as failure. (A machine
  that legitimately has no Fable bucket is fine — that's not a loss.)
- **But protecting the cache must not weld the account shut.** After the same shape is
  rejected `PARSE_GIVE_UP` (5) times in a row — roughly 2 hours once the backoff ladder is
  factored in — the new structure is accepted, **provided it still carries at least one
  percentage**. A response containing nothing at all is never the "new normal". Without
  that proviso this escape hatch would be a post-dated cheque for wiping the cache.
- **Two crash-loop entry points are sealed.** Non-finite numbers are dropped at the door
  (`-1e400` is quietly parsed as `-inf` by `JSONSerialization`, while a positive `1e400`
  throws), and any externally-sourced number of seconds is clamped before `Int()`
  conversion (out-of-range `Int(Double)` in Swift is a trap, not an overflow). Once the
  process aborts, `KeepAlive` relaunches it, it re-reads the same data and crashes again —
  the only way out for a user would be deleting `state.json` by hand.
- **Every request gate is timed on the monotonic clock**, so changing the system clock
  can't freeze polling forever. The single exception is "how old is this data", which has
  to survive restarts and therefore uses the wall clock; a backwards clock jump is treated
  as "old", which fetches more, never silently less.
- **The UI clock and main-thread callbacks run in the common runloop mode.** While a menu
  is tracking, the main runloop is in `NSEventTrackingRunLoopMode`, where a default-mode
  `Timer` never fires once — and a menu being open is precisely the one window where
  in-place updates matter.
- **The menu is built once and updated in place**, never `removeAllItems` from an async
  callback — that swaps the item under the cursor between mouse-down and mouse-up.

## Configuration

**None.** At launch the widget discovers accounts on its own: it scans the Claude Code
config directories `~/.claude` and `~/.claude-*` and keeps the ones that actually have
login credentials in the Keychain (if none are found, a single A row says so). `~/.claude` becomes A, `~/.claude-b` becomes B,
`~/.claude-work` becomes WORK, and so on.

How: Claude Code stores one OAuth credential per config directory in the Keychain — the
default directory under `Claude Code-credentials`, any other directory (the one
`CLAUDE_CONFIG_DIR` points at) under `Claude Code-credentials-` plus the first 8 hex
characters of the SHA-256 of the directory's absolute path. So a `~/.claude-xxx` that
isn't a config directory is never picked up, and a leftover Keychain entry whose directory
is gone doesn't show up either.

- **Logged into a new account:** restart the widget (it scans once, at launch):
  `launchctl kickstart -k gui/$(id -u)/io.github.davie521.claude-reset-menubar`, or re-run
  `./install.sh`.
- **Not found:** `CLAUDE_CONFIG_DIR` points outside `~/.claude-*`, or is spelled
  differently from the real path (a trailing `/` changes the hash).
- **Many accounts:** the menu bar title grows one ring group (~50pt) per account; on a
  notched display macOS hides the whole item when it no longer fits. The footer's polling
  interval follows the account count; at launch it fetches one account and warms up at most
  two more (the endpoint is rate-limited too hard to fan out per account), the rest follow
  the 30-minute rotation. Long names (`~/.claude-personal`) are truncated in the dropdown;
  hover for the full name and directory.
- **Plan:** read from `subscriptionType` in the Keychain credential. `pro` gets no Fable
  ring (on Pro, Fable runs on pay-as-you-go usage credits rather than plan limits, and the
  API returns no Fable bucket); `max` does. Without a plan type, it falls back to whether
  the API returned a Fable bucket.
- **Which account is "in use"** is read from `~/.claude-current-acct`, a file containing
  just `a`, `b`, …. It only drives the solid-vs-translucent dot; if the file is absent,
  account `a` is assumed. Write it from whatever you use to switch accounts.
- The tracked scoped model is matched by display name containing "Fable"
  (`UsageStore.parseUsage`). Change that string to track a different model's weekly
  bucket — and the `"Fable"` UI label alongside it.

## Install

```bash
./install.sh
```

Requires Xcode Command Line Tools (`swiftc` compiles from source). No Homebrew, no
runtime dependencies.

The script compiles the binary, installs it to
`~/Library/Application Support/claude-reset/` and registers the LaunchAgent
`io.github.davie521.claude-reset-menubar` (starts at login; `KeepAlive` only relaunches on
a crash). Runtime files deliberately live outside the repo directory: repos tend to sit
under `~/Desktop` or `~/Documents`, which are TCC-protected paths where a launchd
background process can't reliably read and write. State lives in
`~/Library/Application Support/claude-reset/state.json`, logs in `menubar.log` next to it.

The order inside `install.sh` is the interesting part: everything that can fail — making
directories, compiling, writing the plist, moving files into place — happens *before* the
running instance is touched. Any failure leaves you with "the old one is still running,
the new one didn't take effect", never "the old one is unloaded and the new one isn't
installed".

Two legacy paths it still guards:

- The app used to be installed under the label `com.yifan.claude-reset-menubar`. If that
  agent is still registered, `install.sh` boots it out and removes its plist before
  loading the new one — otherwise you'd get two icons, double the requests, and two
  processes rewriting the same `state.json` and erasing each other's backoff windows.
- There was also a private Homebrew tap; it's gone. `install.sh` still refuses to install
  if `homebrew.mxcl.claude-reset-notifier` is registered or its plist is lying around, for
  the same coexistence reasons. Use `./install.sh --force` to install anyway.

## Uninstall

```bash
launchctl bootout gui/$(id -u)/io.github.davie521.claude-reset-menubar
rm ~/Library/LaunchAgents/io.github.davie521.claude-reset-menubar.plist
rm -rf ~/Library/Application\ Support/claude-reset
```

If you ever ran a build from before the rename, clean up the old label too:

```bash
launchctl bootout gui/$(id -u)/com.yifan.claude-reset-menubar 2>/dev/null
rm -f ~/Library/LaunchAgents/com.yifan.claude-reset-menubar.plist
```

Nothing else is left behind — the app writes only inside its own Application Support
directory and never modifies the Keychain.

## Development

```bash
swiftc -O -warnings-as-errors menubar/ClaudeReset.swift -o /tmp/crn -framework Cocoa  # build
bash -n install.sh && shellcheck install.sh                                           # script checks
```

That's exactly what CI (`.github/workflows/ci.yml`) runs on pull requests and on `main`:
compile on a macOS runner, script checks on a Linux runner. `-warnings-as-errors` is
intentional — this file carries its invariants in long comments, and a new warning usually
means someone dislodged something.

A locally installed shellcheck may be more lenient than the runner's (seen with 0.11.0:
green locally, SC2015 in CI). Cross-check against the same image before pushing:

```bash
docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:stable install.sh
```

## Caveats

- **`/api/oauth/usage` is an internal, undocumented endpoint.** It can change shape or go
  away at any time. The parser is built to fail loudly-but-safely when it does (keep the
  cache, show ⚠), and to adapt after 5 consecutive rejections — but a removed endpoint is
  a removed endpoint.
- **It is rate-limited aggressively.** If you fork this and make it poll faster, you will
  get 429s. The default cadence — one request every 30 minutes in total, rotating across
  accounts — is the point.
- Reading the Keychain may raise an authorisation prompt the first time (the app waits up
  to 45 seconds for you to click it). Grant "Always Allow" to avoid repeats.
- macOS only, Apple silicon and Intel alike; no signing or notarisation, since you compile
  it yourself.
- The app never refreshes tokens. When one expires, that row says so — run `claude` to
  refresh, then hit "Refresh now".

## License

[Apache-2.0](LICENSE). You may use, modify and redistribute it, including commercially;
in return the license asks you to keep the copyright and [NOTICE](NOTICE), and to state
prominently in any modified files that you changed them.
