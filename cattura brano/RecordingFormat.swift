//
//  RecordingFormat.swift
//  cattura brano
//
//  Formati di salvataggio audio ad alta fedeltà selezionabili dall'utente.
//

import AVFoundation

/// I formati di esportazione supportati dall'app.
///
/// Tutti mantengono la frequenza di campionamento e il numero di canali
/// dell'interfaccia usata in registrazione, per preservare la fedeltà.
nonisolated enum RecordingFormat: String, CaseIterable, Identifiable, Sendable {
    /// PCM lineare 24 bit non compresso (senza perdita).
    case wav
    /// PCM lineare 24 bit non compresso (senza perdita), big-endian.
    case aiff
    /// Apple Lossless: compresso senza perdita di qualità.
    case alac
    /// FLAC: compresso senza perdita di qualità, formato aperto.
    case flac
    /// AAC: compresso con perdita, alta qualità (256 kbps).
    case aac
    /// MP3: compresso con perdita, 320 kbps. Richiede l'encoder LAME.
    case mp3

    var id: String { rawValue }

    /// I formati effettivamente proponibili: l'MP3 compare solo se l'encoder
    /// LAME è stato integrato nel progetto.
    static var selectable: [RecordingFormat] {
        allCases.filter { $0 != .mp3 || MP3Encoder.isAvailable }
    }

    var displayName: String {
        let base = switch self {
        case .wav: "WAV · PCM 24 bit (senza perdita)"
        case .aiff: "AIFF · PCM 24 bit (senza perdita)"
        case .alac: "Apple Lossless · ALAC (compresso, senza perdita)"
        case .flac: "FLAC (compresso, senza perdita)"
        case .aac: "AAC · 256 kbps (compresso, alta qualità)"
        case .mp3: "MP3 · 320 kbps (compresso, massima compatibilità)"
        }
        return "\(base) — .\(fileExtension)"
    }

    /// `true` se il formato viene scritto tramite l'encoder LAME anziché AVAudioFile.
    var usesLAME: Bool { self == .mp3 }

    /// Bitrate di destinazione in kbps per i formati compressi con perdita.
    var bitrateKbps: Int {
        switch self {
        case .aac: 256
        case .mp3: 320
        default: 0
        }
    }

    var fileExtension: String {
        switch self {
        case .wav: "wav"
        case .aiff: "aiff"
        case .alac: "m4a"
        case .flac: "flac"
        case .aac: "m4a"
        case .mp3: "mp3"
        }
    }

    /// Le impostazioni da passare a `AVAudioFile(forWriting:settings:...)`.
    func settings(sampleRate: Double, channels: AVAudioChannelCount) -> [String: Any] {
        let channelCount = Int(channels)
        switch self {
        case .wav:
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
        case .aiff:
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: true,
                AVLinearPCMIsNonInterleaved: false
            ]
        case .alac:
            return [
                AVFormatIDKey: kAudioFormatAppleLossless,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVEncoderBitDepthHintKey: 24
            ]
        case .flac:
            return [
                AVFormatIDKey: kAudioFormatFLAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount
            ]
        case .aac:
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVEncoderBitRateKey: bitrateKbps * 1000,
                AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue
            ]
        case .mp3:
            // L'MP3 non viene scritto da AVAudioFile ma dall'encoder LAME.
            return [:]
        }
    }
}
