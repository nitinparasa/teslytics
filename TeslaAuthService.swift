import Foundation
import AuthenticationServices
import Combine
import CryptoKit

// MARK: - Token Model
struct TeslaToken: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresIn: Int
    var createdAt: Date? // Optional to avoid decode failures if server omits it

    // MARK: - Computed Properties
    var isExpired: Bool {
        guard let createdAt else { return true }
        let expiryDate = createdAt.addingTimeInterval(Double(expiresIn))
        return Date() > expiryDate
    }

    // MARK: - Coding Keys
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case createdAt
    }
}

// MARK: - PKCE Utilities
private enum PKCE {
    static func generateVerifier() -> String {
        // 43–128 chars, URL-safe
        let length = 64
        let chars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        var result = ""
        result.reserveCapacity(length)
        for _ in 0..<length {
            if let c = chars.randomElement() {
                result.append(c)
            }
        }
        return result
    }

    static func challenge(for verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        let base64 = Data(hash).base64EncodedString()
        // base64url (RFC 7636)
        return base64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Presentation Provider
private final class AuthPresentationProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let windowScene: UIWindowScene

    init(windowScene: UIWindowScene) {
        self.windowScene = windowScene
        super.init()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // 1. Try to find the key window within the specific windowScene
        if let keyWindow = windowScene.windows.first(where: { $0.isKeyWindow }) {
            return keyWindow
        }
        
        // 2. Fallback to any window in that scene
        if let anyWindow = windowScene.windows.first {
            return anyWindow
        }
        
        // 3. FIX: Use the new iOS 26.0 initializer instead of ASPresentationAnchor()
        return ASPresentationAnchor(windowScene: windowScene)
    }
}

// MARK: - Auth Service
@MainActor
class TeslaAuthService: ObservableObject {

    // MARK: - Published Properties
    @Published var isAuthenticated: Bool = false
    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil

    // MARK: - Private Properties
    private let tokenKey = "tesla_token"
    private var webAuthSession: ASWebAuthenticationSession?
    
    // 1. ADD THIS LINE: This keeps the provider alive during login
    private var authProvider: AuthPresentationProvider?
    
    private var currentCodeVerifier: String?

    // MARK: - Init
        init() {
            isAuthenticated = loadToken() != nil
        }
    
    // MARK: - Login
    func login() async {
            isLoading = true
            errorMessage = nil

            let verifier = PKCE.generateVerifier()
            currentCodeVerifier = verifier
            let challenge = PKCE.challenge(for: verifier)

            var components = URLComponents(string: "\(Config.authBaseURL)/oauth2/v3/authorize")!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: Config.clientID),
                URLQueryItem(name: "redirect_uri", value: Config.redirectURI),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: Config.scopes),
                URLQueryItem(name: "state", value: UUID().uuidString),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256")
            ]

            guard let authURL = components.url else {
                errorMessage = "Failed to build auth URL"
                isLoading = false
                return
            }

            do {
                let callbackURL = try await performWebAuth(url: authURL)
                guard let code = extractCode(from: callbackURL) else {
                    errorMessage = "Failed to extract auth code"
                    isLoading = false
                    return
                }

                try await exchangeCodeForToken(code: code)
                isAuthenticated = true
            } catch {
                errorMessage = error.localizedDescription
            }

            isLoading = false
        }

    // MARK: - Logout
    func logout() {
        deleteToken()
        isAuthenticated = false
    }

    // MARK: - Get Valid Token
    func validToken() async throws -> String {
        guard var token = loadToken() else {
            throw AuthError.noToken
        }

        if token.isExpired {
            token = try await refreshToken(token: token)
        }

        return token.accessToken
    }
}

// MARK: - Private Methods
private extension TeslaAuthService {

    // Opens Tesla login page in a secure sheet
    func performWebAuth(url: URL) async throws -> URL {
        var isResumed = false
        
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: "teslytics"
            ) { [weak self] callbackURL, error in // Use weak self to avoid cycles
                guard !isResumed else { return }
                isResumed = true
                
                // Clean up the provider when done
                self?.authProvider = nil
                
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let callbackURL = callbackURL {
                    continuation.resume(returning: callbackURL)
                }
            }

            let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
                ?? UIApplication.shared.connectedScenes.first as? UIWindowScene

            if let scene = scene {
                // STORE THE PROVIDER STRONGLY
                let provider = AuthPresentationProvider(windowScene: scene)
                self.authProvider = provider
                session.presentationContextProvider = provider
            } else {
                if !isResumed {
                    isResumed = true
                    continuation.resume(throwing: AuthError.noWindowScene)
                }
                return
            }
            
            session.prefersEphemeralWebBrowserSession = true
            self.webAuthSession = session
            
            if !session.start() {
                if !isResumed {
                    isResumed = true
                    self.authProvider = nil
                    continuation.resume(throwing: NSError(domain: "Auth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to start session"]))
                }
            }
        }
    }

    // Pulls the auth code out of the redirect URL
    func extractCode(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "code" })?
            .value
    }

    // Exchanges the one-time auth code for an access token
    func exchangeCodeForToken(code: String) async throws {
        let url = URL(string: "\(Config.authBaseURL)/oauth2/v3/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        // Prefer PKCE on device; client_secret may be optional/unused depending on your Tesla app config
        var body: [String: String] = [
            "grant_type": "authorization_code",
            "client_id": Config.clientID,
            "code": code,
            "redirect_uri": Config.redirectURI
        ]
        if let verifier = currentCodeVerifier {
            body["code_verifier"] = verifier
        }
        // If your app is configured to require a client secret, keep it:
        // body["client_secret"] = Config.clientSecret

        request.httpBody = formURLEncoded(from: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        var token = try JSONDecoder().decode(TeslaToken.self, from: data)
        token.createdAt = Date()
        saveToken(token)
    }

    // Gets a new access token using the refresh token
    func refreshToken(token: TeslaToken) async throws -> TeslaToken {
        let url = URL(string: "\(Config.authBaseURL)/oauth2/v3/token")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "client_id": Config.clientID,
            "refresh_token": token.refreshToken
        ]

        request.httpBody = formURLEncoded(from: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        var newToken = try JSONDecoder().decode(TeslaToken.self, from: data)
        newToken.createdAt = Date()
        saveToken(newToken)
        return newToken
    }

    // Encodes a dictionary to application/x-www-form-urlencoded
    func formURLEncoded(from dict: [String: String]) -> Data? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let pairs = dict.map { key, value -> String in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }
        return pairs.joined(separator: "&").data(using: .utf8)
    }

    // MARK: - Token Storage
    func saveToken(_ token: TeslaToken) {
        if let data = try? JSONEncoder().encode(token) {
            UserDefaults.standard.set(data, forKey: tokenKey)
        }
    }

    func loadToken() -> TeslaToken? {
        guard let data = UserDefaults.standard.data(forKey: tokenKey) else {
            return nil
        }
        return try? JSONDecoder().decode(TeslaToken.self, from: data)
    }

    func deleteToken() {
        UserDefaults.standard.removeObject(forKey: tokenKey)
    }
}

// MARK: - Auth Errors
enum AuthError: LocalizedError {
    case noToken
    case expiredToken
    case noWindowScene // Add this case

    var errorDescription: String? {
        switch self {
        case .noToken:
            return "No token found, please login"
        case .expiredToken:
            return "Token expired, please login again"
        case .noWindowScene:
            return "Could not find an active window to display the login screen"
        }
    }
}
