/// The handful of macOS virtual key codes the encoder has to know about by number.
///
/// Numbers, not AppKit constants: `NyxCore` cannot import AppKit, and these are the same codes
/// `kVK_ANSI_Keypad*` names in Carbon's `Events.h` -- fixed for the life of the platform. The
/// AppKit layer passes `NSEvent.keyCode` straight through.
public enum MacKeyCodes {
    /// The keys on the numeric keypad, as opposed to the ones on the main block that produce the
    /// same characters.
    ///
    /// `NSEvent.modifierFlags.numericPad` cannot answer this: macOS sets that flag for the arrow
    /// keys too, so a terminal that trusted it would send keypad sequences for the cursor keys.
    /// The key codes are unambiguous.
    ///
    /// `kVK_ANSI_KeypadClear` (71) is deliberately absent: the Mac keypad has no NumLock, and Clear
    /// reports itself as `NSClearLineFunctionKey`, which no application-keypad sequence describes.
    public static func isKeypad(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 65,                    // KeypadDecimal
             67,                    // KeypadMultiply
             69,                    // KeypadPlus
             75,                    // KeypadDivide
             76,                    // KeypadEnter
             78,                    // KeypadMinus
             81,                    // KeypadEquals
             82...89,               // Keypad0...Keypad7
             91, 92:                // Keypad8, Keypad9
            return true
        default:
            return false
        }
    }
}
