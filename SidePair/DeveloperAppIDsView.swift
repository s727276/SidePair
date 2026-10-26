import SwiftUI

struct DeveloperAppIDsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var signing: AppleSigningModel
    let onManageAppleSigning: () -> Void
    @State private var searchText = ""
    @State private var selectedAppID: AppleDeveloperAppID?
    @State private var isWaitingForSession = true

    private var teamDescription: String? {
        guard let status = signing.status else { return nil }
        let name = status.teamName.trimmingCharacters(in: .whitespacesAndNewlines)
        let identifier = status.teamId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return identifier.isEmpty ? name : "\(name) · \(identifier)"
    }

    private var filteredAppIDs: [AppleDeveloperAppID] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return signing.developerAppIDs }
        return signing.developerAppIDs.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.identifier.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                settingsBackButton
                heading
                searchField
                Text("App IDs registered to this team")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(red: 0.46, green: 0.52, blue: 0.64))
                    .padding(.horizontal, 8)

                results
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .background(appIDsBackground)
        .toolbar(.hidden, for: .navigationBar)
        .task { await loadAppIDs() }
        .sheet(item: $selectedAppID) { appID in
            AppIDCapabilityOverviewView(appID: appID)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var settingsBackButton: some View {
        Button {
            dismiss()
        } label: {
            Label("Settings", systemImage: "chevron.left")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(red: 0.13, green: 0.48, blue: 0.84))
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .overlay { Capsule().stroke(.white.opacity(0.75), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back to Settings")
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Developer App IDs")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .tracking(-0.5)
                .foregroundStyle(Color(red: 0.06, green: 0.11, blue: 0.22))
                .fixedSize(horizontal: false, vertical: true)
            Text(teamDescription ?? "No developer team loaded")
                .font(.system(size: 16))
                .foregroundStyle(Color(red: 0.47, green: 0.53, blue: 0.66))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(Color(red: 0.47, green: 0.53, blue: 0.66))
            TextField("Search name or bundle ID", text: $searchText)
                .font(.system(size: 16))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("Search developer App IDs")
        }
        .padding(.horizontal, 16)
        .frame(height: 50)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().stroke(.white.opacity(0.78), lineWidth: 1) }
    }

    @ViewBuilder
    private var results: some View {
        if isWaitingForSession || signing.isLoadingDeveloperAppIDs {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading App IDs from Apple…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 34)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
        } else if let error = signing.developerAppIDsErrorMessage {
            VStack(alignment: .leading, spacing: 12) {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if signing.status == nil {
                    Button("Manage Apple signing", action: onManageAppleSigning)
                        .font(.subheadline.weight(.semibold))
                } else {
                    Button("Try again") { signing.loadDeveloperAppIDs() }
                        .font(.subheadline.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
        } else if filteredAppIDs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(searchText.isEmpty ? "No App IDs registered to this team" : "No matching App IDs")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(red: 0.10, green: 0.15, blue: 0.26))
                Text(searchText.isEmpty
                     ? "Apple did not return any App IDs for the signed-in developer team."
                     : "Try another app name or bundle identifier.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
        } else {
            appIDList
        }
    }

    private var appIDList: some View {
        VStack(spacing: 0) {
            ForEach(filteredAppIDs) { appID in
                Button {
                    selectedAppID = appID
                } label: {
                    appIDRow(appID)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the capability overview for \(appID.name)")

                if appID.id != filteredAppIDs.last?.id {
                    Divider()
                        .padding(.leading, 65)
                }
            }
        }
        .padding(.horizontal, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 27, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 27, style: .continuous)
                .stroke(.white.opacity(0.78), lineWidth: 1)
        }
        .shadow(color: .blue.opacity(0.045), radius: 13, y: 5)
    }

    private func appIDRow(_ appID: AppleDeveloperAppID) -> some View {
        HStack(spacing: 13) {
            Image(systemName: "shippingbox")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(Color(red: 0.61, green: 0.67, blue: 0.78))
                .frame(width: 46, height: 46)
                .background(Color(red: 0.91, green: 0.94, blue: 0.99), in: RoundedRectangle(cornerRadius: 15, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(appID.name)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.08, green: 0.13, blue: 0.25))
                    .lineLimit(1)
                Text(appID.identifier)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 0.47, green: 0.53, blue: 0.66))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            HStack(spacing: 5) {
                Text("Capabilities")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(red: 0.13, green: 0.48, blue: 0.84))
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.53, green: 0.60, blue: 0.70))
            }
        }
        .padding(.vertical, 16)
        .contentShape(Rectangle())
    }

    private var appIDsBackground: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.90, green: 0.94, blue: 0.99),
                        Color(red: 0.98, green: 0.99, blue: 1.00),
                        Color(red: 0.90, green: 0.95, blue: 1.00)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Circle()
                    .fill(.white.opacity(0.28))
                    .frame(width: geometry.size.width * 0.90)
                    .offset(x: -geometry.size.width * 0.44, y: -geometry.size.height * 0.40)
                Ellipse()
                    .fill(Color.blue.opacity(0.035))
                    .frame(width: geometry.size.width * 1.2, height: geometry.size.height * 0.48)
                    .rotationEffect(.degrees(-18))
                    .offset(x: geometry.size.width * 0.34, y: geometry.size.height * 0.40)
            }
        }
        .ignoresSafeArea()
    }

    private func loadAppIDs() async {
        signing.restoreSessionIfAvailable()
        for _ in 0..<80 {
            if signing.status != nil || !signing.isWorking { break }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        isWaitingForSession = false
        signing.loadDeveloperAppIDs()
    }
}

private struct AppIDCapabilityOverviewView: View {
    @Environment(\.dismiss) private var dismiss
    let appID: AppleDeveloperAppID
    @State private var showingEntitlementMessage = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(appID.name)
                            .font(.system(size: 27, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(red: 0.06, green: 0.11, blue: 0.22))
                        Text(appID.identifier)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 6)

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Apple-reported capability identifiers")
                            .font(.headline)
                        if appID.featureIds.isEmpty {
                            Text("Apple returned no capability identifiers for this App ID.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            ForEach(appID.featureIds, id: \.self) { featureID in
                                Label(featureID, systemImage: "checkmark.circle")
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                            }
                        }
                        Text("These identifiers are reported by Apple for this App ID; AquaSign has not changed or independently validated their entitlement status.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                    Button("Manage entitlements") {
                        showingEntitlementMessage = true
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.blue, in: Capsule())
                    .foregroundStyle(.white)
                    .buttonStyle(.plain)
                }
                .padding(20)
                .padding(.top, 12)
            }
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Capabilities")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Entitlement management", isPresented: $showingEntitlementMessage) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("AquaSign can verify registered App IDs now. Requesting or changing entitlements is not available yet.")
            }
        }
    }
}
