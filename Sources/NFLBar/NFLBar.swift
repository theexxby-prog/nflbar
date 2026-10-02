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
    private var rotateTimer: Timer?
    private var rotateIndex = 0

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
        // With two or more starred live games the title takes turns, 8 s each.
        rotateTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.rotateIndex += 1
                self.updateTitle()
            }
        }
        updateTitle()
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        guard let title = store.menuBarTitle(rotation: rotateIndex) else {
            button.attributedTitle = NSAttributedString(string: "")
            return
        }
        // Monospaced digits so a ticking clock doesn't make the item jitter.
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        let out = NSMutableAttributedString(string: " ", attributes: [.font: font])
        for (i, part) in title.parts.enumerated() {
            if i == title.possessionIndex, let ball = NSImage(systemSymbolName: "football.fill", accessibilityDescription: "Has the ball") {
                let a = NSTextAttachment()
                a.image = ball.withSymbolConfiguration(.init(pointSize: 8, weight: .regular))
                a.bounds = CGRect(x: 0, y: 1, width: 9, height: 6)
                out.append(NSAttributedString(attachment: a))
                out.append(NSAttributedString(string: " ", attributes: [.font: font]))
            }
            out.append(NSAttributedString(string: part, attributes: [.font: font]))
        }
        button.attributedTitle = out
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
    let id: String
    let name: String
    let abbr: String
    let logo: URL?
    let score: Int
    let record: String
    let colorHex: String?
    let altColorHex: String?
    let linescores: [String]
    let winner: Bool

    var color: Color { Color(hex: colorHex) }

    /// Text on the team's colour block: the alternate colour when it reads (3:1), else white or black.
    var blockText: Color {
        guard let bg = RGB(hex: colorHex) else { return .white }
        if let alt = RGB(hex: altColorHex), bg.contrast(with: alt) >= 3 { return alt.color }
        return bg.contrast(with: RGB.white) >= bg.contrast(with: RGB.black) ? .white : .black
    }
}

struct Situation {
    let downDistance: String?     // "3rd & 7 at LV 32"
    let shortDownDistance: String?
    let possessionText: String?   // "LV 32"
    let possessionTeamId: String?
    let isRedZone: Bool
    let homeWinPct: Double?       // 0...1
}

struct Game: Identifiable {
    let id: String
    let kickoff: Date
    let away: TeamInfo
    let home: TeamInfo
    let venue: String
    let cityState: String
    let indoor: Bool
    let weatherText: String?
    let temperature: Int?
    let networks: [String]
    let state: String        // pre / in / post
    let detail: String       // ESPN's short detail: "4:12 - 3rd", "Halftime", "Final/OT"
    let period: Int?
    let clock: String?
    let situation: Situation?
    let odds: String?        // "KC -4.5"
    let overUnder: Double?
    let link: URL?

    var isLive: Bool { state == "in" }
    var isFinal: Bool { state == "post" }
    var teams: [TeamInfo] { [away, home] }

    /// "Q3 4:12", "OT 2:01", otherwise ESPN's own label (Halftime, End of 2nd, Final/OT).
    var clockLabel: String {
        if isLive, let p = period, let c = clock, !detail.localizedCaseInsensitiveContains("half"),
           !detail.localizedCaseInsensitiveContains("end") {
            return p <= 4 ? "Q\(p) \(c)" : "OT \(c)"
        }
        return detail
    }

    var possession: TeamInfo? {
        guard let id = situation?.possessionTeamId else { return nil }
        return teams.first { $0.id == id }
    }

    /// How far the team with the ball has come towards the end zone, 0...1, from "LV 32" / "50".
    var fieldProgress: Double? {
        guard let team = possession, let text = situation?.possessionText ?? situation?.downDistance.flatMap({ $0.components(separatedBy: " at ").last }) else { return nil }
        let bits = text.split(separator: " ")
        guard let yard = bits.last.flatMap({ Int($0) }) else { return nil }
        if bits.count == 1 { return Double(yard) / 100 } // midfield: "50"
        let side = String(bits.first!)
        return Double(side == team.abbr ? yard : 100 - yard) / 100
    }

    var weatherSymbol: String? {
        if indoor { return nil }
        let t = (weatherText ?? "").lowercased()
        if t.contains("thunder") || t.contains("storm") { return "cloud.bolt.rain" }
        if t.contains("snow") || t.contains("flurr") || t.contains("sleet") || t.contains("ice") { return "snowflake" }
        if t.contains("rain") || t.contains("shower") || t.contains("drizzle") { return "cloud.rain" }
        if t.contains("fog") || t.contains("haze") || t.contains("mist") { return "cloud.fog" }
        if t.contains("wind") { return "wind" }
        if t.contains("partly") || t.contains("mostly sunny") || t.contains("intermittent") { return "cloud.sun" }
        if t.contains("cloud") || t.contains("overcast") { return "cloud" }
        if t.contains("sun") || t.contains("clear") || t.contains("fair") { return "sun.max" }
        return temperature == nil ? nil : "thermometer.medium"
    }

    var oddsLine: String? {
        let parts = [odds, overUnder.map { "O/U \(String(format: $0.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.1f", $0))" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

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
            case "NFL NETWORK", "NFLN", "NFL NET":
                                 s = Stream(name: "NFL+",        url: "https://www.nfl.com/plus/")
            case "NETFLIX":      s = Stream(name: "Netflix",     url: "https://www.netflix.com")
            case "YOUTUBE":      s = Stream(name: "YouTube",     url: "https://www.youtube.com")
            default:             s = Stream(name: n,             url: "https://www.nfl.com/ways-to-watch/")
            }
            if seen.insert(s.name).inserted { out.append(s) }
        }
        return out
    }

    /// The card's "where to watch" row: TV networks, then where to stream them.
    /// At most three slots; streams are kept first when they don't all fit, and the
    /// rest go behind a "+N" menu so the row never wraps.
    var watchSlots: (shown: [WatchSlot], extra: [WatchSlot]) {
        let streamSlots = streams.map { WatchSlot(name: $0.name, url: URL(string: $0.url), isStream: true) }
        let tvSlots = networks
            .filter { n in !streamSlots.contains { $0.name == n } } // an unmapped network is already its own link
            .map { WatchSlot(name: $0, url: nil, isStream: false) }
        let all = tvSlots + streamSlots
        if all.count <= 3 { return (all, []) }
        let keepStreams = Array(streamSlots.prefix(2))
        let keepTV = Array(tvSlots.prefix(3 - keepStreams.count))
        let shown = keepTV + keepStreams
        return (shown, all.filter { s in !shown.contains { $0.name == s.name } })
    }
}

struct WatchSlot: Hashable {
    let name: String
    let url: URL?
    let isStream: Bool
}

struct RGB {
    let r: Double, g: Double, b: Double
    static let white = RGB(r: 1, g: 1, b: 1)
    static let black = RGB(r: 0, g: 0, b: 0)

    init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }
    init?(hex: String?) {
        guard let hex = hex, hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        r = Double((v >> 16) & 0xff) / 255; g = Double((v >> 8) & 0xff) / 255; b = Double(v & 0xff) / 255
    }
    var color: Color { Color(red: r, green: g, blue: b) }
    var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }
    func contrast(with o: RGB) -> Double {
        let a = luminance, b = o.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

extension Color {
    init(hex: String?, fallback: Color = .gray) {
        guard let c = RGB(hex: hex) else { self = fallback; return }
        self = c.color
    }
}

// MARK: - ESPN decoding

private struct Scoreboard: Decodable, Sendable {
    let events: [Event]
    let week: Week?
}
private struct Week: Decodable, Sendable { let number: Int? }
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
    let situation: ESPNSituation?
    let odds: [Odds]?

    private enum Keys: String, CodingKey { case venue, broadcasts, competitors, status, situation, odds }
    // Everything past the basics is optional and decoded leniently: one odd field must never cost a whole day.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        venue = try? c.decode(Venue.self, forKey: .venue)
        broadcasts = try? c.decode([Broadcast].self, forKey: .broadcasts)
        competitors = try? c.decode([Competitor].self, forKey: .competitors)
        status = try? c.decode(Status.self, forKey: .status)
        situation = try? c.decode(ESPNSituation.self, forKey: .situation)
        odds = try? c.decode([Odds].self, forKey: .odds)
    }
}
private struct Venue: Decodable, Sendable { let fullName: String?; let address: Address?; let indoor: Bool? }
private struct Address: Decodable, Sendable { let city: String?; let state: String? }
private struct Broadcast: Decodable, Sendable { let names: [String] }
private struct Competitor: Decodable, Sendable {
    let homeAway: String
    let score: String?
    let team: Team
    let records: [Record]?
    let linescores: [Linescore]?
    let winner: Bool?
}
private struct Linescore: Decodable, Sendable { let value: Double?; let displayValue: String? }
private struct Record: Decodable, Sendable { let type: String?; let summary: String? }
private struct Team: Decodable, Sendable {
    let id: String?
    let shortDisplayName: String?
    let displayName: String
    let abbreviation: String?
    let logo: String?
    let color: String?
    let alternateColor: String?
}
private struct Status: Decodable, Sendable {
    let type: StatusType
    let period: Int?
    let displayClock: String?
}
private struct StatusType: Decodable, Sendable { let state: String; let shortDetail: String?; let detail: String? }
private struct ESPNSituation: Decodable, Sendable {
    let downDistanceText: String?
    let shortDownDistanceText: String?
    let possessionText: String?
    let possession: String?
    let isRedZone: Bool?
    let lastPlay: LastPlay?
}
private struct LastPlay: Decodable, Sendable { let probability: Probability? }
private struct Probability: Decodable, Sendable { let homeWinPercentage: Double? }
private struct Odds: Decodable, Sendable { let details: String?; let overUnder: Double? }

// MARK: - Store

@MainActor
final class GameStore: ObservableObject {
    @Published var games: [Game] = []
    @Published var week: Int?
    @Published var lastUpdated: Date?
    @Published var error: String?
    @Published var loading = false
    @Published var favorites: Set<String> {
        didSet { UserDefaults.standard.set(Array(favorites), forKey: "favorites") }
    }
    @Published var hideFinals: Bool {
        didSet { UserDefaults.standard.set(hideFinals, forKey: "hideFinals") }
    }

    private var timer: Timer?

    // ESPN can hang; don't wait the default 60 s for it.
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.timeoutIntervalForResource = 20
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

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

    /// Starred games first, then by kickoff.
    func ordered(_ gs: [Game]) -> [Game] {
        gs.sorted { a, b in
            let fa = isFavorite(a), fb = isFavorite(b)
            return fa != fb ? fa : a.kickoff < b.kickoff
        }
    }

    var liveGames: [Game] { ordered(games.filter { $0.isLive }) }

    var nextGame: Game? { ordered(games.filter { $0.state == "pre" && $0.kickoff > Date() }).first }

    struct MenuTitle { let parts: [String]; let possessionIndex: Int? }

    /// What to print in the menu bar. A live game (starred first, taking turns when
    /// several starred games are live), else today's kickoff, else nothing (just the glyph).
    func menuBarTitle(rotation: Int) -> MenuTitle? {
        let live = liveGames
        if !live.isEmpty {
            let starred = live.filter(isFavorite)
            let pool = starred.count >= 2 ? starred : [live[0]]
            let g = pool[rotation % pool.count]
            let ball = g.possession?.id
            let parts = ["\(g.away.abbr) \(g.away.score)–\(g.home.score) \(g.home.abbr) · \(g.clockLabel)"]
            // Put the football glyph in front of the team with the ball.
            if ball == g.away.id { return MenuTitle(parts: parts, possessionIndex: 0) }
            if ball == g.home.id {
                return MenuTitle(parts: ["\(g.away.abbr) \(g.away.score)–\(g.home.score) ", "\(g.home.abbr) · \(g.clockLabel)"], possessionIndex: 1)
            }
            return MenuTitle(parts: parts, possessionIndex: nil)
        }
        let upcoming = ordered(games.filter { $0.state == "pre" })
        if let g = upcoming.first, Calendar.current.isDateInToday(g.kickoff) || isFavorite(g) && g.kickoff.timeIntervalSinceNow < 6 * 3600 {
            return MenuTitle(parts: ["\(g.away.abbr) @ \(g.home.abbr) \(Self.shortTime(g.kickoff))"], possessionIndex: nil)
        }
        return nil
    }

    static func shortTime(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mma"
        return f.string(from: d).lowercased().replacingOccurrences(of: "m", with: "")
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
        if loading { return }
        loading = true
        defer { loading = false; schedule() }
        // ESPN's schedule days are US Eastern days, so the day windows are too.
        let et: Calendar = {
            var c = Calendar(identifier: .gregorian)
            c.timeZone = TimeZone(identifier: "America/New_York")!
            return c
        }()
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        fmt.timeZone = et.timeZone
        let today = Date()
        let session = Self.session

        // ESPN no longer reliably accepts a date range, so query each day and merge.
        // nil means the day failed (after one retry), which is not the same as a day with no games.
        @Sendable func fetchDay(_ offset: Int) async -> (Int, Scoreboard?) {
            let d = et.date(byAdding: .day, value: offset, to: today)!
            let url = URL(string: "https://site.api.espn.com/apis/site/v2/sports/football/nfl/scoreboard?dates=\(fmt.string(from: d))")!
            for attempt in 0..<2 {
                if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64.random(in: 300_000_000...1_000_000_000)) }
                if let (data, resp) = try? await session.data(from: url),
                   (resp as? HTTPURLResponse)?.statusCode == 200,
                   let board = try? JSONDecoder().decode(Scoreboard.self, from: data) {
                    return (offset, board)
                }
            }
            return (offset, nil)
        }

        var boards: [Int: Scoreboard] = [:]
        await withTaskGroup(of: (Int, Scoreboard?).self) { group in
            for i in 0...4 { group.addTask { await fetchDay(i) } }
            for await (i, b) in group { if let b { boards[i] = b } }
        }

        let failed = (0...4).filter { boards[$0] == nil }
        if failed.count == 5 {
            // ESPN is unreachable: keep what's on screen and say so, rather than emptying the list.
            error = games.isEmpty ? "Couldn't reach ESPN.\nCheck your connection, then refresh." : "Couldn't reach ESPN"
            return
        }

        var events: [Event] = []
        var seen = Set<String>()
        for i in 0...4 { for ev in boards[i]?.events ?? [] where seen.insert(ev.id).inserted { events.append(ev) } }
        // The week of the first day that has games (an empty day reports last week's number).
        if let w = (0...4).first(where: { !(boards[$0]?.events.isEmpty ?? true) }).flatMap({ boards[$0]?.week?.number }) { week = w }

        let startOfToday = Calendar.current.startOfDay(for: today)
        var fresh = events.compactMap { Self.game(from: $0, notBefore: startOfToday) }
        // A day that failed keeps the games it had last time instead of dropping out silently.
        if !failed.isEmpty {
            let start = et.startOfDay(for: today)
            let windows = failed.map { i -> DateInterval in
                let s = et.date(byAdding: .day, value: i, to: start)!
                return DateInterval(start: s, end: et.date(byAdding: .day, value: 1, to: s)!)
            }
            let ids = Set(fresh.map(\.id))
            fresh += games.filter { g in !ids.contains(g.id) && windows.contains { $0.contains(g.kickoff) } }
        }
        games = fresh.sorted { $0.kickoff < $1.kickoff }
        lastUpdated = Date()
        error = failed.isEmpty ? nil : "Some days didn't load"
    }

    private static let isoMinutes: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
        f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    private static let isoSeconds: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    private static func game(from ev: Event, notBefore: Date) -> Game? {
        guard let comp = ev.competitions.first,
              let kickoff = isoMinutes.date(from: ev.date) ?? isoSeconds.date(from: ev.date),
              kickoff >= notBefore else { return nil }

        func info(_ c: Competitor?) -> TeamInfo {
            TeamInfo(
                id: c?.team.id ?? "",
                name: c?.team.shortDisplayName ?? c?.team.displayName ?? "?",
                abbr: c?.team.abbreviation ?? "",
                logo: c?.team.logo.flatMap { URL(string: $0) },
                score: Int(c?.score ?? "") ?? 0,
                record: c?.records?.first { $0.type == "total" }?.summary ?? "",
                colorHex: c?.team.color,
                altColorHex: c?.team.alternateColor,
                linescores: (c?.linescores ?? []).map { $0.displayValue ?? $0.value.map { String(Int($0)) } ?? "" },
                winner: c?.winner ?? false
            )
        }

        let city = [comp.venue?.address?.city, comp.venue?.address?.state].compactMap { $0 }.joined(separator: ", ")
        let state = comp.status?.type.state ?? "pre"
        let rawDetail = comp.status?.type.shortDetail ?? ""
        // ESPN's own label for finished games: "Final", "Final/OT", "Postponed", "Canceled".
        let detail = state == "post" && rawDetail.isEmpty ? "Final" : rawDetail
        let s = comp.situation
        let situation = state == "in" && s != nil ? Situation(
            downDistance: s?.downDistanceText, shortDownDistance: s?.shortDownDistanceText,
            possessionText: s?.possessionText, possessionTeamId: s?.possession,
            isRedZone: s?.isRedZone ?? false, homeWinPct: s?.lastPlay?.probability?.homeWinPercentage) : nil
        let conditionText = ev.weather?.conditionText ?? ""

        return Game(
            id: ev.id,
            kickoff: kickoff,
            away: info(comp.competitors?.first { $0.homeAway == "away" }),
            home: info(comp.competitors?.first { $0.homeAway == "home" }),
            venue: comp.venue?.fullName ?? "TBD",
            cityState: city,
            indoor: comp.venue?.indoor == true,
            weatherText: conditionText.isEmpty ? nil : conditionText,
            temperature: comp.venue?.indoor == true ? nil : ev.weather?.temperature,
            networks: comp.broadcasts?.flatMap { $0.names } ?? [],
            state: state,
            detail: detail,
            period: comp.status?.period,
            clock: comp.status?.displayClock,
            situation: situation,
            odds: comp.odds?.first?.details,
            overUnder: comp.odds?.first?.overUnder,
            link: ev.links?.first.flatMap { URL(string: $0.href) }
        )
    }
}

// MARK: - List

private enum Metrics {
    static let width: CGFloat = 380
    static let teamRow: CGFloat = 30
    static let strip: CGFloat = 30
    static let cardGap: CGFloat = 8
    static let section: CGFloat = 30
    static let header: CGFloat = 46
    static let footer: CGFloat = 32
}

struct GameListView: View {
    @ObservedObject var store: GameStore

    private struct Day: Identifiable { let id: Date; let games: [Game] }

    private var visibleGames: [Game] {
        store.games.filter { !($0.isFinal && store.hideFinals) && !$0.isLive }
    }

    private var days: [Day] {
        let cal = Calendar.current
        let byDay = Dictionary(grouping: visibleGames) { cal.startOfDay(for: $0.kickoff) }
        return byDay.keys.sorted().map { d in Day(id: d, games: store.ordered(byDay[d]!)) }
    }

    private func cardHeight(_ g: Game) -> CGFloat {
        let strips: CGFloat = g.isLive && g.situation != nil ? 2 : 1
        return Metrics.teamRow * 2 + Metrics.strip * strips + Metrics.cardGap
    }

    private var popoverHeight: CGFloat {
        let live = store.liveGames
        let ds = days
        var h = Metrics.header + Metrics.footer + 12
        if !live.isEmpty { h += Metrics.section + live.reduce(0) { $0 + cardHeight($1) } }
        h += ds.reduce(0) { $0 + Metrics.section + $1.games.reduce(0) { $0 + cardHeight($1) } }
        return min(660, max(170, h))
    }

    private var headerNote: String {
        let live = store.liveGames.count
        if live > 0 { return live == 1 ? "1 live" : "\(live) live" }
        guard let g = store.nextGame else { return "Next 5 days" }
        let secs = Int(g.kickoff.timeIntervalSinceNow)
        let h = secs / 3600, m = (secs % 3600) / 60
        let when = h >= 24 ? "\(h / 24)d \(h % 24)h" : h > 0 ? "\(h)h \(m)m" : "\(max(m, 1))m"
        return "\(g.away.abbr) @ \(g.home.abbr) in \(when)"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)

            if let err = store.error, store.games.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "wifi.exclamationmark").font(.system(size: 22)).foregroundColor(.secondary)
                    Text(err).font(.system(size: 12)).foregroundColor(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(20)
            } else if store.games.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "football").font(.system(size: 22)).foregroundColor(.secondary)
                    Text(store.loading ? "Loading games…" : "No games in the next 5 days.").font(.system(size: 12)).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(20)
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        if !store.liveGames.isEmpty {
                            SectionHeader(left: "LIVE", right: store.liveGames.count == 1 ? "1 game" : "\(store.liveGames.count) games", live: true)
                            ForEach(store.liveGames) { g in GameCard(game: g, store: store) }
                        }
                        ForEach(days) { day in
                            let label = dayLabel(day.id, games: day.games)
                            SectionHeader(left: label.0, right: label.1, live: false)
                            ForEach(day.games) { g in GameCard(game: g, store: store) }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider().opacity(0.6)
            footer
        }
        .frame(width: Metrics.width, height: popoverHeight)
        .onAppear { Task { await store.refresh() } }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("NFL").font(.system(size: 15, weight: .bold))
            if let w = store.week {
                Text("WEEK \(w)")
                    .font(.system(size: 10, weight: .bold)).tracking(0.8)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.35), lineWidth: 1))
            }
            Spacer(minLength: 6)
            Text(headerNote)
                .font(.system(size: 11).monospacedDigit())
                .foregroundColor(store.liveGames.isEmpty ? .secondary : .red)
                .lineLimit(1)
            Menu {
                Toggle("Hide finals", isOn: $store.hideFinals)
                Divider()
                Text("Right-click a game to star a team")
                Divider()
                Button("Quit NFLBar") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .foregroundColor(.secondary)
            Button { Task { await store.refresh() } } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .rotationEffect(.degrees(store.loading ? 360 : 0))
                    .animation(store.loading ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: store.loading)
            }
            .buttonStyle(.plain).foregroundColor(.secondary).help("Refresh")
        }
        .padding(.horizontal, 14)
        .frame(height: Metrics.header)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let err = store.error, !store.games.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundColor(.orange)
                Text(err).font(.system(size: 10)).foregroundColor(.orange).lineLimit(1)
                if let t = store.lastUpdated {
                    Text("· showing \(t.formatted(date: .omitted, time: .shortened))").font(.system(size: 10)).foregroundColor(.secondary).lineLimit(1)
                }
            } else if let t = store.lastUpdated {
                Text("Updated \(t.formatted(date: .omitted, time: .shortened))").font(.system(size: 10)).foregroundColor(.secondary)
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .font(.system(size: 10)).buttonStyle(.plain).foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: Metrics.footer)
    }

    /// ("TONIGHT", "SUN, OCT 4"), ("TOMORROW", "MON, OCT 5"), or ("THU, OCT 8", "").
    private func dayLabel(_ d: Date, games: [Game]) -> (String, String) {
        let cal = Calendar.current
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"
        let dateStr = f.string(from: d).uppercased()
        if cal.isDateInToday(d) {
            let evening = games.allSatisfy { $0.isFinal || cal.component(.hour, from: $0.kickoff) >= 17 }
            return (evening && games.contains { !$0.isFinal } ? "TONIGHT" : "TODAY", dateStr)
        }
        if cal.isDateInTomorrow(d) { return ("TOMORROW", dateStr) }
        return (dateStr, "")
    }
}

struct SectionHeader: View {
    let left: String
    let right: String
    let live: Bool
    var body: some View {
        HStack(spacing: 6) {
            if live { PulsingDot() }
            Text(left).font(.system(size: 11, weight: .bold)).tracking(0.8)
                .foregroundColor(live ? .red : .secondary)
            Spacer()
            Text(right).font(.system(size: 11, weight: live ? .semibold : .bold)).tracking(live ? 0 : 0.8)
                .foregroundColor(live ? .red : .secondary)
        }
        .padding(.horizontal, 4)
        .frame(height: Metrics.section, alignment: .bottom)
        .padding(.bottom, 2)
    }
}

// MARK: - Card

/// One game as a TV scorebug: away over home, colour blocks, fixed columns,
/// then strips for the drive (live), where to watch, or the final line score.
struct GameCard: View {
    let game: Game
    @ObservedObject var store: GameStore
    @Environment(\.colorScheme) private var scheme

    private var fav: Bool { store.isFavorite(game) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    TeamRow(team: game.away, game: game, starred: store.favorites.contains(game.away.abbr))
                    Divider().opacity(0.5).padding(.leading, 44)
                    TeamRow(team: game.home, game: game, starred: store.favorites.contains(game.home.abbr))
                }
                if game.state == "pre" { kickoffColumn }
            }
            .frame(height: Metrics.teamRow * 2)

            if game.isLive, let s = game.situation {
                Divider().opacity(0.5)
                driveStrip(s)
            }
            if game.isFinal {
                Divider().opacity(0.5)
                finalStrip
            } else {
                Divider().opacity(0.5)
                watchStrip
            }
        }
        .background(alignment: .bottom) {
            if game.isLive, let p = game.situation?.homeWinPct { winProbability(home: p) }
        }
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(scheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(fav ? Color.yellow.opacity(0.85) : Color.primary.opacity(0.08), lineWidth: fav ? 1.5 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .opacity(game.isFinal ? 0.72 : 1)
        .padding(.bottom, Metrics.cardGap)
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

    private var kickoffColumn: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(GameStore.shortTime(game.kickoff))
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
            HStack(spacing: 3) {
                if game.indoor {
                    Text("Indoors")
                } else if let t = game.temperature {
                    if let sym = game.weatherSymbol { Image(systemName: sym) }
                    Text("\(t)°").monospacedDigit()
                }
            }
            .font(.system(size: 11)).foregroundColor(.secondary)
        }
        .frame(width: 74, alignment: .trailing)
        .padding(.trailing, 12)
    }

    private func driveStrip(_ s: Situation) -> some View {
        HStack(spacing: 10) {
            FieldBar(progress: game.fieldProgress, color: game.possession?.color ?? .secondary, redZone: s.isRedZone)
                .frame(width: 92, height: 8)
            Text(s.downDistance ?? s.shortDownDistance ?? "")
                .font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 4)
            Text(game.clockLabel)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundColor(.red).lineLimit(1)
        }
        .padding(.leading, 56).padding(.trailing, 12)
        .frame(height: Metrics.strip)
    }

    /// Networks and streaming buttons: always on the card, never collapsed into hover.
    private var watchStrip: some View {
        let slots = game.watchSlots
        return HStack(spacing: 6) {
            Group {
                if game.isLive {
                    if let p = game.situation?.homeWinPct {
                        let home = p >= 0.5
                        Text("\(home ? game.home.abbr : game.away.abbr) \(Int((home ? p : 1 - p) * 100 + 0.5))% to win")
                    } else if game.situation == nil {
                        Text(game.clockLabel).foregroundColor(.red)
                    } else {
                        Text(game.cityState)
                    }
                } else {
                    Text(game.oddsLine ?? game.cityState)
                }
            }
            .font(.system(size: 11).monospacedDigit()).foregroundColor(.secondary)
            .lineLimit(1).truncationMode(.tail).layoutPriority(-1)
            Spacer(minLength: 4)
            ForEach(slots.shown, id: \.self) { WatchButton(slot: $0) }
            if !slots.extra.isEmpty {
                Menu {
                    ForEach(slots.extra, id: \.self) { s in
                        if let url = s.url { Button("Watch on \(s.name)") { NSWorkspace.shared.open(url) } } else { Text("On \(s.name)") }
                    }
                } label: { Text("+\(slots.extra.count)").font(.system(size: 11, weight: .semibold)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
        }
        .padding(.leading, 56).padding(.trailing, 10)
        .frame(height: Metrics.strip)
    }

    private var finalStrip: some View {
        HStack(spacing: 0) {
            Text(game.detail).font(.system(size: 12, weight: .semibold))
            Spacer()
            let quarters = max(game.away.linescores.count, game.home.linescores.count)
            HStack(spacing: 0) {
                ForEach(0..<quarters, id: \.self) { q in
                    VStack(spacing: 0) {
                        Text(q < game.away.linescores.count ? game.away.linescores[q] : "")
                        Text(q < game.home.linescores.count ? game.home.linescores[q] : "")
                    }
                    .font(.system(size: 9.5, design: .monospaced)).foregroundColor(.secondary)
                    .frame(width: 22, alignment: .trailing)
                }
            }
        }
        .padding(.leading, 56).padding(.trailing, 14)
        .frame(height: Metrics.strip)
    }

    private func winProbability(home p: Double) -> some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Rectangle().fill(game.away.color).frame(width: geo.size.width * (1 - p))
                Rectangle().fill(game.home.color)
            }
        }
        .frame(height: 3)
    }
}

struct TeamRow: View {
    let team: TeamInfo
    let game: Game
    let starred: Bool

    private var lost: Bool { game.isFinal && !team.winner && (game.away.winner || game.home.winner) }
    private var hasBall: Bool { game.isLive && game.possession?.id == team.id && !team.id.isEmpty }

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Rectangle().fill(team.color)
                Text(team.abbr)
                    .font(.system(size: 12, weight: .heavy)).tracking(0.3)
                    .foregroundColor(team.blockText)
                if starred {
                    Rectangle().strokeBorder(Color.yellow, lineWidth: 2)
                }
            }
            .frame(width: 44)

            AsyncImage(url: team.logo) { img in
                img.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                Circle().fill(Color.secondary.opacity(0.18))
            }
            .frame(width: 20, height: 20)
            .padding(.leading, 10)

            Text(team.name)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundColor(lost ? .secondary : .primary)
                .lineLimit(1)
                .padding(.leading, 8)
            if hasBall {
                Image(systemName: "football.fill").font(.system(size: 8)).foregroundColor(.secondary)
                    .padding(.leading, 5).help("Has the ball")
            }
            Spacer(minLength: 4)
            Text(team.record)
                .font(.system(size: 11).monospacedDigit()).foregroundColor(.secondary)
                .frame(width: 40, alignment: .trailing)
            if game.state != "pre" {
                Text("\(team.score)")
                    .font(.system(size: 18, weight: lost ? .medium : .bold, design: .rounded).monospacedDigit())
                    .foregroundColor(lost ? .secondary : .primary)
                    .contentTransition(.numericText())
                    .animation(.default, value: team.score)
                    .frame(width: 44, alignment: .trailing)
                    .padding(.trailing, 12)
            }
        }
        .frame(height: Metrics.teamRow)
    }
}

/// The drive at a glance: filled from the offence's own goal line to the ball.
struct FieldBar: View {
    let progress: Double?
    let color: Color
    let redZone: Bool
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, p = min(1, max(0, progress ?? 0))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                // The last fifth is the red zone.
                Capsule().fill(Color.red.opacity(redZone ? 0.35 : 0.15)).frame(width: w * 0.2).offset(x: w * 0.8)
                if progress != nil {
                    Capsule().fill(color).frame(width: max(6, w * p))
                    Rectangle().fill(Color.primary).frame(width: 2, height: geo.size.height + 4).offset(x: max(0, w * p - 1))
                }
            }
        }
    }
}

struct WatchButton: View {
    let slot: WatchSlot
    var body: some View {
        if let url = slot.url {
            Button { NSWorkspace.shared.open(url) } label: { label }
                .buttonStyle(.plain).help("Watch on \(slot.name)")
        } else {
            label.help("On \(slot.name)")
        }
    }

    private var label: some View {
        HStack(spacing: 4) {
            Image(systemName: slot.isStream ? "play.rectangle.fill" : "tv").font(.system(size: 9.5))
            Text(slot.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .fixedSize()
        .padding(.horizontal, 7).frame(height: 20)
        .foregroundColor(slot.isStream ? .white : .primary.opacity(0.75))
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(slot.isStream ? Color.accentColor : Color.primary.opacity(0.05))
        )
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(slot.isStream ? 0 : 0.1), lineWidth: 1))
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
