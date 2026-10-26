import SwiftUI

enum AquaSignRoute: Hashable {
    case appLibrary
    case appleSigning
    case developerAppIDs
    case settings
}

struct SettingsView: View {
    @ObservedObject var signing: AppleSigningModel
    @AppStorage("sidepairShowIPACustomizationBeforeSigning") private var showCustomizationBeforeSigning = false
    @AppStorage("sidepairShowSettingsInTabBar") private var showSettingsInTabBar = false
    let onNavigate: (AquaSignRoute) -> Void
    let onOpenSettings: () -> Void

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
                developerAppIDsCard
                versionCard
                tabNavigationCard
                customizationCard
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 24)
        }
        .background(Color(red: 0.95, green: 0.97, blue: 1).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Settings")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .tracking(-0.5)
                    .foregroundStyle(Color(red: 0.08, green: 0.13, blue: 0.25))
                Text("App information")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .background(.regularMaterial, in: Circle())
            }
            .accessibilityLabel("Settings")
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
                    Button("Manage Apple signing") { onNavigate(.appleSigning) }
                        .font(.caption.weight(.semibold))
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

    private var developerAppIDsCard: some View {
        Button {
            onNavigate(.developerAppIDs)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(Color.blue)
                    .frame(width: 52, height: 52)
                    .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Developer App IDs")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Browse IDs registered to your team")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.7), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
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

    private var tabNavigationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $showSettingsInTabBar) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Show Settings in tab bar")
                        .font(.subheadline.weight(.semibold))
                    Text("Add Settings as a bottom tab. The top-right gear remains available either way.")
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

}
