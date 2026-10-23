import Foundation

/// Govee lights. Straight over the local network with the Govee LAN API where a light has
/// "LAN Control" switched on (no cloud, no account), and through the Govee Developer API
/// with the user's API key for the others. Either one alone is enough.
@MainActor
public final class GoveeService: DeviceService {
    public let id = "govee"
    public let title = "Govee"
    public var onChange: (() -> Void)?

    struct Config: Codable {
        /// Look for lights on this Wi-Fi.
        var lan = true
        /// The Govee Developer API key, for lights without LAN control.
        var apiKey: String?
        /// Lights found before, by device id, so they answer without a new scan.
        var known: [String: Known] = [:]
        /// Addresses typed in by hand, for networks where a scan does not reach them.
        var hosts: [String] = []
    }

    struct Known: Codable {
        var sku: String
        var name: String?
        var ip: String?
        var cloud = false
        /// The cloud's device type ("devices.types.light", "devices.types.socket"…).
        var type: String?

        /// A smart plug: only on and off.
        var isPlug: Bool { type?.contains("socket") == true }
    }

    private let vault: SecretStore
    private var config: Config?
    private let lan = GoveeLAN()
    private let session: URLSession
    private var lastScan: Date?

    public init(vault: SecretStore) {
        self.vault = vault
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        session = URLSession(configuration: configuration)
        config = vault.read().flatMap { try? JSONDecoder().decode(Config.self, from: $0) }
    }

    public var isConnected: Bool { config != nil }

    public var info: [String: Any] {
        guard let config else { return ["connected": false] }
        let lights = config.known.count
        return ["connected": true, "name": "Govee", "lan": config.lan, "cloud": config.apiKey != nil,
                "lights": lights, "hosts": config.hosts]
    }

    /// The API key travels to a paired Mac or iPhone; the addresses are found again there.
    public var shareable: [String: Any]? {
        guard let config else { return nil }
        var out: [String: Any] = ["lan": config.lan, "hosts": config.hosts]
        if let key = config.apiKey { out["apiKey"] = key }
        return out
    }

    public func adopt(_ shared: [String: Any]?) {
        guard let shared else {
            if config != nil { disconnect() }
            return
        }
        var next = config ?? Config()
        next.lan = shared["lan"] as? Bool ?? true
        next.apiKey = (shared["apiKey"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        next.hosts = shared["hosts"] as? [String] ?? next.hosts
        save(next)
    }

    public func disconnect() {
        config = nil
        vault.write(nil)
    }

    /// Turns Govee on. With a key, the key is checked against Govee first.
    public func connect(lan: Bool, apiKey raw: String?, hosts: [String] = []) async throws {
        let key = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = (key?.isEmpty ?? true) ? nil : key
        guard lan || apiKey != nil else { throw ServiceFailure("Turn on local control or enter an API key") }
        if let apiKey { _ = try await cloudDevices(key: apiKey) }
        var next = config ?? Config()
        next.lan = lan
        next.apiKey = apiKey
        next.hosts = hosts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        save(next)
        _ = try? await devices()
    }

    private func save(_ next: Config) {
        config = next
        vault.write(try? JSONEncoder().encode(next))
    }

    // MARK: - Devices

    public func devices() async throws -> [ServiceDevice] {
        guard var next = config else { return [] }
        var problem: Error?

        if next.lan {
            let extra = next.hosts + next.known.values.compactMap(\.ip)
            let found = await lan.discover(extra: extra)
            lastScan = Date()
            for light in found {
                // An address belongs to one light: a light that moved frees its old one.
                for (other, known) in next.known where known.ip == light.ip && other != light.id {
                    next.known[other]?.ip = nil
                }
                var known = next.known[light.id] ?? Known(sku: light.sku)
                known.sku = light.sku
                known.ip = light.ip
                next.known[light.id] = known
            }
        }
        if let key = next.apiKey {
            do {
                for device in try await cloudDevices(key: key) {
                    var known = next.known[device.id] ?? Known(sku: device.sku)
                    known.sku = device.sku
                    known.name = device.name
                    known.cloud = true
                    known.type = device.type
                    next.known[device.id] = known
                }
            } catch {
                problem = error
            }
        }
        save(next)
        if next.known.isEmpty, let problem { throw problem }
        if next.known.isEmpty, next.lan, next.apiKey == nil {
            throw ServiceFailure("No Govee light answered on this Wi-Fi. Switch on LAN Control for each light in the Govee app, or add an API key.")
        }

        return next.known.map { id, known in
            var device = ServiceDevice(id: id, name: known.name ?? "Govee \(known.sku)", kind: .light)
            device.capabilities = known.isPlug ? [] : ["brightness", "temp", "color"]
            let route = known.ip != nil ? "Wi-Fi \(known.ip ?? "")" : known.cloud ? "Govee cloud" : "not found"
            device.detail = "\(known.sku)\(known.isPlug ? " plug" : "") · \(route)"
            device.online = known.ip != nil || known.cloud
            return device
        }.sorted { $0.name < $1.name }
    }

    public func read(_ ids: Set<String>) async throws -> [String: DeviceReading] {
        guard let config, !ids.isEmpty else { return [:] }
        var out: [String: DeviceReading] = [:]

        let local = ids.compactMap { id in config.known[id]?.ip.map { (id, $0) } }
        if config.lan, !local.isEmpty {
            let answers = await lan.status(local.map { $0.1 })
            for (id, ip) in local {
                if let status = answers[ip] { out[id] = DeviceReading(light: Self.lightState(status)) }
            }
            // A light that stopped answering may have a new address: look again, now and then.
            if out.count < local.count, Date().timeIntervalSince(lastScan ?? .distantPast) > 60 {
                lastScan = Date()
                Task { @MainActor [weak self] in
                    _ = try? await self?.devices()
                    self?.onChange?()
                }
            }
        }
        if let key = config.apiKey {
            for id in ids where out[id] == nil {
                guard let known = config.known[id], known.cloud,
                      let state = try? await cloudState(key: key, sku: known.sku, device: id) else { continue }
                out[id] = state
            }
        }
        return out
    }

    public func send(kind: DeviceKind, id: String, patch raw: [String: Any], state: [String: Any]) async throws {
        guard kind == .light else { throw ServiceFailure("Govee has no air conditioners here") }
        guard let config, let known = config.known[id] else { throw ServiceFailure("This Govee light is not known any more. Look for lights again.") }
        let patch = DeviceKind.withPower(raw, state: state)
        var commands = Self.commands(patch)
        if known.isPlug { commands = commands.filter { if case .power = $0 { return true } else { return false } } }
        guard !commands.isEmpty else { return }

        if config.lan, let ip = known.ip {
            for (index, command) in commands.enumerated() {
                // Govee lights drop a packet that follows another too closely.
                if index > 0 { try? await Task.sleep(nanoseconds: 60_000_000) }
                switch command {
                case .power(let on): lan.power(on, ip: ip)
                case .brightness(let value): lan.brightness(value, ip: ip)
                case .color(let r, let g, let b): lan.color(r: r, g: g, b: b, ip: ip)
                case .kelvin(let value): lan.kelvin(value, ip: ip)
                }
            }
            await lan.flush()
            return
        }
        guard let key = config.apiKey, known.cloud else {
            throw ServiceFailure("\(known.name ?? known.sku) is not on this Wi-Fi. Switch on LAN Control in the Govee app, or add an API key.")
        }
        for command in commands {
            try await cloudControl(key: key, sku: known.sku, device: id, command)
        }
    }

    // MARK: - Mapping

    enum Command: Equatable {
        case power(Bool)
        case brightness(Int)
        case color(Int, Int, Int)
        case kelvin(Int)
    }

    /// The panel's change as Govee commands, in the order a light takes them: switched on
    /// first, switched off last.
    static func commands(_ patch: [String: Any]) -> [Command] {
        var out: [Command] = []
        let on = patch["on"] as? Bool
        if on == true { out.append(.power(true)) }
        if let b = patch.double("brightness") { out.append(.brightness(Int((max(0.01, min(1, b)) * 100).rounded()))) }
        if let hex = patch["color"] as? String, let (r, g, b) = ColorMath.rgb(hex) {
            out.append(.color(Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded())))
        } else if let k = patch.double("temp") {
            out.append(.kelvin(Int(k.rounded())))
        }
        if on == false { out.append(.power(false)) }
        return out
    }

    static func lightState(_ status: GoveeLAN.Status) -> [String: Any] {
        var out: [String: Any] = [:]
        if let on = status.on { out["on"] = on }
        if let b = status.brightness { out["brightness"] = max(0.01, min(1, Double(b) / 100)) }
        if let k = status.kelvin, k > 0 {
            out["temp"] = Double(k)
            out["color"] = NSNull()
        } else if let c = status.color {
            out["color"] = ColorMath.hex(r: Double(c.r) / 255, g: Double(c.g) / 255, b: Double(c.b) / 255)
        }
        return out
    }

    // MARK: - Govee Developer API

    private static let base = "https://openapi.api.govee.com/router/api/v1"

    struct CloudDevice {
        var id: String
        var sku: String
        var name: String?
        var type: String?
    }

    private func cloudDevices(key: String) async throws -> [CloudDevice] {
        let json = try await call(key: key, "GET", "/user/devices")
        let list = json["data"] as? [[String: Any]] ?? []
        return list.compactMap { item in
            guard let id = item["device"] as? String, let sku = item["sku"] as? String else { return nil }
            // Lights and plugs (a lamp on a plug is a light that only switches); sensors,
            // kettles and humidifiers live in the same account and are left out.
            let type = item["type"] as? String
            if let type, !type.contains("light"), !type.contains("socket") { return nil }
            return CloudDevice(id: id.uppercased(), sku: sku, name: item["deviceName"] as? String, type: type)
        }
    }

    private func cloudState(key: String, sku: String, device: String) async throws -> DeviceReading {
        let json = try await call(key: key, "POST", "/device/state", body: [
            "requestId": UUID().uuidString, "payload": ["sku": sku, "device": device],
        ])
        let capabilities = (json["payload"] as? [String: Any])?["capabilities"] as? [[String: Any]] ?? []
        var light: [String: Any] = [:]
        var online = true
        for capability in capabilities {
            let value = (capability["state"] as? [String: Any])?["value"]
            let number = (value as? NSNumber)?.doubleValue
            switch capability["instance"] as? String {
            case "online": online = (value as? Bool) ?? (number.map { $0 != 0 } ?? true)
            case "powerSwitch": if let number { light["on"] = number != 0 }
            case "brightness": if let number { light["brightness"] = max(0.01, min(1, number / 100)) }
            case "colorTemperatureK":
                if let number, number > 0 { light["temp"] = number; light["color"] = NSNull() }
            case "colorRgb":
                if let number, light["temp"] == nil {
                    let v = Int(number)
                    light["color"] = ColorMath.hex(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255,
                                                   b: Double(v & 0xFF) / 255)
                }
            default: break
            }
        }
        return DeviceReading(light: light, online: online)
    }

    private func cloudControl(key: String, sku: String, device: String, _ command: Command) async throws {
        let capability: [String: Any]
        switch command {
        case .power(let on):
            capability = ["type": "devices.capabilities.on_off", "instance": "powerSwitch", "value": on ? 1 : 0]
        case .brightness(let value):
            capability = ["type": "devices.capabilities.range", "instance": "brightness", "value": value]
        case .color(let r, let g, let b):
            capability = ["type": "devices.capabilities.color_setting", "instance": "colorRgb", "value": (r << 16) | (g << 8) | b]
        case .kelvin(let value):
            capability = ["type": "devices.capabilities.color_setting", "instance": "colorTemperatureK", "value": value]
        }
        _ = try await call(key: key, "POST", "/device/control", body: [
            "requestId": UUID().uuidString,
            "payload": ["sku": sku, "device": device, "capability": capability],
        ])
    }

    private func call(key: String, _ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let url = URL(string: Self.base + path) else { throw ServiceFailure("Bad Govee address") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(key, forHTTPHeaderField: "Govee-API-Key")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ServiceFailure("Govee did not answer: \(error.localizedDescription)")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if status == 401 || status == 403 { throw ServiceFailure("Govee does not accept this API key") }
        if status == 429 { throw ServiceFailure("Govee's daily limit for this API key is used up") }
        let code = (json["code"] as? NSNumber)?.intValue ?? status
        guard (200..<300).contains(status), code == 200 else {
            let reason = json["msg"] as? String ?? json["message"] as? String ?? "status \(code)"
            throw ServiceFailure("Govee: \(reason)")
        }
        return json
    }
}
