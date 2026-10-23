import Combine
import Darwin
import Foundation
import IDevice

struct RSDDeviceDetails: Equatable {
    let name: String
    let model: String
    let version: String
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
            state = .failed("Pair this iPhone first so SidePair has a Remote Pairing record to use.")
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
                "SidePair".withCString { hostname in
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
            version: plistString(values, "ProductVersion") ?? "Unknown iOS version"
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
