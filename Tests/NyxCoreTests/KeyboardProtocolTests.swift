import Testing
@testable import NyxCore

private let ESC = "\u{1B}"

private func enc(_ key: Key, _ mods: KeyModifiers = [], text: String? = nil,
                 app: Bool = false, meta: Bool = false,
                 keypad: Bool = false, isKeypad: Bool = false,
                 other: ModifyOtherKeys = .off) -> String? {
    KeyEncoder.encode(KeyEvent(key: key, modifiers: mods, text: text, isKeypad: isKeypad),
                      options: KeyEncoderOptions(cursorKeysApp: app, optionAsMeta: meta,
                                                 keypadApp: keypad, modifyOtherKeys: other))
        .map { String(decoding: $0, as: UTF8.self) }
}

private func hex(_ s: String?) -> String {
    guard let s else { return "nil" }
    return Array(s.utf8).map { String(format: "%02X", $0) }.joined()
}

// MARK: - The legacy encoding must not move

/// Every key the encoder knows, crossed with every modifier combination, both cursor-key modes and
/// both option-as-meta settings: 1344 encodings, frozen from the encoder as it stood *before*
/// application keypad and modifyOtherKeys were added to it.
///
/// The rule this pins is the one that matters most about both new modes: with neither of them
/// asked for, the terminal types exactly what it typed before they existed. A key encoder is the
/// one component whose regressions the user meets on the very first keystroke, and no feature it
/// grows is worth a byte of drift in the default path -- so this table is deliberately a snapshot
/// of behaviour rather than a restatement of the rules, and any diff against it is a bug report.
///
/// Fields per key, in order: modifier bits 0...7 (bit 0 shift, 1 alt, 2 ctrl), each with the four
/// combinations of `cursorKeysApp` and `optionAsMeta` in the order 00, 01, 10, 11.
private let legacyGolden: [String] = [
        "up:1B5B41,1B5B41,1B4F41,1B4F41,1B5B313B3241,1B5B313B3241,1B5B313B3241,1B5B313B3241,1B5B313B3341,1B5B313B3341,1B5B313B3341,1B5B313B3341,1B5B313B3441,1B5B313B3441,1B5B313B3441,1B5B313B3441,1B5B313B3541,1B5B313B3541,1B5B313B3541,1B5B313B3541,1B5B313B3641,1B5B313B3641,1B5B313B3641,1B5B313B3641,1B5B313B3741,1B5B313B3741,1B5B313B3741,1B5B313B3741,1B5B313B3841,1B5B313B3841,1B5B313B3841,1B5B313B3841",
        "down:1B5B42,1B5B42,1B4F42,1B4F42,1B5B313B3242,1B5B313B3242,1B5B313B3242,1B5B313B3242,1B5B313B3342,1B5B313B3342,1B5B313B3342,1B5B313B3342,1B5B313B3442,1B5B313B3442,1B5B313B3442,1B5B313B3442,1B5B313B3542,1B5B313B3542,1B5B313B3542,1B5B313B3542,1B5B313B3642,1B5B313B3642,1B5B313B3642,1B5B313B3642,1B5B313B3742,1B5B313B3742,1B5B313B3742,1B5B313B3742,1B5B313B3842,1B5B313B3842,1B5B313B3842,1B5B313B3842",
        "left:1B5B44,1B5B44,1B4F44,1B4F44,1B5B313B3244,1B5B313B3244,1B5B313B3244,1B5B313B3244,1B5B313B3344,1B5B313B3344,1B5B313B3344,1B5B313B3344,1B5B313B3444,1B5B313B3444,1B5B313B3444,1B5B313B3444,1B5B313B3544,1B5B313B3544,1B5B313B3544,1B5B313B3544,1B5B313B3644,1B5B313B3644,1B5B313B3644,1B5B313B3644,1B5B313B3744,1B5B313B3744,1B5B313B3744,1B5B313B3744,1B5B313B3844,1B5B313B3844,1B5B313B3844,1B5B313B3844",
        "right:1B5B43,1B5B43,1B4F43,1B4F43,1B5B313B3243,1B5B313B3243,1B5B313B3243,1B5B313B3243,1B5B313B3343,1B5B313B3343,1B5B313B3343,1B5B313B3343,1B5B313B3443,1B5B313B3443,1B5B313B3443,1B5B313B3443,1B5B313B3543,1B5B313B3543,1B5B313B3543,1B5B313B3543,1B5B313B3643,1B5B313B3643,1B5B313B3643,1B5B313B3643,1B5B313B3743,1B5B313B3743,1B5B313B3743,1B5B313B3743,1B5B313B3843,1B5B313B3843,1B5B313B3843,1B5B313B3843",
        "home:1B5B48,1B5B48,1B4F48,1B4F48,1B5B313B3248,1B5B313B3248,1B5B313B3248,1B5B313B3248,1B5B313B3348,1B5B313B3348,1B5B313B3348,1B5B313B3348,1B5B313B3448,1B5B313B3448,1B5B313B3448,1B5B313B3448,1B5B313B3548,1B5B313B3548,1B5B313B3548,1B5B313B3548,1B5B313B3648,1B5B313B3648,1B5B313B3648,1B5B313B3648,1B5B313B3748,1B5B313B3748,1B5B313B3748,1B5B313B3748,1B5B313B3848,1B5B313B3848,1B5B313B3848,1B5B313B3848",
        "end:1B5B46,1B5B46,1B4F46,1B4F46,1B5B313B3246,1B5B313B3246,1B5B313B3246,1B5B313B3246,1B5B313B3346,1B5B313B3346,1B5B313B3346,1B5B313B3346,1B5B313B3446,1B5B313B3446,1B5B313B3446,1B5B313B3446,1B5B313B3546,1B5B313B3546,1B5B313B3546,1B5B313B3546,1B5B313B3646,1B5B313B3646,1B5B313B3646,1B5B313B3646,1B5B313B3746,1B5B313B3746,1B5B313B3746,1B5B313B3746,1B5B313B3846,1B5B313B3846,1B5B313B3846,1B5B313B3846",
        "pageUp:1B5B357E,1B5B357E,1B5B357E,1B5B357E,1B5B353B327E,1B5B353B327E,1B5B353B327E,1B5B353B327E,1B5B353B337E,1B5B353B337E,1B5B353B337E,1B5B353B337E,1B5B353B347E,1B5B353B347E,1B5B353B347E,1B5B353B347E,1B5B353B357E,1B5B353B357E,1B5B353B357E,1B5B353B357E,1B5B353B367E,1B5B353B367E,1B5B353B367E,1B5B353B367E,1B5B353B377E,1B5B353B377E,1B5B353B377E,1B5B353B377E,1B5B353B387E,1B5B353B387E,1B5B353B387E,1B5B353B387E",
        "pageDown:1B5B367E,1B5B367E,1B5B367E,1B5B367E,1B5B363B327E,1B5B363B327E,1B5B363B327E,1B5B363B327E,1B5B363B337E,1B5B363B337E,1B5B363B337E,1B5B363B337E,1B5B363B347E,1B5B363B347E,1B5B363B347E,1B5B363B347E,1B5B363B357E,1B5B363B357E,1B5B363B357E,1B5B363B357E,1B5B363B367E,1B5B363B367E,1B5B363B367E,1B5B363B367E,1B5B363B377E,1B5B363B377E,1B5B363B377E,1B5B363B377E,1B5B363B387E,1B5B363B387E,1B5B363B387E,1B5B363B387E",
        "insert:1B5B327E,1B5B327E,1B5B327E,1B5B327E,1B5B323B327E,1B5B323B327E,1B5B323B327E,1B5B323B327E,1B5B323B337E,1B5B323B337E,1B5B323B337E,1B5B323B337E,1B5B323B347E,1B5B323B347E,1B5B323B347E,1B5B323B347E,1B5B323B357E,1B5B323B357E,1B5B323B357E,1B5B323B357E,1B5B323B367E,1B5B323B367E,1B5B323B367E,1B5B323B367E,1B5B323B377E,1B5B323B377E,1B5B323B377E,1B5B323B377E,1B5B323B387E,1B5B323B387E,1B5B323B387E,1B5B323B387E",
        "delete:1B5B337E,1B5B337E,1B5B337E,1B5B337E,1B5B333B327E,1B5B333B327E,1B5B333B327E,1B5B333B327E,1B5B333B337E,1B5B333B337E,1B5B333B337E,1B5B333B337E,1B5B333B347E,1B5B333B347E,1B5B333B347E,1B5B333B347E,1B5B333B357E,1B5B333B357E,1B5B333B357E,1B5B333B357E,1B5B333B367E,1B5B333B367E,1B5B333B367E,1B5B333B367E,1B5B333B377E,1B5B333B377E,1B5B333B377E,1B5B333B377E,1B5B333B387E,1B5B333B387E,1B5B333B387E,1B5B333B387E",
        "backspace:7F,7F,7F,7F,7F,7F,7F,7F,1B7F,1B7F,1B7F,1B7F,1B7F,1B7F,1B7F,1B7F,08,08,08,08,08,08,08,08,1B08,1B08,1B08,1B08,1B08,1B08,1B08,1B08",
        "tab:09,09,09,09,1B5B5A,1B5B5A,1B5B5A,1B5B5A,1B09,1B09,1B09,1B09,1B5B5A,1B5B5A,1B5B5A,1B5B5A,09,09,09,09,1B5B5A,1B5B5A,1B5B5A,1B5B5A,1B09,1B09,1B09,1B09,1B5B5A,1B5B5A,1B5B5A,1B5B5A",
        "enter:0D,0D,0D,0D,0D,0D,0D,0D,1B0D,1B0D,1B0D,1B0D,1B0D,1B0D,1B0D,1B0D,0D,0D,0D,0D,0D,0D,0D,0D,1B0D,1B0D,1B0D,1B0D,1B0D,1B0D,1B0D,1B0D",
        "escape:1B,1B,1B,1B,1B,1B,1B,1B,1B1B,1B1B,1B1B,1B1B,1B1B,1B1B,1B1B,1B1B,1B,1B,1B,1B,1B,1B,1B,1B,1B1B,1B1B,1B1B,1B1B,1B1B,1B1B,1B1B,1B1B",
        "f1:1B4F50,1B4F50,1B4F50,1B4F50,1B5B313B3250,1B5B313B3250,1B5B313B3250,1B5B313B3250,1B5B313B3350,1B5B313B3350,1B5B313B3350,1B5B313B3350,1B5B313B3450,1B5B313B3450,1B5B313B3450,1B5B313B3450,1B5B313B3550,1B5B313B3550,1B5B313B3550,1B5B313B3550,1B5B313B3650,1B5B313B3650,1B5B313B3650,1B5B313B3650,1B5B313B3750,1B5B313B3750,1B5B313B3750,1B5B313B3750,1B5B313B3850,1B5B313B3850,1B5B313B3850,1B5B313B3850",
        "f2:1B4F51,1B4F51,1B4F51,1B4F51,1B5B313B3251,1B5B313B3251,1B5B313B3251,1B5B313B3251,1B5B313B3351,1B5B313B3351,1B5B313B3351,1B5B313B3351,1B5B313B3451,1B5B313B3451,1B5B313B3451,1B5B313B3451,1B5B313B3551,1B5B313B3551,1B5B313B3551,1B5B313B3551,1B5B313B3651,1B5B313B3651,1B5B313B3651,1B5B313B3651,1B5B313B3751,1B5B313B3751,1B5B313B3751,1B5B313B3751,1B5B313B3851,1B5B313B3851,1B5B313B3851,1B5B313B3851",
        "f3:1B4F52,1B4F52,1B4F52,1B4F52,1B5B313B3252,1B5B313B3252,1B5B313B3252,1B5B313B3252,1B5B313B3352,1B5B313B3352,1B5B313B3352,1B5B313B3352,1B5B313B3452,1B5B313B3452,1B5B313B3452,1B5B313B3452,1B5B313B3552,1B5B313B3552,1B5B313B3552,1B5B313B3552,1B5B313B3652,1B5B313B3652,1B5B313B3652,1B5B313B3652,1B5B313B3752,1B5B313B3752,1B5B313B3752,1B5B313B3752,1B5B313B3852,1B5B313B3852,1B5B313B3852,1B5B313B3852",
        "f4:1B4F53,1B4F53,1B4F53,1B4F53,1B5B313B3253,1B5B313B3253,1B5B313B3253,1B5B313B3253,1B5B313B3353,1B5B313B3353,1B5B313B3353,1B5B313B3353,1B5B313B3453,1B5B313B3453,1B5B313B3453,1B5B313B3453,1B5B313B3553,1B5B313B3553,1B5B313B3553,1B5B313B3553,1B5B313B3653,1B5B313B3653,1B5B313B3653,1B5B313B3653,1B5B313B3753,1B5B313B3753,1B5B313B3753,1B5B313B3753,1B5B313B3853,1B5B313B3853,1B5B313B3853,1B5B313B3853",
        "f5:1B5B31357E,1B5B31357E,1B5B31357E,1B5B31357E,1B5B31353B327E,1B5B31353B327E,1B5B31353B327E,1B5B31353B327E,1B5B31353B337E,1B5B31353B337E,1B5B31353B337E,1B5B31353B337E,1B5B31353B347E,1B5B31353B347E,1B5B31353B347E,1B5B31353B347E,1B5B31353B357E,1B5B31353B357E,1B5B31353B357E,1B5B31353B357E,1B5B31353B367E,1B5B31353B367E,1B5B31353B367E,1B5B31353B367E,1B5B31353B377E,1B5B31353B377E,1B5B31353B377E,1B5B31353B377E,1B5B31353B387E,1B5B31353B387E,1B5B31353B387E,1B5B31353B387E",
        "f6:1B5B31377E,1B5B31377E,1B5B31377E,1B5B31377E,1B5B31373B327E,1B5B31373B327E,1B5B31373B327E,1B5B31373B327E,1B5B31373B337E,1B5B31373B337E,1B5B31373B337E,1B5B31373B337E,1B5B31373B347E,1B5B31373B347E,1B5B31373B347E,1B5B31373B347E,1B5B31373B357E,1B5B31373B357E,1B5B31373B357E,1B5B31373B357E,1B5B31373B367E,1B5B31373B367E,1B5B31373B367E,1B5B31373B367E,1B5B31373B377E,1B5B31373B377E,1B5B31373B377E,1B5B31373B377E,1B5B31373B387E,1B5B31373B387E,1B5B31373B387E,1B5B31373B387E",
        "f7:1B5B31387E,1B5B31387E,1B5B31387E,1B5B31387E,1B5B31383B327E,1B5B31383B327E,1B5B31383B327E,1B5B31383B327E,1B5B31383B337E,1B5B31383B337E,1B5B31383B337E,1B5B31383B337E,1B5B31383B347E,1B5B31383B347E,1B5B31383B347E,1B5B31383B347E,1B5B31383B357E,1B5B31383B357E,1B5B31383B357E,1B5B31383B357E,1B5B31383B367E,1B5B31383B367E,1B5B31383B367E,1B5B31383B367E,1B5B31383B377E,1B5B31383B377E,1B5B31383B377E,1B5B31383B377E,1B5B31383B387E,1B5B31383B387E,1B5B31383B387E,1B5B31383B387E",
        "f8:1B5B31397E,1B5B31397E,1B5B31397E,1B5B31397E,1B5B31393B327E,1B5B31393B327E,1B5B31393B327E,1B5B31393B327E,1B5B31393B337E,1B5B31393B337E,1B5B31393B337E,1B5B31393B337E,1B5B31393B347E,1B5B31393B347E,1B5B31393B347E,1B5B31393B347E,1B5B31393B357E,1B5B31393B357E,1B5B31393B357E,1B5B31393B357E,1B5B31393B367E,1B5B31393B367E,1B5B31393B367E,1B5B31393B367E,1B5B31393B377E,1B5B31393B377E,1B5B31393B377E,1B5B31393B377E,1B5B31393B387E,1B5B31393B387E,1B5B31393B387E,1B5B31393B387E",
        "f9:1B5B32307E,1B5B32307E,1B5B32307E,1B5B32307E,1B5B32303B327E,1B5B32303B327E,1B5B32303B327E,1B5B32303B327E,1B5B32303B337E,1B5B32303B337E,1B5B32303B337E,1B5B32303B337E,1B5B32303B347E,1B5B32303B347E,1B5B32303B347E,1B5B32303B347E,1B5B32303B357E,1B5B32303B357E,1B5B32303B357E,1B5B32303B357E,1B5B32303B367E,1B5B32303B367E,1B5B32303B367E,1B5B32303B367E,1B5B32303B377E,1B5B32303B377E,1B5B32303B377E,1B5B32303B377E,1B5B32303B387E,1B5B32303B387E,1B5B32303B387E,1B5B32303B387E",
        "f10:1B5B32317E,1B5B32317E,1B5B32317E,1B5B32317E,1B5B32313B327E,1B5B32313B327E,1B5B32313B327E,1B5B32313B327E,1B5B32313B337E,1B5B32313B337E,1B5B32313B337E,1B5B32313B337E,1B5B32313B347E,1B5B32313B347E,1B5B32313B347E,1B5B32313B347E,1B5B32313B357E,1B5B32313B357E,1B5B32313B357E,1B5B32313B357E,1B5B32313B367E,1B5B32313B367E,1B5B32313B367E,1B5B32313B367E,1B5B32313B377E,1B5B32313B377E,1B5B32313B377E,1B5B32313B377E,1B5B32313B387E,1B5B32313B387E,1B5B32313B387E,1B5B32313B387E",
        "f11:1B5B32337E,1B5B32337E,1B5B32337E,1B5B32337E,1B5B32333B327E,1B5B32333B327E,1B5B32333B327E,1B5B32333B327E,1B5B32333B337E,1B5B32333B337E,1B5B32333B337E,1B5B32333B337E,1B5B32333B347E,1B5B32333B347E,1B5B32333B347E,1B5B32333B347E,1B5B32333B357E,1B5B32333B357E,1B5B32333B357E,1B5B32333B357E,1B5B32333B367E,1B5B32333B367E,1B5B32333B367E,1B5B32333B367E,1B5B32333B377E,1B5B32333B377E,1B5B32333B377E,1B5B32333B377E,1B5B32333B387E,1B5B32333B387E,1B5B32333B387E,1B5B32333B387E",
        "f12:1B5B32347E,1B5B32347E,1B5B32347E,1B5B32347E,1B5B32343B327E,1B5B32343B327E,1B5B32343B327E,1B5B32343B327E,1B5B32343B337E,1B5B32343B337E,1B5B32343B337E,1B5B32343B337E,1B5B32343B347E,1B5B32343B347E,1B5B32343B347E,1B5B32343B347E,1B5B32343B357E,1B5B32343B357E,1B5B32343B357E,1B5B32343B357E,1B5B32343B367E,1B5B32343B367E,1B5B32343B367E,1B5B32343B367E,1B5B32343B377E,1B5B32343B377E,1B5B32343B377E,1B5B32343B377E,1B5B32343B387E,1B5B32343B387E,1B5B32343B387E,1B5B32343B387E",
        "char(a):61,61,61,61,61,61,61,61,61,1B61,61,1B61,61,1B61,61,1B61,01,01,01,01,01,01,01,01,1B01,1B01,1B01,1B01,1B01,1B01,1B01,1B01",
        "char(b):62,62,62,62,62,62,62,62,62,1B62,62,1B62,62,1B62,62,1B62,02,02,02,02,02,02,02,02,1B02,1B02,1B02,1B02,1B02,1B02,1B02,1B02",
        "char(c):63,63,63,63,63,63,63,63,63,1B63,63,1B63,63,1B63,63,1B63,03,03,03,03,03,03,03,03,1B03,1B03,1B03,1B03,1B03,1B03,1B03,1B03",
        "char(z):7A,7A,7A,7A,7A,7A,7A,7A,7A,1B7A,7A,1B7A,7A,1B7A,7A,1B7A,1A,1A,1A,1A,1A,1A,1A,1A,1B1A,1B1A,1B1A,1B1A,1B1A,1B1A,1B1A,1B1A",
        "char(@):40,40,40,40,40,40,40,40,40,1B40,40,1B40,40,1B40,40,1B40,00,00,00,00,00,00,00,00,1B00,1B00,1B00,1B00,1B00,1B00,1B00,1B00",
        "char( ):20,20,20,20,20,20,20,20,20,1B20,20,1B20,20,1B20,20,1B20,00,00,00,00,00,00,00,00,1B00,1B00,1B00,1B00,1B00,1B00,1B00,1B00",
        "char([):5B,5B,5B,5B,5B,5B,5B,5B,5B,1B5B,5B,1B5B,5B,1B5B,5B,1B5B,1B,1B,1B,1B,1B,1B,1B,1B,1B1B,1B1B,1B1B,1B1B,1B1B,1B1B,1B1B,1B1B",
        "char(]):5D,5D,5D,5D,5D,5D,5D,5D,5D,1B5D,5D,1B5D,5D,1B5D,5D,1B5D,1D,1D,1D,1D,1D,1D,1D,1D,1B1D,1B1D,1B1D,1B1D,1B1D,1B1D,1B1D,1B1D",
        "char(\\):5C,5C,5C,5C,5C,5C,5C,5C,5C,1B5C,5C,1B5C,5C,1B5C,5C,1B5C,1C,1C,1C,1C,1C,1C,1C,1C,1B1C,1B1C,1B1C,1B1C,1B1C,1B1C,1B1C,1B1C",
        "char(^):5E,5E,5E,5E,5E,5E,5E,5E,5E,1B5E,5E,1B5E,5E,1B5E,5E,1B5E,1E,1E,1E,1E,1E,1E,1E,1E,1B1E,1B1E,1B1E,1B1E,1B1E,1B1E,1B1E,1B1E",
        "char(_):5F,5F,5F,5F,5F,5F,5F,5F,5F,1B5F,5F,1B5F,5F,1B5F,5F,1B5F,1F,1F,1F,1F,1F,1F,1F,1F,1B1F,1B1F,1B1F,1B1F,1B1F,1B1F,1B1F,1B1F",
        "char(/):2F,2F,2F,2F,2F,2F,2F,2F,2F,1B2F,2F,1B2F,2F,1B2F,2F,1B2F,1F,1F,1F,1F,1F,1F,1F,1F,1B1F,1B1F,1B1F,1B1F,1B1F,1B1F,1B1F,1B1F",
        "char(?):3F,3F,3F,3F,3F,3F,3F,3F,3F,1B3F,3F,1B3F,3F,1B3F,3F,1B3F,7F,7F,7F,7F,7F,7F,7F,7F,1B7F,1B7F,1B7F,1B7F,1B7F,1B7F,1B7F,1B7F",
        "char(1):31,31,31,31,31,31,31,31,31,1B31,31,1B31,31,1B31,31,1B31,31,31,31,31,31,31,31,31,1B31,1B31,1B31,1B31,1B31,1B31,1B31,1B31",
        "char(.):2E,2E,2E,2E,2E,2E,2E,2E,2E,1B2E,2E,1B2E,2E,1B2E,2E,1B2E,2E,2E,2E,2E,2E,2E,2E,2E,1B2E,1B2E,1B2E,1B2E,1B2E,1B2E,1B2E,1B2E",
        "char(;):3B,3B,3B,3B,3B,3B,3B,3B,3B,1B3B,3B,1B3B,3B,1B3B,3B,1B3B,3B,3B,3B,3B,3B,3B,3B,3B,1B3B,1B3B,1B3B,1B3B,1B3B,1B3B,1B3B,1B3B",
]

@Test func legacyEncodingIsUnchangedWhenNoKeyboardModeIsOn() {
    var keys: [(String, Key)] = [
        ("up", .up), ("down", .down), ("left", .left), ("right", .right),
        ("home", .home), ("end", .end), ("pageUp", .pageUp), ("pageDown", .pageDown),
        ("insert", .insert), ("delete", .delete),
        ("backspace", .backspace), ("tab", .tab), ("enter", .enter), ("escape", .escape),
    ]
    for n in 1...12 { keys.append(("f\(n)", .f(n))) }
    for c in "abcz@ []\\^_/?1.;" {
        keys.append(("char(\(c))", .char(String(c).unicodeScalars.first!)))
    }
    #expect(keys.count == legacyGolden.count)

    for (i, (name, key)) in keys.enumerated() {
        var fields: [String] = []
        for bits in 0..<8 {
            var m: KeyModifiers = []
            if bits & 1 != 0 { m.insert(.shift) }
            if bits & 2 != 0 { m.insert(.alt) }
            if bits & 4 != 0 { m.insert(.ctrl) }
            for app in [false, true] {
                for meta in [false, true] {
                    var text: String?
                    if case .char(let s) = key { text = String(s) }
                    fields.append(hex(enc(key, m, text: text, app: app, meta: meta)))
                }
            }
        }
        #expect("\(name):\(fields.joined(separator: ","))" == legacyGolden[i])
    }
}

// MARK: - Application keypad (DECKPAM)

/// The rule: in application keypad mode a keypad key names itself with an SS3 sequence, so an
/// application can bind keypad `1` (`<k1>` in vim) separately from the `1` on the number row. Out
/// of that mode the keypad is just those characters, which is what it always was.
@Test func applicationKeypadSendsSS3ForEveryKeypadKey() {
    let expected: [(Unicode.Scalar, String)] = [
        ("0", "p"), ("1", "q"), ("2", "r"), ("3", "s"), ("4", "t"),
        ("5", "u"), ("6", "v"), ("7", "w"), ("8", "x"), ("9", "y"),
        (".", "n"), (",", "l"), ("+", "k"), ("-", "m"), ("*", "j"), ("/", "o"), ("=", "X"),
    ]
    for (scalar, final) in expected {
        let text = String(scalar)
        #expect(enc(.char(scalar), text: text, keypad: true, isKeypad: true) == ESC + "O" + final)
        // Same physical key, mode off: the character, exactly as before.
        #expect(enc(.char(scalar), text: text, keypad: false, isKeypad: true) == text)
        // Same character, main block: never an SS3 sequence, whatever the mode says.
        #expect(enc(.char(scalar), text: text, keypad: true, isKeypad: false) == text)
    }
    #expect(enc(.enter, keypad: true, isKeypad: true) == ESC + "OM")
    #expect(enc(.enter, keypad: true, isKeypad: false) == "\r")
    #expect(enc(.enter, keypad: false, isKeypad: true) == "\r")
}

/// xterm reports `modifyKeypadKeys` as 0 -- keypad keys are not modified -- so shift and ctrl are
/// dropped rather than encoded, and option stays Meta's ESC prefix.
@Test func applicationKeypadIgnoresShiftAndControlButNotMeta() {
    #expect(enc(.char("1"), [.shift], text: "1", keypad: true, isKeypad: true) == ESC + "Oq")
    #expect(enc(.char("1"), [.ctrl], text: "1", keypad: true, isKeypad: true) == ESC + "Oq")
    #expect(enc(.char("1"), [.alt], text: "1", keypad: true, isKeypad: true) == ESC + ESC + "Oq")
    // Command is still the application's shortcut, not input.
    #expect(enc(.char("1"), [.cmd], text: "1", keypad: true, isKeypad: true) == nil)
}

/// A key the keypad can produce that has no SS3 form (Clear on a Mac keypad, or whatever a
/// non-US layout puts there) falls through to the character rather than to nothing.
@Test func keypadKeysWithoutAnSS3FormFallThrough() {
    #expect(enc(.char("\u{F739}"), text: "\u{F739}", keypad: true, isKeypad: true) == "\u{F739}")
    #expect(enc(.char("%"), text: "%", keypad: true, isKeypad: true) == "%")
}

@Test func keypadKeyCodesAreTheKeypadAndNothingElse() {
    // The Mac keypad, by kVK_ANSI_Keypad* code.
    for code: UInt16 in [65, 67, 69, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92] {
        #expect(MacKeyCodes.isKeypad(code))
    }
    // Return (36), the digit row (18...23 is 1...5), the arrows (123...126) -- macOS sets its
    // `numericPad` modifier flag for the arrows, which is exactly why this asks the key code.
    for code: UInt16 in [36, 18, 19, 20, 21, 23, 48, 123, 124, 125, 126, 71] {
        #expect(!MacKeyCodes.isKeypad(code))
    }
}

// MARK: - modifyOtherKeys

/// The rule the mode exists for: without it these combinations arrive as bytes that a different,
/// easier-to-type combination also produces, so no application can bind them. With level 2 on,
/// each one names itself.
@Test func level2DisambiguatesCombinationsLegacyEncodingLoses() {
    // key, modifiers, what legacy sends, what that collides with, what level 2 sends
    #expect(enc(.tab, [.ctrl]) == "\t")                                   // == plain Tab
    #expect(enc(.tab, [.ctrl], other: .allOtherKeys) == ESC + "[27;5;9~")
    #expect(enc(.enter, [.ctrl]) == "\r")                                 // == plain Enter
    #expect(enc(.enter, [.ctrl], other: .allOtherKeys) == ESC + "[27;5;13~")
    #expect(enc(.enter, [.shift]) == "\r")                                // == plain Enter
    #expect(enc(.enter, [.shift], other: .allOtherKeys) == ESC + "[27;2;13~")
    #expect(enc(.char("A"), [.ctrl, .shift], text: "A") == "\u{01}")       // == ctrl+a
    #expect(enc(.char("A"), [.ctrl, .shift], text: "A", other: .allOtherKeys) == ESC + "[27;6;65~")
    #expect(enc(.char("1"), [.ctrl], text: "1") == "1")                    // == typing "1"
    #expect(enc(.char("1"), [.ctrl], text: "1", other: .allOtherKeys) == ESC + "[27;5;49~")
    #expect(enc(.backspace, [.ctrl]) == "\u{08}")                          // == ctrl+h
    #expect(enc(.backspace, [.ctrl], other: .allOtherKeys) == ESC + "[27;5;127~")
}

/// Level 2 covers the keys xterm calls "well known" as well, which is the whole reason
/// applications ask for level 2 and not level 1 (vim's `keyprotocol=xterm:mok2`).
@Test func level2AlsoRewritesTheUnambiguousControlKeys() {
    #expect(enc(.char("c"), [.ctrl], text: "c", other: .allOtherKeys) == ESC + "[27;5;99~")
    #expect(enc(.char(" "), [.ctrl], text: " ", other: .allOtherKeys) == ESC + "[27;5;32~")
    #expect(enc(.escape, [.ctrl], other: .allOtherKeys) == ESC + "[27;5;27~")
    #expect(enc(.char("c"), [.alt], text: "ç", meta: true, other: .allOtherKeys) == ESC + "[27;3;99~")
    #expect(enc(.char("c"), [.ctrl, .alt], text: "c", other: .allOtherKeys) == ESC + "[27;7;99~")
}

/// Level 1 is the cautious one: it rewrites only what legacy encoding actually loses, and only on
/// character keys. ctrl+c stays 0x03 -- an application that turned on level 1 and then lost the
/// interrupt would be a worse terminal, not a better one.
@Test func level1RewritesOnlyAmbiguousCharacterKeys() {
    // Ambiguous: ctrl on a key with no control character, and shift swallowed by one that has.
    #expect(enc(.char("1"), [.ctrl], text: "1", other: .ambiguousOnly) == ESC + "[27;5;49~")
    #expect(enc(.char(";"), [.ctrl], text: ";", other: .ambiguousOnly) == ESC + "[27;5;59~")
    #expect(enc(.char("A"), [.ctrl, .shift], text: "A", other: .ambiguousOnly) == ESC + "[27;6;65~")
    // Unambiguous, or one of xterm's well-known keys: untouched at level 1.
    #expect(enc(.char("c"), [.ctrl], text: "c", other: .ambiguousOnly) == "\u{03}")
    #expect(enc(.char(" "), [.ctrl], text: " ", other: .ambiguousOnly) == "\u{00}")
    #expect(enc(.char("c"), [.alt], text: "ç", meta: true, other: .ambiguousOnly) == ESC + "c")
    #expect(enc(.tab, [.ctrl], other: .ambiguousOnly) == "\t")
    #expect(enc(.enter, [.ctrl], other: .ambiguousOnly) == "\r")
    #expect(enc(.backspace, [.ctrl], other: .ambiguousOnly) == "\u{08}")
    #expect(enc(.escape, [.ctrl], other: .ambiguousOnly) == ESC)
}

/// What the mode must never touch, at any level: a key pressed with nothing held, and the keys
/// that already carry their modifier in a parameter of their own. Rewriting either would break
/// plain typing and every arrow key in every full-screen application.
@Test func modifyOtherKeysLeavesUnmodifiedAndParameterisedKeysAlone() {
    for level in [ModifyOtherKeys.ambiguousOnly, .allOtherKeys] {
        #expect(enc(.char("a"), text: "a", other: level) == "a")
        #expect(enc(.char("A"), [.shift], text: "A", other: level) == "A")
        #expect(enc(.char("o"), [.alt], text: "ø", other: level) == "ø")   // option composes, not modifies
        #expect(enc(.tab, other: level) == "\t")
        #expect(enc(.enter, other: level) == "\r")
        #expect(enc(.escape, other: level) == ESC)
        #expect(enc(.backspace, other: level) == "\u{7F}")
        #expect(enc(.up, [.ctrl], other: level) == ESC + "[1;5A")
        #expect(enc(.f(5), [.ctrl], other: level) == ESC + "[15;5~")
        #expect(enc(.delete, [.ctrl, .shift], other: level) == ESC + "[3;6~")
        // Back-tab is its own key everywhere it is read; it never becomes an "other key".
        #expect(enc(.tab, [.shift], other: level) == ESC + "[Z")
        // Keypad mode wins over it: xterm reports modifyKeypadKeys as 0.
        #expect(enc(.char("1"), [.ctrl], text: "1", keypad: true, isKeypad: true, other: level) == ESC + "Oq")
        // Command still belongs to the application.
        #expect(enc(.char("c"), [.cmd], text: "c", other: level) == nil)
    }
}

/// The code in the sequence is what the unmodified key sends, so an application can map it back to
/// a key without a table: a character's own code point, and the control byte for the rest.
@Test func theReportedCodeIsWhatTheUnmodifiedKeySends() {
    #expect(enc(.tab, [.ctrl], other: .allOtherKeys) == ESC + "[27;5;9~")        // Tab sends 0x09
    #expect(enc(.enter, [.ctrl], other: .allOtherKeys) == ESC + "[27;5;13~")     // Enter sends 0x0D
    #expect(enc(.escape, [.alt], other: .allOtherKeys) == ESC + "[27;3;27~")     // Escape sends 0x1B
    #expect(enc(.backspace, [.shift], other: .allOtherKeys) == ESC + "[27;2;127~")  // Backspace sends DEL
    #expect(enc(.char("é"), [.ctrl], text: "é", other: .allOtherKeys) == ESC + "[27;5;233~")
}

// MARK: - The mode over the wire

@Test func xtmodkeysSetsAndClearsModifyOtherKeys() {
    let t = makeTerminal().run(ESC + "[>4;2m")
    #expect(t.modes.modifyOtherKeys == .allOtherKeys)
    t.run(ESC + "[>4;1m")
    #expect(t.modes.modifyOtherKeys == .ambiguousOnly)
    t.run(ESC + "[>4;0m")
    #expect(t.modes.modifyOtherKeys == .off)
    // No Pv means "back to the initial value", and so does a bare CSI > m.
    t.run(ESC + "[>4;2m" + ESC + "[>4m")
    #expect(t.modes.modifyOtherKeys == .off)
    t.run(ESC + "[>4;2m" + ESC + "[>m")
    #expect(t.modes.modifyOtherKeys == .off)
}

/// A value this resource does not have, and a resource we do not implement, leave the mode where
/// it was rather than guessing at what was meant.
@Test func xtmodkeysIgnoresValuesItDoesNotImplement() {
    let t = makeTerminal().run(ESC + "[>4;2m")
    t.run(ESC + "[>4;9m")
    #expect(t.modes.modifyOtherKeys == .allOtherKeys)
    t.run(ESC + "[>1;0m" + ESC + "[>2;0m" + ESC + "[>3;0m")
    #expect(t.modes.modifyOtherKeys == .allOtherKeys)
}

/// XTQMODKEYS answers for every resource, and answers with what this terminal really does, so an
/// application can read the reply instead of assuming.
@Test func xtqmodkeysReportsTheTruth() {
    let t = makeTerminal().run(ESC + "[?4m")
    #expect(t.responseText == ESC + "[>4;0m")
    t.responses = []
    t.run(ESC + "[>4;2m" + ESC + "[?4m")
    #expect(t.responseText == ESC + "[>4;2m")
    t.responses = []
    // Cursor and function keys really do carry their modifier as CSI 1;Pm X -- xterm's level 2 --
    // and the keypad really does not carry one, which is xterm's level 0.
    t.run(ESC + "[?0m" + ESC + "[?1m" + ESC + "[?2m" + ESC + "[?3m")
    #expect(t.responseText == ESC + "[>0;0m" + ESC + "[>1;2m" + ESC + "[>2;2m" + ESC + "[>3;0m")
    t.responses = []
    // A resource we have never heard of gets no answer rather than an invented one.
    t.run(ESC + "[?9m")
    #expect(t.responseText == "")
}

/// RIS means "as though the terminal had just started", and a keyboard mode a crashed application
/// left on is exactly what a user reaches for RIS to undo.
@Test func risClearsModifyOtherKeysAndTheKeypad() {
    let t = makeTerminal().run(ESC + "[>4;2m" + ESC + "=")
    #expect(t.modes.modifyOtherKeys == .allOtherKeys && t.modes.keypadApp)
    t.run(ESC + "c")
    #expect(t.modes.modifyOtherKeys == .off && !t.modes.keypadApp)
}

/// Leaving the alternate screen does *not* clear it, because xterm has no such rule: tmux and less
/// set keyboard modes on the main screen and pass through the alternate one, and an application
/// that owns the mode turns it off itself on the way out (vim's `t_TE`).
@Test func leavingTheAlternateScreenKeepsKeyboardModes() {
    let t = makeTerminal().run(ESC + "[>4;2m" + ESC + "=" + ESC + "[?1049h")
    #expect(t.modes.modifyOtherKeys == .allOtherKeys && t.modes.keypadApp)
    t.run(ESC + "[?1049l")
    #expect(t.modes.altScreen == false)
    #expect(t.modes.modifyOtherKeys == .allOtherKeys && t.modes.keypadApp)
}

/// DECKPAM/DECKPNM already parsed before this change; what was missing was anyone reading the
/// flag. This pins the round trip from the escape sequence to the bytes a keypad key sends.
@Test func deckpamReachesTheEncoder() {
    let t = makeTerminal().run(ESC + "=")
    #expect(t.modes.keypadApp)
    let one = KeyEvent(key: .char("1"), modifiers: [], text: "1",
                       isKeypad: MacKeyCodes.isKeypad(83))   // kVK_ANSI_Keypad1
    var options = KeyEncoderOptions(cursorKeysApp: t.modes.cursorKeysApp, optionAsMeta: false,
                                    keypadApp: t.modes.keypadApp, modifyOtherKeys: t.modes.modifyOtherKeys)
    var bytes = KeyEncoder.encode(one, options: options)
    #expect(bytes.map { String(decoding: $0, as: UTF8.self) } == ESC + "Oq")

    t.run(ESC + ">")
    #expect(!t.modes.keypadApp)
    options = KeyEncoderOptions(cursorKeysApp: t.modes.cursorKeysApp, optionAsMeta: false,
                                keypadApp: t.modes.keypadApp, modifyOtherKeys: t.modes.modifyOtherKeys)
    bytes = KeyEncoder.encode(one, options: options)
    #expect(bytes.map { String(decoding: $0, as: UTF8.self) } == "1")
}

/// The same round trip for modifyOtherKeys: the sequence an application sends, then the bytes the
/// key it cares about produces.
@Test func xtmodkeysReachesTheEncoder() {
    let t = makeTerminal()
    let ctrlEnter = KeyEvent(key: .enter, modifiers: [.ctrl], text: nil)
    func encodeNow() -> String? {
        let options = KeyEncoderOptions(cursorKeysApp: t.modes.cursorKeysApp, optionAsMeta: false,
                                        keypadApp: t.modes.keypadApp, modifyOtherKeys: t.modes.modifyOtherKeys)
        return KeyEncoder.encode(ctrlEnter, options: options).map { String(decoding: $0, as: UTF8.self) }
    }
    #expect(encodeNow() == "\r")
    t.run(ESC + "[>4;2m")
    #expect(encodeNow() == ESC + "[27;5;13~")
    t.run(ESC + "[>4;0m")
    #expect(encodeNow() == "\r")
}
