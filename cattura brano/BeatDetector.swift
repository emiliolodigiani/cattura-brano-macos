//
//  BeatDetector.swift
//  cattura brano
//
//  Analisi ritmica (BPM e posizione delle battute) tramite il beat tracker
//  di aubio (libaubio).
//
//  Come per LAME, il codice reale è compilato solo con il flag `AUBIO_ENABLED`:
//  senza aubio l'app compila comunque e le opzioni ritmiche restano nascoste.
//

import AVFoundation

/// Esito dell'analisi ritmica di una registrazione.
nonisolated struct BeatAnalysis {
    /// BPM stimati, `nil` se il tempo non è rilevabile con sicurezza.
    let bpm: Double?
    /// Posizioni delle battute (frame assoluti nel file sorgente).
    /// Vuoto quando il tempo non è affidabile.
    let beats: [AVAudioFramePosition]

    static let none = BeatAnalysis(bpm: nil, beats: [])
}

#if AUBIO_ENABLED

nonisolated enum BeatDetector {

    static let isAvailable = true

    /// Numero minimo di battiti rilevati perché il tempo sia considerato reale.
    private static let minimumBeats = 8
    /// Frazione minima di intervalli tra battiti entro ±10% dalla mediana.
    /// (La "confidenza" di aubio si è rivelata scorrelata dalla qualità del
    /// tracking su registrazioni reali: la regolarità della pulsazione è un
    /// criterio molto più affidabile.)
    private static let regularityThreshold = 0.5
    /// Intervallo di BPM plausibili per un brano.
    private static let plausibleRange = 40.0...220.0

    /// Analizza la regione [startFrame, endFrame) del file.
    /// Il beat tracker lavora in modo incrementale (hop da 512 campioni) e
    /// segue anche variazioni graduali di tempo: le posizioni delle battute
    /// sono quelle realmente rilevate, non una griglia a BPM fisso.
    static func analyze(
        readFile: AVAudioFile,
        startFrame: AVAudioFramePosition,
        endFrame: AVAudioFramePosition
    ) -> BeatAnalysis {
        let format = readFile.processingFormat
        let hop: UInt32 = 512
        let window: UInt32 = 1024
        let channels = Int(format.channelCount)

        guard let tempo = new_aubio_tempo("default", window, hop, UInt32(format.sampleRate)),
              let hopVec = new_fvec(hop),
              let beatVec = new_fvec(1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: hop)
        else { return .none }
        defer {
            del_aubio_tempo(tempo)
            del_fvec(hopVec)
            del_fvec(beatVec)
        }

        var beats: [AVAudioFramePosition] = []

        readFile.framePosition = startFrame
        var remaining = endFrame - startFrame
        while remaining > 0 {
            let toRead = AVAudioFrameCount(min(AVAudioFramePosition(hop), remaining))
            guard (try? readFile.read(into: buffer, frameCount: toRead)) != nil else { break }
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }

            guard let channelData = buffer.floatChannelData else { break }
            // Mixdown mono; l'eventuale coda oltre la fine resta a zero.
            for index in 0..<Int(hop) {
                var sample: Float = 0
                if index < frames {
                    for channel in 0..<channels { sample += channelData[channel][index] }
                    sample /= Float(channels)
                }
                fvec_set_sample(hopVec, sample, UInt32(index))
            }
            aubio_tempo_do(tempo, hopVec, beatVec)
            if fvec_get_sample(beatVec, 0) != 0 {
                // Posizione dell'ultima battuta, dall'inizio della regione.
                beats.append(startFrame + AVAudioFramePosition(aubio_tempo_get_last(tempo)))
            }

            remaining -= AVAudioFramePosition(frames)
            if frames < Int(toRead) { break }
        }

        // Accettazione: serve una pulsazione coerente. I BPM vengono calcolati
        // dall'intervallo mediano tra battiti, più stabile della stima globale.
        guard beats.count >= minimumBeats else { return .none }
        let sampleRate = format.sampleRate
        let intervals = zip(beats.dropFirst(), beats).map { Double($0 - $1) / sampleRate }
        let median = intervals.sorted()[intervals.count / 2]
        guard median > 0 else { return .none }
        let regularCount = intervals.count { $0 > median * 0.9 && $0 < median * 1.1 }
        guard Double(regularCount) >= Double(intervals.count) * regularityThreshold else {
            return .none
        }
        let bpm = 60.0 / median
        guard plausibleRange.contains(bpm) else { return .none }

        // Il click deve suonare anche nelle battute senza attacchi (pause,
        // sezioni di sola voce): riempiamo i vuoti e proseguiamo fino a fine
        // regione a passo mediano. Dove i battiti reali ci sono, il click
        // segue la loro fase e si risincronizza col brano.
        let filled = fillGaps(
            in: beats,
            medianInterval: AVAudioFramePosition(median * sampleRate),
            startFrame: startFrame,
            endFrame: endFrame
        )
        return BeatAnalysis(bpm: bpm, beats: filled)
    }

    /// Costruisce la griglia completa del click a partire dai battiti rilevati:
    /// scarta i doppi scatti della fase di aggancio del tracker, riempie i
    /// vuoti a passo `medianInterval` e prolunga la griglia all'indietro fino
    /// a `startFrame` e in avanti fino a `endFrame`.
    private static func fillGaps(
        in beats: [AVAudioFramePosition],
        medianInterval: AVAudioFramePosition,
        startFrame: AVAudioFramePosition,
        endFrame: AVAudioFramePosition
    ) -> [AVAudioFramePosition] {
        guard medianInterval > 0, !beats.isEmpty else { return beats }
        let minimumGap = medianInterval * 6 / 10

        // Scarta i battiti troppo ravvicinati (doppi scatti dell'aggancio).
        var cleaned: [AVAudioFramePosition] = []
        for beat in beats {
            if let last = cleaned.last, beat - last < minimumGap { continue }
            cleaned.append(beat)
        }
        guard let first = cleaned.first else { return beats }

        // Prolunga all'indietro fino all'inizio della regione, così il click
        // parte dal primo suono anche se il tracker aggancia dopo qualche
        // secondo.
        var filled: [AVAudioFramePosition] = []
        var previous = first - medianInterval
        while previous >= startFrame {
            filled.append(previous)
            previous -= medianInterval
        }
        filled.reverse()
        filled.append(first)

        // Riempie i vuoti interni mantenendo la fase dei battiti reali.
        for beat in cleaned.dropFirst() {
            var expected = filled[filled.count - 1] + medianInterval
            while beat - expected > minimumGap {
                filled.append(expected)
                expected += medianInterval
            }
            filled.append(beat)
        }

        // Prolunga in avanti fino alla fine della regione.
        var next = filled[filled.count - 1] + medianInterval
        while next < endFrame {
            filled.append(next)
            next += medianInterval
        }
        return filled
    }
}

#else

/// Segnaposto usato quando aubio non è integrato: l'analisi non è disponibile.
nonisolated enum BeatDetector {
    static let isAvailable = false

    static func analyze(
        readFile: AVAudioFile,
        startFrame: AVAudioFramePosition,
        endFrame: AVAudioFramePosition
    ) -> BeatAnalysis { .none }
}

#endif
