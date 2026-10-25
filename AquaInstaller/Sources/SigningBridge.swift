import Darwin
import Foundation

struct AppleTrustedNumber: Decodable, Identifiable {
    let numberWithDialCode: String
    let lastTwoDigits: String
    let pushMode: String
    let id: UInt32
}

struct AppleTwoFactorRequest: Decodable {
    let lastError: String?
    let unknown: Bool
    let sms: Bool
    let numbers: [AppleTrustedNumber]
    let selectedNumberId: UInt32?
}

struct AppleTwoFactorPrompt: Identifiable {
    let id = UUID()
    let request: AppleTwoFactorRequest
}

enum SigningBridgeError: LocalizedError {
    case failed(String)
    case certificateRecovery(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            message
        case let .certificateRecovery(message):
            "Apple returned certificate error 7460: \(message) Aqua Installer did not revoke any certificate. Resolve the certificate conflict in AquaSign's confirmed certificate-recovery flow, then try again."
        }
    }
}

private typealias SigningTwoFactorCallback = @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafePointer<CChar>?,
    UnsafeMutablePointer<CChar>?,
    UInt
) -> Int32

@_silgen_name("sidepair_sign_in")
private func sidepair_sign_in(
    _ appleID: UnsafePointer<CChar>,
    _ password: UnsafePointer<CChar>,
    _ storageDirectory: UnsafePointer<CChar>,
    _ bundleID: UnsafePointer<CChar>,
    _ deviceName: UnsafePointer<CChar>,
    _ deviceUDID: UnsafePointer<CChar>,
    _ twoFactorCallback: SigningTwoFactorCallback?,
    _ callbackContext: UnsafeMutableRawPointer?,
    _ outSessionJSON: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    _ outStatusJSON: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    _ outError: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("sidepair_sign_ipa")
private func sidepair_sign_ipa(
    _ sessionJSON: UnsafePointer<CChar>,
    _ storageDirectory: UnsafePointer<CChar>,
    _ ipaPath: UnsafePointer<CChar>,
    _ deviceName: UnsafePointer<CChar>,
    _ deviceUDID: UnsafePointer<CChar>,
    _ outSignedAppPath: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
    _ outError: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> Int32

@_silgen_name("sidepair_signing_string_free")
private func sidepair_signing_string_free(_ value: UnsafeMutablePointer<CChar>?)

private struct CertificateRecoveryInfo: Decodable {
    let message: String
}

private final class TwoFactorResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func set(_ value: String?) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class SigningTwoFactorContext: @unchecked Sendable {
    private let present: @MainActor (String, @escaping (String?) -> Void) -> Void

    init(present: @escaping @MainActor (String, @escaping (String?) -> Void) -> Void) {
        self.present = present
    }

    func waitForAnswer(requestJSON: String) -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        let response = TwoFactorResponseBox()
        Task { @MainActor [present] in
            present(requestJSON) { answer in
                response.set(answer)
                semaphore.signal()
            }
        }
        semaphore.wait()
        return response.get()
    }
}

private let signingTwoFactorCallback: SigningTwoFactorCallback = { context, requestJSON, responseJSON, responseCapacity in
    guard let context, let requestJSON, let responseJSON else { return 0 }
    let handler = Unmanaged<SigningTwoFactorContext>.fromOpaque(context).takeUnretainedValue()
    guard let answer = handler.waitForAnswer(requestJSON: String(cString: requestJSON)) else { return 0 }
    let bytes = Array(answer.utf8) + [0]
    guard bytes.count <= Int(responseCapacity) else { return 0 }
    for (index, byte) in bytes.enumerated() {
        responseJSON[index] = CChar(bitPattern: byte)
    }
    return 1
}

enum SigningBridge {
    static func signIn(
        appleID: String,
        password: String,
        storageDirectory: URL,
        bundleID: String,
        deviceName: String,
        deviceUDID: String,
        presentTwoFactor: @escaping @MainActor (String, @escaping (String?) -> Void) -> Void
    ) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let context = SigningTwoFactorContext(present: presentTwoFactor)
            let retainedContext = Unmanaged.passRetained(context).toOpaque()
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = callSignIn(
                    appleID: appleID,
                    password: password,
                    storageDirectory: storageDirectory.path,
                    bundleID: bundleID,
                    deviceName: deviceName,
                    deviceUDID: deviceUDID,
                    callbackContext: retainedContext
                )
                Unmanaged<SigningTwoFactorContext>.fromOpaque(retainedContext).release()
                DispatchQueue.main.async {
                    switch outcome {
                    case let .success(sessionJSON):
                        continuation.resume(returning: sessionJSON)
                    case let .failure(error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    static func signIPA(
        sessionJSON: String,
        storageDirectory: URL,
        ipaURL: URL,
        deviceName: String,
        deviceUDID: String
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var signedAppOutput: UnsafeMutablePointer<CChar>?
                var errorOutput: UnsafeMutablePointer<CChar>?
                let result = sessionJSON.withCString { sessionPointer in
                    storageDirectory.path.withCString { storagePointer in
                        ipaURL.path.withCString { ipaPointer in
                            deviceName.withCString { deviceNamePointer in
                                deviceUDID.withCString { deviceUDIDPointer in
                                    sidepair_sign_ipa(
                                        sessionPointer,
                                        storagePointer,
                                        ipaPointer,
                                        deviceNamePointer,
                                        deviceUDIDPointer,
                                        &signedAppOutput,
                                        &errorOutput
                                    )
                                }
                            }
                        }
                    }
                }
                let signedAppPath = signedAppOutput.map { String(cString: $0) }
                let errorText = errorOutput.map { String(cString: $0) }
                if let signedAppOutput { sidepair_signing_string_free(signedAppOutput) }
                if let errorOutput { sidepair_signing_string_free(errorOutput) }

                DispatchQueue.main.async {
                    if result == 0, let signedAppPath {
                        continuation.resume(returning: URL(fileURLWithPath: signedAppPath, isDirectory: true))
                    } else {
                        continuation.resume(throwing: SigningBridgeError.failed(
                            errorText ?? "The AquaSign IPA could not be signed with the saved Apple developer session."
                        ))
                    }
                }
            }
        }
    }

    private static func callSignIn(
        appleID: String,
        password: String,
        storageDirectory: String,
        bundleID: String,
        deviceName: String,
        deviceUDID: String,
        callbackContext: UnsafeMutableRawPointer
    ) -> Result<String, Error> {
        var sessionOutput: UnsafeMutablePointer<CChar>?
        var statusOutput: UnsafeMutablePointer<CChar>?
        var errorOutput: UnsafeMutablePointer<CChar>?
        let result = appleID.withCString { accountPointer in
            password.withCString { passwordPointer in
                storageDirectory.withCString { storagePointer in
                    bundleID.withCString { bundlePointer in
                        deviceName.withCString { deviceNamePointer in
                            deviceUDID.withCString { devicePointer in
                                sidepair_sign_in(
                                    accountPointer,
                                    passwordPointer,
                                    storagePointer,
                                    bundlePointer,
                                    deviceNamePointer,
                                    devicePointer,
                                    signingTwoFactorCallback,
                                    callbackContext,
                                    &sessionOutput,
                                    &statusOutput,
                                    &errorOutput
                                )
                            }
                        }
                    }
                }
            }
        }
        let sessionJSON = sessionOutput.map { String(cString: $0) }
        let statusJSON = statusOutput.map { String(cString: $0) }
        let errorText = errorOutput.map { String(cString: $0) }
        if let sessionOutput { sidepair_signing_string_free(sessionOutput) }
        if let statusOutput { sidepair_signing_string_free(statusOutput) }
        if let errorOutput { sidepair_signing_string_free(errorOutput) }

        if result == 0, let sessionJSON {
            return .success(sessionJSON)
        }
        if result == 3 {
            let message = statusJSON
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode(CertificateRecoveryInfo.self, from: $0).message }
                ?? errorText
                ?? "Apple requires an existing development certificate to be resolved."
            return .failure(SigningBridgeError.certificateRecovery(message))
        }
        return .failure(SigningBridgeError.failed(
            errorText ?? "Apple sign-in failed (\(result)). Check the account details and verification response."
        ))
    }
}
