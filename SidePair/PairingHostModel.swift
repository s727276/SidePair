import Combine
import Foundation
import IDevice
import Darwin
import UIKit
import UserNotifications

enum PairingState: Equatable {
    case ready
    case preparing
    case waiting
    case connecting
    case pin(String)
    case paired
    case failed(String)
}

@MainActor
final class PairingHostModel: NSObject, ObservableObject, NetServiceDelegate, UNUserNotificationCenterDelegate {
    @Published private(set) var state: PairingState = .ready
    @Published private(set) var pairingFileURL: URL?
    @Published private(set) var deviceName: String?
    @Published private(set) var deviceModel: String?
    @Published private(set) var devices: [PairedDevice] = []
    @Published private(set) var selectedDeviceID: UUID?

    private var currentSession = UUID()
    private var activeSocket: PairingSocketState?
    private var netService: NetService?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var cachedHost: PreparedHost?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        restorePairedDevices()
    }

    var selectedDevice: PairedDevice? {
        guard let selectedDeviceID else { return nil }
        return devices.first { $0.id == selectedDeviceID }
    }

    var isBusy: Bool {
        switch state {
        case .preparing, .waiting, .connecting, .pin:
            true
        case .ready, .paired, .failed:
            false
        }
    }

    var isSupportedSystem: Bool {
        if #available(iOS 27.0, *) { return true }
        return false
    }

    func selectDevice(_ id: UUID) {
        guard devices.contains(where: { $0.id == id }) else { return }
        selectedDeviceID = id
        UserDefaults.standard.set(id.uuidString, forKey: PairedDeviceStorage.selectedDeviceIDKey)
        refreshSelectedDevice()
    }

    func updateDeviceIP(_ deviceIP: String, for id: UUID) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[index].deviceIP = deviceIP
        PairedDeviceStorage.saveDevices(devices)
    }

    func startPairing() {
        guard !isBusy else { return }
        guard isSupportedSystem else {
            state = .failed("Remote Pairing host setup requires iOS 27 or later.")
            return
        }

        state = .preparing
        Task {
            do {
                let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                guard state == .preparing else { return }
                guard allowed else {
                    state = .failed("Allow notifications so AquaSign can show the pairing code while you confirm it in Settings.")
                    return
                }
            } catch {
                state = .failed("AquaSign couldn't request notification access for the pairing code.")
                return
            }
            guard state == .preparing else { return }
            beginPairingRun()
        }
    }

    func stopPairing() {
        guard isBusy else { return }
        currentSession = UUID()
        netService?.stop()
        netService = nil
        activeSocket?.close()
        activeSocket = nil
        endBackgroundTask()
        state = .ready
    }

    private func beginPairingRun() {
        let session = UUID()
        let recordID = UUID()
        currentSession = session
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "AquaSign Remote Pairing") { [weak self] in
            Task { @MainActor in self?.stopPairing() }
        }

        let existingHost = cachedHost
        let pinContext = PairingPINContext { [weak self] pin in
            DispatchQueue.main.async {
                self?.receivedPIN(pin, session: session)
            }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let host = try existingHost ?? Self.prepareHost()
                let listener = try Self.makeListener()
                let socket = PairingSocketState(listenerFD: listener.fd)

                DispatchQueue.main.async { [weak self] in
                    guard let self, self.currentSession == session else {
                        socket.close()
                        if existingHost == nil { pairable_host_free(host.handle) }
                        return
                    }

                    if existingHost == nil { self.cachedHost = host }
                    self.activeSocket = socket
                    let service = NetService(
                        domain: "local.",
                        type: "_remotepairing-pairable-host._tcp.",
                        name: host.serviceID,
                        port: Int32(listener.port)
                    )
                    service.delegate = self
                    service.setTXTRecord(NetService.data(fromTXTRecord: host.txtRecords))
                    self.netService = service
                    service.publish()
                    self.state = .waiting

                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        Self.acceptDevice(
                            socket: socket,
                            host: host,
                            pinContext: pinContext,
                            session: session,
                            recordID: recordID
                        ) { result in
                            DispatchQueue.main.async {
                                self?.finish(result, session: session)
                            }
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.finish(.failed(error.localizedDescription), session: session)
                }
            }
        }
    }

    func netServiceDidPublish(_ sender: NetService) {
        guard sender === netService, state == .waiting else { return }
        state = .waiting
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        guard sender === netService else { return }
        let code = errorDict[NetService.errorCode]?.intValue ?? -1
        finish(.failed("Could not advertise the pairing service (Bonjour error \(code)). Check Local Network access in Settings and try again."), session: currentSession)
    }

    private func receivedPIN(_ pin: String, session: UUID) {
        guard currentSession == session else { return }
        state = .pin(pin)

        let content = UNMutableNotificationContent()
        content.title = "AquaSign pairing code"
        content.body = "Your code is \(pin). Enter it in Developer Mode settings."
        content.sound = .default
        content.threadIdentifier = "sidepair-pairing"
        let request = UNNotificationRequest(identifier: "sidepair-pairing-pin", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    private func finish(_ result: PairingRunResult, session: UUID) {
        guard currentSession == session else { return }
        netService?.stop()
        netService = nil
        activeSocket?.close()
        activeSocket = nil
        endBackgroundTask()

        switch result {
        case let .paired(id, url, name, model, udid):
            let previousDevice = udid.flatMap { deviceID in devices.first { $0.udid == deviceID } }
            let shouldSelectDevice = selectedDeviceID == nil || previousDevice?.id == selectedDeviceID
            if let previousDevice {
                devices.removeAll { $0.id == previousDevice.id }
                if previousDevice.pairingFileURL != url {
                    try? FileManager.default.removeItem(at: previousDevice.pairingFileURL)
                }
            }

            let device = PairedDevice(
                id: id,
                name: name,
                model: model,
                deviceIP: previousDevice?.deviceIP ?? "",
                udid: udid,
                pairingFileName: url.lastPathComponent
            )
            devices.insert(device, at: 0)
            PairedDeviceStorage.saveDevices(devices)
            if shouldSelectDevice {
                selectedDeviceID = device.id
                UserDefaults.standard.set(device.id.uuidString, forKey: PairedDeviceStorage.selectedDeviceIDKey)
                refreshSelectedDevice()
            }
            UserDefaults.standard.set(name, forKey: "pairedDeviceName")
            UserDefaults.standard.set(model, forKey: "pairedDeviceModel")
            state = .paired
        case let .failed(message):
            state = .failed(message)
        case .stopped:
            if isBusy { state = .ready }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func restorePairedDevices() {
        let defaults = UserDefaults.standard
        devices = (PairedDeviceStorage.loadDevices() ?? []).filter {
            FileManager.default.fileExists(atPath: $0.pairingFileURL.path)
        }

        if devices.isEmpty {
            let legacyURL = PairedDeviceStorage.legacyPairingFileURL
            if FileManager.default.fileExists(atPath: legacyURL.path),
               let size = try? FileManager.default.attributesOfItem(atPath: legacyURL.path)[.size] as? Int,
               size > 0 {
                let device = PairedDevice(
                    id: UUID(),
                    name: defaults.string(forKey: "pairedDeviceName") ?? "This iPhone",
                    model: defaults.string(forKey: "pairedDeviceModel") ?? "iPhone",
                    deviceIP: defaults.string(forKey: "sidepairLoopbackDeviceIP") ?? "10.7.0.1",
                    udid: nil,
                    pairingFileName: PairedDeviceStorage.legacyPairingFileName
                )
                devices = [device]
                PairedDeviceStorage.saveDevices(devices)
            }
        }

        let storedID = defaults.string(forKey: PairedDeviceStorage.selectedDeviceIDKey).flatMap(UUID.init(uuidString:))
        selectedDeviceID = storedID.flatMap { id in devices.contains(where: { $0.id == id }) ? id : nil }
            ?? devices.first?.id
        if let selectedDeviceID {
            defaults.set(selectedDeviceID.uuidString, forKey: PairedDeviceStorage.selectedDeviceIDKey)
            refreshSelectedDevice()
            state = .paired
        } else {
            defaults.removeObject(forKey: PairedDeviceStorage.selectedDeviceIDKey)
        }
    }

    private func refreshSelectedDevice() {
        guard let selectedDevice else {
            pairingFileURL = nil
            deviceName = nil
            deviceModel = nil
            return
        }
        pairingFileURL = selectedDevice.pairingFileURL
        deviceName = selectedDevice.name
        deviceModel = selectedDevice.model
    }

    private static func prepareHost() throws -> PreparedHost {
        var handle: OpaquePointer?
        var serviceID: UnsafeMutablePointer<CChar>?
        var txtData: UnsafeMutablePointer<UInt8>?
        var txtLength: UInt = 0
        var hostAltIRK = [UInt8](repeating: 0, count: 16)

        let error = "AquaSign".withCString { name in
            "Mac17,7".withCString { model in
                hostAltIRK.withUnsafeMutableBufferPointer { altIRK in
                    pairable_host_prepare(
                        name,
                        model,
                        false,
                        &handle,
                        &serviceID,
                        &txtData,
                        &txtLength,
                        altIRK.baseAddress
                    )
                }
            }
        }

        if let error {
            let message = error.pointee.message.map { String(cString: $0) } ?? "IDEvice could not prepare a pairing host."
            idevice_error_free(error)
            throw PairingHostError.failed(message)
        }

        guard let handle, let serviceID, let txtData, txtLength > 0 else {
            if let handle { pairable_host_free(handle) }
            if let serviceID { idevice_string_free(serviceID) }
            if let txtData { idevice_data_free(txtData, txtLength) }
            throw PairingHostError.failed("IDEvice returned incomplete pairing-host data.")
        }
        defer {
            idevice_string_free(serviceID)
            idevice_data_free(txtData, txtLength)
        }

        let recordsData = Data(bytes: txtData, count: Int(txtLength))
        guard let propertyList = try PropertyListSerialization.propertyList(from: recordsData, options: [], format: nil) as? [String: String] else {
            pairable_host_free(handle)
            throw PairingHostError.failed("IDEvice returned invalid Bonjour records.")
        }
        let records = propertyList.mapValues { Data($0.utf8) }
        return PreparedHost(handle: handle, serviceID: String(cString: serviceID), txtRecords: records)
    }

    private static func makeListener() throws -> (fd: Int32, port: UInt16) {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PairingHostError.failed("Could not open a local network socket.") }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: in_addr_t(0))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw PairingHostError.failed("Could not bind the pairing socket.")
        }

        var actualAddress = sockaddr_in()
        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let addressResult = withUnsafeMutablePointer(to: &actualAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &addressLength)
            }
        }
        guard addressResult == 0, Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw PairingHostError.failed("Could not start the pairing listener.")
        }

        return (fd, UInt16(bigEndian: actualAddress.sin_port))
    }

    private static func acceptDevice(
        socket: PairingSocketState,
        host: PreparedHost,
        pinContext: PairingPINContext,
        session: UUID,
        recordID: UUID,
        completion: @escaping (PairingRunResult) -> Void
    ) {
        guard let clientFD = socket.acceptConnection() else {
            completion(.stopped)
            return
        }

        var peer: UnsafeMutablePointer<RpPairingPeerDeviceC>?
        var pairingFile: OpaquePointer?
        let context = Unmanaged.passRetained(pinContext).toOpaque()
        let error = pairable_host_accept_fd(
            host.handle,
            clientFD,
            pairingPINCallback,
            context,
            &peer,
            &pairingFile
        )
        Unmanaged<PairingPINContext>.fromOpaque(context).release()
        defer {
            if let peer { rppairing_peer_device_free(peer) }
            if let pairingFile { rp_pairing_file_free(pairingFile) }
        }

        if let error {
            let message = error.pointee.message.map { String(cString: $0) } ?? "Remote Pairing failed."
            idevice_error_free(error)
            completion(.failed(message))
            return
        }

        guard let pairingFile else {
            completion(.failed("IDEvice completed pairing without a pairing record."))
            return
        }

        var pairingBytes: UnsafeMutablePointer<UInt8>?
        var pairingLength: UInt = 0
        if let error = rp_pairing_file_to_bytes(pairingFile, &pairingBytes, &pairingLength) {
            let message = error.pointee.message.map { String(cString: $0) } ?? "Could not serialize the pairing record."
            idevice_error_free(error)
            completion(.failed(message))
            return
        }
        guard let pairingBytes, pairingLength > 0 else {
            completion(.failed("IDEvice returned an empty pairing record."))
            return
        }
        defer { idevice_data_free(pairingBytes, pairingLength) }

        do {
            let data = Data(bytes: pairingBytes, count: Int(pairingLength))
            let url = PairedDeviceStorage.pairingFileURL(for: recordID)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            let name = peer?.pointee.name.map { String(cString: $0) } ?? "This iPhone"
            let model = peer?.pointee.model.map { String(cString: $0) } ?? "iPhone"
            completion(.paired(id: recordID, url: url, name: name, model: model, udid: nil))
        } catch {
            completion(.failed("Could not save the pairing record: \(error.localizedDescription)"))
        }
    }
}

private struct PreparedHost {
    let handle: OpaquePointer
    let serviceID: String
    let txtRecords: [String: Data]
}

private enum PairingRunResult {
    case paired(id: UUID, url: URL, name: String, model: String, udid: String?)
    case failed(String)
    case stopped
}

private enum PairingHostError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        if case let .failed(message) = self { return message }
        return nil
    }
}

private final class PairingPINContext: @unchecked Sendable {
    let deliver: (String) -> Void
    init(deliver: @escaping (String) -> Void) { self.deliver = deliver }
}

private let pairingPINCallback: PairableHostPinCb = { pin, context in
    guard let pin, let context else { return }
    let callback = Unmanaged<PairingPINContext>.fromOpaque(context).takeUnretainedValue()
    callback.deliver(String(cString: pin))
}

private final class PairingSocketState: @unchecked Sendable {
    private let lock = NSLock()
    private var listenerFD: Int32
    private var connectionFD: Int32 = -1
    private var closed = false

    init(listenerFD: Int32) { self.listenerFD = listenerFD }

    func acceptConnection() -> Int32? {
        lock.lock()
        let fd = listenerFD
        let alreadyClosed = closed
        lock.unlock()
        guard fd >= 0, !alreadyClosed else { return nil }

        var address = sockaddr()
        var addressLength = socklen_t(MemoryLayout<sockaddr>.size)
        let connection = withUnsafeMutablePointer(to: &address) {
            Darwin.accept(fd, $0, &addressLength)
        }
        guard connection >= 0 else { return nil }

        lock.lock()
        if closed {
            lock.unlock()
            Darwin.close(connection)
            return nil
        }
        connectionFD = connection
        lock.unlock()
        return connection
    }

    func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let listener = listenerFD
        let connection = connectionFD
        listenerFD = -1
        connectionFD = -1
        lock.unlock()

        if connection >= 0 {
            Darwin.shutdown(connection, SHUT_RDWR)
            Darwin.close(connection)
        }
        if listener >= 0 {
            Darwin.shutdown(listener, SHUT_RDWR)
            Darwin.close(listener)
        }
    }
}
