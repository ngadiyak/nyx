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
    // A secret header whose value is not `<scheme> <token>` has nothing worth keeping in front,
    // so the whole value goes. (`Cookie:` is the exception and has its own test.)
    #expect(SecretMasking.maskedHeaderValue(name: "x-api-key", value: "sk_live_0123456789") == "••••6789")
    #expect(SecretMasking.maskedHeaderValue(name: "x-auth-token", value: "not a scheme word") == "••••word")
    #expect(SecretMasking.maskedHeaderValue(name: "x-amz-security-token", value: "abc") == "••••")
}

@Test func theCookieHeaderIsMaskedValueByValue() {
    // One masked blob would hide `theme=dark` behind the same bullets as the session, and show
    // the tail of whichever cookie happened to be last. Each value is masked on its own.
    #expect(SecretMasking.maskedHeaderValue(name: "Cookie", value: "session=0123456789abcd; theme=dark")
        == "session=••••abcd; theme=••••")
    #expect(SecretMasking.maskedHeaderValue(name: "cookie", value: "novaluehere") == "••••here")
}

@Test func optionValueSecretsAreMaskedByShape() {
    // `user:password` and `certpath:password` keep the half in front of the colon; a password
    // option is all secret.
    #expect(SecretMasking.maskedOptionValue(option: "-U", value: "proxyuser:0123456789abcd")
        == "proxyuser:••••abcd")
    #expect(SecretMasking.maskedOptionValue(option: "--proxy-user", value: "u:p") == "u:••••")
    #expect(SecretMasking.maskedOptionValue(option: "-E", value: "/etc/cert.pem:0123456789wxyz")
        == "/etc/cert.pem:••••wxyz")
    #expect(SecretMasking.maskedOptionValue(option: "-E", value: "/etc/cert.pem") == "/etc/cert.pem")
    #expect(SecretMasking.maskedOptionValue(option: "--key-password", value: "0123456789efgh") == "••••efgh")
    #expect(SecretMasking.maskedOptionValue(option: "--tls-password", value: "abc") == "••••")
    #expect(SecretMasking.maskedOptionValue(option: "--proxy", value: "http://p:3128") == "http://p:3128")
}

@Test func aParameterListIsMaskedPairByPair() {
    #expect(SecretMasking.maskedParameterList("user=nik&password=0123456789abcd")
        == "user=nik&password=••••abcd")
    #expect(SecretMasking.maskedParameterList("password=0123456789abcd&user=nik")
        == "password=••••abcd&user=nik")
    #expect(SecretMasking.maskedParameterList("{\"a\":1}") == "{\"a\":1}")
    #expect(SecretMasking.maskedParameter("q=a&b") == "q=a&b")   // one pair, `&` is data
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
