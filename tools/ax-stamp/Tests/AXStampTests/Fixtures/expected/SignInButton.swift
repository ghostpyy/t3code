import SwiftUI
import AuthenticationServices

struct AuthScreen: View {
    @State private var nonce: String?
    @State private var error: String?

    var body: some View {
        VStack {
            SignInWithAppleButton(.signIn) { request in
                nonce = prepare(request)
            } onCompletion: { result in
                switch extract(result) {
                case .success(let token):
                    handle(token, nonce)
                case .failure(let message):
                    error = message
                }
            }
            .frame(height: 52).inspectable()
        }.inspectable()
    }

    private func prepare(_ r: ASAuthorizationAppleIDRequest) -> String { "" }
    private func extract(_ r: Result<ASAuthorization, Error>) -> Outcome { .cancelled }
    private func handle(_ token: String, _ nonce: String?) { }

    enum Outcome {
        case success(String)
        case failure(String)
        case cancelled
    }
}
