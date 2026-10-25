import Foundation

struct ConnectedUSBDevice: Hashable, Identifiable, Sendable {
    let coreDeviceIdentifier: String
    let udid: String
    let name: String
    let osVersion: String

    var id: String { udid }
}

enum DeviceCtlError: LocalizedError {
    case toolUnavailable(String)
    case commandFailed(String)
    case noWiredDevices
    case unreadableDeviceList
    case invalidIPA(String)
    case wrongApp(String)

    var errorDescription: String? {
        switch self {
        case let .toolUnavailable(message):
            "Aqua Installer could not run Apple's device tools. Install Xcode, select it as the active developer directory, and try again. \(message)"
        case let .commandFailed(message):
            message
        case .noWiredDevices:
            "No paired iPhone was found over USB. Connect it by cable, unlock it, and accept the Trust This Computer prompt."
        case .unreadableDeviceList:
            "Apple's device tools returned an unsupported device list. Update Xcode and scan again."
        case let .invalidIPA(message):
            message
        case let .wrongApp(bundleIdentifier):
            "This IPA contains '\(bundleIdentifier)', not AquaSign (com.Andrewdev.aquasign). Choose the AquaSign IPA from GitHub Actions."
        }
    }
}

enum DeviceCtl {
    private struct CommandResult {
        let status: Int32
        let output: Data
        let errorOutput: Data

        var outputText: String { String(decoding: output, as: UTF8.self) }
        var errorText: String { String(decoding: errorOutput, as: UTF8.self) }
    }

    static func discoverWiredDevices() throws -> [ConnectedUSBDevice] {
        let listURL = temporaryJSONURL()
        defer { try? FileManager.default.removeItem(at: listURL) }

        let listResult = try runXcrun(["devicectl", "list", "devices", "--json-output", listURL.path])
        guard listResult.status == 0 else {
            throw DeviceCtlError.commandFailed(actionableMessage(from: listResult.errorText + listResult.outputText))
        }
        guard let data = try? Data(contentsOf: listURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let rawDevices = result["devices"] as? [[String: Any]] else {
            throw DeviceCtlError.unreadableDeviceList
        }

        var devices: [ConnectedUSBDevice] = []
        for rawDevice in rawDevices {
            let platform = string(in: rawDevice, paths: [
                ["properties", "hardware", "platform"],
                ["hardwareProperties", "platform"],
                ["properties", "platform"],
            ]) ?? recursiveString(in: rawDevice, key: "platform") ?? ""
            guard platform.localizedCaseInsensitiveContains("ios") || platform.localizedCaseInsensitiveContains("iphone") else { continue }

            let transport = string(in: rawDevice, paths: [
                ["properties", "connection", "transportType"],
                ["properties", "connectionProperties", "transportType"],
                ["connectionProperties", "transportType"],
            ]) ?? recursiveString(in: rawDevice, key: "transportType") ?? ""
            guard transport.caseInsensitiveCompare("wired") == .orderedSame
                    || transport.caseInsensitiveCompare("usb") == .orderedSame else { continue }

            guard let coreDeviceIdentifier = rawDevice["identifier"] as? String, !coreDeviceIdentifier.isEmpty else { continue }
            let listedUDID = string(in: rawDevice, paths: [
                ["properties", "hardware", "udid"],
                ["hardwareProperties", "udid"],
                ["properties", "udid"],
            ])
            let udid = listedUDID ?? (try? deviceUDID(for: coreDeviceIdentifier))
            guard let udid, !udid.isEmpty else { continue }

            let name = string(in: rawDevice, paths: [
                ["properties", "deviceProperties", "name"],
                ["deviceProperties", "name"],
                ["properties", "name"],
            ]) ?? "iPhone"
            let osVersion = string(in: rawDevice, paths: [
                ["properties", "deviceProperties", "osVersionNumber"],
                ["deviceProperties", "osVersionNumber"],
                ["properties", "osVersionNumber"],
            ]) ?? "Unknown iOS"

            devices.append(ConnectedUSBDevice(
                coreDeviceIdentifier: coreDeviceIdentifier,
                udid: udid,
                name: name,
                osVersion: osVersion
            ))
        }
        return devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func bundleIdentifier(in ipaURL: URL) throws -> String {
        let listing = try runExecutable(URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-Z1", ipaURL.path])
        guard listing.status == 0 else {
            throw DeviceCtlError.invalidIPA("The selected file is not a readable IPA. Choose the unsigned AquaSign IPA artifact.")
        }
        let infoPaths = listing.outputText
            .components(separatedBy: .newlines)
            .filter { path in
                let components = path.split(separator: "/")
                return components.count == 3
                    && components[0] == "Payload"
                    && components[1].hasSuffix(".app")
                    && components[2] == "Info.plist"
            }
        guard infoPaths.count == 1, let infoPath = infoPaths.first else {
            throw DeviceCtlError.invalidIPA("The IPA must contain exactly one app bundle with an Info.plist in Payload.")
        }

        let plistResult = try runExecutable(URL(fileURLWithPath: "/usr/bin/unzip"), arguments: ["-p", ipaURL.path, infoPath])
        guard plistResult.status == 0,
              let plist = try? PropertyListSerialization.propertyList(from: plistResult.output, options: [], format: nil) as? [String: Any],
              let bundleIdentifier = plist["CFBundleIdentifier"] as? String,
              !bundleIdentifier.isEmpty else {
            throw DeviceCtlError.invalidIPA("Aqua Installer could not read the app's bundle identifier from the IPA.")
        }
        return bundleIdentifier
    }

    static func install(appBundleURL: URL, on device: ConnectedUSBDevice) throws {
        let result = try runXcrun([
            "devicectl", "device", "install", "app",
            "--device", device.udid,
            appBundleURL.path,
        ])
        guard result.status == 0 else {
            throw DeviceCtlError.commandFailed(actionableMessage(from: result.errorText + result.outputText))
        }
    }

    private static func deviceUDID(for coreDeviceIdentifier: String) throws -> String? {
        let detailsURL = temporaryJSONURL()
        defer { try? FileManager.default.removeItem(at: detailsURL) }
        let result = try runXcrun([
            "devicectl", "device", "info", "details",
            "--device", coreDeviceIdentifier,
            "--json-output", detailsURL.path,
        ])
        guard result.status == 0,
              let data = try? Data(contentsOf: detailsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let commandResult = root["result"] as? [String: Any] else { return nil }
        return string(in: commandResult, paths: [
            ["properties", "hardware", "udid"],
            ["hardwareProperties", "udid"],
            ["properties", "udid"],
        ]) ?? recursiveString(in: commandResult, key: "udid")
    }

    private static func temporaryJSONURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AquaInstaller-\(UUID().uuidString).json")
    }

    private static func string(in dictionary: [String: Any], paths: [[String]]) -> String? {
        for path in paths {
            var value: Any = dictionary
            var found = true
            for component in path {
                guard let nested = value as? [String: Any], let next = nested[component] else {
                    found = false
                    break
                }
                value = next
            }
            if found, let string = value as? String, !string.isEmpty { return string }
        }
        return nil
    }

    private static func recursiveString(in value: Any, key: String) -> String? {
        if let dictionary = value as? [String: Any] {
            for (candidate, nested) in dictionary where candidate.caseInsensitiveCompare(key) == .orderedSame {
                if let string = nested as? String, !string.isEmpty { return string }
            }
            for nested in dictionary.values {
                if let string = recursiveString(in: nested, key: key) { return string }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let string = recursiveString(in: nested, key: key) { return string }
            }
        }
        return nil
    }

    private static func actionableMessage(from output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercase = trimmed.lowercased()
        if lowercase.contains("developer mode") {
            return "Enable Developer Mode on the iPhone in Settings → Privacy & Security → Developer Mode, then retry. \(trimmed)"
        }
        if lowercase.contains("trust") || lowercase.contains("pair") || lowercase.contains("unlock") {
            return "Unlock the iPhone, accept the Trust This Computer prompt, and pair it with this Mac before retrying. \(trimmed)"
        }
        if trimmed.isEmpty {
            return "Apple's device tools could not complete the operation. Confirm Xcode Command Line Tools are installed and the iPhone is connected by USB."
        }
        return "Apple's device tools could not complete the operation: \(trimmed)"
    }

    private static func runXcrun(_ arguments: [String]) throws -> CommandResult {
        try runExecutable(URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: arguments)
    }

    private static func runExecutable(_ executable: URL, arguments: [String]) throws -> CommandResult {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("AquaInstaller-out-\(UUID().uuidString)")
        let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent("AquaInstaller-err-\(UUID().uuidString)")
        _ = FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        _ = FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }

        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            outputHandle.closeFile()
            errorHandle.closeFile()
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw DeviceCtlError.toolUnavailable(error.localizedDescription)
        }
        process.waitUntilExit()
        outputHandle.synchronizeFile()
        errorHandle.synchronizeFile()
        return CommandResult(
            status: process.terminationStatus,
            output: (try? Data(contentsOf: outputURL)) ?? Data(),
            errorOutput: (try? Data(contentsOf: errorURL)) ?? Data()
        )
    }
}
