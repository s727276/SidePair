import SwiftUI
import UniformTypeIdentifiers

struct IPACustomizationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var library: AppLibraryModel
    @ObservedObject var signing: AppleSigningModel
    @ObservedObject var connection: RSDConnectionModel
    @StateObject private var model: IPACustomizationModel
    @State private var showingIconImporter = false
    @State private var showingInfoPlistReview = false
    @State private var showingSigningProfile = false
    @State private var showingFrameworkInfo = false

    init(app: IPAAppMetadata, library: AppLibraryModel, signing: AppleSigningModel, connection: RSDConnectionModel) {
        self.library = library
        self.signing = signing
        self.connection = connection
        _model = StateObject(wrappedValue: IPACustomizationModel(app: app))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    appSummaryCard
                    iconSection
                    detailsSection
                    infoPlistSection
                    frameworksSection
                    signingReadinessSection

                    if model.isPreparing {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Preparing a safe working copy…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                    }

                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 22)
                .padding(.bottom, 24)
            }
            .background(Color(red: 0.95, green: 0.97, blue: 1).ignoresSafeArea())
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomActions
        }
        .fileImporter(
            isPresented: $showingIconImporter,
            allowedContentTypes: [.png],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                if let url = urls.first { model.chooseIcon(from: url) }
            case let .failure(error):
                if (error as? CocoaError)?.code != .userCancelled {
                    model.reportError(error.localizedDescription)
                }
            }
        }
        .sheet(isPresented: $showingInfoPlistReview) {
            InfoPlistReviewView(rows: model.currentInfoPlistRows)
        }
        .sheet(isPresented: $showingSigningProfile) {
            AppleSigningView(model: signing, connection: connection)
        }
        .alert("Framework compatibility", isPresented: $showingFrameworkInfo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Framework editing will be available through the compatible-framework manager. It will accept only compatible frameworks for apps you own or are authorized to modify. Standalone dylib injection isn’t supported because it changes executable code and can invalidate the signature or break the app.")
        }
        .interactiveDismissDisabled()
        .task { model.prepare() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Customize IPA")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .tracking(-0.5)
                .foregroundStyle(Color(red: 0.08, green: 0.13, blue: 0.25))
            Text("Review changes before signing.")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }

    private var appSummaryCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                appIcon(size: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.displayName.isEmpty ? "App" : model.displayName)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                    Text(model.bundleIdentifier)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Label("Original kept safe", systemImage: "checkmark.circle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.green.opacity(0.1), in: Capsule())
            }
            .padding(16)

            Divider().overlay(.white.opacity(0.55))

            HStack {
                Text("Version")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(model.version.isEmpty ? "—" : model.version)
                    .fontWeight(.medium)
            }
            .font(.subheadline)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .customizationCard()
    }

    private var iconSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("App icon", subtitle: "Choose a custom icon for your app.")
            HStack(spacing: 14) {
                appIcon(size: 72)
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        showingIconImporter = true
                    } label: {
                        Text("Choose icon")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(!model.canReplaceIcon || model.isPreparing || model.isWorking)

                    Text(model.iconAvailabilityMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .customizationCard()
        }
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("App details", subtitle: "Edit the basic information for your app.")
            VStack(spacing: 0) {
                editableRow("Display name", text: $model.displayName)
                Divider().padding(.leading, 16)
                editableRow("Version", text: $model.version)
                Divider().padding(.leading, 16)
                HStack {
                    Text("Bundle identifier")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 14)
                    Text(model.bundleIdentifier)
                        .font(.subheadline)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
                .font(.subheadline)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
            }
            .customizationCard()
        }
    }

    private var infoPlistSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("Info.plist", subtitle: "Review and customize the app’s Info.plist file.")
            HStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 58, height: 58)
                    .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 7) {
                    Button("Review values") { showingInfoPlistReview = true }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    Text("Identity and signing-controlled keys stay protected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .customizationCard()
        }
    }

    private var frameworksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("Frameworks", subtitle: "Add additional frameworks to include in the IPA.")
            HStack(spacing: 12) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 58, height: 58)
                    .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 7) {
                    Button("Add compatible framework") { showingFrameworkInfo = true }
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                    Text("Only compatible frameworks are supported. Standalone dylib injection isn’t supported.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("I own or am authorized to modify this IPA", isOn: $model.confirmsAuthorizedModification)
                        .font(.caption.weight(.medium))
                        .tint(.blue)
                }
            }
            .padding(14)
            .customizationCard()
        }
    }

    private var signingReadinessSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("Signing readiness", subtitle: "Make sure everything is set before signing.")
            Button {
                showingSigningProfile = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 58, height: 58)
                        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Profile & entitlements")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Text("Review your Apple profile before signing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
            }
            .buttonStyle(.plain)
            .customizationCard()
        }
    }

    private var bottomActions: some View {
        HStack(spacing: 10) {
            Button("Cancel") {
                model.discardWorkspace()
                dismiss()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(model.isWorking || model.isPreparing)

            Button {
                model.reviewAndSign(library: library, signing: signing, connection: connection) {
                    dismiss()
                }
            } label: {
                HStack(spacing: 8) {
                    if model.isWorking { ProgressView().tint(.white) }
                    Text(model.isWorking ? "Signing…" : "Review & Sign")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.blue)
            .disabled(!model.canReviewAndSign)
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }

    private var ipaImageType: UTType { .png }

    private func appIcon(size: CGFloat) -> some View {
        Group {
            if let image = model.iconPreview {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: size * 0.38, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.blue.opacity(0.55))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    private func sectionHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(Color(red: 0.08, green: 0.13, blue: 0.25))
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    private func editableRow(_ title: String, text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 118, alignment: .leading)
            TextField(title, text: text)
                .font(.subheadline)
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

private extension View {
    func customizationCard() -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.7), lineWidth: 1)
            }
    }
}

private struct InfoPlistReviewView: View {
    @Environment(\.dismiss) private var dismiss
    let rows: [IPACustomizationInfoRow]

    var body: some View {
        NavigationStack {
            List(rows) { row in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(row.key)
                            .font(.subheadline.weight(.semibold))
                        Spacer(minLength: 8)
                        if row.key == "CFBundleIdentifier" {
                            Label("Locked", systemImage: "lock.fill")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(row.value)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(4)
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("Info.plist values")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
