import SwiftUI
import UIKit
import CoreData
import AVFoundation

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
    let id = UUID()
    let title: String
    let artist: String
    let artwork: String?
    let album: String?
    let url: String?
    
    init(from track: QobuzTrack) {
        self.title = track.title
        self.artist = track.artist
        self.artwork = track.image
        self.album = track.album
        self.url = track.url
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

    func play(song: Song) {
        currentSong = song
        AudioPlayer.shared.play(song: song)
        isPlaying = true
    }
    
    func playFromQobuz(track: QobuzTrack) {
        // Create a temporary Song object for playing
        let tempSong = TempSong(from: track)
        currentSong = tempSong
        
        // For Qobuz tracks, we'll stream them directly
        if let urlString = track.url, let url = URL(string: urlString) {
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.play()
                isPlaying = true
            } catch {
                print("Error playing Qobuz track: \(error)")
            }
        }
    }
    
    func togglePlayPause() {
        if isPlaying {
            AudioPlayer.shared.pause()
            isPlaying = false
        } else {
            AudioPlayer.shared.resume()
            isPlaying = true
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
        
        if songExists {
            return false
        }
        
        let song = Song(context: viewContext)
        song.id = UUID()
        song.title = title
        song.artist = artist
        song.artwork = artwork
        song.album = album
        song.url = url
        song.qobuzTrackId = Int64(qobuzTrackId ?? 0)
        song.dateAdded = Date()
        song.downloadStatus = DownloadStatus.notDownloaded.rawValue
        
        do {
            try viewContext.save()
            
            // If it's a Qobuz track, start the download process
            if let trackId = qobuzTrackId {
                DownloadManager.shared.downloadSongFromQobuz(song, trackId: trackId, context: viewContext)
            }
            
            return true
        } catch {
            print("Error saving song: \(error)")
            return false
        }
    }
    
    func deleteSong(_ song: Song) {
        // Delete the downloaded file if it exists
        DownloadManager.shared.deleteDownloadedFile(for: song)
        
        viewContext.delete(song)
        try? viewContext.save()
    }
    
    private func getAllSongs() -> [Song] {
        let request: NSFetchRequest<Song> = Song.fetchRequest()
        do {
            return try viewContext.fetch(request)
        } catch {
            print("Error fetching songs: \(error)")
            return []
        }
    }
    
    func searchSongs(query: String) -> [Song] {
        let request: NSFetchRequest<Song> = Song.fetchRequest()
        request.predicate = NSPredicate(format: "title CONTAINS[cd] %@ OR artist CONTAINS[cd] %@ OR album CONTAINS[cd] %@", query, query, query)
        do {
            return try viewContext.fetch(request)
        } catch {
            print("Error searching songs: \(error)")
            return []
        }
    }
}

// MARK: - Qobuz API
class QobuzAPI: ObservableObject {
    @Published var tracks: [QobuzTrack] = []
    @Published var isLoading = false
    
    func search(query: String) {
        isLoading = true
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let url = URL(string: "https://us.doubledouble.top/search?q=\(encodedQuery)")!
        
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isLoading = false
                if let data = data {
                    do {
                        let response = try JSONDecoder().decode(QobuzResponse.self, from: data)
                        self?.tracks = response.tracks ?? []
                    } catch {
                        print("Error decoding Qobuz response: \(error)")
                        self?.tracks = []
                    }
                }
            }
        }.resume()
    }
}

// MARK: - Main ContentView
struct ContentView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @StateObject private var player = MusicPlayer()
    @StateObject private var libraryManager: LibraryManager
    @StateObject private var persistenceController = PersistenceController.shared
    
    init() {
        let persistenceController = PersistenceController.shared
        _libraryManager = StateObject(wrappedValue: LibraryManager(context: persistenceController.container.viewContext, persistenceController: persistenceController))
    }
    
    var body: some View {
        TabView {
            LibraryView()
                .tabItem {
                    Image(systemName: "music.note")
                    Text("Library")
                }
                .environmentObject(player)
                .environmentObject(libraryManager)
            
            RadioView()
                .tabItem {
                    Image(systemName: "radio")
                    Text("Radio")
                }
            
            SearchView()
                .tabItem {
                    Image(systemName: "magnifyingglass")
                    Text("Search")
                }
                .environmentObject(player)
                .environmentObject(libraryManager)
        }
        .accentColor(Color(red: 1.0, green: 45/255, blue: 85/255))
        .background(Color.black.ignoresSafeArea())
    }
}

// MARK: - NowPlayingView
struct NowPlayingView: View {
    @EnvironmentObject var player: MusicPlayer

    var body: some View {
        VStack {
            Spacer()
            
            if let song = player.currentSong as? Song {
                // Core Data Song - display FLAC metadata
                SongArtworkView(song: song)
                    .frame(width: 260, height: 260)
                    .cornerRadius(12)
                    .padding(.vertical, 24)

                Text(song.title ?? "Unknown Title")
                    .font(.title).fontWeight(.semibold).foregroundColor(.white)
                Text(song.artist ?? "Unknown Artist")
                    .font(.subheadline).foregroundColor(.white.opacity(0.85))
                if let album = song.album, !album.isEmpty {
                    Text(album)
                        .font(.caption).foregroundColor(.white.opacity(0.7))
                }
            } else if let tempSong = player.currentSong as? TempSong {
                // Temporary Song from Qobuz
                if let art = tempSong.artwork, let url = URL(string: art) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFit()
                        } else if phase.error != nil {
                            Image(systemName: "exclamationmark.triangle")
                                .resizable()
                                .scaledToFit()
                                .foregroundColor(.gray)
                        } else {
                            Image(systemName: "music.note")
                                .resizable()
                                .scaledToFit()
                                .foregroundColor(.gray)
                        }
                    }
                    .frame(width: 260, height: 260)
                    .cornerRadius(12).padding(.vertical, 24)
                } else {
                    Image(systemName: "music.note")
                        .resizable()
                        .scaledToFit()
                        .foregroundColor(.gray)
                        .frame(width: 260, height: 260)
                        .cornerRadius(12).padding(.vertical, 24)
                }

                Text(tempSong.title)
                    .font(.title).fontWeight(.semibold).foregroundColor(.white)
                Text(tempSong.artist)
                    .font(.subheadline).foregroundColor(.white.opacity(0.85))
                if let album = tempSong.album, !album.isEmpty {
                    Text(album)
                        .font(.caption).foregroundColor(.white.opacity(0.7))
                }
            }

            Spacer()
            Button(action: { player.togglePlayPause() }) {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 72))
                    .foregroundColor(Color(red: 1.0, green: 45/255, blue: 85/255))
            }
            Spacer()
        }
        .padding().background(Color.black.ignoresSafeArea())
    }
}

// MARK: - Song Artwork View
struct SongArtworkView: View {
    let song: Song
    
    var body: some View {
        Group {
            if let artworkPath = song.artwork, 
               FileManager.default.fileExists(atPath: artworkPath),
               let imageData = FLACMetadataExtractor.getArtworkImage(for: song),
               let uiImage = UIImage(data: imageData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "music.note")
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(.gray)
            }
        }
    }
}

// MARK: - LibraryView
struct LibraryView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject var player: MusicPlayer
    @EnvironmentObject var libraryManager: LibraryManager
    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \Song.dateAdded, ascending: false)],
        animation: .default)
    private var songs: FetchedResults<Song>

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Songs").foregroundColor(.white)) {
                    ForEach(songs) { song in
                        HStack {
                            SongArtworkView(song: song)
                                .frame(width: 44, height: 44)
                                .cornerRadius(5)
                            
                            VStack(alignment: .leading) {
                                Text(song.title ?? "Unknown Title").foregroundColor(.white)
                                Text(song.artist ?? "Unknown Artist").font(.caption).foregroundColor(.white.opacity(0.8))
                                if let album = song.album, !album.isEmpty {
                                    Text(album).font(.caption2).foregroundColor(.white.opacity(0.6))
                                }
                                
                                // Show status for downloading, queued, or failed
                                if song.downloadStatus == DownloadStatus.downloading.rawValue {
                                    HStack {
                                        Image(systemName: "arrow.down.circle.fill")
                                            .foregroundColor(.blue)
                                            .font(.caption)
                                        Text("Downloading...")
                                            .font(.caption2)
                                            .foregroundColor(.blue)
                                    }
                                } else if song.downloadStatus == DownloadStatus.queued.rawValue {
                                    HStack {
                                        Image(systemName: "clock.circle.fill")
                                            .foregroundColor(.orange)
                                            .font(.caption)
                                        Text("Queued...")
                                            .font(.caption2)
                                            .foregroundColor(.orange)
                                    }
                                } else if song.downloadStatus == DownloadStatus.failed.rawValue {
                                    HStack {
                                        Image(systemName: "exclamationmark.circle.fill")
                                            .foregroundColor(.red)
                                            .font(.caption)
                                        Text("Failed")
                                            .font(.caption2)
                                            .foregroundColor(.red)
                                    }
                                }
                                // Downloaded songs show nothing
                            }
                            Spacer()
                            
                            // Play button
                            Button(action: { player.play(song: song) }) {
                                Image(systemName: "play.fill").foregroundColor(.white)
                            }
                        }
                        .listRowBackground(Color.clear)
                    }
                    .onDelete(perform: deleteSongs)
                }
            }
            .navigationTitle("Library")
        }
    }
    
    private func deleteSongs(offsets: IndexSet) {
        withAnimation {
            offsets.map { songs[$0] }.forEach(libraryManager.deleteSong)
        }
    }
}

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
                }

                if searchFocused || !query.isEmpty {
                    if mode == .library {
                        List {
                            ForEach(filteredLibrary) { song in
                                HStack {
                                    SongArtworkView(song: song)
                                        .frame(width: 44, height: 44)
                                        .cornerRadius(5)
                                    
                                    VStack(alignment: .leading) {
                                        Text(song.title ?? "Unknown Title").foregroundColor(.white)
                                        Text(song.artist ?? "Unknown Artist").font(.caption).foregroundColor(.white.opacity(0.8))
                                        if let album = song.album, !album.isEmpty {
                                            Text(album).font(.caption2).foregroundColor(.white.opacity(0.6))
                                        }
                                    }
                                    Spacer()
                                    Button(action: { player.play(song: song) }) {
                                        Image(systemName: "play.fill").foregroundColor(.white)
                                    }
                                }
                                .listRowBackground(Color.clear)
                            }
                        }
                    } else {
                        if qobuzAPI.isLoading {
                            ProgressView("Searching...")
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            List {
                                ForEach(qobuzAPI.tracks) { track in
                                    HStack {
                                        if let imageUrl = track.image, let url = URL(string: imageUrl) {
                                            AsyncImage(url: url) { phase in
                                                if let image = phase.image {
                                                    image.resizable().scaledToFit()
                                                } else if phase.error != nil {
                                                    Image(systemName: "music.note")
                                                        .resizable()
                                                        .scaledToFit()
                                                        .foregroundColor(.gray)
                                                } else {
                                                    Image(systemName: "music.note")
                                                        .resizable()
                                                        .scaledToFit()
                                                        .foregroundColor(.gray)
                                                }
                                            }
                                            .frame(width: 44, height: 44)
                                            .cornerRadius(5)
                                        } else {
                                            Image(systemName: "music.note")
                                                .resizable()
                                                .scaledToFit()
                                                .foregroundColor(.gray)
                                                .frame(width: 44, height: 44)
                                                .cornerRadius(5)
                                        }
                                        
                                        VStack(alignment: .leading) {
                                            Text(track.title).foregroundColor(.white)
                                            Text(track.artist).font(.caption).foregroundColor(.white.opacity(0.8))
                                            if let album = track.album {
                                                Text(album).font(.caption2).foregroundColor(.white.opacity(0.6))
                                            }
                                        }
                                        
                                        Spacer()
                                        
                                        HStack(spacing: 12) {
                                            // Play button
                                            Button(action: { 
                                                player.playFromQobuz(track: track)
                                            }) {
                                                Image(systemName: "play.fill")
                                                    .foregroundColor(.white)
                                            }
                                            .buttonStyle(PlainButtonStyle())
                                            
                                            // Add to library button
                                            Button(action: {
                                                let songKey = "\(track.id)"
                                                addingSongs.insert(songKey)
                                                
                                                let success = libraryManager.addSong(
                                                    title: track.title,
                                                    artist: track.artist,
                                                    artwork: track.image,
                                                    album: track.album,
                                                    url: track.url,
                                                    qobuzTrackId: track.id
                                                )
                                                
                                                if success {
                                                    addedSongs.insert(songKey)
                                                }
                                                
                                                addingSongs.remove(songKey)
                                            }) {
                                                let songKey = "\(track.id)"
                                                if addingSongs.contains(songKey) {
                                                    ProgressView()
                                                        .scaleEffect(0.8)
                                                } else if addedSongs.contains(songKey) {
                                                    Image(systemName: "checkmark")
                                                        .foregroundColor(.red)
                                                        .scaleEffect(1.2)
                                                        .animation(.easeInOut(duration: 0.2), value: addedSongs.contains(songKey))
                                                } else {
                                                    Image(systemName: "plus")
                                                        .foregroundColor(.white)
                                                }
                                            }
                                            .buttonStyle(PlainButtonStyle())
                                        }
                                    }
                                    .listRowBackground(Color.clear)
                                }
                            }
                        }
                    }
                } else {
                    Spacer()
                }
            }
            .navigationTitle("Search")
        }
    }
}
