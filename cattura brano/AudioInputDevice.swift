//
//  AudioInputDevice.swift
//  cattura brano
//
//  Enumerazione delle interfacce/dispositivi di ingresso audio via Core Audio.
//

import CoreAudio
import Foundation

/// Un dispositivo di ingresso audio (interfaccia, microfono, ecc.) selezionabile.
nonisolated struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let inputChannels: Int
}

/// Interroga Core Audio per elencare i dispositivi con ingressi disponibili.
nonisolated enum AudioDeviceEnumerator {

    /// Tutti i dispositivi che espongono almeno un canale di ingresso.
    static func inputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        )
        guard status == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        )
        guard status == noErr else { return [] }

        return deviceIDs.compactMap { id in
            let channels = inputChannelCount(id)
            guard channels > 0 else { return nil }
            return AudioInputDevice(
                id: id,
                name: stringProperty(id, kAudioObjectPropertyName) ?? "Dispositivo sconosciuto",
                uid: stringProperty(id, kAudioDevicePropertyDeviceUID) ?? "",
                inputChannels: channels
            )
        }
    }

    /// L'ID del dispositivo di ingresso predefinito del sistema, se presente.
    static func defaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    /// Numero di canali di ingresso esposti dal dispositivo.
    static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }

        let rawPtr = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPtr.deallocate() }

        let listPtr = rawPtr.assumingMemoryBound(to: AudioBufferList.self)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, listPtr) == noErr else {
            return 0
        }

        let buffers = UnsafeMutableAudioBufferListPointer(listPtr)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Legge una proprietà di tipo stringa (nome, UID) dal dispositivo.
    private static func stringProperty(
        _ id: AudioDeviceID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value as String?
    }
}
