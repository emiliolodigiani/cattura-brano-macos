//
//  MP3Encoder.swift
//  cattura brano
//
//  Codifica MP3 tramite la libreria LAME (libmp3lame).
//
//  macOS non include un encoder MP3: per abilitare questo formato bisogna
//  integrare LAME nel progetto (vedi le istruzioni fornite). Il codice reale è
//  compilato solo quando è definito il flag di compilazione `LAME_ENABLED`,
//  così senza LAME l'app continua a compilare e l'MP3 resta semplicemente
//  nascosto dal menu dei formati.
//

import AVFoundation

#if LAME_ENABLED

/// Scrive un file MP3 a partire da buffer PCM float, usando LAME.
nonisolated final class MP3Encoder {

    static let isAvailable = true

    private let lame: lame_t
    private let handle: FileHandle
    private let channelCount: Int

    init(url: URL, sampleRate: Double, channels: AVAudioChannelCount, bitrateKbps: Int) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            throw RecorderError.invalidFormat
        }
        self.handle = handle
        self.channelCount = Int(channels)

        guard let lame = lame_init() else {
            try? handle.close()
            throw RecorderError.invalidFormat
        }
        self.lame = lame

        lame_set_in_samplerate(lame, Int32(sampleRate))
        lame_set_num_channels(lame, Int32(channels))
        lame_set_mode(lame, channels == 1 ? MONO : JOINT_STEREO)
        lame_set_brate(lame, Int32(bitrateKbps))
        lame_set_quality(lame, 2) // 0 = migliore/più lento, 2 = alta qualità

        guard lame_init_params(lame) >= 0 else {
            lame_close(lame)
            try? handle.close()
            throw RecorderError.invalidFormat
        }
    }

    /// Codifica un buffer PCM (campioni float non interleaved, -1…1).
    func encode(_ buffer: AVAudioPCMBuffer) throws {
        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        let left = channelData[0]
        let right = channelCount > 1 ? channelData[1] : channelData[0]

        let capacity = Int(Double(frames) * 1.25) + 7200
        var mp3buf = [UInt8](repeating: 0, count: capacity)
        let written = lame_encode_buffer_ieee_float(
            lame, left, right, Int32(frames), &mp3buf, Int32(capacity)
        )
        guard written >= 0 else { throw RecorderError.invalidFormat }
        if written > 0 {
            try handle.write(contentsOf: Data(mp3buf[0..<Int(written)]))
        }
    }

    /// Svuota i buffer interni di LAME e chiude il file.
    func finalize() throws {
        let capacity = 7200
        var mp3buf = [UInt8](repeating: 0, count: capacity)
        let written = lame_encode_flush(lame, &mp3buf, Int32(capacity))
        if written > 0 {
            try handle.write(contentsOf: Data(mp3buf[0..<Int(written)]))
        }
        lame_close(lame)
        try handle.close()
    }
}

#else

/// Segnaposto usato quando LAME non è integrato: l'MP3 non è disponibile.
nonisolated enum MP3Encoder {
    static let isAvailable = false
}

#endif
