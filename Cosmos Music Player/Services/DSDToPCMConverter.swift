//
//  DSDToPCMConverter.swift
//  Cosmos Music Player
//
//  Native DSD-to-PCM conversion for DSD rates SFBAudioEngine's built-in
//  DSDPCMDecoder doesn't support (confirmed: SFBAudioEngine's DSD-to-PCM
//  conversion is DSD64-only per its own README/feature list — see
//  https://github.com/sbooth/SFBAudioEngine).
//
//  This reads the DSF (DSD Stream File) container directly from disk and
//  does not call SFBAudioEngine's DSDDecoder at all. Earlier versions of
//  this file drove DSDDecoder.decode(into:count:) manually via a hand-built
//  AVAudioCompressedBuffer, which crashed at the memory level, 100%
//  reproducibly, at different points on different files/runs — a classic
//  symptom of undefined behavior from calling an API outside its intended
//  contract. SFBAudioEngine's own reference implementation (SimplePlayer)
//  never drives DSDDecoder this way either: it always wraps it in the
//  decorator classes DSDPCMDecoder/DoPDecoder, never touching raw packets
//  directly. Since those decorators are exactly what's rate-limited to
//  DSD64, driving the raw API ourselves isn't a supported path.
//
//  The DSF container format itself, by contrast, is a simple, stable, and
//  publicly documented format (used unchanged for well over a decade by
//  foobar2000, ffmpeg, dCS, and others), so parsing it directly here removes
//  the dependency on any undocumented internal contract:
//    "DSD " chunk (28 bytes) -> "fmt " chunk (52 bytes) -> "data" chunk
//  Audio in the data chunk is block-interleaved (NOT sample-interleaved):
//  `channelCount` consecutive fixed-size per-channel blocks (commonly 4096
//  bytes each) form one group, repeating until EOF.
//
//  Strategy: convert the whole file to a cached temporary PCM (CAF) file
//  once, then hand that file to the existing native AVAudioFile playback
//  path unchanged — avoids touching PlayerEngine's AVAudioEngine scheduling
//  code.
//
//  First-run calibration note: bit order within each byte (MSB vs LSB first)
//  is read from the fmt chunk's bitsPerSample field per the DSF spec (1 =
//  LSB-first, 8 = MSB-first) rather than assumed — but if playback still
//  comes out as noise on a given file, that field is the first thing to
//  double check against the "DSF header parsed" log line.
//

import Foundation
import AVFoundation
import Accelerate

enum DSDConversionError: Error {
    case unsupportedChannelCount(Int)
    case decoderOpenFailed
    case outputFileCreationFailed
    case conversionFailed(String)
}

final class DSDToPCMConverter {

    /// Target output PCM sample rate. Chosen conservatively (16x CD rate) so
    /// the decimation ratio stays reasonable for DSD64/128/256 alike and the
    /// FIR filter cost stays real-time-feasible on iPhone hardware. Can be
    /// raised later (e.g. to 176400) once correctness is confirmed.
    static let targetOutputSampleRate: Double = 88_200

    /// Converts a DSD file to a cached PCM (CAF) file, returning its URL.
    /// If a valid cache entry already exists for this exact source file
    /// (matched by path + modification date), conversion is skipped.
    static func convertedFileURL(forDSDFileAt sourceURL: URL) async throws -> URL {
        // IMPORTANT: this must be Documents, not Caches. Caches is explicitly
        // allowed to be purged by iOS at any time — low disk space, app not
        // running, reinstalls — with zero warning. A ~10-second-per-track
        // conversion cache stored there provides no real benefit at all if
        // it keeps evaporating between sessions, which is exactly what was
        // happening here. ArtworkManager already correctly uses Documents
        // for its own disk cache — this matches that existing pattern.
        let cacheDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DSDConverted", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let mtime = (try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.modificationDate] as? Date) ?? nil
        let mtimeStamp = mtime.map { String($0.timeIntervalSince1970) } ?? "0"
        let cacheKey = "\(sourceURL.lastPathComponent)-\(mtimeStamp)"
            .replacingOccurrences(of: "/", with: "_")
        let outputURL = cacheDir.appendingPathComponent(cacheKey).appendingPathExtension("caf")

        if FileManager.default.fileExists(atPath: outputURL.path) {
            // Guard against leftover broken/empty cache files from a prior
            // crashed conversion (this exact scenario happened before this
            // fix existed — an empty .caf got treated as a permanent cache
            // hit). A real converted file will always be well over a few KB;
            // anything suspiciously small is treated as invalid and removed
            // so we actually retry the conversion instead of trusting it.
            let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
            let size = (attrs?[.size] as? Int) ?? 0
            if size > 4096 {
                DebugLogger.shared.info("Using cached DSD->PCM conversion for \(sourceURL.lastPathComponent) (\(size) bytes)", category: "Playback")
                return outputURL
            } else {
                DebugLogger.shared.error("Discarding invalid/empty cached conversion for \(sourceURL.lastPathComponent) (\(size) bytes) — likely leftover from a prior crash. Re-converting.", category: "Playback")
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        // Convert into a temp file first, and only move it into the real
        // cache location once conversion has FULLY succeeded. If we wrote
        // directly to outputURL and the process crashed or got killed
        // mid-conversion, AVAudioFile(forWriting:) would already have
        // created an empty/partial file at outputURL — and the fileExists()
        // check above would then treat that broken file as a permanent
        // cache hit, silently "succeeding" with dead/empty audio on every
        // future attempt instead of ever retrying the real conversion.
        let tempURL = cacheDir.appendingPathComponent(cacheKey + "-inprogress").appendingPathExtension("caf")
        try? FileManager.default.removeItem(at: tempURL)

        DebugLogger.shared.info("Starting native DSD->PCM conversion for \(sourceURL.lastPathComponent)", category: "Playback")
        do {
            try await convert(sourceURL: sourceURL, outputURL: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        try FileManager.default.moveItem(at: tempURL, to: outputURL)
        DebugLogger.shared.info("Finished native DSD->PCM conversion for \(sourceURL.lastPathComponent)", category: "Playback")
        return outputURL
    }

    /// Fixed-layout DSF container header, per the publicly documented DSF
    /// (DSD Stream File) format spec — stable, widely implemented (ffmpeg,
    /// foobar2000, dCS, etc.) and unrelated to SFBAudioEngine's internal API.
    private struct DSFHeader {
        let channelCount: Int
        let dsdSampleRate: Double
        let bitsPerSample: UInt32   // 1 = LSB-first bit order, 8 = MSB-first
        let blockSizePerChannel: Int
        let sampleCountPerChannel: UInt64
        let dataOffset: UInt64
        let dataSize: UInt64
    }

    private static func readUInt32LE(_ fh: FileHandle) throws -> UInt32 {
        guard let d = try fh.read(upToCount: 4), d.count == 4 else {
            throw DSDConversionError.conversionFailed("Unexpected EOF reading DSF header")
        }
        return d.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
    }

    private static func readUInt64LE(_ fh: FileHandle) throws -> UInt64 {
        guard let d = try fh.read(upToCount: 8), d.count == 8 else {
            throw DSDConversionError.conversionFailed("Unexpected EOF reading DSF header")
        }
        return d.withUnsafeBytes { $0.load(as: UInt64.self) }.littleEndian
    }

    private static func readChunkID(_ fh: FileHandle) throws -> String {
        guard let d = try fh.read(upToCount: 4), d.count == 4 else {
            throw DSDConversionError.conversionFailed("Unexpected EOF reading DSF header")
        }
        return String(data: d, encoding: .ascii) ?? "????"
    }

    /// Parses the DSF container directly from the file, bypassing
    /// SFBAudioEngine's DSDDecoder entirely. Layout (all little-endian):
    ///   "DSD " chunk (28 bytes): ckID, ckDataSize, fileSize, metadataOffset
    ///   "fmt " chunk (52 bytes): ckID, ckDataSize, formatVersion, formatID,
    ///     channelType, channelNum, samplingFrequency, bitsPerSample,
    ///     sampleCount, blockSizePerChannel, reserved
    ///   "data" chunk: ckID, ckDataSize, then raw sample data
    private static func parseDSFHeader(_ fh: FileHandle) throws -> DSFHeader {
        let dsdID = try readChunkID(fh)
        guard dsdID == "DSD " else {
            throw DSDConversionError.conversionFailed("Not a valid DSF file (expected 'DSD ' chunk, found '\(dsdID)')")
        }
        _ = try readUInt64LE(fh) // ckDataSize (28)
        _ = try readUInt64LE(fh) // fileSize
        _ = try readUInt64LE(fh) // metadataOffset

        let fmtID = try readChunkID(fh)
        guard fmtID == "fmt " else {
            throw DSDConversionError.conversionFailed("Not a valid DSF file (expected 'fmt ' chunk, found '\(fmtID)')")
        }
        _ = try readUInt64LE(fh) // ckDataSize (52)
        _ = try readUInt32LE(fh) // formatVersion
        _ = try readUInt32LE(fh) // formatID
        _ = try readUInt32LE(fh) // channelType
        let channelNum = try readUInt32LE(fh)
        let samplingFrequency = try readUInt32LE(fh)
        let bitsPerSample = try readUInt32LE(fh)
        let sampleCount = try readUInt64LE(fh)
        let blockSizePerChannel = try readUInt32LE(fh)
        _ = try readUInt32LE(fh) // reserved

        let dataID = try readChunkID(fh)
        guard dataID == "data" else {
            throw DSDConversionError.conversionFailed("Not a valid DSF file (expected 'data' chunk, found '\(dataID)')")
        }
        let dataCkSize = try readUInt64LE(fh)
        let dataOffset = fh.offsetInFile
        let dataSize = dataCkSize >= 12 ? dataCkSize - 12 : 0

        return DSFHeader(
            channelCount: Int(channelNum),
            dsdSampleRate: Double(samplingFrequency),
            bitsPerSample: bitsPerSample,
            blockSizePerChannel: Int(blockSizePerChannel),
            sampleCountPerChannel: sampleCount,
            dataOffset: dataOffset,
            dataSize: dataSize
        )
    }

    private static func convert(sourceURL: URL, outputURL: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            guard sourceURL.pathExtension.lowercased() == "dsf" else {
                throw DSDConversionError.conversionFailed("Direct parsing only supports .dsf (got .\(sourceURL.pathExtension)) — DSDIFF/.dff uses a different big-endian IFF container, not implemented here")
            }

            guard let fileHandle = try? FileHandle(forReadingFrom: sourceURL) else {
                throw DSDConversionError.conversionFailed("Could not open \(sourceURL.lastPathComponent) for reading")
            }
            defer { try? fileHandle.close() }

            let header = try parseDSFHeader(fileHandle)
            DebugLogger.shared.info(
                "DSF header parsed for \(sourceURL.lastPathComponent): channels=\(header.channelCount), dsdSampleRate=\(header.dsdSampleRate), bitsPerSample=\(header.bitsPerSample), blockSizePerChannel=\(header.blockSizePerChannel), sampleCountPerChannel=\(header.sampleCountPerChannel), dataOffset=\(header.dataOffset), dataSize=\(header.dataSize)",
                category: "Playback"
            )

            let channelCount = header.channelCount
            guard channelCount == 1 || channelCount == 2 else {
                throw DSDConversionError.unsupportedChannelCount(channelCount)
            }
            guard header.blockSizePerChannel > 0 else {
                throw DSDConversionError.conversionFailed("Invalid blockSizePerChannel (0) in DSF header")
            }

            let dsdSampleRate = header.dsdSampleRate
            let decimationRatio = Int((dsdSampleRate / targetOutputSampleRate).rounded())
            guard decimationRatio >= 2 else {
                throw DSDConversionError.conversionFailed("Computed decimation ratio < 2 (dsdSampleRate=\(dsdSampleRate)) — refusing to convert")
            }
            let outputSampleRate = dsdSampleRate / Double(decimationRatio)
            DebugLogger.shared.info("DSD conversion plan: decimationRatio=\(decimationRatio), outputSampleRate=\(outputSampleRate)", category: "Playback")

            guard let outputFormat = AVAudioFormat(standardFormatWithSampleRate: outputSampleRate, channels: AVAudioChannelCount(channelCount)) else {
                throw DSDConversionError.outputFileCreationFailed
            }
            let outputFile: AVAudioFile
            do {
                outputFile = try AVAudioFile(forWriting: outputURL, settings: outputFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            } catch {
                throw DSDConversionError.conversionFailed("Failed to create output file: \(error)")
            }

            let decimators = (0..<channelCount).map { _ in DSDDecimator(decimationRatio: decimationRatio) }
            // Per the DSF spec, bitsPerSample here means bit ORDER within each
            // byte, not sample width (every DSD sample is inherently 1 bit):
            // 1 = LSB-first, 8 = MSB-first.
            let msbFirst = header.bitsPerSample != 1

            // DSF data is NOT sample-interleaved — it's block-interleaved:
            // `channelCount` consecutive fixed-size per-channel blocks
            // (blockSizePerChannel bytes, typically 4096) form one "group",
            // then the next group follows. Read several groups per pass to
            // keep memory bounded on very long tracks.
            let blockSize = header.blockSizePerChannel
            let groupsPerRead = 8
            let groupSizeBytes = blockSize * channelCount
            let readChunkSizeBytes = groupSizeBytes * groupsPerRead

            try fileHandle.seek(toOffset: header.dataOffset)
            var bytesRemaining = header.dataSize
            var totalDSDBytesProcessed: Int64 = 0
            var loggedFirstChunkDiagnostics = false

            while bytesRemaining > 0 {
                try Task.checkCancellation()
                let thisReadSize = min(UInt64(readChunkSizeBytes), bytesRemaining)
                guard let chunkData = try fileHandle.read(upToCount: Int(thisReadSize)), !chunkData.isEmpty else {
                    break
                }
                bytesRemaining -= UInt64(chunkData.count)

                let fullGroups = chunkData.count / groupSizeBytes
                guard fullGroups > 0 else { break }

                var perChannelBits = [[Float]](repeating: [], count: channelCount)
                for ch in 0..<channelCount {
                    perChannelBits[ch].reserveCapacity(fullGroups * blockSize * 8)
                }

                chunkData.withUnsafeBytes { (rawPtr: UnsafeRawBufferPointer) in
                    let bytePtr = rawPtr.bindMemory(to: UInt8.self)
                    for g in 0..<fullGroups {
                        let groupBase = g * groupSizeBytes
                        for ch in 0..<channelCount {
                            let chBase = groupBase + ch * blockSize
                            for i in 0..<blockSize {
                                appendBits(bytePtr[chBase + i], msbFirst: msbFirst, to: &perChannelBits[ch])
                            }
                        }
                    }
                }

                if !loggedFirstChunkDiagnostics {
                    loggedFirstChunkDiagnostics = true
                    DebugLogger.shared.info(
                        "DSD first chunk diagnostics: readBytes=\(chunkData.count), fullGroups=\(fullGroups), blockSize=\(blockSize), bitsUnpackedPerChannel=\(perChannelBits[0].count)",
                        category: "Playback"
                    )
                }

                totalDSDBytesProcessed += Int64(fullGroups * groupSizeBytes)

                var decimatedChannels = [[Float]](repeating: [], count: channelCount)
                for ch in 0..<channelCount {
                    decimatedChannels[ch] = decimators[ch].process(perChannelBits[ch])
                }

                let frameCount = decimatedChannels.map { $0.count }.min() ?? 0
                guard frameCount > 0 else { continue }

                guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: outputFile.processingFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
                    throw DSDConversionError.conversionFailed("Failed to allocate output PCM buffer")
                }
                pcmBuffer.frameLength = AVAudioFrameCount(frameCount)
                for ch in 0..<channelCount {
                    guard let dst = pcmBuffer.floatChannelData?[ch] else { continue }
                    decimatedChannels[ch].withUnsafeBufferPointer { src in
                        dst.update(from: src.baseAddress!, count: frameCount)
                    }
                }

                do {
                    try outputFile.write(from: pcmBuffer)
                } catch {
                    throw DSDConversionError.conversionFailed("Failed to write PCM chunk: \(error)")
                }
            }

            DebugLogger.shared.info("DSD conversion processed \(totalDSDBytesProcessed) raw DSD bytes -> \(outputURL.lastPathComponent)", category: "Playback")
        }.value
    }

    @inline(__always)
    private static func appendBits(_ byte: UInt8, msbFirst: Bool, to array: inout [Float]) {
        var b = byte
        if msbFirst {
            for _ in 0..<8 {
                let bit = (b & 0x80) != 0
                array.append(bit ? 1.0 : -1.0)
                b <<= 1
            }
        } else {
            for _ in 0..<8 {
                let bit = (b & 0x01) != 0
                array.append(bit ? 1.0 : -1.0)
                b >>= 1
            }
        }
    }
}

/// Streaming FIR low-pass + decimate, using Accelerate's vDSP_desamp.
/// Maintains filter history across chunk boundaries for continuous, click-free
/// output at chunk seams.
final class DSDDecimator {
    private let decimationRatio: Int
    private let filterTaps: [Float]
    private var history: [Float] = []

    /// Builds a windowed-sinc low-pass filter (Kaiser window) sized to the
    /// decimation ratio. Tap count scales with ratio to maintain a reasonable
    /// transition band / stopband attenuation for rejecting DSD's ultrasonic
    /// noise floor. Not maximally optimized (a multi-stage decimator would be
    /// cheaper for large ratios) — correctness first, revisit if conversion
    /// speed is a problem on-device.
    init(decimationRatio: Int) {
        self.decimationRatio = decimationRatio
        let tapCount = min(8 * decimationRatio + 1, 2047) | 1 // force odd
        self.filterTaps = Self.designLowPassFilter(tapCount: tapCount, decimationRatio: decimationRatio)
        self.history = [Float](repeating: 0, count: tapCount - 1)
    }

    /// Filters + decimates one channel's chunk of bipolar DSD samples.
    func process(_ samples: [Float]) -> [Float] {
        let P = filterTaps.count
        let input = history + samples
        let usableLength = input.count
        guard usableLength >= P else {
            // Not enough samples yet for even one output — buffer and wait
            history = input
            return []
        }

        let outputCount = (usableLength - P) / decimationRatio + 1
        guard outputCount > 0 else {
            history = Array(input.suffix(P - 1))
            return []
        }

        var output = [Float](repeating: 0, count: outputCount)
        input.withUnsafeBufferPointer { inPtr in
            filterTaps.withUnsafeBufferPointer { fPtr in
                vDSP_desamp(inPtr.baseAddress!,
                            vDSP_Stride(decimationRatio),
                            fPtr.baseAddress!,
                            &output,
                            vDSP_Length(outputCount),
                            vDSP_Length(P))
            }
        }

        // Carry over the tail needed to keep filtering continuous next chunk
        let consumedSamples = outputCount * decimationRatio
        history = Array(input.suffix(from: min(consumedSamples, input.count - (P - 1))))
        if history.count > P - 1 {
            history = Array(history.suffix(P - 1))
        }

        return output
    }

    private static func designLowPassFilter(tapCount: Int, decimationRatio: Int) -> [Float] {
        // Cutoff at 90% of the output Nyquist frequency (normalized to input rate)
        let cutoff = 0.9 * (0.5 / Double(decimationRatio))
        let M = tapCount - 1
        let beta = 8.0 // Kaiser window beta — strong stopband attenuation

        var taps = [Float](repeating: 0, count: tapCount)
        let i0Beta = besselI0(beta)

        for n in 0...M {
            let m = Double(n) - Double(M) / 2.0
            let sinc: Double = (m == 0) ? (2.0 * cutoff) : sin(2.0 * .pi * cutoff * m) / (.pi * m)
            let windowArg = beta * sqrt(1.0 - pow(2.0 * Double(n) / Double(M) - 1.0, 2))
            let window = besselI0(windowArg) / i0Beta
            taps[n] = Float(sinc * window)
        }

        // Normalize DC gain to 1.0
        let sum = taps.reduce(0, +)
        if sum != 0 {
            for i in 0..<taps.count { taps[i] /= sum }
        }
        return taps
    }

    /// Zeroth-order modified Bessel function of the first kind (for Kaiser window)
    private static func besselI0(_ x: Double) -> Double {
        var sum = 1.0
        var term = 1.0
        let xHalf = x / 2.0
        var k = 1
        while true {
            term *= (xHalf / Double(k)) * (xHalf / Double(k))
            sum += term
            if term < 1e-12 * sum { break }
            k += 1
            if k > 100 { break }
        }
        return sum
    }
}