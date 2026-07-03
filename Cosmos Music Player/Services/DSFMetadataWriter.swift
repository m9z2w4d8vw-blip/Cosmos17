//
//  DSFMetadataWriter.swift
//  Cosmos Music Player
//
//  Writes ID3v2.3 tags directly into .dsf files, so metadata edits made in
//  the app persist in the actual file — visible in Apple Music, Finder,
//  other players, etc. — not just in Cosmos's own database.
//
//  Why hand-rolled instead of going through SFBAudioEngine: this project
//  already hit repeated, hard-to-diagnose crashes driving SFBAudioEngine's
//  low-level DSD APIs outside their documented usage (see
//  DSDToPCMConverter.swift's history). The DSF container format itself is
//  simple, stable, and publicly documented, so — same as that converter —
//  this reads/writes the container directly instead of going through
//  SFBAudioEngine at all.
//
//  Strategy: only the small ID3v2 tag region at the end of the file (a few
//  KB, occasionally a few MB with embedded artwork) is ever read into
//  memory. The (typically hundreds-of-MB) audio payload is never touched —
//  we truncate the file at the tag's start offset and re-append a freshly
//  built tag, then patch the two relevant fields (fileSize, metadataOffset)
//  in the fixed 28-byte "DSD " header at the very start of the file.
//
//  Any frame we're not explicitly changing (title, track/disc number, year,
//  embedded artwork, or any frame this app doesn't otherwise know about) is
//  preserved byte-for-byte from the existing tag, if one exists.
//

import Foundation

enum DSFMetadataWriterError: Error, LocalizedError {
    case notADSFFile
    case fileTooSmallOrCorrupt
    case ioError(String)

    var errorDescription: String? {
        switch self {
        case .notADSFFile: return "Not a .dsf file"
        case .fileTooSmallOrCorrupt: return "File is too small or not a valid DSF container"
        case .ioError(let msg): return msg
        }
    }
}

enum DSFMetadataWriter {

    /// A single ID3v2 frame kept as its raw payload bytes (NOT including the
    /// 10-byte frame header) plus its 4-character frame ID. Re-serialized
    /// with a freshly computed (always v2.3-style, non-synchsafe) size field
    /// regardless of what version tag it was originally read from, so mixing
    /// preserved v2.4 frames into a v2.3 tag we're writing can't corrupt the
    /// frame boundaries.
    private struct Frame {
        let id: String
        let payload: Data
    }

    // MARK: - Public API

    /// Updates the given tag fields on a .dsf file. Any parameter left `nil`
    /// leaves that field untouched (preserving whatever was already there,
    /// if anything). Non-nil parameters overwrite that field entirely.
    static func writeTags(
        to url: URL,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        albumArtist: String? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        year: Int? = nil,
        artworkJPEGData: Data? = nil
    ) throws {
        guard url.pathExtension.lowercased() == "dsf" else {
            throw DSFMetadataWriterError.notADSFFile
        }

        guard let fh = try? FileHandle(forUpdating: url) else {
            throw DSFMetadataWriterError.ioError("Could not open \(url.lastPathComponent) for updating")
        }
        defer { try? fh.close() }

        // --- Walk the fixed DSF chunk layout to find where audio data ends ---
        try fh.seek(toOffset: 0)
        guard let dsdID = try fh.read(upToCount: 4), dsdID == Data("DSD ".utf8) else {
            throw DSFMetadataWriterError.notADSFFile
        }
        _ = try readUInt64LE(fh) // ckDataSize (28)
        _ = try readUInt64LE(fh) // fileSize (stale copy — we recompute and rewrite this)
        _ = try readUInt64LE(fh) // metadataOffset (stale copy — we recompute and rewrite this)

        guard let fmtID = try fh.read(upToCount: 4), fmtID == Data("fmt ".utf8) else {
            throw DSFMetadataWriterError.fileTooSmallOrCorrupt
        }
        let fmtChunkSize = try readUInt64LE(fh)
        guard fmtChunkSize >= 12 else { throw DSFMetadataWriterError.fileTooSmallOrCorrupt }
        let afterFmtHeader = try fh.offset()
        try fh.seek(toOffset: afterFmtHeader + (fmtChunkSize - 12)) // skip fmt payload

        guard let dataID = try fh.read(upToCount: 4), dataID == Data("data".utf8) else {
            throw DSFMetadataWriterError.fileTooSmallOrCorrupt
        }
        let dataChunkSize = try readUInt64LE(fh)
        guard dataChunkSize >= 12 else { throw DSFMetadataWriterError.fileTooSmallOrCorrupt }
        let dataPayloadStart = try fh.offset()
        let rawAudioEnd = dataPayloadStart + (dataChunkSize - 12)

        let actualFileSize = try fh.seekToEnd()

        // Anything already sitting after the audio payload is either an
        // existing ID3v2 tag or nothing. Read only that trailing region.
        let existingTagRegionStart = min(rawAudioEnd, actualFileSize)
        var preservedFrames: [Frame] = []
        if existingTagRegionStart < actualFileSize {
            try fh.seek(toOffset: existingTagRegionStart)
            let existingTagData = try fh.read(upToCount: Int(actualFileSize - existingTagRegionStart)) ?? Data()
            preservedFrames = parseID3v2Frames(existingTagData) ?? []
        }

        // Drop any preserved frame whose ID we're about to overwrite.
        var overwrittenIDs = Set<String>()
        if title != nil { overwrittenIDs.insert("TIT2") }
        if artist != nil { overwrittenIDs.insert("TPE1") }
        if album != nil { overwrittenIDs.insert("TALB") }
        if albumArtist != nil { overwrittenIDs.insert("TPE2") }
        if trackNumber != nil { overwrittenIDs.insert("TRCK") }
        if discNumber != nil { overwrittenIDs.insert("TPOS") }
        if year != nil { overwrittenIDs.insert("TYER") }
        if artworkJPEGData != nil { overwrittenIDs.insert("APIC") } // replace ALL existing pictures with the new one
        preservedFrames.removeAll { overwrittenIDs.contains($0.id) }

        var newFrames: [Frame] = []
        if let title { newFrames.append(textFrame(id: "TIT2", value: title)) }
        if let artist { newFrames.append(textFrame(id: "TPE1", value: artist)) }
        if let album { newFrames.append(textFrame(id: "TALB", value: album)) }
        if let albumArtist { newFrames.append(textFrame(id: "TPE2", value: albumArtist)) }
        if let trackNumber { newFrames.append(textFrame(id: "TRCK", value: String(trackNumber))) }
        if let discNumber { newFrames.append(textFrame(id: "TPOS", value: String(discNumber))) }
        if let year { newFrames.append(textFrame(id: "TYER", value: String(year))) }
        if let artworkJPEGData { newFrames.append(artworkFrame(jpegData: artworkJPEGData)) }

        let allFrames = preservedFrames + newFrames
        let tagBody = allFrames.map { serializeFrame($0) }.reduce(Data(), +)

        var header = Data()
        header.append(contentsOf: [0x49, 0x44, 0x33]) // "ID3"
        header.append(3) // major version 2.3
        header.append(0) // revision
        header.append(0) // flags
        header.append(synchsafe(UInt32(tagBody.count)))

        let newTagData = header + tagBody
        let newTagOffset = existingTagRegionStart

        // --- Commit: truncate off the old tag (if any), append the new one ---
        try fh.truncate(atOffset: newTagOffset)
        try fh.seek(toOffset: newTagOffset)
        try fh.write(contentsOf: newTagData)

        let newFileSize = newTagOffset + UInt64(newTagData.count)
        try fh.seek(toOffset: 12)
        try fh.write(contentsOf: uint64LE(newFileSize))
        try fh.seek(toOffset: 20)
        try fh.write(contentsOf: uint64LE(newTagOffset))

        DebugLogger.shared.info(
            "Wrote DSF ID3v2 tag for \(url.lastPathComponent): \(newFrames.count) field(s) updated, \(preservedFrames.count) frame(s) preserved, tag size=\(newTagData.count) bytes",
            category: "Metadata"
        )
    }

    // MARK: - ID3v2 frame parsing (read-side, for preservation only)

    private static func parseID3v2Frames(_ data: Data) -> [Frame]? {
        guard data.count >= 10 else { return nil }
        guard data[data.startIndex] == 0x49, data[data.startIndex + 1] == 0x44, data[data.startIndex + 2] == 0x33 else {
            return nil // no "ID3" signature — nothing to preserve
        }
        let majorVersion = data[data.startIndex + 3]
        let flags = data[data.startIndex + 5]
        let declaredSize = unsynchsafe(data, offset: data.startIndex + 6)

        var offset = data.startIndex + 10

        // Extended header isn't fully supported here — if present, bail out
        // rather than risk misparsing frame boundaries. The new tag will
        // simply be written without preserving old frames in that case.
        if flags & 0x40 != 0 {
            DebugLogger.shared.info("DSF ID3v2 tag has an extended header — not preserving old frames for this file", category: "Metadata")
            return []
        }

        let tagEnd = min(data.startIndex + 10 + Int(declaredSize), data.endIndex)
        var frames: [Frame] = []

        while offset + 10 <= tagEnd {
            if data[offset] == 0x00 { break } // padding reached

            let idBytes = data.subdata(in: offset..<(offset + 4))
            guard let id = String(data: idBytes, encoding: .ascii) else { break }
            let sizeOffset = offset + 4
            let frameSize: Int
            if majorVersion >= 4 {
                frameSize = Int(unsynchsafe(data, offset: sizeOffset))
            } else {
                frameSize = Int(uint32BE(data, offset: sizeOffset))
            }
            let frameDataStart = offset + 10
            guard frameSize >= 0, frameDataStart + frameSize <= tagEnd else { break }

            let payload = data.subdata(in: frameDataStart..<(frameDataStart + frameSize))
            frames.append(Frame(id: id, payload: payload))

            offset = frameDataStart + frameSize
        }

        return frames
    }

    // MARK: - Frame building / serialization

    private static func textFrame(id: String, value: String) -> Frame {
        var payload = Data([0x03]) // encoding: UTF-8
        payload.append(contentsOf: value.utf8)
        return Frame(id: id, payload: payload)
    }

    /// Builds an APIC (attached picture) frame. Picture type 3 = "Cover
    /// (front)", the type virtually every player (including Apple Music)
    /// looks for as the primary album artwork.
    private static func artworkFrame(jpegData: Data) -> Frame {
        var payload = Data([0x00]) // encoding: ISO-8859-1 (ASCII-safe for the MIME string below)
        payload.append(contentsOf: "image/jpeg".utf8)
        payload.append(0x00) // MIME type terminator
        payload.append(0x03) // picture type: front cover
        payload.append(0x00) // empty description, terminator only
        payload.append(jpegData)
        return Frame(id: "APIC", payload: payload)
    }

    private static func serializeFrame(_ frame: Frame) -> Data {
        var out = Data()
        out.append(contentsOf: frame.id.utf8) // 4 bytes, assumed well-formed since it came from a parsed/known ID
        out.append(uint32BE(UInt32(frame.payload.count)))
        out.append(contentsOf: [0x00, 0x00]) // frame flags
        out.append(frame.payload)
        return out
    }

    // MARK: - Byte helpers

    private static func readUInt64LE(_ fh: FileHandle) throws -> UInt64 {
        guard let d = try fh.read(upToCount: 8), d.count == 8 else {
            throw DSFMetadataWriterError.fileTooSmallOrCorrupt
        }
        return d.withUnsafeBytes { $0.load(as: UInt64.self) }.littleEndian
    }

    private static func uint64LE(_ value: UInt64) -> Data {
        var v = value.littleEndian
        return Data(bytes: &v, count: 8)
    }

    private static func uint32BE(_ value: UInt32) -> Data {
        var v = value.bigEndian
        return Data(bytes: &v, count: 4)
    }

    private static func uint32BE(_ data: Data, offset: Int) -> UInt32 {
        let b0 = UInt32(data[offset]), b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2]), b3 = UInt32(data[offset + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    /// ID3v2 "synchsafe" integer: 4 bytes, top bit of each byte always 0,
    /// giving 28 usable bits total. Used for the overall tag size in the
    /// header (all versions) and for frame sizes in v2.4 frames specifically.
    private static func synchsafe(_ value: UInt32) -> Data {
        let b0 = UInt8((value >> 21) & 0x7F)
        let b1 = UInt8((value >> 14) & 0x7F)
        let b2 = UInt8((value >> 7) & 0x7F)
        let b3 = UInt8(value & 0x7F)
        return Data([b0, b1, b2, b3])
    }

    private static func unsynchsafe(_ data: Data, offset: Int) -> UInt32 {
        let b0 = UInt32(data[offset] & 0x7F), b1 = UInt32(data[offset + 1] & 0x7F)
        let b2 = UInt32(data[offset + 2] & 0x7F), b3 = UInt32(data[offset + 3] & 0x7F)
        return (b0 << 21) | (b1 << 14) | (b2 << 7) | b3
    }
}