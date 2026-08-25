import CoreMIDI
import Foundation

/// Reads the Hot Hand's CC7/4/9 (X axis) over CoreMIDI. Y (CC5/8) is intentionally
/// ignored — this mirrors the Windows build's `EnableY = false` (X-only pass).
final class MidiSensor {
    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private var connectedSources: [MIDIEndpointRef] = []
    private(set) var connected = false
    private(set) var status = "looking for sensor"

    /// Latest raw X value, 0...127.
    private(set) var lastX: Int = 64
    var onSample: ((Int) -> Void)?

    private static func isHotHand(_ name: String) -> Bool {
        let compact = name.replacingOccurrences(of: " ", with: "")
        return compact.range(of: "HotHand", options: .caseInsensitive) != nil
            || name.range(of: "Source Audio", options: .caseInsensitive) != nil
    }

    func connect() -> Bool {
        if connected { return true }

        if client == 0 {
            MIDIClientCreateWithBlock("HOVER" as CFString, &client) { [weak self] _ in
                // Device (dis)connect notifications — re-scan on next tick via `connect()`.
                _ = self
            }
        }
        if inPort == 0 {
            MIDIInputPortCreateWithBlock(client, "HOVER In" as CFString, &inPort) { [weak self] packetList, _ in
                self?.handle(packetList)
            }
        }

        let count = MIDIGetNumberOfSources()
        var opened: [MIDIEndpointRef] = []
        for i in 0..<count {
            let source = MIDIGetSource(i)
            var cfName: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(source, kMIDIPropertyName, &cfName)
            let name = (cfName?.takeRetainedValue() as String?) ?? ""
            guard Self.isHotHand(name) else { continue }
            if MIDIPortConnectSource(inPort, source, nil) == noErr {
                opened.append(source)
            }
        }

        connectedSources = opened
        connected = !opened.isEmpty
        status = connected
            ? (opened.count == 1 ? "live" : "live · \(opened.count) receivers")
            : "looking for sensor"

        if connected { unmuteHotHands() }
        return connected
    }

    /// The Hot Hand receiver ships muted until something explicitly wakes it up over
    /// its MIDI OUTPUT (destination) side — this was written on the Windows side
    /// (`MidiInput.cs`'s `UnmuteHotHands`) but never actually wired into the live app
    /// there either. Sends CC112=127 then CC102–111=127 on all 16 channels to every
    /// MIDI destination whose name matches the Hot Hand, which is what actually starts
    /// the sensor CC stream flowing.
    private func unmuteHotHands() {
        if outPort == 0 {
            MIDIOutputPortCreate(client, "HOVER Out" as CFString, &outPort)
        }
        let count = MIDIGetNumberOfDestinations()
        for i in 0..<count {
            let dest = MIDIGetDestination(i)
            var cfName: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(dest, kMIDIPropertyName, &cfName)
            let name = (cfName?.takeRetainedValue() as String?) ?? ""
            guard Self.isHotHand(name) else { continue }
            for channel: UInt8 in 0..<16 {
                send(cc: 112, value: 127, channel: channel, to: dest)
                for cc: UInt8 in 102...111 {
                    send(cc: cc, value: 127, channel: channel, to: dest)
                }
            }
        }
    }

    private func send(cc: UInt8, value: UInt8, channel: UInt8, to destination: MIDIEndpointRef) {
        var packetList = MIDIPacketList()
        var bytes: [UInt8] = [0xB0 | channel, cc, value]
        withUnsafeMutablePointer(to: &packetList) { listPtr in
            var packetPtr = MIDIPacketListInit(listPtr)
            packetPtr = MIDIPacketListAdd(listPtr, 1024, packetPtr, 0, bytes.count, &bytes)
            _ = packetPtr
            let status = MIDISend(outPort, destination, listPtr)
            if status != noErr {
                FileHandle.standardError.write("DEBUG MIDISend failed: \(status)\n".data(using: .utf8)!)
            }
        }
    }

    func disconnect() {
        for source in connectedSources {
            MIDIPortDisconnectSource(inPort, source)
        }
        connectedSources.removeAll()
        connected = false
        status = "looking for sensor"
    }

    private func handle(_ packetList: UnsafePointer<MIDIPacketList>) {
        var packet = packetList.pointee.packet
        for _ in 0..<packetList.pointee.numPackets {
            let bytes = withUnsafeBytes(of: packet.data) { Array($0) }
            var i = 0
            while i + 2 < bytes.count {
                let status = bytes[i]
                // Control Change = 0xB0..0xBF.
                if (status & 0xF0) == 0xB0 {
                    let cc = Int(bytes[i + 1])
                    let value = Int(bytes[i + 2])
                    // Hot Hand: CC 4/7/9 = X only. CC 5/8 (Y) intentionally ignored.
                    if cc == 4 || cc == 7 || cc == 9 {
                        lastX = value
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.onSample?(self.lastX)
                        }
                    }
                    i += 3
                } else {
                    i += 1
                }
            }
            packet = MIDIPacketNext(&packet).pointee
        }
    }
}
