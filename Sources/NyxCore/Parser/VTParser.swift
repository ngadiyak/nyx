/// Receiver of parser actions. Implemented by `Terminal`.
public protocol TerminalActions: AnyObject {
    func print(_ scalar: Unicode.Scalar)
    func execute(_ byte: UInt8)
    func csi(_ params: CSIParams, intermediates: [UInt8], final: UInt8)
    func esc(intermediates: [UInt8], final: UInt8)
    func osc(_ data: [UInt8])
    func dcsHook(_ params: CSIParams, intermediates: [UInt8], final: UInt8)
    func dcsPut(_ byte: UInt8)
    func dcsUnhook()
}

/// DEC ANSI-compatible escape sequence parser (Paul Williams' state machine) with an inline UTF-8 decoder.
/// 8-bit C1 controls are not recognised: all bytes >= 0x80 are UTF-8.
public final class VTParser {
    public static let maxOSCLength = 65536
    public static let maxParams = 32

    private enum State {
        case ground, escape, escapeIntermediate
        case csiEntry, csiParam, csiIntermediate, csiIgnore
        case oscString
        case dcsEntry, dcsParam, dcsIntermediate, dcsPassthrough, dcsIgnore
        case sosPmApcString
    }

    private weak var actions: TerminalActions?
    private var state: State = .ground
    private var intermediates: [UInt8] = []
    private var params: [[Int]] = []
    private var currentSub: [Int] = []
    private var currentValue = 0
    private var hasDigits = false
    private var oscBuffer: [UInt8] = []
    private var oscOverflow = false
    private var utf8Pending = 0
    private var utf8Value: UInt32 = 0
    private var utf8Min: UInt32 = 0

    public init(actions: TerminalActions) {
        self.actions = actions
        oscBuffer.reserveCapacity(256)
    }

    public func feed(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { feed($0) }
    }

    public func feed(_ bytes: UnsafeBufferPointer<UInt8>) {
        for b in bytes { advance(b) }
    }

    // MARK: - Byte dispatch

    private func advance(_ b: UInt8) {
        if utf8Pending > 0 {
            if b & 0xC0 == 0x80 {
                utf8Value = (utf8Value << 6) | UInt32(b & 0x3F)
                utf8Pending -= 1
                if utf8Pending == 0 {
                    if utf8Value < utf8Min || utf8Value > 0x10FFFF || (0xD800...0xDFFF).contains(utf8Value) {
                        actions?.print("\u{FFFD}")
                    } else {
                        actions?.print(Unicode.Scalar(utf8Value)!)
                    }
                }
                return
            }
            utf8Pending = 0
            actions?.print("\u{FFFD}")
            // fall through: `b` is processed normally
        }

        // "Anywhere" transitions.
        switch b {
        case 0x18, 0x1A:
            leaveStringState()
            actions?.execute(b)
            state = .ground
            return
        case 0x1B:
            leaveStringState()
            enter(.escape)
            return
        default:
            break
        }

        switch state {
        case .ground:
            if b < 0x20 { actions?.execute(b) }
            else if b < 0x7F { actions?.print(Unicode.Scalar(b)) }
            else if b == 0x7F { /* DEL ignored */ }
            else { startUTF8(b) }

        case .escape:
            switch b {
            case 0x00...0x1F: actions?.execute(b)
            case 0x20...0x2F: intermediates.append(b); state = .escapeIntermediate
            case 0x50: enter(.dcsEntry)                       // P
            case 0x58, 0x5E, 0x5F: state = .sosPmApcString    // X ^ _
            case 0x5B: enter(.csiEntry)                       // [
            case 0x5D: enter(.oscString)                      // ]
            case 0x30...0x4F, 0x51...0x57, 0x59, 0x5A, 0x5C, 0x60...0x7E:
                actions?.esc(intermediates: intermediates, final: b)
                state = .ground
            default: break
            }

        case .escapeIntermediate:
            switch b {
            case 0x00...0x1F: actions?.execute(b)
            case 0x20...0x2F: intermediates.append(b)
            case 0x30...0x7E:
                actions?.esc(intermediates: intermediates, final: b)
                state = .ground
            default: break
            }

        case .csiEntry, .csiParam, .csiIntermediate:
            switch b {
            case 0x00...0x1F: actions?.execute(b)
            case 0x30...0x39 where state != .csiIntermediate:
                currentValue = min(currentValue * 10 + Int(b - 0x30), 65535)
                hasDigits = true
                state = .csiParam
            case 0x3A where state != .csiIntermediate:
                pushSubParam(); state = .csiParam
            case 0x3B where state != .csiIntermediate:
                pushParam(); state = .csiParam
            case 0x3C...0x3F where state == .csiEntry:
                intermediates.append(b); state = .csiParam
            case 0x30...0x3F:
                state = .csiIgnore
            case 0x20...0x2F:
                intermediates.append(b); state = .csiIntermediate
            case 0x40...0x7E:
                finishParams()
                actions?.csi(CSIParams(params), intermediates: intermediates, final: b)
                state = .ground
            default: break
            }

        case .csiIgnore:
            switch b {
            case 0x00...0x1F: actions?.execute(b)
            case 0x40...0x7E: state = .ground
            default: break
            }

        case .oscString:
            switch b {
            case 0x07:
                dispatchOSC()
                state = .ground
            case 0x00...0x06, 0x08...0x1F:
                break
            default:
                if oscBuffer.count < VTParser.maxOSCLength { oscBuffer.append(b) } else { oscOverflow = true }
            }

        case .dcsEntry, .dcsParam, .dcsIntermediate:
            switch b {
            case 0x00...0x1F: break
            case 0x30...0x39 where state != .dcsIntermediate:
                currentValue = min(currentValue * 10 + Int(b - 0x30), 65535)
                hasDigits = true
                state = .dcsParam
            case 0x3A where state != .dcsIntermediate:
                pushSubParam(); state = .dcsParam
            case 0x3B where state != .dcsIntermediate:
                pushParam(); state = .dcsParam
            case 0x3C...0x3F where state == .dcsEntry:
                intermediates.append(b); state = .dcsParam
            case 0x30...0x3F:
                state = .dcsIgnore
            case 0x20...0x2F:
                intermediates.append(b); state = .dcsIntermediate
            case 0x40...0x7E:
                finishParams()
                actions?.dcsHook(CSIParams(params), intermediates: intermediates, final: b)
                state = .dcsPassthrough
            default: break
            }

        case .dcsPassthrough:
            if b != 0x7F { actions?.dcsPut(b) }

        case .dcsIgnore, .sosPmApcString:
            break
        }
    }

    // MARK: - Helpers

    private func enter(_ s: State) {
        intermediates.removeAll(keepingCapacity: true)
        params.removeAll(keepingCapacity: true)
        currentSub.removeAll(keepingCapacity: true)
        currentValue = 0
        hasDigits = false
        if s == .oscString { oscBuffer.removeAll(keepingCapacity: true); oscOverflow = false }
        state = s
    }

    /// Called before leaving a string-collecting state through ESC/CAN/SUB.
    private func leaveStringState() {
        switch state {
        case .oscString: dispatchOSC()
        case .dcsPassthrough: actions?.dcsUnhook()
        default: break
        }
    }

    private func dispatchOSC() {
        if !oscOverflow { actions?.osc(oscBuffer) }
        oscBuffer.removeAll(keepingCapacity: true)
        oscOverflow = false
    }

    private func pushSubParam() {
        currentSub.append(currentValue)
        currentValue = 0
        hasDigits = false
    }

    private func pushParam() {
        currentSub.append(currentValue)
        if params.count < VTParser.maxParams { params.append(currentSub) }
        currentSub.removeAll(keepingCapacity: true)
        currentValue = 0
        hasDigits = false
    }

    private func finishParams() {
        if hasDigits || !currentSub.isEmpty || !params.isEmpty { pushParam() }
    }

    private func startUTF8(_ b: UInt8) {
        switch b {
        case 0xC2...0xDF: utf8Pending = 1; utf8Value = UInt32(b & 0x1F); utf8Min = 0x80
        case 0xE0...0xEF: utf8Pending = 2; utf8Value = UInt32(b & 0x0F); utf8Min = 0x800
        case 0xF0...0xF4: utf8Pending = 3; utf8Value = UInt32(b & 0x07); utf8Min = 0x10000
        default: actions?.print("\u{FFFD}")
        }
    }
}
