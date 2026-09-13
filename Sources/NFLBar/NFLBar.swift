import SwiftUI
import AppKit

// MARK: - App

@main
struct NFLBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = GameStore()

    var body: some Scene {
        MenuBarExtra {
            GameListView(store: store)
        } label: {
            Image(systemName: "football.fill")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Model

struct TeamInfo {
    let name: String        // "Buccaneers"
    let abbr: String        // "TB"
    let logo: URL?
    let score: String?
}

struct Game: Identifiable {
    let id: String
    let kickoff: Date
    let away: TeamInfo
    let home: TeamInfo
    let venue: String
    let cityState: String
    let networks: [String]
    let state: String        // "pre", "in", "post"
    let detail: String       // "Q2 5:31", "Final", etc.

    var isLive: Bool { state == "in" }
    var isFinal: Bool { state == "post" }

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

// MARK: - ESPN decoding

private struct Scoreboard: Decodable { let events: [Event] }
private struct Event: Decodable {
    let id: String
    let date: String
    let competitions: [Competition]
}
private struct Competition: Decodable {
    let venue: Venue?
    let broadcasts: [Broadcast]?
    let competitors: [Competitor]?
    let status: Status?
}
private struct Venue: Decodable { let fullName: String?; let address: Address? }
private struct Address: Decodable { let city: String?; let state: String? }
private struct Broadcast: Decodable { let names: [String] }
private struct Competitor: Decodable {
    let homeAway: String
    let score: String?
    let team: Team
}
private struct Team: Decodable {
    let shortDisplayName: String?
    let displayName: String
    let abbreviation: String?
    let logo: String?
}
private struct Status: Decodable { let type: StatusType }
private struct StatusType: Decodable { let state: String; let shortDetail: String? }

// MARK: - Store

@MainActor
final class GameStore: ObservableObject {
    @Published var games: [Game] = []
    @Published var lastUpdated: Date?
    @Published var error: String?

    private var timer: Timer?

    init() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
    }

    func refresh() async {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        let today = Date()
        let end = Calendar.current.date(byAdding: .day, value: 4, to: today)!
        let urlString = "https://site.api.espn.com/apis/site/v2/sports/football/nfl/scoreboard?dates=\(fmt.string(from: today))-\(fmt.string(from: end))"

        do {
            let (data, _) = try await URLSession.shared.data(from: URL(string: urlString)!)
            let board = try JSONDecoder().decode(Scoreboard.self, from: data)

            let f1 = DateFormatter(); f1.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
            let f2 = DateFormatter(); f2.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
            for f in [f1, f2] { f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX") }
            func parse(_ s: String) -> Date? { f1.date(from: s) ?? f2.date(from: s) }

            func info(_ c: Competitor?) -> TeamInfo {
                TeamInfo(
                    name: c?.team.shortDisplayName ?? c?.team.displayName ?? "?",
                    abbr: c?.team.abbreviation ?? "",
                    logo: c?.team.logo.flatMap { URL(string: $0) },
                    score: c?.score
                )
            }

            let startOfToday = Calendar.current.startOfDay(for: today)
            games = board.events.compactMap { ev -> Game? in
                guard let comp = ev.competitions.first,
                      let kickoff = parse(ev.date),
                      kickoff >= startOfToday else { return nil }

                let city = [comp.venue?.address?.city, comp.venue?.address?.state]
                    .compactMap { $0 }.joined(separator: ", ")

                return Game(
                    id: ev.id,
                    kickoff: kickoff,
                    away: info(comp.competitors?.first { $0.homeAway == "away" }),
                    home: info(comp.competitors?.first { $0.homeAway == "home" }),
                    venue: comp.venue?.fullName ?? "TBD",
                    cityState: city,
                    networks: comp.broadcasts?.flatMap { $0.names } ?? [],
                    state: comp.status?.type.state ?? "pre",
                    detail: comp.status?.type.shortDetail ?? ""
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

// MARK: - Views

struct GameListView: View {
    @ObservedObject var store: GameStore

    private struct Slot: Identifiable { let id: Date; let games: [Game] }
    private struct Day: Identifiable { let id: Date; let slots: [Slot] }

    private var days: [Day] {
        let cal = Calendar.current
        let byDay = Dictionary(grouping: store.games) { cal.startOfDay(for: $0.kickoff) }
        return byDay.keys.sorted().map { d in
            let bySlot = Dictionary(grouping: byDay[d]!) { $0.kickoff }
            return Day(id: d, slots: bySlot.keys.sorted().map { Slot(id: $0, games: bySlot[$0]!) })
        }
    }

    private var popoverHeight: CGFloat {
        let ds = days
        let slots = ds.reduce(0) { $0 + $1.slots.count }
        let rows = CGFloat(store.games.count) * 60 + CGFloat(ds.count) * 34 + CGFloat(slots) * 26 + 100
        return min(640, max(140, rows))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("NFL").font(.system(size: 14, weight: .bold))
                Text("next 5 days").font(.system(size: 12)).foregroundColor(.secondary)
                Spacer()
                Button { Task { await store.refresh() } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundColor(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            Divider()

            if let err = store.error {
                Text(err).foregroundColor(.red).font(.caption).padding(14)
                Spacer()
            } else if store.games.isEmpty {
                Text("No games in the next 5 days.").foregroundColor(.secondary).padding(14)
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
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
                                    GameRow(game: g)
                                        .padding(.horizontal, 14).padding(.vertical, 5)
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
            HStack {
                Text("Out-of-market: NFL Sunday Ticket on YouTube TV")
                    .font(.system(size: 10)).foregroundColor(.secondary)
                Spacer()
                if let t = store.lastUpdated {
                    Text(t, style: .time).font(.system(size: 10)).foregroundColor(.secondary)
                }
                Button("Quit") { NSApp.terminate(nil) }
                    .font(.system(size: 10)).buttonStyle(.plain).foregroundColor(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .frame(width: 360, height: popoverHeight)
        .onAppear { Task { await store.refresh() } }
    }

    private func dayLabel(_ d: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter(); f.dateFormat = "EEE, MMM d"
        let dateStr = f.string(from: d)
        if cal.isDateInToday(d) { return "TODAY  ·  \(dateStr.uppercased())" }
        if cal.isDateInTomorrow(d) { return "TOMORROW  ·  \(dateStr.uppercased())" }
        return f.string(from: d).uppercased()
    }
}

struct GameRow: View {
    let game: Game

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TeamChip(team: game.away)
                Text("@").font(.system(size: 11)).foregroundColor(.secondary)
                TeamChip(team: game.home)
                Spacer()
                statusView
            }
            Text("\(game.venue) · \(game.cityState)")
                .font(.system(size: 11)).foregroundColor(.secondary)
                .lineLimit(1)
            HStack(spacing: 5) {
                ForEach(game.networks, id: \.self) { n in
                    Pill(text: n, tint: .secondary)
                }
                ForEach(game.streams, id: \.name) { s in
                    Button { NSWorkspace.shared.open(URL(string: s.url)!) } label: {
                        Pill(text: s.name, tint: .accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Open \(s.name)")
                }
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        if game.isLive {
            HStack(spacing: 4) {
                Circle().fill(Color.red).frame(width: 6, height: 6)
                Text("\(game.away.score ?? "0")–\(game.home.score ?? "0")")
                    .font(.system(size: 12, weight: .bold))
                Text(game.detail).font(.system(size: 10)).foregroundColor(.secondary)
            }
        } else if game.isFinal {
            HStack(spacing: 4) {
                Text("\(game.away.score ?? "0")–\(game.home.score ?? "0")")
                    .font(.system(size: 12, weight: .semibold))
                Text("Final").font(.system(size: 10)).foregroundColor(.secondary)
            }
        }
    }
}

struct TeamChip: View {
    let team: TeamInfo
    var body: some View {
        HStack(spacing: 4) {
            AsyncImage(url: team.logo) { img in
                img.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                Circle().fill(Color.secondary.opacity(0.2))
            }
            .frame(width: 18, height: 18)
            Text(team.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
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
