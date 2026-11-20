import Foundation
import Combine
import Security

struct SavedConnection: Codable, Identifiable {
    var id: UUID
    var options: ConnectionOptionsForStorage
    var savedTicket: Bool
}
// Persistent profiles deliberately do not contain passwords or inline CA blobs.
struct ConnectionOptionsForStorage: Codable {
    var host: String
    var port: Int?
    var tlsPort: Int?
    var caFile: String?
    var subject: String?
    var proxy: String?
    var insecure: Bool
}
@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [SavedConnection] = []
    private let defaults = UserDefaults.standard
    init() {
        if let data = defaults.data(forKey: "connections"), data.count <= 1_048_576,
           let decoded = try? JSONDecoder().decode([SavedConnection].self, from: data) { profiles = Array(decoded.prefix(30)) }
    }
    func save(_ options: ConnectionOptionsForStorage, ticket: String?) throws {
        let existing = profiles.first { $0.options.host == options.host && $0.options.port == options.port && $0.options.tlsPort == options.tlsPort }
        let id = existing?.id ?? UUID()
        if let ticket { try CredentialStore.save(ticket, account: id.uuidString) }
        else { CredentialStore.remove(account: id.uuidString) }
        profiles.removeAll { $0.id == id }
        profiles.insert(SavedConnection(id: id, options: options, savedTicket: ticket != nil), at: 0)
        for discarded in profiles.dropFirst(30) { CredentialStore.remove(account: discarded.id.uuidString) }
        profiles = Array(profiles.prefix(30)); persist()
    }
    func remove(_ id: UUID) { CredentialStore.remove(account: id.uuidString); profiles.removeAll { $0.id == id }; persist() }
    private func persist() { if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: "connections") } }
}
enum CredentialStore {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"org.spice4mac.client",kSecAttrAccount as String:account]
    }
    static func save(_ ticket:String,account:String) throws {
        let q=query(account), attributes=[kSecValueData as String:Data(ticket.utf8)]
        var status=SecItemUpdate(q as CFDictionary,attributes as CFDictionary)
        if status==errSecItemNotFound {
            var item=q;item.merge(attributes){_,new in new};item[kSecAttrAccessible as String]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status=SecItemAdd(item as CFDictionary,nil)
        }
        if status != errSecSuccess {throw NSError(domain:NSOSStatusErrorDomain,code:Int(status),userInfo:[NSLocalizedDescriptionKey:"Could not save the ticket in Keychain."])}
    }
    static func load(account:String)->String? {
        var q=query(account);q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
        var item:CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary,&item)==errSecSuccess,let data=item as? Data else{return nil}
        return String(data:data,encoding:.utf8)
    }
    static func remove(account:String){SecItemDelete(query(account) as CFDictionary)}
}
