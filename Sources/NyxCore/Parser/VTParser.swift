/// Receiver of parser actions. Implemented by `Terminal`.
public protocol TerminalActions: AnyObject {
    func print(_ scalar: Unicode.Scalar)
    /// Print a run of printable ASCII bytes (0x20...0x7E), in order. Equivalent to one `print`
    /// per byte; receivers that can write a whole run at once override it for throughput.
    func printASCII(_ bytes: UnsafePointer<UInt8>, count: Int)
    func execute(_ byte: UInt8)
    func csi(_ params: CSIParams, intermediates: [UInt8], final: UInt8)
    func esc(intermediates: [UInt8], final: UInt8)
    func osc(_ data: [UInt8])
    func dcsHook(_ params: CSIParams, intermediates: [UInt8], final: UInt8)
    func dcsPut(_ byte: UInt8)
    func dcsUnhook()
}

extension TerminalActions {
    public func printASCII(_ bytes: UnsafePointer<UInt8>, count: Int) {
        for i in 0..<count { self.print(Unicode.Scalar(bytes[i])) }
    }
}

/// Type-erasing receiver, so `VTParser` (below) can be built over any `TerminalActions` value.
/// Costs one extra hop per action; `Terminal` instantiates `VTParserOf<Terminal>` and pays nothing.
public final class AnyTerminalActions: TerminalActions {
    private unowned(unsafe) let base: TerminalActions

    public init(_ base: TerminalActions) { self.base = base }

    public func print(_ scalar: Unicode.Scalar) { base.print(scalar) }
    public func printASCII(_ bytes: UnsafePointer<UInt8>, count: Int) { base.printASCII(bytes, count: count) }
    public func execute(_ byte: UInt8) { base.execute(byte) }
    public func csi(_ params: CSIParams, intermediates: [UInt8], final: UInt8) { base.csi(params, intermediates: intermediates, final: final) }
    public func esc(intermediates: [UInt8], final: UInt8) { base.esc(intermediates: intermediates, final: final) }
    public func osc(_ data: [UInt8]) { base.osc(data) }
    public func dcsHook(_ params: CSIParams, intermediates: [UInt8], final: UInt8) { base.dcsHook(params, intermediates: intermediates, final: final) }
    public func dcsPut(_ byte: UInt8) { base.dcsPut(byte) }
    public func dcsUnhook() { base.dcsUnhook() }
}

/// A parser over a statically known receiver. `VTParser` is the type-erased form.
public typealias VTParser = VTParserOf<AnyTerminalActions>

/// DEC ANSI-compatible escape sequence parser (Paul Williams' state machine) with an inline UTF-8 decoder.
/// 8-bit C1 controls are not recognised: all bytes >= 0x80 are UTF-8.
///
/// Generic over the receiver so that every action call specialises to a direct, inlinable call:
/// dispatching a `TerminalActions` existential per byte cost a witness lookup plus
/// `swift_unknownObjectRetain`/`Release` around each call.
public final class VTParserOf<A: TerminalActions> {
    public static var maxOSCLength: Int { 65536 }
    public static var maxParams: Int { 32 }

    private enum State {
        case ground, escape, escapeIntermediate
        case csiEntry, csiParam, csiIntermediate, csiIgnore
        case oscString
        case dcsEntry, dcsParam, dcsIntermediate, dcsPassthrough, dcsIgnore
        case sosPmApcString
    }

    /// Unowned-unsafe: the parser is owned by its actions receiver (`Terminal` holds the parser),
    /// so the receiver always outlives it. A `weak` reference here cost a side-table load and an
    /// ARC release on every single byte.
    private unowned(unsafe) let actions: A
    /// Non-nil only for the type-erased form, which owns the box it dispatches through.
    private let ownedActions: AnyObject?
    private var state: State = .ground
    private var intermediates: [UInt8] = []
    /// Parameters of the sequence being parsed, flat: all values end to end in `flatParams`,
    /// with one end index per parameter in `paramEnds`. Both buffers are reused between sequences,
    /// so a CSI costs no allocation (the previous nested `[[Int]]` allocated per parameter).
    private var flatParams: [Int] = []
    private var paramEnds: [Int] = []
    private var currentValue = 0
    private var hasDigits = false
    private var oscBuffer: [UInt8] = []
    private var oscOverflow = false
    private var utf8Pending = 0
    private var utf8Value: UInt32 = 0
    private var utf8Min: UInt32 = 0

    public init(actions: A, owning: AnyObject? = nil) {
        self.actions = actions
        ownedActions = owning
        oscBuffer.reserveCapacity(256)
        flatParams.reserveCapacity(Self.maxParams * 2)
        paramEnds.reserveCapacity(Self.maxParams)
    }

    public func feed(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { feed($0) }
    }

    public func feed(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard let base = bytes.baseAddress else { return }
        let n = bytes.count
        var i = 0
        while i < n {
            // Ground-state fast path: hand a whole run of printable ASCII to the receiver at once,
            // instead of one state-machine dispatch (and one cell write) per byte.
            if state == .ground, utf8Pending == 0, base[i] >= 0x20, base[i] < 0x7F {
                var j = i + 1
                while j < n, base[j] >= 0x20, base[j] < 0x7F { j += 1 }
                actions.printASCII(base + i, count: j - i)
                i = j
                continue
            }
            advance(base[i])
            i += 1
        }
    }

    // MARK: - Byte dispatch

    private func advance(_ b: UInt8) {
        if utf8Pending > 0 {
            if b & 0xC0 == 0x80 {
                utf8Value = (utf8Value << 6) | UInt32(b & 0x3F)
                utf8Pending -= 1
                if utf8Pending == 0 {
                    if utf8Value < utf8Min || utf8Value > 0x10FFFF || (0xD800...0xDFFF).contains(utf8Value) {
                        actions.print("\u{FFFD}")
                    } else {
                        actions.print(Unicode.Scalar(utf8Value)!)
                    }
                }
                return
            }
            utf8Pending = 0
            actions.print("\u{FFFD}")
            // fall through: `b` is processed normally
        }

        // "Anywhere" transitions.
        switch b {
        case 0x18, 0x1A:
            leaveStringState()
            actions.execute(b)
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
            if b < 0x20 { actions.execute(b) }
            else if b < 0x7F { actions.print(Unicode.Scalar(b)) }
            else if b == 0x7F { /* DEL ignored */ }
            else { startUTF8(b) }

        case .escape:
            switch b {
            case 0x00...0x1F: actions.execute(b)
            case 0x20...0x2F: intermediates.append(b); state = .escapeIntermediate
            case 0x50: enter(.dcsEntry)                       // P
            case 0x58, 0x5E, 0x5F: state = .sosPmApcString    // X ^ _
            case 0x5B: enter(.csiEntry)                       // [
            case 0x5D: enter(.oscString)                      // ]
            case 0x30...0x4F, 0x51...0x57, 0x59, 0x5A, 0x5C, 0x60...0x7E:
                actions.esc(intermediates: intermediates, final: b)
                state = .ground
            default: break
            }

        case .escapeIntermediate:
            switch b {
            case 0x00...0x1F: actions.execute(b)
            case 0x20...0x2F: intermediates.append(b)
            case 0x30...0x7E:
                actions.esc(intermediates: intermediates, final: b)
                state = .ground
            default: break
            }

        case .csiEntry, .csiParam, .csiIntermediate:
            switch b {
            case 0x00...0x1F: actions.execute(b)
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
                actions.csi(currentParams(), intermediates: intermediates, final: b)
                state = .ground
            default: break
            }

        case .csiIgnore:
            switch b {
            case 0x00...0x1F: actions.execute(b)
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
                if oscBuffer.count < Self.maxOSCLength { oscBuffer.append(b) } else { oscOverflow = true }
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
                actions.dcsHook(currentParams(), intermediates: intermediates, final: b)
                state = .dcsPassthrough
            default: break
            }

        case .dcsPassthrough:
            if b != 0x7F { actions.dcsPut(b) }

        case .dcsIgnore, .sosPmApcString:
            break
        }
    }

    // MARK: - Helpers

    private func enter(_ s: State) {
        intermediates.removeAll(keepingCapacity: true)
        flatParams.removeAll(keepingCapacity: true)
        paramEnds.removeAll(keepingCapacity: true)
        currentValue = 0
        hasDigits = false
        if s == .oscString { oscBuffer.removeAll(keepingCapacity: true); oscOverflow = false }
        state = s
    }

    /// Called before leaving a string-collecting state through ESC/CAN/SUB.
    private func leaveStringState() {
        switch state {
        case .oscString: dispatchOSC()
        case .dcsPassthrough: actions.dcsUnhook()
        default: break
        }
    }

    private func dispatchOSC() {
        if !oscOverflow { actions.osc(oscBuffer) }
        oscBuffer.removeAll(keepingCapacity: true)
        oscOverflow = false
    }

    private func pushSubParam() {
        flatParams.append(currentValue)
        currentValue = 0
        hasDigits = false
    }

    private func pushParam() {
        flatParams.append(currentValue)
        if paramEnds.count < Self.maxParams {
            paramEnds.append(flatParams.count)
        } else {
            // Over the cap: drop this parameter's values again.
            flatParams.removeLast(flatParams.count - (paramEnds.last ?? 0))
        }
        currentValue = 0
        hasDigits = false
    }

    private func finishParams() {
        if hasDigits || flatParams.count > (paramEnds.last ?? 0) || !paramEnds.isEmpty { pushParam() }
    }

    @inline(__always)
    private func currentParams() -> CSIParams { CSIParams(flat: flatParams, ends: paramEnds) }

    private func startUTF8(_ b: UInt8) {
        switch b {
        case 0xC2...0xDF: utf8Pending = 1; utf8Value = UInt32(b & 0x1F); utf8Min = 0x80
        case 0xE0...0xEF: utf8Pending = 2; utf8Value = UInt32(b & 0x0F); utf8Min = 0x800
        case 0xF0...0xF4: utf8Pending = 3; utf8Value = UInt32(b & 0x07); utf8Min = 0x10000
        default: actions.print("\u{FFFD}")
        }
    }
}

extension VTParserOf where A == AnyTerminalActions {
    /// Builds a parser over any receiver, boxing it. Prefer `VTParserOf<Concrete>` on hot paths.
    public convenience init<R: TerminalActions>(actions receiver: R) {
        let box = AnyTerminalActions(receiver)
        self.init(actions: box, owning: box)
    }
}
