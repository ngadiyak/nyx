import Testing
@testable import NyxCore

@Test func shortMaskIsFourDots() {
    // Under eight characters there is not enough left to show a tail without giving the whole
    // thing away, so nothing is shown.
    #expect(SecretMasking.masked("abc") == "••••")
    #expect(SecretMasking.masked("1234567") == "••••")
    #expect(SecretMasking.masked("12345678") == "••••5678")
}

@Test func longMaskKeepsTheLastFour() {
    let token = "ghp_1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d9f2c"
    #expect(token.count == 40)
    #expect(SecretMasking.masked(token) == "••••9f2c")
}

@Test func bearerKeepsScheme() {
    // The scheme word is not the secret, and dropping it makes the header unreadable as an
    // authorization header at a glance.
    let token = "ghp_1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d9f2c"
    #expect(SecretMasking.maskedHeaderValue(name: "Authorization", value: "Bearer \(token)") == "Bearer ••••9f2c")
    #expect(SecretMasking.maskedHeaderValue(name: "authorization", value: "Basic YWxhZGRpbjpvcGVuc2VzYW1l") == "Basic ••••YW1l")
}

@Test func aValueWithNoSchemeWordIsMaskedWhole() {
    // `Cookie: session=abcdefgh` must not keep `session=abcdefgh` just because it has a space in
    // it somewhere -- only a real auth scheme word is kept.
    #expect(SecretMasking.maskedHeaderValue(name: "Cookie", value: "session=abcdefgh; theme=dark")
        == "••••dark")
    #expect(SecretMasking.maskedHeaderValue(name: "x-api-key", value: "sk_live_0123456789") == "••••6789")
}

@Test func anOrdinaryHeaderIsNotMasked() {
    #expect(SecretMasking.maskedHeaderValue(name: "Accept", value: "application/json") == "application/json")
    #expect(SecretMasking.isSecretHeader("Accept") == false)
}

@Test func secretHeaderNamesAreCaseInsensitive() {
    #expect(SecretMasking.isSecretHeader("Authorization"))
    #expect(SecretMasking.isSecretHeader("X-API-Key"))
    #expect(SecretMasking.isSecretHeader("x-amz-security-token"))
    #expect(SecretMasking.isSecretHeader("proxy-authorization"))
    #expect(SecretMasking.isSecretHeader("Cookie"))
    #expect(SecretMasking.isSecretHeader("X-Auth-Token"))
    #expect(SecretMasking.isSecretHeader("api-key"))
}

@Test func secretParameterNamesAreCaseInsensitive() {
    #expect(SecretMasking.isSecretParameter("token"))
    #expect(SecretMasking.isSecretParameter("API_KEY"))
    #expect(SecretMasking.isSecretParameter("apikey"))
    #expect(SecretMasking.isSecretParameter("key"))
    #expect(SecretMasking.isSecretParameter("secret"))
    #expect(SecretMasking.isSecretParameter("password"))
    #expect(SecretMasking.isSecretParameter("access_token"))
    #expect(SecretMasking.isSecretParameter("client_secret"))
    #expect(SecretMasking.isSecretParameter("refresh_token"))
    #expect(SecretMasking.isSecretParameter("limit") == false)
}
