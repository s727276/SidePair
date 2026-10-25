import AppIntents
import SwiftUI
import WidgetKit

private let sharedAppGroup = "group.com.Andrewdev.aquasign.shared"
private let widgetAppsKey = "aquaSignWidgetApps"
private let pendingRefreshKey = "aquaSignPendingWidgetRefresh"
private let widgetKind = "com.Andrewdev.aquasign.sidepairwidgetextension.widget"

private struct WidgetAppSummary: Decodable {
    let displayName: String
    let profileExpiration: Date?
}

struct SidePairWidgetExtensionEntry: TimelineEntry {
    let date: Date
    let installedCount: Int
    let nextExpiringApp: String?
    let profileExpiration: Date?
    let refreshRequested: Bool
}

struct SidePairWidgetExtensionProvider: TimelineProvider {
    func placeholder(in context: Context) -> SidePairWidgetExtensionEntry {
        SidePairWidgetExtensionEntry(
            date: Date(),
            installedCount: 3,
            nextExpiringApp: "Example app",
            profileExpiration: Date().addingTimeInterval(6 * 86_400),
            refreshRequested: false
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (SidePairWidgetExtensionEntry) -> Void) {
        completion(makeEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SidePairWidgetExtensionEntry>) -> Void) {
        let entry = makeEntry()
        var entries = [entry]
        if let expiration = entry.profileExpiration, expiration > entry.date {
            entries.append(makeEntry(at: expiration))
        }
        completion(Timeline(entries: entries, policy: .after(Date().addingTimeInterval(900))))
    }

    private func makeEntry(at date: Date = Date()) -> SidePairWidgetExtensionEntry {
        let defaults = UserDefaults(suiteName: sharedAppGroup)
        let data = defaults?.data(forKey: widgetAppsKey)
        let apps = data.flatMap { try? JSONDecoder().decode([WidgetAppSummary].self, from: $0) } ?? []
        let expiringApps = apps.compactMap { app -> (String, Date)? in
            guard let expiration = app.profileExpiration else { return nil }
            return (app.displayName, expiration)
        }
        let now = date
        let nextExpiringApp = expiringApps
            .filter { $0.1 > now }
            .min { $0.1 < $1.1 }
            ?? expiringApps.max { $0.1 < $1.1 }

        return SidePairWidgetExtensionEntry(
            date: date,
            installedCount: apps.count,
            nextExpiringApp: nextExpiringApp?.0,
            profileExpiration: nextExpiringApp?.1,
            refreshRequested: defaults?.bool(forKey: pendingRefreshKey) ?? false
        )
    }
}

struct SidePairWidgetExtensionEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: SidePairWidgetExtensionProvider.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 10) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .foregroundStyle(.blue)
                Text("AquaSign")
                    .font(.headline)
                Spacer(minLength: 0)
            }

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(entry.installedCount)")
                    .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                Text(entry.installedCount == 1 ? "app installed" : "apps installed")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let name = entry.nextExpiringApp, let expiration = entry.profileExpiration {
                VStack(alignment: .leading, spacing: 2) {
                    Text(family == .systemSmall ? "\(name) profile" : "\(name) profile expires in")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if expiration > entry.date {
                        Text(expiration, style: .timer)
                            .font(.caption.monospacedDigit().weight(.semibold))
                    } else {
                        Text("Expired")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    if family != .systemSmall {
                        Text(expiration.formatted(.dateTime.month(.abbreviated).day().year().hour().minute().second()))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text("LocalDevVPN must be active to refresh.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text(entry.installedCount == 0 ? "Add apps in AquaSign to begin." : "Refresh an app to read its profile expiry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Button(intent: RefreshAllAppsIntent()) {
                Label(
                    entry.refreshRequested ? "Opening…" : (family == .systemSmall ? "Refresh" : "Refresh all"),
                    systemImage: "arrow.clockwise"
                )
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)
        }
        .padding(4)
        .containerBackground(Color(uiColor: .secondarySystemGroupedBackground), for: .widget)
    }
}

struct RefreshAllAppsIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh all apps"
    static var description = IntentDescription("Open AquaSign and refresh every installed app over LocalDevVPN.")
    static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        UserDefaults(suiteName: sharedAppGroup)?.set(true, forKey: pendingRefreshKey)
        WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
        return .result()
    }
}

struct SidePairWidgetExtensionWidget: Widget {
    let kind: String = widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SidePairWidgetExtensionProvider()) { entry in
            SidePairWidgetExtensionEntryView(entry: entry)
        }
        .configurationDisplayName("AquaSign Refresh")
        .description("See your installed apps and refresh them together through LocalDevVPN.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct SidePairWidgetExtensionBundle: WidgetBundle {
    var body: some Widget {
        SidePairWidgetExtensionWidget()
    }
}
