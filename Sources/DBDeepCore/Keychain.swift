import Foundation
import Security

public enum PasswordKeychain {
    private static let service = "studio.dbdbdeep.oracle"

    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    public static func save(_ password: String, for id: UUID) throws {
        let item = query(id)
        let data = Data(password.utf8)
        var status = SecItemUpdate(item as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = item
            newItem[kSecValueData as String] = data
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(newItem as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw DatabaseError("키체인 저장 실패 (\(status))") }
    }

    public static func read(for id: UUID) throws -> String {
        var item = query(id)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
            throw DatabaseError("저장된 비밀번호가 없습니다. 연결을 편집해 비밀번호를 입력해 주세요.")
        }
        return password
    }

    public static func delete(for id: UUID) { SecItemDelete(query(id) as CFDictionary) }
}
