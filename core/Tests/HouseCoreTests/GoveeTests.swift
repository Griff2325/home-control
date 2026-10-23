import XCTest
@testable import HouseCore

/// Govee: what the LAN API sends back, and the panel's changes as Govee commands.
@MainActor
final class GoveeTests: XCTestCase {

    func testParsesScanReply() throws {
        let data = Data(#"{"msg":{"cmd":"scan","data":{"ip":"192.168.1.23","device":"1f:80:c5:32:32:36:72:4e","sku":"H618E","bleVersionHard":"3.01.01","wifiVersionSoft":"1.02.03"}}}"#.utf8)
        guard case .found(let light) = GoveeLAN.parse(data, from: "192.168.1.99") else { return XCTFail("not a scan reply") }
        XCTAssertEqual(light, GoveeLAN.Found(ip: "192.168.1.23", id: "1F:80:C5:32:32:36:72:4E", sku: "H618E"))
    }

    func testParsesStatusInColourAndWhite() throws {
        let colour = Data(#"{"msg":{"cmd":"devStatus","data":{"onOff":1,"brightness":42,"color":{"r":255,"g":64,"b":0},"colorTemInKelvin":0}}}"#.utf8)
        guard case .status(let ip, let status) = GoveeLAN.parse(colour, from: "10.0.0.5") else { return XCTFail("not a status") }
        XCTAssertEqual(ip, "10.0.0.5")
        let light = GoveeService.lightState(status)
        XCTAssertEqual(light["on"] as? Bool, true)
        XCTAssertEqual(light["brightness"] as? Double ?? 0, 0.42, accuracy: 0.001)
        XCTAssertEqual(light["color"] as? String, "#ff4000")
        XCTAssertNil(light["temp"])

        let white = Data(#"{"msg":{"cmd":"devStatus","data":{"onOff":0,"brightness":100,"color":{"r":255,"g":255,"b":255},"colorTemInKelvin":2700}}}"#.utf8)
        guard case .status(_, let warm) = GoveeLAN.parse(white, from: "10.0.0.5") else { return XCTFail("not a status") }
        let lamp = GoveeService.lightState(warm)
        XCTAssertEqual(lamp["on"] as? Bool, false)
        XCTAssertEqual(lamp["temp"] as? Double, 2700)
        XCTAssertTrue(lamp["color"] is NSNull)
    }

    func testIgnoresOtherPackets() {
        XCTAssertNil(GoveeLAN.parse(Data("hello".utf8), from: "10.0.0.5"))
        XCTAssertNil(GoveeLAN.parse(Data(#"{"msg":{"cmd":"turn","data":{}}}"#.utf8), from: "10.0.0.5"))
    }

    func testCommandsOrderPowerAroundTheRest() {
        XCTAssertEqual(GoveeService.commands(["on": true, "brightness": 0.5, "color": "#00ff80"]),
                       [.power(true), .brightness(50), .color(0, 255, 128)])
        XCTAssertEqual(GoveeService.commands(["temp": 3000.0]), [.kelvin(3000)])
        XCTAssertEqual(GoveeService.commands(["on": false]), [.power(false)])
        XCTAssertEqual(GoveeService.commands(["brightness": 0.0]), [.brightness(1)])
        XCTAssertEqual(GoveeService.commands([:]), [])
    }

    func testSubnetSweepCoversASlash22() {
        var ip = in_addr(), mask = in_addr()
        inet_pton(AF_INET, "192.168.5.37", &ip)
        inet_pton(AF_INET, "255.255.252.0", &mask)
        let hosts = GoveeLAN.subnetHosts(ip: ip, mask: mask)
        XCTAssertEqual(hosts.count, 1021)
        XCTAssertEqual(hosts.first, "192.168.4.1")
        XCTAssertEqual(hosts.last, "192.168.7.254")
        XCTAssertTrue(hosts.contains("192.168.6.20"))
        XCTAssertFalse(hosts.contains("192.168.5.37"))
    }

    func testSubnetSweepStaysWithinASlash22OnBiggerNetworks() {
        var ip = in_addr(), mask = in_addr()
        inet_pton(AF_INET, "10.0.9.5", &ip)
        inet_pton(AF_INET, "255.255.0.0", &mask)
        let hosts = GoveeLAN.subnetHosts(ip: ip, mask: mask)
        XCTAssertEqual(hosts.count, 1021)
        XCTAssertEqual(hosts.first, "10.0.8.1")
        XCTAssertEqual(hosts.last, "10.0.11.254")
    }

    func testSubnetSweepOfASlash24() {
        var ip = in_addr(), mask = in_addr()
        inet_pton(AF_INET, "192.168.1.37", &ip)
        inet_pton(AF_INET, "255.255.255.0", &mask)
        let hosts = GoveeLAN.subnetHosts(ip: ip, mask: mask)
        XCTAssertEqual(hosts.count, 253)
        XCTAssertEqual(hosts.first, "192.168.1.1")
        XCTAssertEqual(hosts.last, "192.168.1.254")
    }

    func testStartsDisconnectedAndForgetsOnDisconnect() async throws {
        let vault = MemorySecretStore()
        let service = GoveeService(vault: vault)
        XCTAssertFalse(service.isConnected)
        service.adopt(["lan": true, "apiKey": "abc", "hosts": ["10.0.0.9"]])
        XCTAssertTrue(service.isConnected)
        XCTAssertEqual(service.shareable?["apiKey"] as? String, "abc")
        XCTAssertNotNil(vault.read())
        service.disconnect()
        XCTAssertFalse(service.isConnected)
        XCTAssertNil(vault.read())
    }
}
