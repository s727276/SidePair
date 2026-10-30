import Foundation

struct PairedDevice: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var model: String
    var deviceIP: String
    var udid: String?
    var pairingFileName: String

    var pairingFileURL: URL {
        PairedDeviceStorage.pairingFileURL(named: pairingFileName)
    }
}

enum PairedDeviceStorage {
    static let devicesKey = "sidepairPairedDevices"
    static let selectedDeviceIDKey = "sidepairSelectedPairedDeviceID"
    static let legacyPairingFileName = "pairingFile.plist"

    static var legacyPairingFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SidePair", isDirectory: true)
            .appendingPathComponent(legacyPairingFileName)
    }

    static var recordsDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SidePair", isDirectory: true)
            .appendingPathComponent("PairedDevices", isDirectory: true)
    }

    static func pairingFileURL(for id: UUID) -> URL {
        recordsDirectoryURL.appendingPathComponent("\(id.uuidString).plist")
    }

    static func pairingFileURL(named fileName: String) -> URL {
        if fileName == legacyPairingFileName {
            return legacyPairingFileURL
        }
        return recordsDirectoryURL.appendingPathComponent(fileName)
    }

    static func loadDevices() -> [PairedDevice]? {
        guard let data = UserDefaults.standard.data(forKey: devicesKey) else { return nil }
        return try? JSONDecoder().decode([PairedDevice].self, from: data)
    }

    static func saveDevices(_ devices: [PairedDevice]) {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        UserDefaults.standard.set(data, forKey: devicesKey)
    }
}
