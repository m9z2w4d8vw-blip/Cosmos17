import SwiftUI
import GRDB
import PhotosUI

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
            playerEngine.prefetchAll(filteredAlbumTracks)
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
    @State private var lookupFailed = false
    
    var body: some View {
        Group {
            if let artist {
                ArtistDetailScreen(artist: artist, allTracks: allTracks)
            } else if lookupFailed {
                VStack(spacing: 16) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("Couldn't load \(artistName)")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            if let found = try DatabaseManager.shared.read(({ db in
                try Artist.filter(Column("name") == artistName).fetchOne(db)
            })) {
                artist = found
            } else {
                // No matching Artist row in the database. Previously this
                // fell back to a placeholder Artist(id: nil, ...) and
                // navigated into ArtistDetailScreen anyway — if that screen
                // (or anything it calls) assumes a real, non-nil artist.id
                // (e.g. to query tracks by artist_id), that's a crash. Since
                // this wrapper only has a name — no guaranteed real row to
                // show — showing a clear "couldn't load" state is safer
                // than guessing at what a nil-id Artist should render as.
                lookupFailed = true
            }
        } catch {
            print("Failed to load artist: \(error)")
            lookupFailed = true
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

    // Artist autocomplete
    @State private var appleMusicSearchText: String = ""
    @State private var artistSuggestions: [ITunesArtist] = []
    @State private var isSearchingArtists = false
    @State private var artistSearchTask: Task<Void, Never>?
    @State private var artistFieldFocused = false

    // Apple Music album matching
    @State private var albumSearchText: String = ""
    @State private var searchedArtistName: String?
    @State private var albumSuggestions: [ITunesAlbum] = []
    @State private var isSearchingAlbums = false
    @State private var matchedAlbum: ITunesAlbum?

    // Cover art
    @State private var artworkPreview: UIImage?
    @State private var pendingArtworkJPEGData: Data?
    @State private var isFetchingArtwork = false
    @State private var photosPickerItem: PhotosPickerItem?

    init(album: Album, tracks: [Track], onSaved: @escaping () -> Void) {
        self.album = album
        self.tracks = tracks
        self.onSaved = onSaved
        _titleText = State(initialValue: album.title)
        let initialArtist = (album.albumArtist?.isEmpty == false) ? album.albumArtist! : ""
        _artistText = State(initialValue: initialArtist)
        _appleMusicSearchText = State(initialValue: initialArtist)
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Cover Art")) {
                    HStack(spacing: 16) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.2))
                            .frame(width: 72, height: 72)
                            .overlay {
                                if isFetchingArtwork {
                                    ProgressView()
                                } else if let artworkPreview {
                                    Image(uiImage: artworkPreview)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 72, height: 72)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                } else {
                                    Image(systemName: "music.note")
                                        .foregroundColor(.secondary)
                                }
                            }

                        VStack(alignment: .leading, spacing: 8) {
                            PhotosPicker(selection: $photosPickerItem, matching: .images) {
                                Text("Choose Photo")
                            }
                            if pendingArtworkJPEGData != nil {
                                Button("Remove New Cover", role: .destructive) {
                                    pendingArtworkJPEGData = nil
                                    artworkPreview = nil
                                }
                                .font(.footnote)
                            }
                        }
                        Spacer()
                    }
                    .onChange(of: photosPickerItem) { _, newItem in
                        guard let newItem else { return }
                        Task { await loadPickedPhoto(newItem) }
                    }
                }

                Section(header: Text("Album")) {
                    TextField("Album Title", text: $titleText)
                        .disabled(isSaving)
                    TextField("Artist", text: $artistText)
                        .disabled(isSaving)
                }

                Section(header: Text("Search Apple Music")) {
                    TextField("Artist name", text: $appleMusicSearchText)
                        .disabled(isSaving)
                        .onChange(of: appleMusicSearchText) { _, newValue in
                            scheduleArtistSearch(for: newValue)
                        }

                    if isSearchingArtists {
                        HStack {
                            ProgressView().scaleEffect(0.7)
                            Text("Searching…").font(.footnote).foregroundColor(.secondary)
                        }
                    } else if !artistSuggestions.isEmpty {
                        ForEach(artistSuggestions) { suggestion in
                            Button {
                                selectArtist(suggestion)
                            } label: {
                                HStack {
                                    Image(systemName: "person.crop.circle")
                                        .foregroundColor(.secondary)
                                    Text(suggestion.artistName)
                                        .foregroundColor(.primary)
                                    Spacer()
                                }
                            }
                        }
                    } else if !appleMusicSearchText.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("No matching artists")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Type an artist name to look up their albums on Apple Music and match this album's title, artist, year, and cover art.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }

                    TextField("Album name", text: $albumSearchText)
                        .disabled(isSaving || searchedArtistName == nil)
                    if searchedArtistName == nil {
                        Text("Search an artist above first, then narrow down their albums here.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else if let searchedArtistName {
                        Text("Searching \(searchedArtistName)'s albums" + (albumSearchText.trimmingCharacters(in: .whitespaces).isEmpty ? "" : " matching \"\(albumSearchText)\""))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                if isSearchingAlbums {
                    Section(header: Text("Matching Apple Music Albums")) {
                        HStack {
                            ProgressView().scaleEffect(0.7)
                            Text("Looking up albums…").font(.footnote).foregroundColor(.secondary)
                        }
                    }
                } else if !displayedAlbumSuggestions.isEmpty {
                    Section(header: Text("Match Apple Music Album")) {
                        ForEach(displayedAlbumSuggestions) { candidate in
                            Button {
                                selectAlbum(candidate)
                            } label: {
                                HStack(spacing: 12) {
                                    AsyncImage(url: URL(string: candidate.artworkUrl100 ?? "")) { phase in
                                        if let image = phase.image {
                                            image.resizable().aspectRatio(contentMode: .fill)
                                        } else {
                                            Rectangle().fill(Color.gray.opacity(0.2))
                                        }
                                    }
                                    .frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(candidate.collectionName)
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                        HStack(spacing: 4) {
                                            Text(candidate.artistName)
                                            if let year = candidate.year {
                                                Text("· \(String(year))")
                                            }
                                        }
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if matchedAlbum?.id == candidate.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                            }
                        }
                    }
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
            .onAppear {
                if !appleMusicSearchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    scheduleArtistSearch(for: appleMusicSearchText)
                }
            }
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

    // MARK: - Artist autocomplete

    private func scheduleArtistSearch(for text: String) {
        artistSearchTask?.cancel()
        matchedAlbum = nil
        albumSuggestions = []
        searchedArtistName = nil

        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            artistSuggestions = []
            isSearchingArtists = false
            return
        }

        artistSearchTask = Task {
            isSearchingArtists = true
            try? await Task.sleep(nanoseconds: 350_000_000) // debounce while typing
            guard !Task.isCancelled else { return }
            do {
                let results = try await AppleMusicLookupService.searchArtists(term: trimmed)
                guard !Task.isCancelled else { return }
                artistSuggestions = results
            } catch {
                artistSuggestions = []
            }
            isSearchingArtists = false
        }
    }

    private func selectArtist(_ suggestion: ITunesArtist) {
        artistText = suggestion.artistName
        artistSuggestions = []
        artistSearchTask?.cancel()
        loadAlbums(forArtist: suggestion.artistName)
    }

    // MARK: - Album matching

    /// The album list actually shown: `albumSuggestions` (all albums fetched
    /// for `searchedArtistName`) narrowed down by whatever's typed in the
    /// album name field. Filtering client-side over the already-fetched list
    /// rather than firing a new network search per keystroke — the artist's
    /// full album list is already in memory from `loadAlbums`.
    private var displayedAlbumSuggestions: [ITunesAlbum] {
        let query = albumSearchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return albumSuggestions }
        return albumSuggestions.filter { $0.collectionName.lowercased().contains(query) }
    }

    private func loadAlbums(forArtist artistName: String) {
        isSearchingAlbums = true
        albumSuggestions = []
        albumSearchText = ""
        searchedArtistName = artistName
        Task {
            do {
                let results = try await AppleMusicLookupService.searchAlbums(artistName: artistName)
                albumSuggestions = results
            } catch {
                albumSuggestions = []
            }
            isSearchingAlbums = false
        }
    }

    private func selectAlbum(_ candidate: ITunesAlbum) {
        matchedAlbum = candidate
        titleText = candidate.collectionName
        artistText = candidate.artistName

        guard let artworkURL = candidate.highResArtworkURL else { return }
        isFetchingArtwork = true
        Task {
            do {
                let data = try await AppleMusicLookupService.downloadArtworkJPEGData(from: artworkURL)
                if let image = UIImage(data: data) {
                    artworkPreview = image
                    pendingArtworkJPEGData = data
                }
            } catch {
                // Non-fatal — the title/artist match still applies even if artwork fails to download
            }
            isFetchingArtwork = false
        }
    }

    // MARK: - Manual photo picking

    private func loadPickedPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }

        // Re-encode as JPEG at a sane size — photo library assets can be
        // very large (HEIC, multiple MB), which would bloat every track's
        // tag unnecessarily.
        let resized = resizedForArtwork(image)
        guard let jpegData = resized.jpegData(compressionQuality: 0.85) else { return }

        artworkPreview = resized
        pendingArtworkJPEGData = jpegData
    }

    private func resizedForArtwork(_ image: UIImage, maxDimension: CGFloat = 1200) -> UIImage {
        let size = image.size
        let largestSide = max(size.width, size.height)
        guard largestSide > maxDimension else { return image }
        let scale = maxDimension / largestSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    // MARK: - Save

    @MainActor
    private func save() async {
        let newTitle = titleText.trimmingCharacters(in: .whitespaces)
        let newArtistName = artistText.trimmingCharacters(in: .whitespaces)
        let newArtist: String? = newArtistName.isEmpty ? nil : newArtistName
        let newYear = matchedAlbum?.year

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
                        albumArtist: newArtist,
                        year: newYear,
                        artworkJPEGData: pendingArtworkJPEGData
                    )
                    if pendingArtworkJPEGData != nil {
                        try? DatabaseManager.shared.updateTrackHasEmbeddedArt(trackStableId: track.stableId, hasEmbeddedArt: true)
                        // Without this, a previously-cached (e.g. blank/old)
                        // artwork result for this track would keep being
                        // served from ArtworkManager's memory/disk cache
                        // indefinitely, even though the file itself now has
                        // a fresh APIC frame — the cache has no other way to
                        // know the underlying file changed.
                        _ = await ArtworkManager.shared.forceRefreshArtwork(for: track)
                    }
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