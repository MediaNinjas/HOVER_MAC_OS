import CoreMIDI
import Foundation

/// One row in the DEVICES list — a MIDI source CoreMIDI can see, and whether the
/// user wants HOVER listening to it.
struct MidiDeviceInfo {
    let name: String
    var enabled: Bool
}

/// Reads the Hot Hand's CC7/4/9 (X axis) and CC5/8 (Y axis) over CoreMIDI.
///
/// Lists every MIDI source it can see (not just ones that look like a Hot Hand),
/// so the DEVICES panel can show all of them with an on/off checkbox each. A
/// device whose name looks like a Hot Hand is enabled by default the first time
/// it's ever seen; anything else defaults off. The user's explicit choice always
/// wins after that — rescanning never silently re-enables something they turned
/// off, and never silently disables something they turned on.
final class MidiSensor {
    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()

    private var allSources: [(name: String, endpoint: MIDIEndpointRef)] = []
    private var enabledNames: Set<String> = []
    private var seenNames: Set<String> = []
    private var connectedNames: Set<String> = []

    private(set) var connected = false
    private(set) var status = "looking for sensor"

    /// Latest raw X value, 0...127.
    private(set) var lastX: Int = 64
    /// Latest raw Y value, 0...127. Kept fully separate from X below — its own
    /// CC numbers, its own stored field — so nothing about X's handling changes.
    private(set) var lastY: Int = 64
    var onSample: ((Int) -> Void)?
    var onSampleY: ((Int) -> Void)?
    /// Fires whenever the device list or any device's enabled state changes, so the
    /// UI can rebuild the DEVICES checkbox list.
    var onDevicesChanged: (() -> Void)?

    private var lastSampleAt = Date.distantPast
    private var lastUnmuteAt = Date.distantPast

    var devices: [MidiDeviceInfo] {
        allSources.map { MidiDeviceInfo(name: $0.name, enabled: enabledNames.contains($0.name)) }
    }

    private static func isHotHand(_ name: String) -> Bool {
        let compact = name.replacingOccurrences(of: " ", with: "")
        return compact.range(of: "HotHand", options: .caseInsensitive) != nil
            || name.range(of: "Source Audio", options: .caseInsensitive) != nil
    }

    private func ensureClientAndPorts() {
        if client == 0 {
            MIDIClientCreateWithBlock("HOVER" as CFString, &client) { [weak self] _ in
                // Device (dis)connect notifications — rescan so the list stays current.
                DispatchQueue.main.async { self?.rescan() }
            }
        }
        if inPort == 0 {
            MIDIInputPortCreateWithBlock(client, "HOVER In" as CFString, &inPort) { [weak self] packetList, _ in
                self?.handle(packetList)
            }
        }
    }

    /// Re-enumerate every MIDI source CoreMIDI currently sees and reapply each
    /// device's enabled state. Also used as the initial connect.
    @discardableResult
    func rescan() -> Bool {
        ensureClientAndPorts()
        var found: [(String, MIDIEndpointRef)] = []
        let count = MIDIGetNumberOfSources()
        for i in 0..<count {
            let source = MIDIGetSource(i)
            var cfName: Unmanaged<CFString>?
            MIDIObjectGetStringProperty(source, kMIDIPropertyName, &cfName)
            let name = (cfName?.takeRetainedValue() as String?) ?? "MIDI \(i)"
            found.append((name, source))
            if !seenNames.contains(name) {
                seenNames.insert(name)
                if Self.isHotHand(name) { enabledNames.insert(name) }
            }
        }
        allSources = found
        applyConnections()
        onDevicesChanged?()
        return connected
    }

    /// Explicit user toggle from the DEVICES list — always wins over auto-detection.
    func setDevice(_ name: String, enabled: Bool) {
        if enabled { enabledNames.insert(name) } else { enabledNames.remove(name) }
        applyConnections()
        onDevicesChanged?()
    }

    private func applyConnections() {
        for (name, endpoint) in allSources {
            let shouldConnect = enabledNames.contains(name)
            let isConnected = connectedNames.contains(name)
            if shouldConnect && !isConnected {
                if MIDIPortConnectSource(inPort, endpoint, nil) == noErr {
                    connectedNames.insert(name)
                }
            } else if !shouldConnect && isConnected {
                MIDIPortDisconnectSource(inPort, endpoint)
                connectedNames.remove(name)
            }
        }
        let wasConnected = connected
        connected = !connectedNames.isEmpty
        status = connected
            ? (connectedNames.count == 1 ? "live" : "live · \(connectedNames.count) receivers")
            : "looking for sensor"
        if connected && !wasConnected {
            unmuteHotHands()
            lastSampleAt = Date() // grace period before the first keepAlive check
        }
    }

    /// Kept for the existing call sites that just want "make sure something is
    /// connected" — equivalent to a rescan.
    @discardableResult
    func connect() -> Bool { rescan() }

    /// Call this on every tick while connected. The receiver appears to mute itself
    /// again after a period without traffic (a wireless power-saving behavior) —
    /// sending the unmute handshake once at connect time isn't enough, it stops
    /// streaming again later in the same session. If no sample has arrived in the
    /// last few seconds, re-send the wake-up handshake as a keep-alive.
    func keepAlive() {
        guard connected else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSampleAt) > 3, now.timeIntervalSince(lastUnmuteAt) > 3 else { return }
        lastUnmuteAt = now
        unmuteHotHands()
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
            _ = MIDISend(outPort, destination, listPtr)
        }
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
                    // Hot Hand: CC 4/7/9 = X. CC 5/8 = Y. Handled as two fully
                    // separate branches, each firing only its own callback —
                    // an X sample never touches lastY/onSampleY or vice versa.
                    if cc == 4 || cc == 7 || cc == 9 {
                        lastX = value
                        lastSampleAt = Date()
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.onSample?(self.lastX)
                        }
                    } else if cc == 5 || cc == 8 {
                        lastY = value
                        lastSampleAt = Date()
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.onSampleY?(self.lastY)
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
