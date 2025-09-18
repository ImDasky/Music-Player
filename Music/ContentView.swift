import SwiftUI
import UIKit
import CoreData
import AVFoundation
import MediaPlayer

// MARK: - BlurView (UIVisualEffectView wrapper)
struct BlurView: UIViewRepresentable {
    let style: UIBlurEffect.Style
    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: style))
    }
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
    }
}

// MARK: - Temporary Song for Playing
struct TempSong: Identifiable, Hashable {
    let id: UUID
    let title: String
    let artist: String
    let artwork: String?
    let album: String?
    let url: String?
    
    init(from track: QobuzTrack) {
        self.id = UUID()
        self.title = track.title
        self.artist = track.artist
        self.artwork = track.image
        self.album = track.album
        self.url = track.url
    }
    
    init(id: UUID = UUID(), title: String, artist: String, artwork: String?, album: String?, url: String?) {
        self.id = id
        self.title = title
        self.artist = artist
        self.artwork = artwork
        self.album = album
        self.url = url
    }
}

// MARK: - Qobuz API Models
struct QobuzResponse: Decodable {
    let tracks: [QobuzTrack]?
}

struct QobuzTrack: Decodable {
    let id: Int
    let title: String
    let artist: String
    let album: String?
    let image: String?
    let url: String?
}

// MARK: - Player + Library managers
final class MusicPlayer: ObservableObject {
    @Published var currentSong: Any? = nil // Can be Song or TempSong
    @Published var isPlaying: Bool = false
    @Published var queue: [Song] = []
    @Published var currentIndex: Int? = nil

    func play(song: Song) {
        currentSong = song
        AudioPlayer.shared.play(song: song)
        // isPlaying will be reflected by AudioPlayer.shared.isPlaying
        if queue.isEmpty || (currentIndex == nil) {
            // Build queue from all songs (latest added first)
            let context = PersistenceController.shared.container.viewContext
            let request: NSFetchRequest<Song> = Song.fetchRequest()
            request.sortDescriptors = [NSSortDescriptor(key: "dateAdded", ascending: false)]
            let all = (try? context.fetch(request)) ?? []
            queue = all
        }
        if let idx = queue.firstIndex(of: song) { currentIndex = idx }
    }
    
    func play(tempSong: TempSong) {
        currentSong = tempSong
        AudioPlayer.shared.play(tempSong: tempSong)
        
        // Clear queue context when streaming temp content
        currentIndex = nil
        queue = []
    }
    
    func playFromQobuz(track: QobuzTrack) {
        // Create a temporary Song object for playing
        let tempSong = TempSong(from: track)
        currentSong = tempSong
        
        // Route streaming playback through the central AudioPlayer for consistent state
        AudioPlayer.shared.play(tempSong: tempSong)
        currentIndex = nil
        queue = []
    }
    
    func skipNext() {
        guard let idx = currentIndex, idx + 1 < queue.count else { return }
        let next = queue[idx + 1]
        currentIndex = idx + 1
        play(song: next)
    }
    
    func skipPrevious(currentTime: TimeInterval) {
        if currentTime > 3 { AudioPlayer.shared.seek(to: 0); return }
        guard let idx = currentIndex else { AudioPlayer.shared.seek(to: 0); return }
        if idx - 1 >= 0 {
            let prev = queue[idx - 1]
            currentIndex = idx - 1
            play(song: prev)
        } else {
            AudioPlayer.shared.seek(to: 0)
        }
    }
    
    func togglePlayPause() {
        if AudioPlayer.shared.isPlaying {
            AudioPlayer.shared.pause()
        } else {
            AudioPlayer.shared.resume()
        }
    }
}

final class LibraryManager: ObservableObject {
    private let viewContext: NSManagedObjectContext
    private let persistenceController: PersistenceController
    
    init(context: NSManagedObjectContext, persistenceController: PersistenceController) {
        self.viewContext = context
        self.persistenceController = persistenceController
    }
    
    func addSong(title: String, artist: String, artwork: String? = nil, album: String? = nil, url: String? = nil, qobuzTrackId: Int? = nil) -> Bool {
        // Check if song already exists
        let existingSongs = getAllSongs()
        let songExists = existingSongs.contains { song in
            song.title == title && song.artist == artist
        }
        
        if !songExists {
            let song = Song(context: viewContext)
            song.id = UUID()
            song.title = title
            song.artist = artist
            song.artwork = artwork
            song.album = album
            song.url = url
            song.qobuzTrackId = Int32(qobuzTrackId ?? 0)
            song.dateAdded = Date()
            song.downloadStatus = DownloadStatus.downloading.rawValue // Start downloading immediately
            persistenceController.save()
            
            // Start download immediately when adding to library
            if let trackId = qobuzTrackId {
                DownloadManager.shared.downloadSongFromQobuz(song, trackId: trackId, context: viewContext)
            } else {
                DownloadManager.shared.downloadSong(song, context: viewContext)
            }
            return true // Successfully added
        }
        return false // Already exists
    }
    
    func addSong(from qobuzTrack: QobuzTrack) -> Bool {
        return addSong(
            title: qobuzTrack.title,
            artist: qobuzTrack.artist,
            artwork: qobuzTrack.image,
            album: qobuzTrack.album,
            url: qobuzTrack.url,
            qobuzTrackId: qobuzTrack.id
        )
    }
    
    // Find matching song already in library (by title/artist or album)
    func findSongMatching(track: QobuzTrack) -> Song? {
        let request: NSFetchRequest<Song> = Song.fetchRequest()
        if let album = track.album {
            request.predicate = NSPredicate(format: "(title ==[cd] %@ AND artist ==[cd] %@) OR (album ==[cd] %@)", track.title, track.artist, album)
        } else {
            request.predicate = NSPredicate(format: "title ==[cd] %@ AND artist ==[cd] %@", track.title, track.artist)
        }
        request.fetchLimit = 1
        do { return try viewContext.fetch(request).first } catch { return nil }
    }

    func deleteSong(_ song: Song) {
        // Delete downloaded file if it exists
        DownloadManager.shared.deleteDownloadedFile(for: song)
        viewContext.delete(song)
        persistenceController.save()
    }
    
    func searchSongs(query: String) -> [Song] {
        if query.isEmpty {
            return getAllSongs()
        } else {
            return searchSongsInDatabase(query: query)
        }
    }
    
    func isSongInLibrary(title: String, artist: String) -> Bool {
        let existingSongs = getAllSongs()
        return existingSongs.contains { song in
            song.title == title && song.artist == artist
        }
    }
    
    // MARK: - Private Helper Methods
    private func getAllSongs() -> [Song] {
        let request: NSFetchRequest<Song> = Song.fetchRequest()
        let sortDescriptor = NSSortDescriptor(key: "dateAdded", ascending: false)
        request.sortDescriptors = [sortDescriptor]
        
        do {
            return try viewContext.fetch(request)
        } catch {
            print("Error fetching songs: \(error)")
            return []
        }
    }
    
    private func searchSongsInDatabase(query: String) -> [Song] {
        let request: NSFetchRequest<Song> = Song.fetchRequest()
        request.predicate = NSPredicate(format: "title CONTAINS[cd] %@ OR artist CONTAINS[cd] %@ OR album CONTAINS[cd] %@", query, query, query)
        let sortDescriptor = NSSortDescriptor(key: "dateAdded", ascending: false)
        request.sortDescriptors = [sortDescriptor]
        
        do {
            return try viewContext.fetch(request)
        } catch {
            print("Error searching songs: \(error)")
            return []
        }
    }
}

// MARK: - Qobuz API Client
final class QobuzAPI: ObservableObject {
    @Published var results: [QobuzTrack] = []

    func search(query: String) {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.qobuz.com/v4/us-en/catalog/search/autosuggest?q=\(encoded)") else { return }

        var request = URLRequest(url: url)
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")

        URLSession.shared.dataTask(with: request) { data, _, error in
            if let data = data {
                do {
                    let decoded = try JSONDecoder().decode(QobuzResponse.self, from: data)
                    DispatchQueue.main.async {
                        self.results = decoded.tracks ?? []
                    }
                } catch {
                    print("Decoding error:", error)
                }
            } else if let error = error {
                print("Request error:", error)
            }
        }.resume()
    }
}

// MARK: - ContentView
struct ContentView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @StateObject private var player = MusicPlayer()
    @StateObject private var libraryManager: LibraryManager
    
    private let miniPlayerBottomPadding: CGFloat = 0

    init() {
        let persistenceController = PersistenceController.shared
        let context = persistenceController.container.viewContext
        let manager = LibraryManager(context: context, persistenceController: persistenceController)
        _libraryManager = StateObject(wrappedValue: manager)
    }

    var body: some View {
        TabView {
            // Library Tab
            ZStack(alignment: .bottom) {
                LibraryView()
                    .environmentObject(player)
                    .environmentObject(libraryManager)
                    .environment(\.managedObjectContext, viewContext)

                if player.currentSong != nil {
                    NowPlayingBar()
                        .environmentObject(player)
                        .padding(.bottom, miniPlayerBottomPadding)
                }
            }
            .tabItem {
                ZStack {
                    Image(systemName: "rectangle.stack.fill")
                    Image(systemName: "music.note")
                        .offset(x: 8, y: 8)
                }
                Text("Library")
            }

            // Radio Tab
            ZStack(alignment: .bottom) {
                RadioView()
                if player.currentSong != nil {
                    NowPlayingBar()
                        .environmentObject(player)
                        .padding(.bottom, miniPlayerBottomPadding)
                }
            }
            .tabItem {
                Label("Radio", systemImage: "dot.radiowaves.left.and.right")
            }

            // Search Tab
            ZStack(alignment: .bottom) {
                SearchView()
                    .environmentObject(player)
                    .environmentObject(libraryManager)
                    .environment(\.managedObjectContext, viewContext)
                if player.currentSong != nil {
                    NowPlayingBar()
                        .environmentObject(player)
                        .padding(.bottom, miniPlayerBottomPadding)
                }
            }
            .tabItem {
                Label("Search", systemImage: "magnifyingglass")
            }
        }
        .accentColor(.white)
    }
}

// MARK: - NowPlayingBar
struct NowPlayingBar: View {
    @EnvironmentObject var player: MusicPlayer
    @State private var showFullPlayer = false
    @ObservedObject private var audio = AudioPlayer.shared
    @Environment(\.managedObjectContext) private var viewContext

    private let blurStyle: UIBlurEffect.Style = .systemChromeMaterialDark

    private func skipForward() { player.skipNext() }
    private func skipBackward() { player.skipPrevious(currentTime: audio.currentTime) }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 0.5)

            HStack(spacing: 12) {
                if let song = player.currentSong as? Song {
                    // Core Data Song
                    LocalArtworkView(song: song, size: 44)
                } else if let tempSong = player.currentSong as? TempSong {
                    // Temporary Song from Qobuz
                    if let art = tempSong.artwork, let url = URL(string: art) {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image {
                                image.resizable()
                            } else if phase.error != nil {
                                Image(systemName: "exclamationmark.triangle")
                                    .resizable()
                                    .foregroundColor(.gray)
                            } else {
                                Image(systemName: "music.note")
                                    .resizable()
                                    .foregroundColor(.gray)
                            }
                        }
                        .frame(width: 44, height: 44)
                        .cornerRadius(4)
                    } else {
                        Image(systemName: tempSong.artwork ?? "music.note")
                            .resizable()
                            .frame(width: 44, height: 44)
                            .cornerRadius(4)
                    }
                }

                VStack(alignment: .leading) {
                    if let song = player.currentSong as? Song {
                        Text(song.title ?? "Unknown Title")
                            .font(.subheadline).fontWeight(.semibold).foregroundColor(.white)
                        Text(song.artist ?? "Unknown Artist")
                            .font(.caption).foregroundColor(.white.opacity(0.8))
                    } else if let tempSong = player.currentSong as? TempSong {
                        Text(tempSong.title)
                            .font(.subheadline).fontWeight(.semibold).foregroundColor(.white)
                        Text(tempSong.artist)
                            .font(.caption).foregroundColor(.white.opacity(0.8))
                    }
                }
                Spacer()

                HStack(spacing: 16) {
                    Button(action: { skipBackward() }) {
                        Image(systemName: "backward.fill")
                            .foregroundColor(.white)
                    }
                    Button(action: { audio.isPlaying ? AudioPlayer.shared.pause() : AudioPlayer.shared.resume() }) {
                        Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                            .foregroundColor(.white)
                    }
                    Button(action: { skipForward() }) {
                        Image(systemName: "forward.fill")
                            .foregroundColor(.white)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(
            ZStack {
                BlurView(style: blurStyle)
                Color(white: 0.06).opacity(0.25)
            }
        )
        .onTapGesture { showFullPlayer.toggle() }
        .sheet(isPresented: $showFullPlayer) {
            FullPlayerView()
                .environmentObject(player)
        }
    }
}

// MARK: - FullPlayerView
struct FullPlayerView: View {
    @EnvironmentObject var player: MusicPlayer
    @ObservedObject private var audio = AudioPlayer.shared
    @Environment(\.managedObjectContext) private var viewContext
    @State private var isScrubbing = false
    @State private var tempTime: Double = 0
    @State private var isShuffling = false
    @State private var repeatMode: RepeatMode = .off
    @State private var showUpNext = false

    enum RepeatMode { case off, one, all }

    private func format(_ t: TimeInterval) -> String {
        guard t.isFinite && !t.isNaN else { return "0:00" }
        let total = Int(t.rounded())
        let m = total / 60, s = total % 60
        return String(format: "%d:%02d", m, s)
    }
    private func skipForward() { player.skipNext() }
    private func skipBackward() { player.skipPrevious(currentTime: audio.currentTime) }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 16) {
                Capsule().fill(Color.white.opacity(0.25)).frame(width: 40, height: 5).padding(.top, 8)
                Spacer(minLength: 0)

                // Artwork
                if let song = player.currentSong as? Song {
                    LocalArtworkView(song: song, size: 300)
                        .frame(width: 300, height: 300)
                        .cornerRadius(16)
                        .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 12)
                } else if let tempSong = player.currentSong as? TempSong, let art = tempSong.artwork, let url = URL(string: art) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else if phase.error != nil {
                            Image(systemName: "exclamationmark.triangle").resizable().scaledToFit().foregroundColor(.gray)
                        } else {
                            Image(systemName: "music.note").resizable().scaledToFit().foregroundColor(.gray)
                        }
                    }
                    .frame(width: 300, height: 300)
                    .cornerRadius(16)
                    .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 12)
                }

                // Titles
                VStack(spacing: 4) {
                    if let song = player.currentSong as? Song {
                        Text(song.title ?? "Unknown Title").font(.title2).fontWeight(.semibold).foregroundColor(.white)
                        Text(song.artist ?? "Unknown Artist").font(.subheadline).foregroundColor(.white.opacity(0.85))
                    } else if let tempSong = player.currentSong as? TempSong {
                        Text(tempSong.title).font(.title2).fontWeight(.semibold).foregroundColor(.white)
                        Text(tempSong.artist).font(.subheadline).foregroundColor(.white.opacity(0.85))
                    }
                }.padding(.top, 4)

                // Scrubber
                VStack(spacing: 6) {
                    LineScrubber(currentTime: Binding(
                        get: { isScrubbing ? tempTime : audio.currentTime },
                        set: { newVal in
                            tempTime = max(0, min(newVal, max(audio.duration, 0)))
                        }
                    ), duration: audio.duration, onCommit: {
                        AudioPlayer.shared.seek(to: tempTime)
                    }, onBegin: {
                        isScrubbing = true
                        tempTime = audio.currentTime
                    }, onEnd: {
                        isScrubbing = false
                    })
                }
                .padding(.horizontal)

                // Playback controls
                HStack(spacing: 28) {
                    Button(action: { isShuffling.toggle() }) {
                        Image(systemName: "shuffle").foregroundColor(isShuffling ? .white : .white.opacity(0.6))
                    }
                    Button(action: { skipBackward() }) {
                        Image(systemName: "backward.fill").foregroundColor(.white)
                    }
                    Button(action: {
                        if audio.isPlaying { AudioPlayer.shared.pause() } else { AudioPlayer.shared.resume() }
                    }) {
                        Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundColor(.white)
                    }
                    Button(action: { skipForward() }) {
                        Image(systemName: "forward.fill").foregroundColor(.white)
                    }
                    Button(action: {
                        switch repeatMode { case .off: repeatMode = .one; case .one: repeatMode = .all; case .all: repeatMode = .off }
                    }) {
                        let symbol: String = (repeatMode == .off ? "repeat" : (repeatMode == .one ? "repeat.1" : "repeat"))
                        Image(systemName: symbol).foregroundColor(repeatMode == .off ? .white.opacity(0.6) : .white)
                    }
                }
                .font(.title2)

                // Volume
                VolumeView()
                    .frame(height: 36)
                    .padding(.horizontal)

                // Up Next / Options row
                HStack {
                    Button(action: { showUpNext.toggle() }) {
                        HStack(spacing: 8) {
                            Image(systemName: "text.line.first.and.arrowtriangle.forward").foregroundColor(.white)
                            Text("Up Next").foregroundColor(.white)
                        }
                    }
                    Spacer()
                    Menu {
                        Picker("Quality", selection: Binding(get: { AudioPlayer.shared.audioQuality }, set: { AudioPlayer.shared.setAudioQuality($0) })) {
                            ForEach(AudioPlayer.AudioQuality.allCases, id: \.self) { q in
                                Text(q.rawValue).tag(q)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle").foregroundColor(.white).font(.title3)
                    }
                }
                .padding(.horizontal)

                // Extra bottom space to allow scrolling further
                Color.clear.frame(height: 300)
            }
        }
        .padding(.bottom, 20)
        .background(Color.black.ignoresSafeArea())
        .sheet(isPresented: $showUpNext) {
            UpNextView().environmentObject(player)
        }
    }
}

// Volume slider wrapper
struct VolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView { MPVolumeView(frame: .zero) }
    func updateUIView(_ view: MPVolumeView, context: Context) {}
}

struct LineScrubber: View {
    @Binding var currentTime: Double
    let duration: Double
    var onCommit: () -> Void
    var onBegin: () -> Void
    var onEnd: () -> Void
    @State private var started = false

    private func format(_ t: Double) -> String {
        guard t.isFinite && !t.isNaN else { return "0:00" }
        let total = Int(t.rounded())
        let m = total / 60, s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.25)).frame(height: 3)
                    Capsule().fill(Color.white).frame(width: progressWidth(total: geo.size.width), height: 3)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !started { started = true; onBegin() }
                        let x = max(0, min(value.location.x, geo.size.width))
                        let ratio = (geo.size.width > 0 ? Double(x / geo.size.width) : 0)
                        currentTime = ratio * max(duration, 0)
                    }
                    .onEnded { _ in
                        onCommit()
                        onEnd()
                        started = false
                    }
                )
            }
            .frame(height: 20)

            HStack {
                Text(format(currentTime)).font(.caption2).foregroundColor(.white.opacity(0.8))
                Spacer()
                Text(format(duration)).font(.caption2).foregroundColor(.white.opacity(0.8))
            }
        }
    }

    private func progressWidth(total: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        let ratio = CGFloat(currentTime / duration)
        return max(0, min(ratio * total, total))
    }
}

struct UpNextView: View {
    @EnvironmentObject var player: MusicPlayer
    var body: some View {
        NavigationView {
            List {
                if let idx = player.currentIndex {
                    let upcoming = Array(player.queue.dropFirst(idx + 1))
                    Section(header: Text("Up Next").foregroundColor(.white)) {
                        ForEach(upcoming) { song in
                            HStack {
                                LocalArtworkView(song: song, size: 44)
                                VStack(alignment: .leading) {
                                    Text(song.title ?? "Unknown Title").foregroundColor(.white)
                                    Text(song.artist ?? "Unknown Artist").font(.caption).foregroundColor(.white.opacity(0.8))
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { player.play(song: song) }
                            .listRowBackground(Color.clear)
                        }
                        if upcoming.isEmpty {
                            Text("No upcoming songs").foregroundColor(.white.opacity(0.6))
                                .listRowBackground(Color.clear)
                        }
                    }
                } else if let temp = player.currentSong as? TempSong {
                    Section(header: Text("Now Playing").foregroundColor(.white)) {
                        HStack {
                            if let art = temp.artwork, let url = URL(string: art) {
                                AsyncImage(url: url) { p in (p.image?.resizable()) ?? Image(systemName: "music.note").resizable() }
                                    .frame(width: 44, height: 44).cornerRadius(6)
                            }
                            VStack(alignment: .leading) {
                                Text(temp.title).foregroundColor(.white)
                                Text(temp.artist).font(.caption).foregroundColor(.white.opacity(0.8))
                            }
                        }
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .navigationTitle("Up Next")
        }
    }
}

// MARK: - Local artwork extractor
struct LocalArtworkView: View {
    let song: Song
    let size: CGFloat
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let art = song.artwork, let url = URL(string: art), art.hasPrefix("http") {
                AsyncImage(url: url) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() }
                    else { Image(systemName: "music.note").resizable().foregroundColor(.gray) }
                }
            } else {
                Image(systemName: "music.note").resizable().foregroundColor(.gray)
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .cornerRadius(size < 100 ? 6 : 12)
        .onAppear(perform: load)
    }

    private func load() {
        guard let path = song.localFilePath, FileManager.default.fileExists(atPath: path) else { return }
        let asset = AVAsset(url: URL(fileURLWithPath: path))
        if let img = extract(from: asset.commonMetadata) { image = img; return }
        for fmt in asset.availableMetadataFormats {
            if let img = extract(from: asset.metadata(forFormat: fmt)) { image = img; return }
        }
    }

    private func extract(from items: [AVMetadataItem]) -> UIImage? {
        for item in items {
            if let data = item.dataValue, let img = UIImage(data: data) { return img }
            if let data = item.value as? Data, let img = UIImage(data: data) { return img }
        }
        return nil
    }
}

// MARK: - Library (Apple Music style hub)
enum LibrarySection: String, CaseIterable { case songs = "Songs", playlists = "Playlists", genres = "Genres", recents = "Recents" }

struct LibraryView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @State private var selection: LibrarySection = .songs

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("", selection: $selection) {
                    ForEach(LibrarySection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding(.horizontal)
                .padding(.top, 8)

                Group {
                    switch selection {
                    case .songs: SongsRootView()
                    case .playlists: PlaylistsView()
                    case .genres: GenresView()
                    case .recents: RecentlyPlayedView()
                    }
                }
            }
            .navigationTitle("Library")
        }
    }
}

// MARK: - Songs Root View (Recently Added only)
struct SongsRootView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Song.dateAdded, ascending: false)],
        animation: .default)
    private var songs: FetchedResults<Song>
    
    private var recentlyAdded: [Song] { Array(songs.prefix(12)) }
    
    @EnvironmentObject var player: MusicPlayer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !recentlyAdded.isEmpty {
                    Text("Recently Added").font(.title2).bold().foregroundColor(.white).padding(.horizontal)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHGrid(rows: [GridItem(.fixed(130), spacing: 20, alignment: .top), GridItem(.fixed(130), spacing: 20, alignment: .top)], spacing: 20) {
                            ForEach(recentlyAdded) { song in
                                VStack(alignment: .leading, spacing: 6) {
                                    LocalArtworkView(song: song, size: 110)
                                    Text(song.title ?? "Unknown").lineLimit(1).font(.caption).foregroundColor(.white)
                                    Text(song.artist ?? "Unknown").lineLimit(1).font(.caption2).foregroundColor(.white.opacity(0.7))
                                }
                                .frame(width: 150, alignment: .leading)
                                .padding(.horizontal, 8)
                                .contentShape(Rectangle())
                                .onTapGesture { player.play(song: song) }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                }

                // Full list
                VStack(alignment: .leading, spacing: 8) {
                    Text("All Songs").font(.headline).foregroundColor(.white).padding(.horizontal)
                    ForEach(songs) { song in
                        SongRow(song: song)
                    }
                }

                // Extra bottom space so last items are fully scrollable above mini player/tab bar
                Color.clear.frame(height: 140)
            }
            .padding(.top, 12)
        }
    }
}

// MARK: - Genres and Recently Played Views
struct GenresView: View { var body: some View { Text("Genres").foregroundColor(.white); Spacer() } }

struct RecentlyPlayedView: View {
    @EnvironmentObject var player: MusicPlayer
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Song.dateAdded, ascending: false)],
        animation: .default)
    private var songs: FetchedResults<Song>
    @ObservedObject private var recents = RecentlyPlayedStore.shared

    private var recentlyPlayed: [Song] {
        let map = Dictionary(uniqueKeysWithValues: songs.compactMap { s in (s.id.map { ($0, s) }) })
        return recents.items.compactMap { map[$0] }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Recently Played").font(.title2).bold().foregroundColor(.white).padding(.horizontal)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    ForEach(recentlyPlayed) { song in
                        VStack(alignment: .leading, spacing: 6) {
                            LocalArtworkView(song: song, size: 110)
                            Text(song.title ?? "Unknown").lineLimit(1).font(.caption).foregroundColor(.white)
                            Text(song.artist ?? "Unknown").lineLimit(1).font(.caption2).foregroundColor(.white.opacity(0.7))
                        }
                        .padding(.horizontal, 4)
                        .contentShape(Rectangle())
                        .onTapGesture { player.play(song: song) }
                    }
                }
                .padding(.horizontal)
            }
            .padding(.top, 12)
        }
    }
}

// MARK: - Song Row (simple inline for now)
struct SongRow: View {
    @EnvironmentObject var player: MusicPlayer
    @EnvironmentObject var libraryManager: LibraryManager
    let song: Song

    var body: some View {
        HStack {
            LocalArtworkView(song: song, size: 44)
            VStack(alignment: .leading) {
                Text(song.title ?? "Unknown Title").foregroundColor(.white)
                Text(song.artist ?? "Unknown Artist").font(.caption).foregroundColor(.white.opacity(0.8))
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { player.play(song: song) }
        .padding(.horizontal)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { libraryManager.deleteSong(song) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

// MARK: - Placeholder sections
struct PlaylistsView: View { var body: some View { Text("Playlists").foregroundColor(.white); Spacer() } }
struct ArtistsView: View { var body: some View { Text("Artists").foregroundColor(.white); Spacer() } }
struct AlbumsView: View { var body: some View { Text("Albums").foregroundColor(.white); Spacer() } }
struct DownloadedView: View { var body: some View { Text("Downloaded").foregroundColor(.white); Spacer() } }

// MARK: - RadioView
struct RadioView: View {
    var body: some View {
        NavigationView {
            VStack {
                Text("Radio").font(.largeTitle).foregroundColor(.white)
                Spacer()
            }
            .navigationTitle("Radio")
        }
    }
}

// MARK: - SearchView
enum SearchMode: String, CaseIterable {
    case library = "Your Library"
    case newMusic = "New Music"
}

struct SearchView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject var player: MusicPlayer
    @EnvironmentObject var libraryManager: LibraryManager
    @StateObject private var qobuzAPI = QobuzAPI()

    @State private var query = ""
    @State private var mode: SearchMode = .library
    @FocusState private var searchFocused: Bool
    @State private var filteredLibrary: [Song] = []
    @State private var addedSongs: Set<String> = [] // Track which songs were just added
    @State private var addingSongs: Set<String> = [] // Track which songs are currently being added

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                TextField("Search", text: $query)
                    .padding(10)
                    .background(Color(white: 0.06).opacity(0.08))
                    .cornerRadius(10)
                    .foregroundColor(.white)
                    .padding(.horizontal)
                    .focused($searchFocused)
                    .onChange(of: query) { newValue in
                        if mode == .newMusic, !newValue.isEmpty {
                            qobuzAPI.search(query: newValue)
                        } else {
                            filteredLibrary = libraryManager.searchSongs(query: newValue)
                        }
                    }

                if searchFocused || !query.isEmpty {
                    Picker("", selection: $mode) {
                        ForEach(SearchMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .padding(.horizontal)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.3), value: searchFocused || !query.isEmpty)
                    .onChange(of: mode) { newValue in
                        if newValue == .library {
                            filteredLibrary = libraryManager.searchSongs(query: query)
                        } else if !query.isEmpty {
                            qobuzAPI.search(query: query)
                        }
                    }
                }

                List {
                    if mode == .library {
                        ForEach(filteredLibrary) { song in
                            HStack {
                                LocalArtworkView(song: song, size: 44)
                                VStack(alignment: .leading) {
                                    Text(song.title ?? "Unknown Title").foregroundColor(.white)
                                    Text(song.artist ?? "Unknown Artist").font(.caption).foregroundColor(.white.opacity(0.8))
                                    
                                    // Show status for downloading, queued, or failed
                                    if song.downloadStatus == DownloadStatus.downloading.rawValue {
                                        Text("Downloading...")
                                            .font(.caption2)
                                            .foregroundColor(.blue)
                                    } else if song.downloadStatus == DownloadStatus.queued.rawValue {
                                        Text("Queued...")
                                            .font(.caption2)
                                            .foregroundColor(.orange)
                                    } else if song.downloadStatus == DownloadStatus.failed.rawValue {
                                        Text("Failed")
                                            .font(.caption2)
                                            .foregroundColor(.red)
                                    }
                                    // Downloaded songs show nothing
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { player.play(song: song) }
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { libraryManager.deleteSong(song) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    } else {
                        ForEach(qobuzAPI.results, id: \.id) { track in
                            HStack {
                                if let art = track.image, let url = URL(string: art) {
                                    AsyncImage(url: url) { phase in
                                        if let image = phase.image {
                                            image.resizable()
                                        } else if phase.error != nil {
                                            Image(systemName: "exclamationmark.triangle")
                                                .resizable()
                                                .foregroundColor(.gray)
                                        } else {
                                            Image(systemName: "music.note")
                                                .resizable()
                                                .foregroundColor(.gray)
                                        }
                                    }
                                    .frame(width: 44, height: 44)
                                    .cornerRadius(4)
                                }

                                VStack(alignment: .leading) {
                                    Text(track.title).foregroundColor(.white)
                                    Text(track.artist).font(.caption).foregroundColor(.white.opacity(0.8))
                                    if let album = track.album {
                                        Text(album).font(.caption2).foregroundColor(.white.opacity(0.6))
                                    }
                                }
                                Spacer()
                                
                                let songKey = "\(track.title)-\(track.artist)"
                                let isInLibrary = libraryManager.isSongInLibrary(title: track.title, artist: track.artist)
                                let wasJustAdded = addedSongs.contains(songKey)
                                let isAdding = addingSongs.contains(songKey)
                                
                                // Add to library button (which now downloads automatically)
                                Button(action: {
                                    if !isInLibrary && !isAdding {
                                        addingSongs.insert(songKey)
                                        
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                            let success = libraryManager.addSong(from: track)
                                            addingSongs.remove(songKey)
                                            
                                            if success {
                                                addedSongs.insert(songKey)
                                                // Remove from added songs after 2 seconds
                                                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                                    addedSongs.remove(songKey)
                                                }
                                            }
                                        }
                                    }
                                }) {
                                    Image(systemName: isInLibrary || wasJustAdded ? "checkmark" : "plus")
                                        .foregroundColor(isInLibrary || wasJustAdded ? .red : .white)
                                        .font(.system(size: 18, weight: .bold))
                                }
                                .disabled(isInLibrary || isAdding)
                                .buttonStyle(PlainButtonStyle())
                                .scaleEffect(isAdding ? 1.2 : 1.0)
                                .animation(.easeInOut(duration: 0.2), value: isAdding)
                            }
                            .listRowBackground(Color.clear)
                            .contentShape(Rectangle()) // Make the row tappable
                            .onTapGesture {
                                // Prefer local if exists; else stream immediately
                                if let localSong = libraryManager.findSongMatching(track: track),
                                   let _ = DownloadManager.shared.getLocalFileURL(for: localSong) {
                                    player.play(song: localSong)
                                } else {
                                    // Show UI immediately with temp metadata
                                    let temp = TempSong(from: track)
                                    player.play(tempSong: temp) // sets UI state
                                    // Resolve full stream URL via existing flow and play
                                    DownloadManager.shared.resolveStreamURLForQobuz(trackId: track.id) { result in
                                        DispatchQueue.main.async {
                                            switch result {
                                            case .success(let url):
                                                let updated = TempSong(id: temp.id, title: temp.title, artist: temp.artist, artwork: temp.artwork, album: temp.album, url: url.absoluteString)
                                                AudioPlayer.shared.play(tempSong: updated)
                                            case .failure(let error):
                                                print("Failed to resolve stream URL: \(error)")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Search")
            .onAppear {
                filteredLibrary = libraryManager.searchSongs(query: query)
            }
        }
    }
}
