import Foundation

/// Even Realities G1 packet formats (same as protocol.py on the Mac).
enum G1P {
    static let service = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
    static let tx = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"   // write
    static let rx = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"   // notify

    static let ackOK: UInt8 = 0xC9
    static let cmdText: UInt8 = 0x4E
    static let cmdExit: UInt8 = 0x18
    static let cmdHeartbeat: UInt8 = 0x25
    static let cmdBattery: UInt8 = 0x2C
    static let cmdBrightness: UInt8 = 0x01
    static let evtDevice: UInt8 = 0xF5

    static let charsPerLine = 40
    static let linesPerPage = 5
    static let statusText: UInt8 = 0x71

    static let events: [UInt8: String] = [
        0x00: "double_tap", 0x01: "single_tap", 0x02: "head_up", 0x03: "head_down",
        0x04: "triple_tap", 0x05: "triple_tap", 0x06: "glasses_on", 0x07: "glasses_off",
        0x08: "case_open", 0x09: "charging", 0x0B: "case_closed",
        0x17: "long_press_start", 0x18: "long_press_end",
    ]

    static var exit: Data { Data([cmdExit]) }
    static var battery: Data { Data([cmdBattery, 0x01]) }
    static var initCmd: Data { Data([0x4D, 0x01]) }

    static func heartbeat(_ seq: UInt8) -> Data { Data([cmdHeartbeat, 0x06, 0x00, seq, 0x04, seq]) }

    static func brightness(_ level: Int, auto: Bool) -> Data {
        Data([cmdBrightness, UInt8(max(0, min(63, level))), auto ? 1 : 0])
    }

    /// Word-wrap into lines of `width` chars, keeping blank lines.
    static func wrap(_ text: String, width: Int = charsPerLine) -> [String] {
        var lines: [String] = []
        for para in text.components(separatedBy: "\n") {
            var cur = ""
            for word in para.split(separator: " ", omittingEmptySubsequences: true) {
                var w = String(word)
                while w.count > width {   // hard-break very long words
                    if !cur.isEmpty { lines.append(cur); cur = "" }
                    lines.append(String(w.prefix(width)))
                    w = String(w.dropFirst(width))
                }
                if cur.isEmpty { cur = w }
                else if cur.count + 1 + w.count <= width { cur += " " + w }
                else { lines.append(cur); cur = w }
            }
            lines.append(cur)
        }
        while lines.last == "" && lines.count > 1 { lines.removeLast() }
        return lines
    }

    static func paginate(_ text: String) -> [String] {
        let lines = wrap(text)
        var pages: [String] = []
        var i = 0
        while i < lines.count {
            pages.append(lines[i..<min(i + linesPerPage, lines.count)].joined(separator: "\n"))
            i += linesPerPage
        }
        return pages.isEmpty ? [""] : pages
    }

    /// 0x4E text packets for one page. `chunk` = max payload bytes per packet.
    static func textPackets(_ page: String, seq: UInt8, pageNo: Int, pages: Int, chunk: Int) -> [Data] {
        var chunks: [Data] = []
        var cur = Data()
        for ch in page {
            let b = Data(String(ch).utf8)
            if cur.count + b.count > chunk { chunks.append(cur); cur = Data() }
            cur.append(b)
        }
        chunks.append(cur)
        return chunks.enumerated().map { i, c in
            var d = Data([cmdText, seq, UInt8(chunks.count), UInt8(i), statusText, 0, 0,
                          UInt8(min(pageNo, 255)), UInt8(min(pages, 255))])
            d.append(c)
            return d
        }
    }
}
