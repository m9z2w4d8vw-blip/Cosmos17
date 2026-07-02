//
//  DSDToPCMConverter.swift
//  Cosmos Music Player
//
//  Native DSD-to-PCM conversion for DSD rates SFBAudioEngine's built-in
//  DSDPCMDecoder doesn't support (confirmed: SFBAudioEngine's DSD-to-PCM
//  conversion is DSD64-only per its own README/feature list — see
//  https://github.com/sbooth/SFBAudioEngine). This bypasses that limitation
//  entirely by reading the raw 1-bit DSD stream directly from SFBAudioEngine's
//  DSDDecoder (which decodes DSF/DSDIFF at ANY rate — only the built-in PCM
//  converter is rate-limited) and running our own decimation filter.
//
//  Strategy: convert the whole file to a cached temporary PCM (CAF) file once,
//  then hand that file to the existing native AVAudioFile playback path
//  unchanged. This avoids touching PlayerEngine's AVAudioEngine scheduling
//  code, which is complex and already fragile — safer than trying to stream
//  converted PCM live.
//
//  IMPORTANT — first-run calibration needed:
//  The exact byte layout SFBAudioEngine's DSDDecoder hands back (interleaved
//  vs planar, bit order within each byte) is asserted here based on Apple's
//  documented native DSD format, but has NOT been verified against actual
//  decoded output. DebugLogger calls below log the raw AVAudioFormat/
//  streamDescription the decoder reports on first run — if playback comes out
//  as noise, silence, or reversed channels, that log output is exactly what's
//  needed to correct the unpacking logic in `unpackDSDBytes`.
//

import Foundation
import AVFoundation
import Accelerate
import SFBAudioEngine

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
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DSDConverted", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let mtime = (try? FileManager.default.attributesOfItem(atPath: sourceURL.path)[.modificationDate] as? Date) ?? nil
        let mtimeStamp = mtime.map { String($0.timeIntervalSince1970) } ?? "0"
        let cacheKey = "\(sourceURL.lastPathComponent)-\(mtimeStamp)"
            .replacingOccurrences(of: "/", with: "_")
        let outputURL = cacheDir.appendingPathComponent(cacheKey).appendingPathExtension("caf")

        if FileManager.default.fileExists(atPath: outputURL.path) {
            DebugLogger.shared.info("Using cached DSD->PCM conversion for \(sourceURL.lastPathComponent)", category: "Playback")
            return outputURL
        }

        DebugLogger.shared.info("Starting native DSD->PCM conversion for \(sourceURL.lastPathComponent)", category: "Playback")
        try await convert(sourceURL: sourceURL, outputURL: outputURL)
        DebugLogger.shared.info("Finished native DSD->PCM conversion for \(sourceURL.lastPathComponent)", category: "Playback")
        return outputURL
    }

    private static func convert(sourceURL: URL, outputURL: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let decoder = try SFBAudioEngine.DSDDecoder(url: sourceURL)
            do {
                try decoder.open()
            } catch {
                throw DSDConversionError.decoderOpenFailed
            }
            defer { try? decoder.close() }

            let sourceFormat = decoder.sourceFormat
            let asbd = sourceFormat.streamDescription.pointee
            let dsdSampleRate = asbd.mSampleRate
            let channelCount = Int(asbd.mChannelsPerFrame)
            let isInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0

            DebugLogger.shared.info(
                "DSDDecoder sourceFormat for \(sourceURL.lastPathComponent): sampleRate=\(dsdSampleRate), channels=\(channelCount), bytesPerPacket=\(asbd.mBytesPerPacket), bytesPerFrame=\(asbd.mBytesPerFrame), interleaved=\(isInterleaved), formatFlags=\(asbd.mFormatFlags)",
                category: "Playback"
            )

            guard channelCount == 1 || channelCount == 2 else {
                throw DSDConversionError.unsupportedChannelCount(channelCount)
            }

            let decimationRatio = Int((dsdSampleRate / targetOutputSampleRate).rounded())
            guard decimationRatio >= 2 else {
                throw DSDConversionError.conversionFailed("Computed decimation ratio < 2 (dsdSampleRate=\(dsdSampleRate)) — refusing to convert")
            }
            let outputSampleRate = dsdSampleRate / Double(decimationRatio)

            DebugLogger.shared.info("DSD conversion plan: decimationRatio=\(decimationRatio), outputSampleRate=\(outputSampleRate)", category: "Playback")

            // Output file: 32-bit float PCM CAF, same channel count/layout as source
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

            // Read DSD in chunks of packets (1 packet = 1 byte per channel = 8 samples per channel)
            let packetsPerChunk: AVAudioPacketCount = 65536
            let bytesPerPacketPerChannel = 1
            let compressedBuffer = AVAudioCompressedBuffer(
                format: sourceFormat,
                packetCapacity: packetsPerChunk,
                maximumPacketSize: bytesPerPacketPerChannel * (isInterleaved ? channelCount : 1)
            )

            var totalPacketsDecoded: Int64 = 0

            while true {
                try Task.checkCancellation()
                compressedBuffer.byteLength = 0
                compressedBuffer.packetCount = 0

                do {
                    try decoder.decode(into: compressedBuffer, count: packetsPerChunk)
                } catch {
                    DebugLogger.shared.error("DSDDecoder.decode failed mid-stream for \(sourceURL.lastPathComponent) after \(totalPacketsDecoded) packets: \(error)", category: "Playback")
                    throw error
                }

                let packetsRead = Int(compressedBuffer.packetCount)
                if packetsRead == 0 {
                    break // EOF
                }
                totalPacketsDecoded += Int64(packetsRead)

                // Unpack raw DSD bytes -> per-channel bipolar Float32 sample arrays
                let channelSamples = unpackDSDBytes(
                    compressedBuffer: compressedBuffer,
                    packetCount: packetsRead,
                    channelCount: channelCount,
                    interleaved: isInterleaved
                )

                // Decimate each channel and write interleaved-free (planar) PCM buffer
                var decimatedChannels: [[Float]] = []
                for ch in 0..<channelCount {
                    decimatedChannels.append(decimators[ch].process(channelSamples[ch]))
                }

                let frameCount = decimatedChannels.first?.count ?? 0
                guard frameCount > 0 else { continue }

                guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: outputFile.processingFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
                    throw DSDConversionError.conversionFailed("Failed to allocate PCM buffer")
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

            DebugLogger.shared.info("DSD conversion wrote \(totalPacketsDecoded) DSD packets -> \(outputURL.lastPathComponent)", category: "Playback")
        }.value
    }

    /// Unpacks raw DSD bytes from a compressed buffer into per-channel arrays
    /// of bipolar Float32 samples (bit=1 -> +1.0, bit=0 -> -1.0), MSB-first,
    /// per Apple's documented native DSD byte layout. ASSUMPTION: interleaved
    /// byte-per-channel ordering when `interleaved == true` (byte 0 = ch0's
    /// 8 samples, byte 1 = ch1's 8 samples, byte 2 = ch0's next 8 samples...).
    /// Verify against the DebugLogger format dump above if output sounds wrong.
    private static func unpackDSDBytes(
        compressedBuffer: AVAudioCompressedBuffer,
        packetCount: Int,
        channelCount: Int,
        interleaved: Bool
    ) -> [[Float]] {
        var result = [[Float]](repeating: [], count: channelCount)
        for ch in 0..<channelCount {
            result[ch].reserveCapacity(packetCount * 8)
        }

        let dataPtr = compressedBuffer.data.assumingMemoryBound(to: UInt8.self)

        if interleaved {
            // packetCount total packets, one byte per channel per packet, channels interleaved
            var offset = 0
            for _ in 0..<packetCount {
                for ch in 0..<channelCount {
                    let byte = dataPtr[offset]
                    offset += 1
                    appendBits(byte, to: &result[ch])
                }
            }
        } else {
            // Planar: each channel's bytes are contiguous
            for ch in 0..<channelCount {
                let base = ch * packetCount
                for i in 0..<packetCount {
                    appendBits(dataPtr[base + i], to: &result[ch])
                }
            }
        }
        return result
    }

    @inline(__always)
    private static func appendBits(_ byte: UInt8, to array: inout [Float]) {
        // MSB-first per Apple's native DSD format documentation
        var b = byte
        for _ in 0..<8 {
            let bit = (b & 0x80) != 0
            array.append(bit ? 1.0 : -1.0)
            b <<= 1
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