import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The Govee LAN API: JSON over UDP on the local network, no cloud and no account.
///
/// - Scans go to port 4001: the multicast group 239.255.255.250, and also every host of the
///   local subnet (up to a /22), because an iPhone app may only send multicast with a special entitlement.
/// - Lights answer on port 4002, where this listens.
/// - Commands and status requests go to the light's port 4003.
///
/// Each light needs "LAN Control" switched on once in the Govee app (device → settings).
final class GoveeLAN: @unchecked Sendable {
    static let scanPort: UInt16 = 4001
    static let listenPort: UInt16 = 4002
    static let commandPort: UInt16 = 4003
    static let multicastGroup = "239.255.255.250"

    struct Found: Equatable {
        var ip: String
        var id: String
        var sku: String
    }

    struct Status {
        var on: Bool?
        var brightness: Int?
        var color: (r: Int, g: Int, b: Int)?
        var kelvin: Int?
    }

    private let queue = DispatchQueue(label: "house.govee.lan")
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    /// Every light that answered a scan, by device id, with when it last did.
    private var found: [String: (Found, Date)] = [:]
    /// The last status each address reported, with when.
    private var statuses: [String: (Status, Date)] = [:]

    deinit { source?.cancel() }

    // MARK: - Asking

    /// Scans the network and returns every light that answered within `wait` seconds.
    func discover(extra: [String], wait: Double = 2.5) async -> [Found] {
        guard start() else { return [] }
        let since = Date()
        queue.async { [self] in
            guard let scan = Self.encode(["cmd": "scan", "data": ["account_topic": "reserve"]]) else { return }
            sendRaw(scan, to: Self.multicastGroup, port: Self.scanPort)
            var targets = Set(extra)
            if let (ip, mask) = Self.localIPv4() { targets.formUnion(Self.subnetHosts(ip: ip, mask: mask)) }
            for ip in targets { sendRaw(scan, to: ip, port: Self.scanPort) }
        }
        // A second scan a moment later catches lights that missed the first.
        try? await Task.sleep(nanoseconds: UInt64(wait / 2 * 1_000_000_000))
        queue.async { [self] in
            guard let scan = Self.encode(["cmd": "scan", "data": ["account_topic": "reserve"]]) else { return }
            sendRaw(scan, to: Self.multicastGroup, port: Self.scanPort)
            for ip in extra { sendRaw(scan, to: ip, port: Self.scanPort) }
        }
        try? await Task.sleep(nanoseconds: UInt64(wait / 2 * 1_000_000_000))
        return lock.withLock { found.values.filter { $0.1 >= since }.map { $0.0 } }
    }

    /// Asks each address for its state; returns what answered within `wait` seconds.
    func status(_ ips: [String], wait: Double = 1.5) async -> [String: Status] {
        guard start(), !ips.isEmpty else { return [:] }
        let since = Date()
        for ip in ips { send(["cmd": "devStatus", "data": [String: Any]()], to: ip) }
        let deadline = since.addingTimeInterval(wait)
        var out: [String: Status] = [:]
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            out = lock.withLock { statuses.filter { ips.contains($0.key) && $0.value.1 >= since }.mapValues { $0.0 } }
            if out.count == ips.count { break }
        }
        return out
    }

    // MARK: - Commands

    func power(_ on: Bool, ip: String) {
        send(["cmd": "turn", "data": ["value": on ? 1 : 0]], to: ip)
    }

    /// 1…100.
    func brightness(_ value: Int, ip: String) {
        send(["cmd": "brightness", "data": ["value": min(max(value, 1), 100)]], to: ip)
    }

    func color(r: Int, g: Int, b: Int, ip: String) {
        send(["cmd": "colorwc", "data": ["color": ["r": r, "g": g, "b": b], "colorTemInKelvin": 0]], to: ip)
    }

    func kelvin(_ value: Int, ip: String) {
        send(["cmd": "colorwc", "data": ["color": ["r": 255, "g": 255, "b": 255], "colorTemInKelvin": value]], to: ip)
    }

    /// Waits until everything queued has been handed to the network.
    func flush() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { done.resume() }
        }
    }

    // MARK: - Socket

    /// Opens the UDP socket on port 4002 the first time; false if that is impossible.
    @discardableResult
    func start() -> Bool {
        queue.sync {
            if fd >= 0 { return true }
            let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard s >= 0 else { return false }

            var yes: Int32 = 1
            let size = socklen_t(MemoryLayout<Int32>.size)
            setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, size)
            setsockopt(s, SOL_SOCKET, SO_REUSEPORT, &yes, size)
            setsockopt(s, SOL_SOCKET, SO_BROADCAST, &yes, size)

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = Self.listenPort.bigEndian
            addr.sin_addr.s_addr = INADDR_ANY
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { close(s); return false }

            // Lights may answer to the multicast group; joining it fails quietly without the entitlement.
            var group = ip_mreq()
            inet_pton(AF_INET, Self.multicastGroup, &group.imr_multiaddr)
            group.imr_interface.s_addr = INADDR_ANY
            setsockopt(s, IPPROTO_IP, IP_ADD_MEMBERSHIP, &group, socklen_t(MemoryLayout<ip_mreq>.size))

            _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
            fd = s
            let reader = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
            reader.setEventHandler { [weak self] in self?.drain() }
            reader.setCancelHandler { close(s) }
            reader.resume()
            source = reader
            return true
        }
    }

    private func send(_ msg: [String: Any], to ip: String) {
        guard start(), let data = Self.encode(msg) else { return }
        queue.async { [self] in sendRaw(data, to: ip, port: Self.commandPort) }
    }

    private static func encode(_ msg: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["msg": msg])
    }

    /// On `queue` only.
    private func sendRaw(_ data: Data, to ip: String, port: UInt16) {
        guard fd >= 0 else { return }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return }
        let socketFD = fd
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { target in
                    _ = sendto(socketFD, buffer.baseAddress, buffer.count, 0, target,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// On `queue` only.
    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let socketFD = fd
        while true {
            var from = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &from) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sender in
                        recvfrom(socketFD, bytes.baseAddress, bytes.count, 0, sender, &length)
                    }
                }
            }
            guard count > 0 else { return }
            let ip = String(cString: inet_ntoa(from.sin_addr))
            receive(Data(buffer[0..<count]), from: ip)
        }
    }

    func receive(_ data: Data, from ip: String) {
        guard let reply = Self.parse(data, from: ip) else { return }
        lock.withLock {
            switch reply {
            case .found(let light): found[light.id] = (light, Date())
            case .status(let address, let status): statuses[address] = (status, Date())
            }
        }
    }

    enum Reply {
        case found(Found)
        case status(String, Status)
    }

    static func parse(_ data: Data, from ip: String) -> Reply? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = json["msg"] as? [String: Any], let cmd = msg["cmd"] as? String,
              let body = msg["data"] as? [String: Any] else { return nil }
        func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue ?? (value as? String).flatMap { Int($0) } }
        switch cmd {
        case "scan":
            guard let id = body["device"] as? String, !id.isEmpty else { return nil }
            return .found(Found(ip: body["ip"] as? String ?? ip, id: id.uppercased(), sku: body["sku"] as? String ?? "Govee"))
        case "devStatus":
            var status = Status()
            status.on = int(body["onOff"]).map { $0 == 1 }
            status.brightness = int(body["brightness"])
            if let c = body["color"] as? [String: Any], let r = int(c["r"]), let g = int(c["g"]), let b = int(c["b"]) {
                status.color = (r, g, b)
            }
            status.kelvin = int(body["colorTemInKelvin"])
            return .status(ip, status)
        default:
            return nil
        }
    }

    // MARK: - The local network

    /// This device's Wi-Fi (en0) IPv4 address and netmask.
    static func localIPv4() -> (in_addr, in_addr)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let entry = current.pointee
            if let addr = entry.ifa_addr, let mask = entry.ifa_netmask,
               addr.pointee.sa_family == UInt8(AF_INET),
               String(cString: entry.ifa_name) == "en0" {
                let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                return (ip, netmask)
            }
            cursor = entry.ifa_next
        }
        return nil
    }

    /// Every other host of the subnet, at most the /22 around this device (home routers
    /// such as eero hand out /22s).
    static func subnetHosts(ip: in_addr, mask: in_addr) -> [String] {
        let address = UInt32(bigEndian: ip.s_addr)
        var netmask = UInt32(bigEndian: mask.s_addr)
        if netmask.nonzeroBitCount < 22 { netmask = 0xFFFF_FC00 }
        let network = address & netmask
        let hosts = ~netmask
        guard hosts > 1, hosts <= 1024 else { return [] }
        return (1..<hosts).compactMap { offset in
            let host = network | offset
            guard host != address else { return nil }
            return String(cString: inet_ntoa(in_addr(s_addr: host.bigEndian)))
        }
    }
}
