import Combine
import Darwin
import Foundation
import IDevice

struct RSDDeviceDetails: Equatable {
    let name: String
    let model: String
    let version: String
    let udid: String?
}

enum RSDConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

@MainActor
final class RSDConnectionModel: ObservableObject {
    @Published private(set) var state: RSDConnectionState = .disconnected
    @Published private(set) var deviceDetails: RSDDeviceDetails?
    @Published private(set) var isInstalling = false
    @Published var deviceIP = UserDefaults.standard.string(forKey: "sidepairLoopbackDeviceIP") ?? "10.7.0.1" {
        didSet { UserDefaults.standard.set(deviceIP, forKey: "sidepairLoopbackDeviceIP") }
    }

    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private var connectionAttempt = UUID()

    var isConnecting: Bool {
        if case .connecting = state { return true }
        return false
    }

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    var isSupportedSystem: Bool {
        if #available(iOS 27.0, *) { return true }
        return false
    }

    var failureMessage: String? {
        if case let .failed(message) = state { return message }
        return nil
    }

    func connect(using pairingFileURL: URL?) {
        guard !isConnecting, !isConnected else { return }
        guard #available(iOS 27.0, *) else {
            state = .failed("This self-pairing tunnel requires iOS 27 or later.")
            return
        }
        guard let pairingFileURL,
              FileManager.default.fileExists(atPath: pairingFileURL.path) else {
            state = .failed("Pair this iPhone first so AquaSign has a Remote Pairing record to use.")
            return
        }

        let ip = deviceIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidIPv4(ip) else {
            state = .failed("Enter the IPv4 Device IP shown in LocalDevVPN settings, such as 10.7.0.1.")
            return
        }

        let attempt = UUID()
        connectionAttempt = attempt
        state = .connecting
        deviceDetails = nil
        let pairingPath = pairingFileURL.path

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result = try Self.openTunnel(deviceIP: ip, pairingFilePath: pairingPath)
                DispatchQueue.main.async {
                    guard let self, self.connectionAttempt == attempt else {
                        Self.close(result)
                        return
                    }
                    self.adapter = result.adapter
                    self.handshake = result.handshake
                    self.deviceDetails = result.details
                    self.state = .connected
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.connectionAttempt == attempt else { return }
                    self.state = .failed(Self.actionableMessage(for: error.localizedDescription))
                }
            }
        }
    }

    func disconnect() {
        guard !isInstalling else { return }
        connectionAttempt = UUID()
        let currentHandshake = handshake
        let currentAdapter = adapter
        handshake = nil
        adapter = nil
        deviceDetails = nil
        state = .disconnected
        Self.close(handshake: currentHandshake, adapter: currentAdapter)
    }

    private static func isValidIPv4(_ value: String) -> Bool {
        var address = in_addr()
        return value.withCString { inet_pton(AF_INET, $0, &address) } == 1
    }

    private static func openTunnel(deviceIP: String, pairingFilePath: String) throws -> RSDConnectionResult {
        var pairingFile: OpaquePointer?
        let readError = pairingFilePath.withCString { rp_pairing_file_read($0, &pairingFile) }
        try check(readError, fallback: "Could not read the saved Remote Pairing record.")
        guard let pairingFile else {
            throw RSDConnectionError.failed("The saved Remote Pairing record is empty or invalid. Pair again and try the new record.")
        }
        defer { rp_pairing_file_free(pairingFile) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(49152).bigEndian
        guard deviceIP.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            throw RSDConnectionError.failed("The Device IP is not a valid IPv4 address.")
        }

        var adapter: OpaquePointer?
        var handshake: OpaquePointer?
        let tunnelError = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                "AquaSign".withCString { hostname in
                    tunnel_create_rppairing(
                        socketAddress,
                        socklen_t(MemoryLayout<sockaddr_in>.stride),
                        hostname,
                        pairingFile,
                        nil,
                        nil,
                        &adapter,
                        &handshake
                    )
                }
            }
        }

        if let tunnelError {
            let message = consume(tunnelError, fallback: "IDEvice could not open the Remote Pairing tunnel.")
            close(handshake: handshake, adapter: adapter)
            throw RSDConnectionError.failed(message)
        }

        guard let adapter, let handshake else {
            close(handshake: handshake, adapter: adapter)
            throw RSDConnectionError.failed("IDEvice returned an incomplete RSD tunnel.")
        }

        do {
            var client: OpaquePointer?
            try check(lockdownd_connect_rsd(adapter, handshake, &client), fallback: "Could not open lockdownd over the RSD tunnel.")
            guard let client else {
                throw RSDConnectionError.failed("The RSD tunnel opened, but the device-information service was unavailable.")
            }
            defer { lockdownd_client_free(client) }

            let details = try readDeviceDetails(client)
            try check(pairingFilePath.withCString { rp_pairing_file_write(pairingFile, $0) }, fallback: "The device connected, but the updated pairing record could not be saved.")
            return RSDConnectionResult(adapter: adapter, handshake: handshake, details: details)
        } catch {
            close(handshake: handshake, adapter: adapter)
            throw error
        }
    }

    private static func readDeviceDetails(_ client: OpaquePointer) throws -> RSDDeviceDetails {
        var values: plist_t?
        try check(lockdownd_get_value(client, nil, nil, &values), fallback: "Could not read device details over RSD.")
        guard let values else {
            throw RSDConnectionError.failed("The device returned no information over RSD.")
        }
        defer { plist_free(values) }

        return RSDDeviceDetails(
            name: plistString(values, "DeviceName") ?? "This iPhone",
            model: plistString(values, "ProductType") ?? "Unknown model",
            version: plistString(values, "ProductVersion") ?? "Unknown iOS version",
            udid: plistString(values, "UniqueDeviceID")
        )
    }

    private static func plistString(_ plist: plist_t, _ key: String) -> String? {
        guard let node = plist_dict_get_item(plist, key) else { return nil }
        var value: UnsafeMutablePointer<CChar>?
        plist_get_string_val(node, &value)
        guard let value else { return nil }
        defer { plist_mem_free(value) }
        return String(cString: value)
    }

    private static func check(_ error: UnsafeMutablePointer<IdeviceFfiError>?, fallback: String) throws {
        if let error {
            throw RSDConnectionError.failed(consume(error, fallback: fallback))
        }
    }

    private static func consume(_ error: UnsafeMutablePointer<IdeviceFfiError>, fallback: String) -> String {
        let message = error.pointee.message.map { String(cString: $0) } ?? fallback
        idevice_error_free(error)
        return message.isEmpty ? fallback : message
    }

    private static func actionableMessage(for message: String) -> String {
        let lowercased = message.lowercased()
        if lowercased.contains("operation not permitted") || lowercased.contains("os error 1") {
            return "iOS blocked the connection to its own VPN address. Check that LocalDevVPN is connected and use its Device IP, not its Connected To address. iOS may also restrict self-tunneling."
        }
        if lowercased.contains("timed out") || lowercased.contains("timeout") {
            return "No response at \(UserDefaults.standard.string(forKey: "sidepairLoopbackDeviceIP") ?? "10.7.0.1"). Connect LocalDevVPN and use the Device IP shown in its settings."
        }
        if lowercased.contains("connection refused") {
            return "The VPN reached the device, but no RSD listener answered. Confirm Developer Mode is enabled, then check LocalDevVPN's Device IP."
        }
        if lowercased.contains("pair") || lowercased.contains("verify") || lowercased.contains("tls") || lowercased.contains("handshake") {
            return "The Remote Pairing record was rejected by the tunnel. Pair this iPhone again and retry with the latest saved pairing record."
        }
        return "Could not connect through LocalDevVPN: \(message)"
    }

    private static func close(_ result: RSDConnectionResult) {
        close(handshake: result.handshake, adapter: result.adapter)
    }

    private static func close(handshake: OpaquePointer?, adapter: OpaquePointer?) {
        if let handshake { rsd_handshake_free(handshake) }
        if let adapter { adapter_free(adapter) }
    }
}

extension RSDConnectionModel {
    func installIPA(
        from ipaURL: URL,
        progress: @escaping @MainActor (Double, String) -> Void
    ) async throws {
        guard isConnected, let adapter, let handshake else {
            throw RSDConnectionError.failed("Connect through LocalDevVPN before installing an IPA.")
        }
        guard !isInstalling else {
            throw RSDConnectionError.failed("Another device operation is already running.")
        }

        isInstalling = true
        defer { isInstalling = false }
        let progressContext = IPAInstallProgressContext { fraction, stage in
            DispatchQueue.main.async { progress(fraction, stage) }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try Self.uploadAndInstall(ipaURL, adapter: adapter, handshake: handshake, progress: progressContext)
                    DispatchQueue.main.async { continuation.resume(returning: ()) }
                } catch {
                    DispatchQueue.main.async { continuation.resume(throwing: error) }
                }
            }
        }
    }

    private static func uploadAndInstall(
        _ ipaURL: URL,
        adapter: OpaquePointer,
        handshake: OpaquePointer,
        progress: IPAInstallProgressContext
    ) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: ipaURL.path)
        guard let fileSize = (attributes[.size] as? NSNumber)?.uint64Value, fileSize > 0 else {
            throw RSDConnectionError.failed("The selected IPA is empty or could not be read.")
        }

        var afcClient: OpaquePointer?
        try check(afc_client_connect_rsd(adapter, handshake, &afcClient), fallback: "Could not open the device file-transfer service over RSD.")
        guard let afcClient else {
            throw RSDConnectionError.failed("The device file-transfer service returned no connection.")
        }
        defer { afc_client_free(afcClient) }

        let remotePath = "/PublicStaging/AquaSign-\(UUID().uuidString).ipa"
        defer {
            if let removeError = remotePath.withCString({ afc_remove_path(afcClient, $0) }) {
                idevice_error_free(removeError)
            }
        }

        let writeMode = AfcFopenMode(rawValue: 3)
        var remoteFile: OpaquePointer?
        try check(remotePath.withCString { afc_file_open(afcClient, $0, writeMode, &remoteFile) }, fallback: "Could not create a staging file on the device.")
        guard let remoteFile else {
            throw RSDConnectionError.failed("The device did not open the IPA staging file.")
        }
        var fileIsOpen = true
        defer {
            if fileIsOpen, let closeError = afc_file_close(remoteFile) {
                idevice_error_free(closeError)
            }
        }

        progress.send(0, "Uploading IPA to iPhone…")
        let input = try FileHandle(forReadingFrom: ipaURL)
        defer { try? input.close() }
        var uploaded: UInt64 = 0
        while true {
            let chunk = try input.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            try check(chunk.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return nil }
                return afc_file_write(remoteFile, baseAddress.assumingMemoryBound(to: UInt8.self), bytes.count)
            }, fallback: "The IPA could not be transferred to the device.")
            uploaded += UInt64(chunk.count)
            progress.send(min(Double(uploaded) / Double(fileSize) * 0.45, 0.45), "Uploading IPA to iPhone…")
        }
        try check(afc_file_close(remoteFile), fallback: "The device could not finish writing the IPA.")
        fileIsOpen = false

        var installationClient: OpaquePointer?
        try check(installation_proxy_connect_rsd(adapter, handshake, &installationClient), fallback: "Could not open the app installation service over RSD.")
        guard let installationClient else {
            throw RSDConnectionError.failed("The app installation service returned no connection.")
        }
        defer { installation_proxy_client_free(installationClient) }

        guard let options: plist_t = plist_new_dict() else {
            throw RSDConnectionError.failed("Could not prepare developer-install options.")
        }
        defer { plist_free(options) }
        guard let packageType = "Developer".withCString({ plist_new_string($0) }) else {
            throw RSDConnectionError.failed("Could not prepare developer-install options.")
        }
        plist_dict_set_item(options, "PackageType", packageType)

        progress.send(0.45, "Installing on iPhone…")
        let context = Unmanaged.passRetained(progress).toOpaque()
        let installError = remotePath.withCString {
            installation_proxy_install_with_callback(
                installationClient,
                $0,
                options,
                ipaInstallProgressCallback,
                context
            )
        }
        Unmanaged<IPAInstallProgressContext>.fromOpaque(context).release()
        try check(installError, fallback: "iOS rejected the signed IPA. Confirm Apple issued a valid profile and the app's required capabilities are allowed for your team.")
        progress.send(1, "Installation complete")
    }
}

private final class IPAInstallProgressContext: @unchecked Sendable {
    private let report: @MainActor (Double, String) -> Void

    init(report: @escaping @MainActor (Double, String) -> Void) {
        self.report = report
    }

    func send(_ fraction: Double, _ stage: String) {
        Task { @MainActor in report(min(max(fraction, 0), 1), stage) }
    }
}

private let ipaInstallProgressCallback: @convention(c) (UInt64, UnsafeMutableRawPointer?) -> Void = { progress, context in
    guard let context else { return }
    let tracker = Unmanaged<IPAInstallProgressContext>.fromOpaque(context).takeUnretainedValue()
    tracker.send(0.45 + min(Double(progress) / 100, 1) * 0.55, "Installing on iPhone…")
}

private struct RSDConnectionResult {
    let adapter: OpaquePointer
    let handshake: OpaquePointer
    let details: RSDDeviceDetails
}

private enum RSDConnectionError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        if case let .failed(message) = self { return message }
        return nil
    }
}
