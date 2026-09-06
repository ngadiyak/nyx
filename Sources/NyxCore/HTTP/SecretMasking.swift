import Foundation

/// Which parts of an HTTP request must not be shown in full on a screen someone else can see, and
/// what to show instead.
///
/// Masking is deliberately one-way and lossy: there is no unmask. A masked line is for reading,
/// never for running, and nothing that writes a command back out may go through here -- see
/// `Masking` in `CurlSerialiser.swift`, where `.none` is the only value the editing path uses.
public enum SecretMasking {
    /// Header names whose value is a credential. Lower-cased, because a header name is
    /// case-insensitive on the wire and Chrome writes them lower-case while Postman does not.
    public static let secretHeaders: Set<String> = [
        "authorization",
        "x-api-key",
        "x-auth-token",
        "api-key",
        "cookie",
        "x-amz-security-token",
        "proxy-authorization",
    ]

    /// Query and body parameter names whose value is a credential.
    public static let secretParameters: Set<String> = [
        "token",
        "api_key",
        "apikey",
        "key",
        "secret",
        "password",
        "access_token",
        "client_secret",
        "refresh_token",
    ]

    /// The authorization schemes worth keeping in front of a masked value: they say *how* the
    /// request authenticates, which is the part a person reading the line needs, and they are
    /// public knowledge in a way the token after them is not.
    private static let authSchemes: Set<String> = [
        "bearer", "basic", "digest", "token", "negotiate", "ntlm", "aws4-hmac-sha256",
    ]

    private static let dots = "••••"

    /// A value with its last four characters left visible -- enough to tell two tokens apart in a
    /// screenshot or a support thread without handing over the credential. Under eight characters
    /// there is not enough left to hide, so nothing is shown.
    public static func masked(_ value: String) -> String {
        guard value.count >= 8 else { return dots }
        return dots + String(value.suffix(4))
    }

    /// Masks a header value, keeping a leading auth scheme word (`Bearer`, `Basic`) so the header
    /// still reads as what it is. Returns the value untouched when the header is not a secret one,
    /// so a caller can hand every header to this without deciding first.
    public static func maskedHeaderValue(name: String, value: String) -> String {
        guard isSecretHeader(name) else { return value }
        if let space = value.firstIndex(of: " ") {
            let scheme = String(value[value.startIndex ..< space])
            if authSchemes.contains(scheme.lowercased()) {
                return scheme + " " + masked(String(value[value.index(after: space)...]))
            }
        }
        return masked(value)
    }

    public static func isSecretHeader(_ name: String) -> Bool {
        secretHeaders.contains(name.lowercased())
    }

    public static func isSecretParameter(_ name: String) -> Bool {
        secretParameters.contains(name.lowercased())
    }

    /// Masks every value in a `name=value; name2=value2` cookie string, separators and spacing
    /// kept as written. Text with no `=` anywhere is a *filename* -- curl's `-b` takes either --
    /// and a path holds no secret, so it is returned untouched.
    static func maskedCookieString(_ text: String) -> String {
        guard text.contains("=") else { return text }
        return text.split(separator: ";", omittingEmptySubsequences: false).map { part in
            let body = part.drop { $0 == " " || $0 == "\t" }
            let lead = String(part.prefix(part.count - body.count))
            guard let equals = body.firstIndex(of: "=") else { return String(part) }
            let name = String(body[body.startIndex ..< equals])
            return lead + name + "=" + masked(String(body[body.index(after: equals)...]))
        }.joined(separator: ";")
    }

    /// Masks the value half of a `name=value` parameter word when the name says it is a secret.
    /// A word with no `=` has no name to judge, so it is left alone.
    static func maskedParameter(_ text: String) -> String {
        guard let equals = text.firstIndex(of: "=") else { return text }
        let name = String(text[text.startIndex ..< equals])
        guard isSecretParameter(name) else { return text }
        return name + "=" + masked(String(text[text.index(after: equals)...]))
    }
}
