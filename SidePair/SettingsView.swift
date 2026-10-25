import SwiftUI

enum AquaSignRoute: Hashable {
    case appLibrary
    case appleSigning
    case settings
}

struct SettingsView: View {
    @ObservedObject var signing: AppleSigningModel
    @AppStorage("sidepairShowIPACustomizationBeforeSigning") private var showCustomizationBeforeSigning = false
    let onNavigate: (AquaSignRoute) -> Void
    let onPair: () -> Void

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unavailable"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unavailable"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                signingIdentityCard
                versionCard
                customizationCard
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 24)
        }
        .background(Color(red: 0.95, green: 0.97, blue: 1).ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            tabBar
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 8)
                .background(.clear)
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Settings")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .tracking(-0.5)
                .foregroundStyle(Color(red: 0.08, green: 0.13, blue: 0.25))
            Text("App information")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
    }

    private var signingIdentityCard: some View {
        HStack(spacing: 16) {
            Image(systemName: "doc.text.badge.gearshape")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 72, height: 72)
                .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text("Apple Developer Team")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                if let developerTeam = developerTeamLabel {
                    Text(developerTeam)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Account team information, not a verified signing-certificate name.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("No Apple developer team loaded")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Manage Apple signing") { onNavigate(.appleSigning) }
                        .font(.caption.weight(.semibold))
                }
            }
            Spacer(minLength: 0)
            Label(
                developerTeamLabel == nil ? "Unavailable" : "Account",
                systemImage: developerTeamLabel == nil ? "questionmark.circle.fill" : "person.crop.circle.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(developerTeamLabel == nil ? Color.secondary : Color.blue)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background((developerTeamLabel == nil ? Color.secondary : Color.blue).opacity(0.1), in: Capsule())
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.7), lineWidth: 1)
        }
    }

    private var developerTeamLabel: String? {
        guard let status = signing.status else { return nil }
        let teamName = status.teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !teamName.isEmpty else { return nil }
        let teamID = status.teamId.trimmingCharacters(in: .whitespacesAndNewlines)
        if teamID.isEmpty { return "iPhone Developer: \(teamName)" }
        return "iPhone Developer: \(teamName) (\(teamID))"
    }

    private var versionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("App version")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .padding(.bottom, 2)
            settingsRow("Version", value: appVersion)
            Divider()
            settingsRow("Build", value: buildNumber)
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.7), lineWidth: 1)
        }
    }

    private var customizationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $showCustomizationBeforeSigning) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Open IPA customization before signing")
                        .font(.subheadline.weight(.semibold))
                    Text("Show the customization workspace before signing or refreshing an app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(.blue)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.7), lineWidth: 1)
        }
    }

    private func settingsRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .font(.subheadline)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            tabItem("Pair", symbol: "rectangle.on.rectangle", selected: false) { onPair() }
            tabItem("App Library", symbol: "square.stack.3d.up.fill", selected: false) { onNavigate(.appLibrary) }
            tabItem("Settings", symbol: "gearshape.fill", selected: true) {}
        }
        .padding(8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay { Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1) }
        .shadow(color: .black.opacity(0.08), radius: 14, y: 5)
    }

    private func tabItem(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(selected ? Color.blue : Color.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background { if selected { Capsule().fill(Color(uiColor: .tertiarySystemGroupedBackground)) } }
        }
        .buttonStyle(.plain)
        .disabled(selected)
    }
}
