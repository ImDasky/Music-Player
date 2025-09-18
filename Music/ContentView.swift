import SwiftUI
import UIKit
import CoreData

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
        isPlaying = true
    }
    
    func playFromQobuz(track: QobuzTrack) {
        // Create a temporary Song object for playing (not saved to Core Data)
        let tempSong = TempSong(from: track)
        currentSong = tempSong
        isPlaying = true
    }
    
    func togglePlayPause() {
        isPlaying.toggle()
    }
}

final class LibraryManager: ObservableObject {
    private let viewContext: NSManagedObjectContext
    private let persistenceController: PersistenceController
    
    init(context: NSManagedObjectContext, persistenceController: PersistenceController) {
        self.viewContext = context
        self.persistenceController = persistenceController
    }
    
    func addSong(title: String, artist: String, artwork: String? = nil, album: String? = nil, url: String? = nil) -> Bool {
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
            song.dateAdded = Date()
            persistenceController.save()
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
            url: qobuzTrack.url
        )
    }
    
    func deleteSong(_ song: Song) {
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
    
    private let miniPlayerBottomPadding: CGFloat = 48

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

    private let blurStyle: UIBlurEffect.Style = .systemChromeMaterialDark

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 0.5)

            HStack(spacing: 12) {
                if let song = player.currentSong as? Song {
                    // Core Data Song
                    if let art = song.artwork, let url = URL(string: art) {
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
                        Image(systemName: song.artwork ?? "music.note")
                            .resizable()
                            .frame(width: 44, height: 44)
                            .cornerRadius(4)
                    }
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
                    Button(action: { player.togglePlayPause() }) {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .foregroundColor(.white)
                    }
                    Button(action: {}) {
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

    var body: some View {
        VStack {
            Spacer()
            
            if let song = player.currentSong as? Song {
                // Core Data Song
                if let art = song.artwork, let url = URL(string: art) {
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
                }

                Text(song.title ?? "Unknown Title")
                    .font(.title).fontWeight(.semibold).foregroundColor(.white)
                Text(song.artist ?? "Unknown Artist")
                    .font(.subheadline).foregroundColor(.white.opacity(0.85))
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
                }

                Text(tempSong.title)
                    .font(.title).fontWeight(.semibold).foregroundColor(.white)
                Text(tempSong.artist)
                    .font(.subheadline).foregroundColor(.white.opacity(0.85))
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
                            Image(systemName: song.artwork ?? "music.note")
                                .resizable().frame(width: 44, height: 44).cornerRadius(5)
                            VStack(alignment: .leading) {
                                Text(song.title ?? "Unknown Title").foregroundColor(.white)
                                Text(song.artist ?? "Unknown Artist").font(.caption).foregroundColor(.white.opacity(0.8))
                            }
                            Spacer()
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
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.3), value: searchFocused || !query.isEmpty)
                    .onChange(of: mode) { _ in
                        if mode == .library {
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
                                Image(systemName: song.artwork ?? "music.note")
                                    .resizable().frame(width: 44, height: 44).cornerRadius(5)
                                VStack(alignment: .leading) {
                                    Text(song.title ?? "Unknown Title").foregroundColor(.white)
                                    Text(song.artist ?? "Unknown Artist").font(.caption).foregroundColor(.white.opacity(0.8))
                                }
                                Spacer()
                                Button(action: { player.play(song: song) }) {
                                    Image(systemName: "play.fill").foregroundColor(.white)
                                }
                            }
                            .listRowBackground(Color.clear)
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
                                
                                // Simple plus button - back to clean styling
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
                                // Play the song when tapping anywhere on the row (doesn't add to library)
                                player.playFromQobuz(track: track)
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
