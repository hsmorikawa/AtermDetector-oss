import XCTest

final class ArpTableTests: XCTestCase {
    /// ARP テーブル (NET_RT_FLAGS/RTF_LLINFO) の 1 エントリ相当のバイト列を合成する。
    /// 構造: rt_msghdr + sockaddr_in(16B) + sockaddr_dl(20B、sdl_data = IF名 + MAC)。
    private func entry(ip: String, mac: [UInt8]?, family: UInt8 = UInt8(AF_INET)) throws -> [UInt8] {
        let rtmSize = MemoryLayout<rt_msghdr>.size
        let octets = try XCTUnwrap(IPv4.octets(of: ip))

        var sin = [UInt8](repeating: 0, count: 16)
        sin[0] = 16
        sin[1] = family
        sin[4 ... 7] = ArraySlice(octets)

        var sdl = [UInt8](repeating: 0, count: 20)
        sdl[0] = 20
        sdl[1] = UInt8(AF_LINK)
        sdl[5] = 3 // sdl_nlen ("en0")
        sdl[6] = UInt8(mac?.count ?? 0) // sdl_alen
        sdl[8 ... 10] = ArraySlice(Array("en0".utf8))
        if let mac {
            sdl[11 ..< (11 + mac.count)] = ArraySlice(mac)
        }

        var bytes = [UInt8](repeating: 0, count: rtmSize) + sin + sdl
        bytes[0] = UInt8(bytes.count & 0xFF) // rtm_msglen (little endian)
        bytes[1] = UInt8(bytes.count >> 8)
        return bytes
    }

    func testFindsMACForIP() throws {
        let table = try entry(ip: "192.168.0.16", mac: [0xAA, 0xBB, 0xCC, 0x00, 0x11, 0x22])
        XCTAssertEqual(ArpParser.mac(for: "192.168.0.16", in: table), "AA:BB:CC:00:11:22")
    }

    func testFindsMACInMultiEntryTable() throws {
        let table = try entry(ip: "192.168.0.1", mac: [0x0C, 0x01, 0x4B, 0xBD, 0x5A, 0x63])
            + entry(ip: "192.168.0.26", mac: [0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01])
        XCTAssertEqual(ArpParser.mac(for: "192.168.0.26", in: table), "DE:AD:BE:EF:00:01")
    }

    func testReturnsNilWhenIPAbsent() throws {
        let table = try entry(ip: "192.168.0.1", mac: [0x0C, 0x01, 0x4B, 0xBD, 0x5A, 0x63])
        XCTAssertNil(ArpParser.mac(for: "192.168.0.99", in: table))
    }

    func testReturnsNilForIncompleteEntry() throws {
        // 未解決エントリ (sdl_alen = 0) は MAC なし扱い
        let table = try entry(ip: "192.168.0.12", mac: nil)
        XCTAssertNil(ArpParser.mac(for: "192.168.0.12", in: table))
    }

    func testReturnsNilForInvalidIPOrEmptyTable() {
        XCTAssertNil(ArpParser.mac(for: "abc", in: [0x01, 0x02]))
        XCTAssertNil(ArpParser.mac(for: "192.168.0.1", in: []))
    }
}
