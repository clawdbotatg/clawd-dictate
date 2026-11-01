import CoreBluetooth
import Foundation

/// Bluetooth link to both arms of the G1. Sends go left first, then right.
@MainActor
final class G1: NSObject, ObservableObject {
    enum Side: String { case L, R }

    @Published var status = "Starting Bluetooth…"
    @Published var leftOK = false
    @Published var rightOK = false
    @Published var battery: Int?
    @Published var lastEvent = ""
    @Published var pages: [String] = []
    @Published var page = 0

    /// Called for touchpad events: (side, name).
    var onEvent: ((Side, String) -> Void)?
    /// Called with LC3 audio from the glasses mic.
    var onMic: ((Data) -> Void)?

    private var central: CBCentralManager!
    private var periph: [Side: CBPeripheral] = [:]
    private var txChar: [Side: CBCharacteristic] = [:]
    private var waiters: [String: CheckedContinuation<Data?, Never>] = [:]
    private var seq: UInt8 = 0
    private var heartbeat: Timer?
    private var busy = false

    var connected: Bool { leftOK && rightOK }

    private let savedKey = "g1.peripherals"

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: "g1central"])
    }

    // MARK: connect

    func start() {
        guard central.state == .poweredOn else { return }
        // Reconnect to known arms (connect() waits until they're in range).
        if let saved = UserDefaults.standard.dictionary(forKey: savedKey) as? [String: String] {
            for (sideRaw, idStr) in saved {
                guard let side = Side(rawValue: sideRaw), let id = UUID(uuidString: idStr),
                      let p = central.retrievePeripherals(withIdentifiers: [id]).first else { continue }
                adopt(p, side: side)
            }
        }
        // Glasses already connected (by another app) don't advertise: pick them up here.
        for p in central.retrieveConnectedPeripherals(withServices: [CBUUID(string: G1P.service)]) {
            let name = p.name ?? ""
            let side: Side? = name.contains("_L_") ? .L : name.contains("_R_") ? .R : nil
            if let side, periph[side] == nil { adopt(p, side: side) }
        }
        if periph.count < 2 { scan() }
    }

    func scan() {
        status = "Looking for glasses…"
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    func forget() {
        UserDefaults.standard.removeObject(forKey: savedKey)
        for p in periph.values { central.cancelPeripheralConnection(p) }
        periph = [:]; txChar = [:]; leftOK = false; rightOK = false
        scan()
    }

    private func adopt(_ p: CBPeripheral, side: Side) {
        periph[side] = p
        p.delegate = self
        var saved = (UserDefaults.standard.dictionary(forKey: savedKey) as? [String: String]) ?? [:]
        saved[side.rawValue] = p.identifier.uuidString
        UserDefaults.standard.set(saved, forKey: savedKey)
        central.connect(p, options: nil)
    }

    private func side(of p: CBPeripheral) -> Side? {
        periph.first { $0.value.identifier == p.identifier }?.key
    }

    private func refreshStatus() {
        leftOK = txChar[.L] != nil && periph[.L]?.state == .connected
        rightOK = txChar[.R] != nil && periph[.R]?.state == .connected
        status = connected ? "Connected" : (leftOK || rightOK ? "One arm connected…" : "Waiting for glasses…")
        if connected { startHeartbeat() }
    }

    // MARK: send

    private func write(_ data: Data, _ side: Side) {
        guard let p = periph[side], let c = txChar[side] else { return }
        let type: CBCharacteristicWriteType = c.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        p.writeValue(data, for: c, type: type)
    }

    /// Write and wait for a reply starting with the same command byte.
    @discardableResult
    private func request(_ data: Data, _ side: Side, timeout: Double = 2) async -> Data? {
        let key = "\(side.rawValue)-\(data[0])"
        waiters[key]?.resume(returning: nil)
        return await withCheckedContinuation { cont in
            waiters[key] = cont
            write(data, side)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
                if let c = self.waiters.removeValue(forKey: key) { c.resume(returning: nil) }
            }
        }
    }

    private func both(_ data: Data) async {
        await request(data, .L)
        await request(data, .R)
    }

    private func nextSeq() -> UInt8 { seq &+= 1; return seq }

    private var chunkSize: Int {
        let mtu = periph.values.map { $0.maximumWriteValueLength(for: .withoutResponse) }.min() ?? 182
        return max(20, min(191, mtu - 9))
    }

    /// Show text; long text is split into pages you flip with next()/prev().
    func show(_ text: String) async {
        pages = G1P.paginate(text)
        page = 0
        await sendPage()
    }

    func next() async { if page + 1 < pages.count { page += 1; await sendPage() } }
    func prev() async { if page > 0 { page -= 1; await sendPage() } }

    private func sendPage() async {
        guard connected, page < pages.count else { return }
        while busy { try? await Task.sleep(nanoseconds: 50_000_000) }
        busy = true; defer { busy = false }
        for pkt in G1P.textPackets(pages[page], seq: nextSeq(), pageNo: page + 1,
                                   pages: pages.count, chunk: chunkSize) {
            await both(pkt)
        }
    }

    func clear() async {
        guard connected else { return }
        pages = []; page = 0
        await both(G1P.exit)
    }

    func setBrightness(_ level: Int) async {
        guard connected else { return }
        await request(G1P.brightness(level, auto: false), .R)
    }

    /// Turn the glasses mic (right arm) on or off.
    func mic(_ on: Bool) async {
        guard connected else { return }
        await request(Data([0x0E, on ? 1 : 0]), .R)
    }

    func micReply(_ on: Bool) async -> Data? {
        guard connected else { return nil }
        return await request(Data([0x0E, on ? 1 : 0]), .R)
    }

    func readBattery() async {
        guard connected, let r = await request(G1P.battery, .L), r.count > 2 else { return }
        battery = Int(r[2])
    }

    private func startHeartbeat() {
        guard heartbeat == nil else { return }
        heartbeat = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.connected, !self.busy else { return }
                await self.both(G1P.heartbeat(self.nextSeq()))
            }
        }
        Task { await readBattery() }
    }
}

// MARK: - CoreBluetooth delegates (queue = main)

extension G1: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        MainActor.assumeIsolated {
            switch c.state {
            case .poweredOn: start()
            case .unauthorized: status = "Bluetooth not allowed (Settings > Glasses)"
            case .poweredOff: status = "Bluetooth is off"
            default: status = "Bluetooth unavailable"
            }
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, willRestoreState dict: [String: Any]) {
        MainActor.assumeIsolated {
            for p in (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? [] {
                let name = p.name ?? ""
                if name.contains("_L_") { periph[.L] = p; p.delegate = self }
                if name.contains("_R_") { periph[.R] = p; p.delegate = self }
            }
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                                    advertisementData ad: [String: Any], rssi: NSNumber) {
        MainActor.assumeIsolated {
            let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
            guard name.hasPrefix("Even") else { return }
            let side: Side? = name.contains("_L_") ? .L : name.contains("_R_") ? .R : nil
            guard let side, periph[side] == nil else { return }
            adopt(p, side: side)
            if periph.count == 2 { c.stopScan() }
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        MainActor.assumeIsolated {
            p.delegate = self
            p.discoverServices([CBUUID(string: G1P.service)])
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            if let s = side(of: p) { txChar[s] = nil }
            refreshStatus()
            c.connect(p, options: nil)  // auto-reconnect when back in range
        }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { c.connect(p, options: nil) }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            for s in p.services ?? [] where s.uuid == CBUUID(string: G1P.service) {
                p.discoverCharacteristics([CBUUID(string: G1P.tx), CBUUID(string: G1P.rx)], for: s)
            }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard let side = side(of: p) else { return }
            for ch in s.characteristics ?? [] {
                if ch.uuid == CBUUID(string: G1P.tx) { txChar[side] = ch }
                if ch.uuid == CBUUID(string: G1P.rx) { p.setNotifyValue(true, for: ch) }
            }
            refreshStatus()
            if txChar[side] != nil { write(G1P.initCmd, side) }
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard let data = ch.value, let first = data.first, let side = side(of: p) else { return }
            if first == 0xF1, data.count > 2 {
                onMic?(data.dropFirst(2))
                return
            }
            if first == G1P.evtDevice, data.count > 1 {
                let name = G1P.events[data[1]] ?? String(format: "0x%02x", data[1])
                lastEvent = "\(side.rawValue) \(name)"
                onEvent?(side, name)
                return
            }
            if first != G1P.cmdHeartbeat { GlassesBridge.log("rx \(side.rawValue) " + data.prefix(12).map { String(format: "%02x", $0) }.joined()) }
            if let c = waiters.removeValue(forKey: "\(side.rawValue)-\(first)") {
                c.resume(returning: data)
            }
        }
    }
}
