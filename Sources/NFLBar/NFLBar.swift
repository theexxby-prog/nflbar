import SwiftUI
import AppKit
import Combine

// MARK: - App

// Plain AppKit entry point. SwiftUI's MenuBarExtra(.window) drifts away from
// the menu bar on macOS 26 and floats over the desktop, and an App with only a
// Settings scene opens an empty Settings window at launch. The status item and
// popover live in AppDelegate; the list itself is still SwiftUI.
@main
enum NFLBarMain {
    @MainActor static func main() {
        let delegate = AppDelegate()
        let app = NSApplication.shared
        app.delegate = delegate
        app.run() // never returns, so `delegate` stays alive
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = GameStore()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var titleSink: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "football.fill", accessibilityDescription: "NFL")
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover)
        }

        popover.behavior = .transient
        popover.animates = false
        let host = NSHostingController(rootView: GameListView(store: store))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host

        // objectWillChange fires before the new value lands, so read it a tick later.
        titleSink = store.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.updateTitle() }
        }
        updateTitle()
    }

    private func updateTitle() {
        statusItem.button?.title = store.menuBarText.map { " \($0)" } ?? ""
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

// MARK: - Model

struct TeamInfo {
    let name: String
    let abbr: String
    let logo: URL?
    let score: Int
    let record: String
    let color: Color
}

struct Game: Identifiable {
    let id: String
    let kickoff: Date
    let away: TeamInfo
    let home: TeamInfo
    let venue: String
    let cityState: String
    let weather: String?
    let networks: [String]
    let state: String        // pre / in / post
    let detail: String       // "Q3 4:12", "Halftime", "Final"
    let link: URL?

    var isLive: Bool { state == "in" }
    var isFinal: Bool { state == "post" }
    var teams: [TeamInfo] { [away, home] }

    struct Stream { let name: String; let url: String }

    var streams: [Stream] {
        var seen = Set<String>()
        var out: [Stream] = []
        for n in networks {
            let s: Stream
            switch n.uppercased() {
            case "NBC":          s = Stream(name: "Peacock",     url: "https://www.peacocktv.com/sports/nfl")
            case "CBS":          s = Stream(name: "Paramount+",  url: "https://www.paramountplus.com/live-tv/")
            case "FOX":          s = Stream(name: "Fox One",     url: "https://www.fox.com/live/")
            case "ESPN", "ABC":  s = Stream(name: "ESPN app",    url: "https://www.espn.com/watch/")
            case "PRIME VIDEO", "AMAZON", "PRIME":
                                 s = Stream(name: "Prime Video", url: "https://www.amazon.com/tnf")
            case "NFL NETWORK", "NFLN":
                                 s = Stream(name: "NFL+",        url: "https://www.nfl.com/plus/")
            case "NETFLIX":      s = Stream(name: "Netflix",     url: "https://www.netflix.com")
            case "YOUTUBE":      s = Stream(name: "YouTube",     url: "https://www.youtube.com")
            default:             s = Stream(name: n,             url: "https://www.nfl.com/ways-to-watch/")
            }
            if seen.insert(s.name).inserted { out.append(s) }
        }
        return out
    }
}

extension Color {
    init(hex: String?, fallback: Color = .gray) {
        guard let hex = hex, hex.count == 6, let v = UInt32(hex, radix: 16) else { self = fallback; return }
        self = Color(red: Double((v >> 16) & 0xff) / 255,
                     green: Double((v >> 8) & 0xff) / 255,
                     blue: Double(v & 0xff) / 255)
    }
}

// MARK: - ESPN decoding

private struct Scoreboard: Decodable, Sendable { let events: [Event] }
private struct Event: Decodable, Sendable {
    let id: String
    let date: String
    let competitions: [Competition]
    let links: [Link]?
    let weather: Weather?
}
private struct Link: Decodable, Sendable { let href: String }
// ESPN inconsistently swaps weather.displayValue and weather.conditionId: on
// some events displayValue is the numeric condition id and the text sits in
// conditionId. Decode both leniently and take whichever isn't a bare number.
private struct Weather: Decodable, Sendable {
    let displayValue: String?
    let conditionId: String?
    let temperature: Int?

    var conditionText: String {
        for v in [displayValue, conditionId] {
            let t = (v ?? "").trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, t.rangeOfCharacter(from: CharacterSet.decimalDigits.inverted) != nil { return t }
        }
        return ""
    }

    private enum Keys: String, CodingKey { case displayValue, conditionId, temperature }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func loose(_ k: Keys) -> String? {
            (try? c.decode(String.self, forKey: k)) ?? (try? c.decode(Int.self, forKey: k)).map { String($0) }
        }
        displayValue = loose(.displayValue)
        conditionId = loose(.conditionId)
        temperature = try? c.decode(Int.self, forKey: .temperature)
    }
}
private struct Competition: Decodable, Sendable {
    let venue: Venue?
    let broadcasts: [Broadcast]?
    let competitors: [Competitor]?
    let status: Status?
}
private struct Venue: Decodable, Sendable { let fullName: String?; let address: Address?; let indoor: Bool? }
private struct Address: Decodable, Sendable { let city: String?; let state: String? }
private struct Broadcast: Decodable, Sendable { let names: [String] }
private struct Competitor: Decodable, Sendable {
    let homeAway: String
    let score: String?
    let team: Team
    let records: [Record]?
}
private struct Record: Decodable, Sendable { let type: String?; let summary: String? }
private struct Team: Decodable, Sendable {
    let shortDisplayName: String?
    let displayName: String
    let abbreviation: String?
    let logo: String?
    let color: String?
}
private struct Status: Decodable, Sendable { let type: StatusType }
private struct StatusType: Decodable, Sendable { let state: String; let shortDetail: String?; let detail: String? }

// MARK: - Store

@MainActor
final class GameStore: ObservableObject {
    @Published var games: [Game] = []
    @Published var lastUpdated: Date?
    @Published var error: String?
    @Published var favorites: Set<String> {
        didSet { UserDefaults.standard.set(Array(favorites), forKey: "favorites") }
    }
    @Published var hideFinals: Bool {
        didSet { UserDefaults.standard.set(hideFinals, forKey: "hideFinals") }
    }

    private var timer: Timer?

    init() {
        favorites = Set(UserDefaults.standard.stringArray(forKey: "favorites") ?? [])
        hideFinals = UserDefaults.standard.bool(forKey: "hideFinals")
        Task { await refresh() }
    }

    func isFavorite(_ g: Game) -> Bool {
        favorites.contains(g.away.abbr) || favorites.contains(g.home.abbr)
    }

    func toggleFavorite(_ abbr: String) {
        if favorites.contains(abbr) { favorites.remove(abbr) } else { favorites.insert(abbr) }
    }

    var liveGames: [Game] { games.filter { $0.isLive } }

    var nextGame: Game? { games.first { $0.state == "pre" } }

    /// What to print in the menu bar. Favorites win; then any live game; then the next kickoff today.
    var menuBarText: String? {
        let live = liveGames.sorted { isFavorite($0) && !isFavorite($1) }
        if let g = live.first {
            return "\(g.away.abbr) \(g.away.score)–\(g.home.score) \(g.home.abbr) · \(g.detail)"
        }
        let upcoming = games.filter { $0.state == "pre" }.sorted { isFavorite($0) && !isFavorite($1) }
        if let g = upcoming.first, Calendar.current.isDateInToday(g.kickoff) || isFavorite(g) && g.kickoff.timeIntervalSinceNow < 6 * 3600 {
            let f = DateFormatter(); f.dateFormat = "h:mma"
            return "\(g.away.abbr) @ \(g.home.abbr) \(f.string(from: g.kickoff).lowercased().replacingOccurrences(of: "m", with: ""))"
        }
        return nil
    }

    private func schedule() {
        timer?.invalidate()
        let now = Date()
        // ESPN flips a game to "in" when the ball is actually kicked, usually 5-10
        // minutes after the listed time. A game past its listed kickoff that isn't
        // live yet is about to be, so poll at the live rate until it flips.
        let imminent = games.contains { $0.state == "pre" && $0.kickoff <= now && now.timeIntervalSince($0.kickoff) < 45 * 60 }
        var interval: TimeInterval = liveGames.isEmpty && !imminent ? 15 * 60 : 60
        // Wake just after the next listed kickoff so the live-rate polling starts on time.
        if let next = games.first(where: { $0.state == "pre" && $0.kickoff > now }) {
            interval = max(15, min(interval, next.kickoff.timeIntervalSince(now) + 20))
        }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    func refresh() async {
        defer { schedule() }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        fmt.timeZone = TimeZone(identifier: "America/New_York")
        let today = Date()

        // ESPN no longer reliably accepts a date range, so query each day and merge.
        func fetchDay(_ offset: Int) async -> [Event] {
            let d = Calendar.current.date(byAdding: .day, value: offset, to: today)!
            let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/football/nfl/scoreboard?dates=\(fmt.string(from: d))")!
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let board = try? JSONDecoder().decode(Scoreboard.self, from: data) else { return [] }
            return board.events
        }

        do {
            var events: [Event] = []
            await withTaskGroup(of: [Event].self) { group in
                for i in 0...4 { group.addTask { await fetchDay(i) } }
                for await evs in group { events += evs }
            }
            var seen = Set<String>()
            events = events.filter { seen.insert($0.id).inserted }
            if events.isEmpty && games.isEmpty {
                throw NSError(domain: "NFLBar", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't reach ESPN. Check your connection and hit refresh."])
            }
            let board = Scoreboard(events: events)

            let f1 = DateFormatter(); f1.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
            let f2 = DateFormatter(); f2.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
            for f in [f1, f2] { f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX") }
            func parse(_ s: String) -> Date? { f1.date(from: s) ?? f2.date(from: s) }

            func info(_ c: Competitor?) -> TeamInfo {
                TeamInfo(
                    name: c?.team.shortDisplayName ?? c?.team.displayName ?? "?",
                    abbr: c?.team.abbreviation ?? "",
                    logo: c?.team.logo.flatMap { URL(string: $0) },
                    score: Int(c?.score ?? "") ?? 0,
                    record: c?.records?.first { $0.type == "total" }?.summary ?? "",
                    color: Color(hex: c?.team.color)
                )
            }

            let startOfToday = Calendar.current.startOfDay(for: today)
            games = board.events.compactMap { ev -> Game? in
                guard let comp = ev.competitions.first,
                      let kickoff = parse(ev.date),
                      kickoff >= startOfToday else { return nil }

                let city = [comp.venue?.address?.city, comp.venue?.address?.state]
                    .compactMap { $0 }.joined(separator: ", ")

                var weather: String? = nil
                if comp.venue?.indoor != true, let w = ev.weather, let t = w.temperature {
                    weather = "\(t)° \(w.conditionText)".trimmingCharacters(in: .whitespaces)
                }

                let state = comp.status?.type.state ?? "pre"
                let rawDetail = comp.status?.type.shortDetail ?? ""
                // ESPN's own label for finished games: "Final", "Final/OT", "Postponed", "Canceled".
                let detail = state == "post" && rawDetail.isEmpty ? "Final" : rawDetail

                return Game(
                    id: ev.id,
                    kickoff: kickoff,
                    away: info(comp.competitors?.first { $0.homeAway == "away" }),
                    home: info(comp.competitors?.first { $0.homeAway == "home" }),
                    venue: comp.venue?.fullName ?? "TBD",
                    cityState: city,
                    weather: weather,
                    networks: comp.broadcasts?.flatMap { $0.names } ?? [],
                    state: state,
                    detail: detail,
                    link: ev.links?.first.flatMap { URL(string: $0.href) }
                )
            }
            .sorted { $0.kickoff < $1.kickoff }
            lastUpdated = Date()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - List

struct GameListView: View {
    @ObservedObject var store: GameStore

    private struct Slot: Identifiable { let id: Date; let games: [Game] }
    private struct Day: Identifiable { let id: Date; let slots: [Slot] }

    private var visibleGames: [Game] {
        store.games.filter { !($0.isFinal && store.hideFinals) && !$0.isLive }
    }

    private var days: [Day] {
        let cal = Calendar.current
        let byDay = Dictionary(grouping: visibleGames) { cal.startOfDay(for: $0.kickoff) }
        return byDay.keys.sorted().map { d in
            let bySlot = Dictionary(grouping: byDay[d]!) { $0.kickoff }
            return Day(id: d, slots: bySlot.keys.sorted().map { Slot(id: $0, games: bySlot[$0]!) })
        }
    }

    private var popoverHeight: CGFloat {
        let ds = days
        let slots = ds.reduce(0) { $0 + $1.slots.count }
        let live = store.liveGames.count
        let rows = CGFloat(visibleGames.count + live) * 66
            + CGFloat(ds.count + (live > 0 ? 1 : 0)) * 34
            + CGFloat(slots) * 26 + 110
        return min(660, max(160, rows))
    }

    private var countdown: String? {
        guard store.liveGames.isEmpty, let g = store.nextGame else { return nil }
        let secs = Int(g.kickoff.timeIntervalSinceNow)
        guard secs > 0 else { return nil }
        let h = secs / 3600, m = (secs % 3600) / 60
        let when = h >= 24 ? "in \(h / 24)d \(h % 24)h" : h > 0 ? "in \(h)h \(m)m" : "in \(m)m"
        return "Next: \(g.away.name) @ \(g.home.name) \(when)"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("NFL").font(.system(size: 14, weight: .bold))
                Text(countdown ?? "next 5 days").font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                Spacer()
                Button { Task { await store.refresh() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundColor(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            Divider()

            if let err = store.error, store.games.isEmpty {
                Text(err).foregroundColor(.red).font(.caption).padding(14)
                Spacer()
            } else if store.games.isEmpty {
                Text("No games in the next 5 days.").foregroundColor(.secondary).padding(14)
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        if !store.liveGames.isEmpty {
                            HStack(spacing: 6) {
                                PulsingDot()
                                Text("LIVE NOW").font(.system(size: 11, weight: .bold)).foregroundColor(.red)
                            }
                            .padding(.top, 12).padding(.bottom, 4).padding(.horizontal, 14)
                            ForEach(store.liveGames) { g in
                                GameRow(game: g, store: store)
                                    .padding(.horizontal, 10).padding(.vertical, 3)
                            }
                        }
                        ForEach(days) { day in
                            Text(dayLabel(day.id))
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.secondary)
                                .padding(.top, 12).padding(.bottom, 4).padding(.horizontal, 14)
                            ForEach(day.slots) { slot in
                                Text(slot.id, style: .time)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.orange)
                                    .padding(.top, 6).padding(.bottom, 2).padding(.horizontal, 14)
                                ForEach(slot.games) { g in
                                    GameRow(game: g, store: store)
                                        .padding(.horizontal, 10).padding(.vertical, 3)
                                }
                            }
                        }
                        Spacer(minLength: 8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            HStack(spacing: 10) {
                Toggle("Hide finals", isOn: $store.hideFinals)
                    .toggleStyle(.checkbox).font(.system(size: 10)).foregroundColor(.secondary)
                Text("Right-click a game to star a team")
                    .font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                Spacer()
                if let t = store.lastUpdated {
                    Text(t, style: .time).font(.system(size: 10)).foregroundColor(.secondary)
                }
                Button("Quit") { NSApp.terminate(nil) }
                    .font(.system(size: 10)).buttonStyle(.plain).foregroundColor(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .frame(width: 370, height: popoverHeight)
        .onAppear { Task { await store.refresh() } }
    }

    private func dayLabel(_ d: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"
        let dateStr = f.string(from: d).uppercased()
        if cal.isDateInToday(d) { return "TODAY  ·  \(dateStr)" }
        if cal.isDateInTomorrow(d) { return "TOMORROW  ·  \(dateStr)" }
        return dateStr
    }
}

// MARK: - Row

struct GameRow: View {
    let game: Game
    @ObservedObject var store: GameStore

    private var fav: Bool { store.isFavorite(game) }
    private var awayWon: Bool { game.isFinal && game.away.score > game.home.score }
    private var homeWon: Bool { game.isFinal && game.home.score > game.away.score }

    var body: some View {
        HStack(spacing: 0) {
            // team color stripe
            LinearGradient(colors: [game.away.color, game.home.color], startPoint: .top, endPoint: .bottom)
                .frame(width: 3)
                .clipShape(Capsule())
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    TeamChip(team: game.away, emphasized: !game.isFinal || awayWon)
                    Text("@").font(.system(size: 11)).foregroundColor(.secondary)
                    TeamChip(team: game.home, emphasized: !game.isFinal || homeWon)
                    Spacer(minLength: 4)
                    statusView
                }
                HStack(spacing: 4) {
                    Text("\(game.venue) · \(game.cityState)")
                        .font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                    if let w = game.weather, !game.isFinal {
                        Text("·").foregroundColor(.secondary)
                        Text(w).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                HStack(spacing: 5) {
                    ForEach(game.networks, id: \.self) { n in Pill(text: n, tint: .secondary) }
                    ForEach(game.streams, id: \.name) { s in
                        Button { NSWorkspace.shared.open(URL(string: s.url)!) } label: {
                            Pill(text: s.name, tint: .accentColor)
                        }
                        .buttonStyle(.plain).help("Open \(s.name)")
                    }
                    if fav {
                        Spacer()
                        Image(systemName: "star.fill").font(.system(size: 9)).foregroundColor(.yellow)
                    }
                }
            }
            .padding(.leading, 8)
        }
        .padding(.horizontal, 6).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(fav ? Color.yellow.opacity(0.10) : Color.clear)
        )
        .opacity(game.isFinal ? 0.6 : 1)
        .contentShape(Rectangle())
        .onTapGesture { if let l = game.link { NSWorkspace.shared.open(l) } }
        .help("Open on ESPN")
        .contextMenu {
            ForEach(game.teams, id: \.abbr) { t in
                Button(store.favorites.contains(t.abbr) ? "Unstar \(t.name)" : "Star \(t.name)") {
                    store.toggleFavorite(t.abbr)
                }
            }
            Divider()
            if let l = game.link { Button("Open on ESPN") { NSWorkspace.shared.open(l) } }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        if game.isLive {
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(game.away.score)–\(game.home.score)")
                    .font(.system(size: 13, weight: .bold)).foregroundColor(.red)
                Text(game.detail).font(.system(size: 10)).foregroundColor(.secondary)
            }
        } else if game.isFinal {
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(game.away.score)–\(game.home.score)").font(.system(size: 13, weight: .semibold))
                Text(game.detail).font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
    }
}

struct TeamChip: View {
    let team: TeamInfo
    var emphasized = true
    var body: some View {
        HStack(spacing: 4) {
            AsyncImage(url: team.logo) { img in
                img.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                Circle().fill(Color.secondary.opacity(0.2))
            }
            .frame(width: 20, height: 20)
            Text(team.name)
                .font(.system(size: 13, weight: emphasized ? .semibold : .regular))
                .foregroundColor(emphasized ? .primary : .secondary)
                .lineLimit(1)
            if !team.record.isEmpty {
                Text(team.record).font(.system(size: 9)).foregroundColor(.secondary)
            }
        }
    }
}

struct Pill: View {
    let text: String
    let tint: Color
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tint.opacity(0.15))
            .foregroundColor(tint == .secondary ? .primary : tint)
            .clipShape(Capsule())
    }
}

final class Pulse: ObservableObject {
    @Published var on = false
}

struct PulsingDot: View {
    @StateObject private var pulse = Pulse()
    var body: some View {
        Circle().fill(Color.red).frame(width: 7, height: 7)
            .opacity(pulse.on ? 1 : 0.3)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse.on)
            .onAppear { pulse.on = true }
    }
}
