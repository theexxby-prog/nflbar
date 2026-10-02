# NFLBar

A small macOS menu bar app that shows NFL games for today and the next four days as TV-style scorebugs: team colours and logos, records, scores, the drive (who has the ball, down and distance, red zone), win probability, odds, weather, and on every card the TV network and where to stream it. Click a streaming button to open the service.

The menu bar shows just a small brown football. If you want the score up there too, turn on **Show live score in menu bar** in the popover's filter menu: while a game is live it shows the score next to the ball (`KC 21–17 LV`), starred teams first. Right-click a game to star a team.

## Install

1. Download `NFLBar-x.y.z.zip` from the [latest release](../../releases/latest).
2. Unzip and drag `NFLBar.app` to `/Applications`.
3. Open it. A brown football appears in the menu bar. There's no Dock icon.
4. Optional: System Settings > General > Login Items > add NFLBar to launch at login.

Requires macOS 13 or later. Signed and notarized, so it opens without Gatekeeper warnings.

## Build from source

```bash
git clone https://github.com/theexxby-prog/nflbar.git
cd nflbar
swift build -c release
.build/release/NFLBar
```

Needs Xcode Command Line Tools (`xcode-select --install`).

## How it works

Schedule, venue, broadcast, odds and score data come from ESPN's public scoreboard endpoint. The app polls every 15 minutes when nothing is on, every 60 seconds while a game is live (and for 45 minutes after a listed kickoff, until ESPN flips it to live), and on each open. Requests time out after 10 seconds and retry once; a day that fails keeps what it showed last time. Streaming links are a static map from network to service (NBC to Peacock, CBS to Paramount+, FOX to Fox One, ESPN/ABC to the ESPN app, Prime Video, NFL Network to NFL+, Netflix, YouTube).

## Caveats

- ESPN's API is unofficial and could change without notice.
- Streaming availability varies by market and package. The Sunday Ticket note covers out-of-market games.
- Not affiliated with the NFL, ESPN, or any broadcaster.

## License

MIT
