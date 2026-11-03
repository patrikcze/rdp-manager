import Testing
@testable import RDPManagerCore

@Suite("Quick Connect address parsing")
struct HostAddressTests {
    @Test(arguments: [
        ("server01.example.com", "server01.example.com", 3389),
        ("server01.example.com:3390", "server01.example.com", 3390),
        ("10.10.20.30", "10.10.20.30", 3389),
        ("  10.10.20.30:3391 ", "10.10.20.30", 3391),
        ("[fe80::1]:3390", "fe80::1", 3390),
        ("fe80::1", "fe80::1", 3389),
        ("rdp://host.example.com/", "host.example.com", 3389),
        ("DC01", "DC01", 3389),
    ] as [(String, String, UInt16)])
    func parsesValidAddresses(input: String, host: String, port: UInt16) throws {
        let address = try HostAddress.parse(input)
        #expect(address.host == host)
        #expect(address.port == port)
    }

    @Test func rejectsEmpty() {
        #expect(throws: HostAddress.ParseError.empty) { try HostAddress.parse("   ") }
    }

    @Test(arguments: ["host:0", "host:70000", "host:abc", "host:"])
    func rejectsBadPorts(input: String) {
        #expect(throws: HostAddress.ParseError.self) { try HostAddress.parse(input) }
    }

    @Test(arguments: ["user@host", "host/path", "a b", "-host", "[fe80::1"])
    func rejectsBadHosts(input: String) {
        #expect(throws: HostAddress.ParseError.self) { try HostAddress.parse(input) }
    }

    @Test func addressLabelHidesDefaultPort() {
        #expect(Connection(name: "a", host: "h", port: 3389).addressLabel == "h")
        #expect(Connection(name: "a", host: "h", port: 3390).addressLabel == "h:3390")
        #expect(Connection(name: "a", host: "fe80::1", port: 3390).addressLabel == "[fe80::1]:3390")
    }
}
