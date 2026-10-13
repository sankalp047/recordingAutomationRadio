import Foundation
import Observation
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore

/// Sign-in and role for the FunAsia admin side of the app.
///
/// Firebase needs `GoogleService-Info.plist` from the `funasiawe` project in
/// the bundle. It is deliberately not committed, so the admin section reports
/// that it is unconfigured rather than the app crashing at launch, which is
/// what `FirebaseApp.configure()` does when the file is absent.
@MainActor
@Observable
final class AdminSession {
    enum Role: String, Codable {
        case user, admin, superadmin
        var canOpenAdmin: Bool { self != .user }
        var isSuper: Bool { self == .superadmin }
    }

    enum State: Equatable {
        case unconfigured          // no GoogleService-Info.plist
        case signedOut
        case signingIn
        case signedIn(email: String, role: Role)
        case refused(String)       // signed in but not an admin
        case failed(String)
    }

    private(set) var state: State = .signedOut
    private(set) var uid: String?

    var role: Role? {
        if case let .signedIn(_, role) = state { return role }
        return nil
    }
    var isReady: Bool { role?.canOpenAdmin == true }

    static let isConfigured: Bool =
        Bundle.main.url(forResource: "GoogleService-Info", withExtension: "plist") != nil

    /// Admin sign-in is restricted to the company domain. The role in
    /// Firestore is still what grants access - this only stops an outside
    /// account from ever reaching the role check.
    static let allowedDomain = "@funasia.net"

    init() {
        guard Self.isConfigured else { state = .unconfigured; return }
        if FirebaseApp.app() == nil { FirebaseApp.configure() }
        if let u = Auth.auth().currentUser {
            Task { await adopt(u) }
        }
    }

    func signIn(email: String, password: String) async {
        guard Self.isConfigured else { state = .unconfigured; return }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard address.hasSuffix(Self.allowedDomain) else {
            state = .failed("Only \(Self.allowedDomain) accounts can sign in here.")
            return
        }
        state = .signingIn
        do {
            let result = try await Auth.auth().signIn(withEmail: address, password: password)
            await adopt(result.user)
        } catch {
            state = .failed(friendly(error))
        }
    }

    func signOut() {
        try? Auth.auth().signOut()
        uid = nil
        state = .signedOut
    }

    /// Reads the role from `users/{uid}`. It is the only authorisation field;
    /// custom claims are not used anywhere in this project.
    private func adopt(_ user: User) async {
        uid = user.uid
        let email = user.email ?? user.uid
        do {
            let snap = try await Firestore.firestore()
                .collection("users").document(user.uid).getDocument()
            let raw = snap.data()?["role"] as? String ?? "user"
            let role = Role(rawValue: raw) ?? .user
            guard email.lowercased().hasSuffix(Self.allowedDomain) else {
                try? Auth.auth().signOut()
                state = .refused("\(email) is not a \(Self.allowedDomain) account.")
                return
            }
            if role.canOpenAdmin {
                state = .signedIn(email: email, role: role)
            } else {
                state = .refused("\(email) is not an admin account.")
            }
        } catch {
            state = .failed("Signed in, but the role could not be read: \(friendly(error))")
        }
    }

    private func friendly(_ error: Error) -> String {
        let ns = error as NSError
        switch AuthErrorCode(rawValue: ns.code) {
        case .wrongPassword, .invalidCredential: return "Wrong email or password."
        case .invalidEmail:                      return "That email address is not valid."
        case .userNotFound:                      return "No account with that email."
        case .networkError:                      return "Could not reach Firebase. Check the connection."
        case .tooManyRequests:                   return "Too many attempts. Wait a moment and try again."
        default:                                 return ns.localizedDescription
        }
    }
}
