import SwiftUI
import GRDB

struct AlbumsScreen: View {
    let allTracks: [Track]
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var albums: [Album] = []
    @State private var settings = DeleteSettings.load()
    
    var body: some View {
        ZStack {
            ScreenSpecificBackgroundView(screen: .albums)
            
            VStack {
                if albums.isEmpty {
                    EmptyAlbumsView()
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 20),
                                GridItem(.flexible())
                            ],
                            spacing: 16
                        ) {
                            ForEach(albums, id: \.id) { album in
                                NavigationLink {
                                    AlbumDetailScreen(album: album, allTracks: allTracks)
                                } label: {
                                    AlbumCardView(album: album,
                                                  tracks: getAlbumTracks(album))
                                        .frame(maxWidth: .infinity, alignment: .topLeading)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                        .padding(.bottom, 100) // Add padding for mini player
                    }
                }
            }
        }
        .navigationTitle(Localized.albums)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadAlbums)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("LibraryNeedsRefresh"))) { _ in
            loadAlbums()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            settings = DeleteSettings.load()
        }
    }
    
    private func getAlbumTracks(_ album: Album) -> [Track] {
        allTracks.filter { $0.albumId == album.id }
    }
    
    private func loadAlbums() {
        do {
            albums = try appCoordinator.getAllAlbums()
        } catch {
            print("Failed to load albums: \(error)")
        }
    }
}

private struct EmptyAlbumsView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "opticaldisc")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(Localized.noAlbumsFound).font(.headline)
            Text(Localized.albumsWillAppear)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// Album card with artwork loading
private struct AlbumCardView: View {
    let album: Album
    let tracks: [Track]
    @State private var artworkImage: UIImage?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Album artwork area with fixed aspect ratio
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.15))
                    .overlay {
                        if let image = artworkImage {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: geometry.size.width, height: geometry.size.width)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        } else {
                            Image(systemName: "music.note")
                                .font(.system(size: 36))
                                .foregroundColor(.secondary)
                        }
                    }
            }
            .aspectRatio(1, contentMode: .fit)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(album.title)
                    .font(.headline)
                    .lineLimit(2)
                
                Text(Localized.songsCount(tracks.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(minHeight: 60, alignment: .topLeading)
        }
        .task {
            loadAlbumArtwork()
        }
    }
    
    private func loadAlbumArtwork() {
        // Use the first track in the album to get artwork
        guard let firstTrack = tracks.first else { return }
        Task {
            artworkImage = await ArtworkManager.shared.getArtwork(for: firstTrack)
        }
    }
}

// Album detail view reconstructed
struct AlbumDetailScreen: View {
    let album: Album
    let allTracks: [Track]
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var artworkImage: UIImage?
    @State private var settings = DeleteSettings.load()
    @State private var albumTracks: [Track] = []
    @State private var artistNameCache: [Int64: String] = [:]
    @State private var showEditSheet = false

    private var playerEngine: PlayerEngine {
        appCoordinator.playerEngine
    }

    private var filteredAlbumTracks: [Track] {
        // Filter out incompatible formats when connected to CarPlay
        if SFBAudioEngineManager.shared.isCarPlayEnvironment {
            return albumTracks.filter { track in
                let ext = URL(fileURLWithPath: track.path).pathExtension.lowercased()
                let incompatibleFormats = ["ogg", "opus", "dsf", "dff"]
                return !incompatibleFormats.contains(ext)
            }
        } else {
            return albumTracks
        }
    }

    private var groupedByDisc: [(discNumber: Int, tracks: [Track])] {
        let grouped = Dictionary(grouping: filteredAlbumTracks) { track in
            track.discNo ?? 1
        }
        return grouped.sorted(by: { $0.key < $1.key }).map { (discNumber: $0.key, tracks: $0.value) }
    }

    private var hasMultipleDiscs: Bool {
        return groupedByDisc.count > 1
    }
    
    private var albumArtist: String {
        if let albumArtist = album.albumArtist, !albumArtist.isEmpty {
            return albumArtist
        }
        if let artistId = album.artistId,
           let artistName = artistNameCache[artistId] {
            return artistName
        }
        return Localized.unknownArtist
    }
    
    var body: some View {
        ZStack {
            ScreenSpecificBackgroundView(screen: .albumDetail)
            
            ScrollView {
                VStack(spacing: 24) {
                    // Artwork + info
                    VStack(spacing: 16) {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.gray.opacity(0.2))
                            .frame(width: 250, height: 250)
                            .overlay {
                                if let image = artworkImage {
                                    Image(uiImage: image)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 250, height: 250)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                } else {
                                    Image(systemName: "music.note")
                                        .font(.system(size: 50))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
                        
                        VStack(spacing: 8) {
                            Text(album.title)
                                .font(.title2)
                                .fontWeight(.bold)
                                .multilineTextAlignment(.center)
                            
                            NavigationLink {
                                ArtistDetailScreenWrapper(artistName: albumArtist, allTracks: allTracks)
                            } label: {
                                Text(albumArtist)
                                    .font(.title3)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .buttonStyle(.plain)
                        }
                        
                        HStack(spacing: 12) {
                            Button {
                                if let first = filteredAlbumTracks.first {
                                    Task {
                                        await playerEngine.playTrack(first, queue: filteredAlbumTracks)
                                    }
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "play.fill")
                                    Text(Localized.play)
                                }
                                .font(.title3.weight(.semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 56)
                                .background(settings.backgroundColorChoice.color)
                                .cornerRadius(28)
                            }

                            Button {
                                guard !filteredAlbumTracks.isEmpty else { return }
                                let shuffled = filteredAlbumTracks.shuffled()
                                Task {
                                    await playerEngine.playTrack(shuffled[0], queue: shuffled)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "shuffle")
                                    Text(Localized.shuffle)
                                }
                                .font(.title3.weight(.semibold))
                                .foregroundColor(settings.backgroundColorChoice.color)
                                .frame(maxWidth: .infinity)
                                .frame(height: 56)
                                .background(settings.backgroundColorChoice.color.opacity(0.1))
                                .cornerRadius(28)
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    .padding(.horizontal)
                    
                    // Track list
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(Localized.songs)
                                .font(.title3.weight(.bold))
                            Spacer()
                            Text(Localized.songsCount(filteredAlbumTracks.count))
                                .font(.body)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 12)

                        LazyVStack(spacing: 0) {
                            ForEach(groupedByDisc, id: \.discNumber) { disc in
                                // Disc header (only show if multiple discs)
                                if hasMultipleDiscs {
                                    HStack {
                                        Text("Disc \(disc.discNumber)")
                                            .font(.headline)
                                            .foregroundColor(.secondary)
                                        Spacer()
                                    }
                                    .padding(.horizontal)
                                    .padding(.top, disc.discNumber > 1 ? 16 : 0)
                                    .padding(.bottom, 8)
                                }

                                // Tracks for this disc
                                ForEach(Array(disc.tracks.enumerated()), id: \.element.stableId) { index, track in
                                    AlbumTrackRowView(
                                        track: track,
                                        trackNumber: track.trackNo ?? (index + 1),
                                        artistName: (try? DatabaseManager.shared.getArtistDisplayName(forTrackStableId: track.stableId, fallbackArtistId: track.artistId)) ?? track.artistId.flatMap { artistNameCache[$0] },
                                        onTap: {
                                            Task {
                                                await playerEngine.playTrack(track, queue: filteredAlbumTracks)
                                            }
                                        }
                                    )

                                    // Add divider between tracks (not after last track of last disc)
                                    let isLastTrackOfDisc = index == disc.tracks.count - 1
                                    let isLastDisc = disc.discNumber == groupedByDisc.last?.discNumber
                                    if !isLastTrackOfDisc || !isLastDisc {
                                        Divider().padding(.leading, 60)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 100) // Add padding for mini player
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showEditSheet = true
                } label: {
                    Image(systemName: "pencil")
                }
            }
        }
        .sheet(isPresented: $showEditSheet) {
            AlbumMetadataEditView(album: album, tracks: albumTracks) {
                // Album title/artist changed — this screen's data no longer
                // matches what's on disk, and re-fetching in place would add
                // a fair bit of state-juggling for a rarely-used edit flow.
                // Simplest correct behavior: pop back to the album list,
                // which reloads fresh from the database.
                dismiss()
            }
        }
        .onAppear {
            loadArtistNameCache()
            loadAlbumTracks()
            loadAlbumArtwork()
        }
        .task {
            // Ensure data loads even if onAppear doesn't trigger
            if albumTracks.isEmpty {
                loadAlbumTracks()
            }
            if artworkImage == nil {
                loadAlbumArtwork()
            }
        }
    }

    private func loadAlbumTracks() {
        guard let albumId = album.id else { return }
        do {
            albumTracks = try appCoordinator.databaseManager.getTracksByAlbumId(albumId)
        } catch {
            print("Failed to load album tracks: \(error)")
        }
    }

    private func loadAlbumArtwork() {
        guard let first = filteredAlbumTracks.first else { return }
        Task {
            do {
                let image = await ArtworkManager.shared.getArtwork(for: first)
                await MainActor.run {
                    artworkImage = image
                }
            }
        }
    }

    private func loadArtistNameCache() {
        do {
            artistNameCache = try DatabaseManager.shared.getAllArtistNamesById()
        } catch {
            print("Failed to load album artist cache: \(error)")
        }
    }
}

struct AlbumTrackRowView: View {
    let track: Track
    let trackNumber: Int
    let artistName: String?
    let onTap: () -> Void
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var isFavorite = false
    @State private var showPlaylistDialog = false
    @State private var showDeleteConfirmation = false
    @State private var deleteSettings = DeleteSettings.load()
    
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                // Track number
                Text("\(trackNumber)")
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
                    .frame(width: 22, alignment: .leading)
                
                // Track info
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                    
                    // Artist name and duration with dot separator
                    HStack(spacing: 0) {
                        if let artistName, !artistName.isEmpty {
                            Text(artistName)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            
                            if track.durationMs != nil {
                                Text(" • ")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        
                        if let duration = track.durationMs {
                            Text(formatDuration(duration))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Spacer()
                
                // Menu button - reduced spacing
                Menu {
                    Button(action: {
                        do {
                            try appCoordinator.toggleFavorite(trackStableId: track.stableId)
                            isFavorite.toggle()
                        } catch {
                            print("Failed to toggle favorite: \(error)")
                        }
                    }) {
                        HStack {
                            Image(systemName: isFavorite ? "heart.slash" : "heart")
                                .foregroundColor(isFavorite ? .red : .primary)
                            Text(isFavorite ? Localized.removeFromLikedSongs : Localized.addToLikedSongs)
                                .foregroundColor(.primary)
                        }
                    }
                    
                    if let artistId = track.artistId,
                       let artist = try? DatabaseManager.shared.read({ db in
                           try Artist.fetchOne(db, key: artistId)
                       }),
                       let allArtistTracks = try? DatabaseManager.shared.getTracksByArtistId(artistId) {
                        NavigationLink(destination: ArtistDetailScreenWrapper(artistName: artist.name, allTracks: allArtistTracks)) {
                            Label(Localized.showArtistPage, systemImage: "person.circle")
                        }
                    }
                    
                    Button(action: {
                        showPlaylistDialog = true
                    }) {
                        Label(Localized.addToPlaylistEllipsis, systemImage: "rectangle.stack.badge.plus")
                    }
                    
                    Button(action: {
                        showDeleteConfirmation = true
                    }) {
                        Label(Localized.deleteFile, systemImage: "trash")
                    }
                    .foregroundColor(.red)
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundColor(.secondary)
                        .frame(width: 24, height: 30)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .onAppear {
            checkFavoriteStatus()
        }
        .sheet(isPresented: $showPlaylistDialog) {
            PlaylistSelectionView(track: track)
                .accentColor(deleteSettings.backgroundColorChoice.color)
        }
        .alert(Localized.deleteFile, isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                deleteFile()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(Localized.deleteFileConfirmation(track.title))
        }
    }
    
    private func checkFavoriteStatus() {
        do {
            isFavorite = try DatabaseManager.shared.isFavorite(trackStableId: track.stableId)
        } catch {
            print("Failed to check favorite status: \(error)")
        }
    }
    
    private func formatDuration(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1000
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
    
    private func deleteFile() {
        Task {
            do {
                let settings = DeleteSettings.load()
                if settings.deleteFromLibraryOnly {
                    DeleteSettings.addExcludedTrack(track.stableId)
                } else {
                    do {
                        try FileManager.default.removeItem(at: URL(fileURLWithPath: track.path))
                    } catch {
                        print("⚠️ Could not remove file from disk: \(error.localizedDescription)")
                    }
                }

                try DatabaseManager.shared.deleteTrack(byStableId: track.stableId)
                NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)
            } catch {
                print("❌ Failed to delete track: \(error)")
            }
        }
    }
}

struct ArtistDetailScreenWrapper: View {
    let artistName: String
    let allTracks: [Track]
    @State private var artist: Artist?
    
    var body: some View {
        Group {
            if let artist {
                ArtistDetailScreen(artist: artist, allTracks: allTracks)
            } else {
                VStack(spacing: 16) {
                    ProgressView()
                    Text(Localized.loadingArtist)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear(perform: loadArtist)
    }
    
    private func loadArtist() {
        do {
            artist = try DatabaseManager.shared.read { db in
                try Artist.filter(Column("name") == artistName).fetchOne(db)
            } ?? Artist(id: nil, name: artistName)
        } catch {
            print("Failed to load artist: \(error)")
            artist = Artist(id: nil, name: artistName)
        }
    }
}

// MARK: - Album Metadata Editing

struct AlbumMetadataEditView: View {
    let album: Album
    let tracks: [Track]
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var titleText: String
    @State private var artistText: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(album: Album, tracks: [Track], onSaved: @escaping () -> Void) {
        self.album = album
        self.tracks = tracks
        self.onSaved = onSaved
        _titleText = State(initialValue: album.title)
        let initialArtist = (album.albumArtist?.isEmpty == false) ? album.albumArtist! : ""
        _artistText = State(initialValue: initialArtist)
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Album")) {
                    TextField("Album Title", text: $titleText)
                        .disabled(isSaving)
                    TextField("Artist", text: $artistText)
                        .disabled(isSaving)
                }

                Section {
                    Text("This updates the tags in each track's file (so it matches in Apple Music, Finder, or other players), plus Cosmos's library. \(nonDSFTrackCount > 0 ? "\(nonDSFTrackCount) track(s) in this album aren't .dsf files — those will be updated in the library only, since native tag writing currently supports .dsf." : "")")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Edit Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Task { await save() }
                        }
                        .disabled(titleText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private var nonDSFTrackCount: Int {
        tracks.filter { URL(fileURLWithPath: $0.path).pathExtension.lowercased() != "dsf" }.count
    }

    @MainActor
    private func save() async {
        let newTitle = titleText.trimmingCharacters(in: .whitespaces)
        let newArtistName = artistText.trimmingCharacters(in: .whitespaces)
        let newArtist: String? = newArtistName.isEmpty ? nil : newArtistName

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        var fileWriteFailures: [String] = []
        do {
            guard let albumId = album.id else {
                throw DSFMetadataWriterError.ioError("Album has no database id")
            }
            let artistRow = try newArtist.map { try DatabaseManager.shared.upsertArtist(name: $0) }

            try DatabaseManager.shared.updateAlbumMetadata(
                albumId: albumId,
                title: newTitle,
                albumArtist: newArtist,
                artistId: artistRow?.id
            )
            try DatabaseManager.shared.setAlbumArtists(albumId: albumId, artistIds: artistRow?.id.map { [$0] } ?? [])

            for track in tracks {
                try? DatabaseManager.shared.updateTrackArtist(trackStableId: track.stableId, artistId: artistRow?.id)
                if let artistId = artistRow?.id {
                    try? DatabaseManager.shared.setTrackArtists(trackStableId: track.stableId, artistIds: [artistId])
                }

                let ext = URL(fileURLWithPath: track.path).pathExtension.lowercased()
                guard ext == "dsf" else {
                    continue // library already updated above; file tag writing not yet supported for this format
                }
                do {
                    try DSFMetadataWriter.writeTags(
                        to: URL(fileURLWithPath: track.path),
                        artist: newArtist,
                        album: newTitle,
                        albumArtist: newArtist
                    )
                } catch {
                    fileWriteFailures.append("\(track.title): \(error.localizedDescription)")
                }
            }

            NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)

            if fileWriteFailures.isEmpty {
                onSaved()
            } else {
                errorMessage = "Library updated, but some files couldn't be tagged:\n" + fileWriteFailures.joined(separator: "\n")
            }
        } catch {
            errorMessage = "Failed to save: \(error.localizedDescription)"
        }
    }
}