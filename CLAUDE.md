# nflbar

NFLBar is a macOS menu-bar app written in Swift. It shows NFL games for today and the
next four days, with networks, streaming links, scores and weather. All the code is in
`Sources/NFLBar/NFLBar.swift`.

| | |
|---|---|
| Live | Mac only: /Applications/NFLBar.app, plus zips on GitHub Releases |
| GitHub | theexxby-prog/nflbar (public) |
| Mac folder | ~/dev/nflbar |
| Deploys by | `./build_release.command <version>` on the Mac (builds, signs, notarizes, staples, zips to `dist/`). Then copy `dist/NFLBar.app` to /Applications and attach `dist/NFLBar-<version>.zip` to a GitHub release tagged `v<version>` |
| Cloudflare | n/a |
| Read also | README.md |

## Rules
- Always pass the version: `./build_release.command 1.2.1`. With no argument the script
  stamps the app as 1.0.0.
- Signing and notarizing need the Mac's Developer ID certificate and notary keychain
  profile. Cloud sessions can't build, sign or release the app. A Swift change made in
  the cloud goes under "Not deployed yet" so a Mac session builds and releases it.
- The iPhone version is a separate private repo, `nfl-codebase-fyi` (a PWA at
  nfl.codebase.fyi). The two share no code. Any change to the game list, the streaming
  map or ESPN parsing has to be made in both.
- Since 1.2.0 the menu-bar item is plain AppKit: an `NSStatusItem` and an `NSPopover`
  hosting the SwiftUI list, started by `NSApplication.run()`. SwiftUI
  `MenuBarExtra(.window)` floated away from the menu bar on macOS 26, and an App with
  only a Settings scene opened an empty Settings window at launch. Don't switch back.
- ESPN sometimes swaps `weather.displayValue` and `conditionId`. The code takes
  whichever field isn't a bare number. Keep that when touching weather.
- Polling: 15 minutes when idle, 60 seconds while a game is live. ESPN flips a game to
  live only when the ball is kicked, so the app wakes just after the listed kickoff and
  polls at the live rate for up to 45 minutes until it flips. The PWA does the same.
- The repo is public. No personal data, no secrets.
- **Look since 1.3.0: "Broadcast"** (picked by Vishal 2026-10-02 from Fable's three directions). Each game
  is a TV-style scorebug card: away over home, a 44pt team-colour block with the abbreviation (alternate
  colour if it has 3:1 contrast, else white/black), logo, name, record and score in fixed columns.
  Live cards add a drive strip (field bar filled from the offence's goal line to the ball, parsed from
  `situation.possessionText` "LV 32"; red-zone tint; down and distance; "Q3 4:12" from period +
  displayClock) and a win-probability line along the bottom edge. **Every live and upcoming card has a
  permanent watch row: TV network(s) plus streaming button(s) that open the service** (Vishal: "I need
  to see where it is streaming"). Max 3 slots; streams are kept first when they don't all fit, the rest
  go behind "+N". Upcoming cards show kickoff time, weather as an SF Symbol + temperature (mapped from
  the condition *text*, so the swapped-fields fix still applies) or "Indoors", and odds. Finals dim, the
  loser greys out, and the strip shows the line score. Starred teams: yellow ring on the block, yellow
  card border, sorted first. Header: week, live count or countdown, a filter menu (Hide finals, Quit),
  refresh (spins while loading).
- **Menu bar since 1.3.1: icon only.** Vishal: menu-bar space is premium. The status item is a small
  brown leather football drawn in code (`AppDelegate.footballIcon()`, a coloured non-template 18pt
  vector image, so it's brown in light and dark bars). No title text by default. The filter menu has
  **"Show live score in menu bar"** (UserDefaults `showLiveScore`, default off): when on, the compact
  score ("KC 21–17 LV", monospaced digits) shows next to the ball only while a game is live, starred
  games first and taking turns every 8 s when 2+ starred games are live. No countdown or kickoff text
  in the bar any more (the countdown lives in the popover header).
- **Fetching since 1.3.0:** own ephemeral URLSession (10 s request / 20 s resource timeout), one retry
  with jitter per day. A failed day keeps the games it showed last time; if all five fail, the list
  stays and the footer says "Couldn't reach ESPN · showing <time>" (empty list: a full message).
- New ESPN fields are all optional and decoded with `try?` (Competition has a lenient init): team id,
  alternateColor, linescores, winner, status period/displayClock, situation, odds, week.

## Session handoff (every session, on any device)

Vishal works on this repo from the Mac terminal, the Claude desktop and phone apps, and
cloud sessions at claude.ai/code. A cloud session sees only this repo, not the Mac's
`~/.claude` files or memory. So anything the next session needs goes in this file, and
`main` on GitHub is the single source of truth.

**Start**
1. The SessionStart hook (`.claude/hooks/session-start.sh`) prints a sync report. If it
   says this copy is behind, run `git pull --ff-only` before touching anything. If it
   lists another branch or an open PR, tell Vishal and ask whether to merge it first.
2. Read **Current state** at the bottom of this file.

**Finish** (every session that changed anything, before saying you're done)
1. Rewrite **Current state**: the date, where you worked (Mac, cloud or phone), what
   changed, what is live, what isn't deployed or tested yet, and what's next. Keep it
   short and current, not a diary. Lasting rules and lessons go in the sections above it.
2. Get the work onto `main`:
   - Mac: commit and `git push origin main`.
   - Cloud: you can push only your own `claude/...` branch. Push it, then
     `gh pr create --fill` and `gh pr merge --squash --delete-branch`, unless Vishal
     asked to review first.
3. If it needs a deploy you couldn't run (cloud sessions can't reach Cloudflare), list
   it under "Not deployed yet" so the next Mac session ships it.

## Current state
_Updated 2026-10-10 from the Mac (overnight motion pass)._
- **Live: 1.3.2** at /Applications/NFLBar.app (signed, notarized, stapled, Gatekeeper OK, relaunched) and
  GitHub release v1.3.2. 1.3.1 backed up in the session scratchpad only.
- 1.3.2: scores roll like an odometer (`ScoreRoll` modifier: `.numericText(value:)` on macOS 14+, so digits
  roll up when a score rises; plain `.numericText()` on 13; a 0.45 s spring). Reduce Motion turns the roll
  into a plain swap and stops the live dot pulsing. ESPN game links and logo URLs now go through
  `webURL()` (http/https only), so a feed glitch can't make a click open a file or another app's scheme.
- Not done: the menu-bar title (the optional live score) is AppKit text, so it still swaps without a roll.
  The roll itself was checked by build only, not watched in a live game (first chance: Sunday).
- Open / next: watch a live Sunday (roll, `possessionText`, win probability). The PWA got the same roll
  in the same pass (nfl-codebase-fyi).
