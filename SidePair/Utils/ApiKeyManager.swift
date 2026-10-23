//
//  ApiKeyManager.swift
//  SidePair
//
//  Secure storage for API keys using Keychain Services
//

import Foundation
import Security
import CryptoKit

/// Manages secure storage of API keys in Keychain
class ApiKeyManager {
    
    // MARK: - Singleton
    
    static let shared = ApiKeyManager()
    
    private init() {
        // Initialize keys from encrypted file on first launch
        UserDefaults.standard.removeObject(forKey: initializationKey)
        initializeKeysFromEncryptedFile()
    }
    
    // MARK: - Properties
    
    // Use the app's bundle identifier as the service name
    private var service: String {
        return Bundle.main.bundleIdentifier ?? "com.projectname.apiKeys"
    }
    
    // UserDefaults key to track initialization
    private let initializationKey = "ApiKeyManager_Initialized"
    
    // Get project name from bundle (should match what Swifty used for encryption)
    private var projectName: String {
        // Try to get from bundle identifier or use a default
        if let bundleId = Bundle.main.bundleIdentifier {
            // Extract project name from bundle ID (e.g., "com.example.MyApp" -> "MyApp")
            let components = bundleId.components(separatedBy: ".")
            return components.last ?? "SidePair"
        }
        return "SidePair"
    }
    
    // MARK: - Public Methods
    
    /// Retrieve an API key from Keychain
    /// - Parameter key: The key name (e.g., "OPENAI_API_KEY")
    /// - Returns: The API key value, or nil if not found
    func get(key: String) -> String? {
        print("calling get")
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecSuccess,
           let data = result as? Data,
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        
        return nil
    }
    
    /// Check if an API key exists in Keychain
    /// - Parameter key: The key name
    /// - Returns: True if the key exists, false otherwise
    func has(key: String) -> Bool {
        return get(key: key) != nil
    }
    
    // MARK: - Private Methods
    
    /// Initializes API keys from encrypted file on first launch
    private func initializeKeysFromEncryptedFile() {
        // Check if already initialized
        if UserDefaults.standard.bool(forKey: initializationKey) {
            print("ApiKeyManager: Already initialized, skipping")
            return
        }
        
        print("ApiKeyManager: Starting initialization")
        print("ApiKeyManager: Project name = \(projectName)")
        
        // Read encrypted plist from bundle
        guard let bundlePath = Bundle.main.path(forResource: "ENCRYPTED_KEYS", ofType: "plist") else {
            print("ApiKeyManager: ENCRYPTED_KEYS.plist not found in bundle")
            UserDefaults.standard.set(true, forKey: initializationKey)
            return
        }
        
        print("ApiKeyManager: Found plist at \(bundlePath)")
        
        guard let plistData = try? Data(contentsOf: URL(fileURLWithPath: bundlePath)) else {
            print("ApiKeyManager: Failed to read plist data")
            UserDefaults.standard.set(true, forKey: initializationKey)
            return
        }
        
        print("ApiKeyManager: Plist data size = \(plistData.count) bytes")
        
        // Try to see what format it is
        if let plistString = String(data: plistData, encoding: .utf8) {
            print("ApiKeyManager: Plist content (first 500 chars): \(String(plistString.prefix(500)))")
        }
        
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
            print("ApiKeyManager: Failed to parse plist as [String: Any] - trying to see what we got")
            if let anyPlist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) {
                print("ApiKeyManager: Parsed as: \(type(of: anyPlist))")
                print("ApiKeyManager: Value: \(anyPlist)")
            } else {
                print("ApiKeyManager: Failed to parse plist at all")
            }
            UserDefaults.standard.set(true, forKey: initializationKey)
            return
        }
        
        print("ApiKeyManager: Found \(plist.count) keys in plist")
        print("ApiKeyManager: Keys: \(Array(plist.keys))")
        
        // Decrypt each value and store in Keychain
        var successCount = 0
        for (key, encryptedValue) in plist {
            print("ApiKeyManager: Processing key '\(key)'")
            print("ApiKeyManager: Encrypted value type: \(type(of: encryptedValue))")
            
            guard let encryptedString = encryptedValue as? String else {
                print("ApiKeyManager: Key '\(key)' has invalid type: \(type(of: encryptedValue))")
                continue
            }
            
            print("ApiKeyManager: Encrypted string length: \(encryptedString.count)")
            print("ApiKeyManager: Decrypting key '\(key)'...")
            
            guard let decryptedValue = decryptValue(encryptedString, projectName: projectName) else {
                print("ApiKeyManager: Failed to decrypt key '\(key)'")
                continue
            }
            
            print("ApiKeyManager: Successfully decrypted key '\(key)', length: \(decryptedValue.count)")
            
            if save(key: key, value: decryptedValue) {
                print("ApiKeyManager: Successfully stored key '\(key)' in Keychain")
                successCount += 1
            } else {
                print("ApiKeyManager: Failed to save key '\(key)' to Keychain")
            }
        }
        
        print("ApiKeyManager: Initialized \(successCount) out of \(plist.count) keys")
        
        // Mark as initialized
        UserDefaults.standard.set(true, forKey: initializationKey)
    }
    
    /// Save an API key to Keychain
    /// - Parameters:
    ///   - key: The key name
    ///   - value: The API key value
    /// - Returns: True if successful, false otherwise
    private func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else {
            return false
        }
        
        // Delete existing item first (if any)
        delete(key: key)
        
        // Create query for saving
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }
    
    /// Delete an API key from Keychain
    /// - Parameter key: The key name
    /// - Returns: True if successful, false otherwise
    private func delete(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
    
    /// Decrypts an encrypted API key value
    /// - Parameters:
    ///   - encryptedValue: Base64-encoded encrypted string
    ///   - projectName: Project name used to derive decryption key
    /// - Returns: Decrypted API key value, or nil if decryption fails
    private func decryptValue(_ encryptedValue: String, projectName: String) -> String? {
        // Decode from base64
        guard let encryptedData = Data(base64Encoded: encryptedValue) else {
            print("ApiKeyManager: Failed to decode base64 for value")
            return nil
        }
        
        print("ApiKeyManager: Decoded base64, data size: \(encryptedData.count) bytes")
        
        // Derive decryption key from project name
        let decryptionKey = deriveKey(from: projectName)
        
        // Create sealed box from combined data (nonce + ciphertext + tag)
        guard let sealedBox = try? AES.GCM.SealedBox(combined: encryptedData) else {
            print("ApiKeyManager: Failed to create sealed box from encrypted data")
            return nil
        }
        
        // Decrypt
        do {
            let decryptedData = try AES.GCM.open(sealedBox, using: decryptionKey)
            let decryptedString = String(data: decryptedData, encoding: .utf8)
            print("ApiKeyManager: Decryption successful, decrypted length: \(decryptedString?.count ?? 0)")
            return decryptedString
        } catch {
            print("ApiKeyManager: Decryption error: \(error.localizedDescription)")
            return nil
        }
    }
    
    /// Derives a symmetric key from project name using SHA256
    /// - Parameter projectName: Project name
    /// - Returns: Symmetric key for encryption/decryption
    private func deriveKey(from projectName: String) -> SymmetricKey {
        // Use SHA256 hash of project name as key material
        let keyData = SHA256.hash(data: projectName.data(using: .utf8) ?? Data())
        return SymmetricKey(data: keyData)
    }
}