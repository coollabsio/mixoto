import Foundation
import IOKit
import IOUSBHost

// Elgato Wave:3 hardware settings, sent as control requests to its vendor
// "Controls" USB interface (3). The audio driver does not claim that
// interface, so audio keeps streaming. The microphone keeps these settings
// only until it is disconnected.
// Protocol: https://github.com/KailasMahavarkar/elgato-wave3-ubuntu (research/dump/PROTOCOL.md)
enum Wave3 {
    private static let uidPrefix = "AppleUSBAudioEngine:Elgato Systems:Elgato Wave:3:"
    private static let configBlock: UInt16 = 0x00, versionBlock: UInt16 = 0x0A
    private static let clipguardOffset = 5
    // The controls interface opens exclusively: one request at a time.
    private static let lock = NSLock()

    // Core Audio UID: AppleUSBAudioEngine:Elgato Systems:Elgato Wave:3:<serial>:<ports>
    static func serial(_ device: Device) -> String? {
        guard device.uid.hasPrefix(uidPrefix) else { return nil }
        return device.uid.dropFirst(uidPrefix.count).split(separator: ":").first.map(String.init)
    }
    // Settings shown in Mixoto. Changes on the microphone (touch mute, dial)
    // appear here when read again.
    struct State: Equatable {
        var gain: Double            // dB, 0...40
        var muted: Bool
        var clipguard: Bool
        var lowCut: Bool            // the microphone's own low-cut filter
        var headphones: Double      // dB, -60...0
        var headphonesMuted: Bool
        var computerMix: Double     // monitor mix percent: 0 is all mic, 100 all computer
        var dial: String            // what the dial controls
        init(config c: [UInt8]) {
            func q8(_ offset: Int) -> Double { Double(Int16(bitPattern: UInt16(c[offset]) | UInt16(c[offset + 1]) << 8)) / 256 }
            gain = q8(0); muted = c[4] & 1 != 0
            clipguard = c[clipguardOffset] != 0; lowCut = c[6] != 0
            headphones = q8(7); headphonesMuted = c[9] & 1 != 0
            computerMix = q8(10)
            dial = [1: "Mic gain", 2: "Headphones", 3: "Monitor mix"][c[12]] ?? "Unknown"
        }
    }
    static func state(_ device: Device) throws -> State { State(config: try config(device)) }
    static func setClipguard(_ enabled: Bool, device: Device) throws {
        let value: UInt8 = enabled ? 1 : 0
        guard try config(device, set: value, at: clipguardOffset)[clipguardOffset] == value else {
            throw MixerError.message("The Wave:3 did not accept the Clipguard setting.")
        }
    }
    // Reads the settings block. To change a value, writes the whole block back
    // (as Wave Link does) and reads it again. Protocol 5.2 has a 14-byte block;
    // 5.3 and later have 16 bytes.
    private static func config(_ device: Device, set value: UInt8? = nil, at offset: Int = 0) throws -> [UInt8] {
        try withControls(device) { controls in
            let version = try transfer(controls, block: versionBlock, length: 2)
            guard version[0] == 5, version[1] >= 2 else {
                throw MixerError.message("Wave:3 firmware protocol \(version[0]).\(version[1]) is not supported.")
            }
            var block = try transfer(controls, block: configBlock, length: version[1] >= 3 ? 16 : 14)
            guard let value, block[offset] != value else { return block }
            block[offset] = value
            try transfer(controls, block: configBlock, write: block)
            return try transfer(controls, block: configBlock, length: block.count)
        }
    }
    // Class request to interface 3: GET (0xA1, 0x85) or SET (0x21, 0x05).
    @discardableResult
    private static func transfer(_ controls: IOUSBHostInterface, block: UInt16, length: Int = 0, write bytes: [UInt8]? = nil) throws -> [UInt8] {
        let data = bytes.map { NSMutableData(bytes: $0, length: $0.count) } ?? NSMutableData(length: length)!
        let request = IOUSBDeviceRequest(bmRequestType: bytes == nil ? 0xA1 : 0x21, bRequest: bytes == nil ? 0x85 : 0x05,
                                         wValue: block, wIndex: 0x3303, wLength: UInt16(data.length))
        var transferred = 0
        try controls.__send(request, data: data, bytesTransferred: &transferred, completionTimeout: 1)
        guard transferred == data.length else { throw MixerError.message("The Wave:3 returned an incomplete response.") }
        return [UInt8](data as Data)
    }
    private static func withControls<T>(_ device: Device, _ body: (IOUSBHostInterface) throws -> T) throws -> T {
        guard let serial = serial(device) else { throw MixerError.message("This microphone is not an Elgato Wave:3.") }
        lock.lock(); defer { lock.unlock() }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &iterator) == KERN_SUCCESS else {
            throw MixerError.message("Cannot list USB devices.")
        }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String, parents: Bool = false) -> Any? {
                IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, nil,
                                                parents ? IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents) : 0)
            }
            guard property("idVendor") as? Int == 0x0fd9, property("idProduct") as? Int == 0x0070,
                  property("bInterfaceNumber") as? Int == 3,
                  property("USB Serial Number", parents: true) as? String == serial else { continue }
            let controls = try IOUSBHostInterface(__ioService: service, options: [], queue: nil, interestHandler: nil)
            defer { controls.destroy() }
            return try body(controls)
        }
        throw MixerError.message("Cannot find the Wave:3 controls. Reconnect the microphone.")
    }
}
