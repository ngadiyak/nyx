import Foundation
import NyxCore

let args = CommandLine.arguments
var data: [UInt8]
if args.count > 1 {
    data = Array(try Data(contentsOf: URL(fileURLWithPath: args[1])))
} else {
    var s = ""
    s.reserveCapacity(120 * 800_000)
    for i in 0..<800_000 {
        s += "\u{1B}[32mline \(i)\u{1B}[0m \u{1B}[1;34mpath/to/file.swift:\(i % 500):7\u{1B}[0m текст Жё 漢字 filler text to make the line about one hundred bytes long\r\n"
    }
    data = Array(s.utf8)
}

let terminal = Terminal(cols: 200, rows: 50, scrollbackLimit: 10_000)
let start = DispatchTime.now()
data.withUnsafeBufferPointer { buf in
    var offset = 0
    while offset < buf.count {
        let n = min(65536, buf.count - offset)
        terminal.feed(UnsafeBufferPointer(rebasing: buf[offset..<(offset + n)]))
        offset += n
    }
}
let seconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
let mb = Double(data.count) / 1e6
print(String(format: "%.1f MB in %.3f s = %.0f MB/s", mb, seconds, mb / seconds))
