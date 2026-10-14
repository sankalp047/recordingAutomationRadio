import Foundation
import Observation

/// Sign-in and role for the FunAsia admin side of the app.
///
/// Uses the Firebase REST endpoints rather than the Firebase SDK: the SDK's
/// Auth component needs the restricted `keychain-access-groups` entitlement,
/// which requires a paid Apple Developer team. See FirebaseREST for detail.
@MainActor
@Observable
final class AdminSession {
    enum Role: String, Codable {
        case user, admin, superadmin
        var canOpenAdmin: Bool { self != .user }
        var isSuper: Bool { self == .superadmin }
    }

    enum State: Equatable {
        case unconfigured
        case signedOut
        case signingIn
        case signedIn(email: String, role: Role)
        case refused(String)
        case failed(String)
    }

    private(set) var state: State = .signedOut
    private(set) var uid: String?
    private var session: FirebaseREST.Session?

    private let config = FirebaseREST.Config.load()
    static let allowedDomain = "@funasia.net"
    static var isConfigured: Bool { FirebaseREST.Config.load() != nil }

    var role: Role? {
        if case let .signedIn(_, role) = state { return role }
        return nil
    }
    var isReady: Bool { role?.canOpenAdmin == true }

    init() {
        guard config != nil else { state = .unconfigured; return }
        // A stored refresh token means a previous sign-in; resume silently.
        if let saved = Keychain.get("adminRefreshToken"), !saved.isEmpty {
            Task { await resume(saved) }
        }
    }

    func signIn(email: String, password: String) async {
        guard let config else { state = .unconfigured; return }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard address.hasSuffix(Self.allowedDomain) else {
            state = .failed("Only \(Self.allowedDomain) accounts can sign in here.")
            return
        }
        state = .signingIn
        do {
            let s = try await FirebaseREST.signIn(email: address, password: password, config: config)
            Keychain.set(s.refreshToken, for: "adminRefreshToken")
            await adopt(s)
        } catch {
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func resume(_ refreshToken: String) async {
        guard let config else { return }
        state = .signingIn
        do {
            let s = try await FirebaseREST.refresh(refreshToken, config: config)
            Keychain.set(s.refreshToken, for: "adminRefreshToken")
            await adopt(s)
        } catch {
            Keychain.delete("adminRefreshToken")
            state = .signedOut
        }
    }

    func signOut() {
        Keychain.delete("adminRefreshToken")
        session = nil
        uid = nil
        state = .signedOut
    }

    /// An ID token lasts an hour; refresh it rather than making the user sign
    /// in again mid-session.
    func validToken() async -> String? {
        guard let config, let s = session else { return nil }
        if s.isFresh { return s.idToken }
        guard let fresh = try? await FirebaseREST.refresh(s.refreshToken, config: config) else {
            signOut(); return nil
        }
        session = fresh
        Keychain.set(fresh.refreshToken, for: "adminRefreshToken")
        return fresh.idToken
    }

    /// Reads the role from `users/{uid}`. It is the only authorisation field;
    /// custom claims are not used anywhere in this project.
    private func adopt(_ s: FirebaseREST.Session) async {
        guard let config else { return }
        session = s
        uid = s.uid
        do {
            let doc = try await FirebaseREST.getDoc(path: "users/\(s.uid)",
                                                    token: s.idToken, config: config)
            guard let doc else {
                state = .refused("No user record exists for this account. "
                               + "A superadmin needs to create users/\(s.uid) with a role.")
                return
            }
            let email = (doc["email"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? s.email
            guard email.lowercased().hasSuffix(Self.allowedDomain) || s.email.lowercased().hasSuffix(Self.allowedDomain) else {
                signOut()
                state = .refused("\(email) is not a \(Self.allowedDomain) account.")
                return
            }
            let role = Role(rawValue: doc["role"] as? String ?? "user") ?? .user
            if role.canOpenAdmin {
                state = .signedIn(email: email, role: role)
            } else {
                state = .refused("\(email) is signed in, but its role is “\(role.rawValue)”. "
                               + "A superadmin must set it to admin or superadmin.")
            }
        } catch {
            state = .failed("Signed in, but the role could not be read: "
                          + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription))
        }
    }

    var firebaseConfig: FirebaseREST.Config? { config }
}
