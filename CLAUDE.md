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
_Updated 2026-09-24 from the Mac (housekeeping session: added this handoff setup)._
- **Live:** 1.2.0, installed at /Applications/NFLBar.app and published as the latest
  GitHub release (v1.2.0, 2026-09-21).
- **Not deployed yet:** nothing.
- **Open / next:**
  - `nfl-codebase-fyi` has an open PR #2 (2026-09 review, 22 fixes). Two of them match
    problems in this app's ESPN fetch:
    1. `fetchDay` turns any network or decode error into an empty day. Days that fail
       drop out silently. If all five fail while games are already on screen, the list
       is replaced with nothing and no error shows. The error only appears when the
       list was already empty.
    2. There is no timeout or retry on the ESPN requests. `URLSession.shared` waits up
       to 60 seconds.
    The PR's DST, star, day-label and kickoff-recheck fixes don't apply here: this app
    uses `Calendar` day arithmetic, one star per team, and already rechecks at kickoff.
  - README is stale: it links a `screenshot.png` that isn't in the repo, the clone URL
    says `YOUR-USER`, and it says the app polls every 15 minutes (it polls every 60
    seconds while a game is live).
  - The comment at the top of `build_release.command` still gives the old
    `~/Projects/NFLBar` path.
