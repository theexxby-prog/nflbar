# NFLBar

A tiny macOS menu bar app that shows NFL games for today and the next four days: who's playing, where, what network it's on, and where to stream it. Click a streaming pill to open the service.

![screenshot](screenshot.png)

## Install

1. Download `NFLBar-x.y.z.zip` from the [latest release](../../releases/latest).
2. Unzip and drag `NFLBar.app` to `/Applications`.
3. Open it. A football icon appears in the menu bar. There's no Dock icon.
4. Optional: System Settings > General > Login Items > add NFLBar to launch at login.

Requires macOS 13 or later. Signed and notarized, so it opens without Gatekeeper warnings.

## Build from source

```bash
git clone https://github.com/YOUR-USER/nflbar.git
cd nflbar
swift build -c release
.build/release/NFLBar
```

Needs Xcode Command Line Tools (`xcode-select --install`).

## How it works

Schedule, venue, broadcast and score data come from ESPN's public scoreboard endpoint. The app polls every 15 minutes and on each open. Streaming links are a static map from network to service (NBC to Peacock, CBS to Paramount+, FOX to Fox One, ESPN/ABC to the ESPN app, Prime Video, NFL Network to NFL+, Netflix, YouTube).

## Caveats

- ESPN's API is unofficial and could change without notice.
- Streaming availability varies by market and package. The Sunday Ticket note covers out-of-market games.
- Not affiliated with the NFL, ESPN, or any broadcaster.

## License

MIT
