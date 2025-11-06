import SwiftUI
import UIKit
import CoreData
import AVFoundation
import MediaPlayer
import Combine
import CommonCrypto

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

// MARK: - Qobuz Search Response Models
struct QobuzAlbumSearchResponse: Decodable {
    let query: String?
    let albums: QobuzAlbumSearchData?
}

struct QobuzAlbumSearchData: Decodable {
    let offset: Int?
    let items: [QobuzAlbumSearchItem]?
}

struct QobuzAlbumSearchItem: Decodable {
    let id: String
    let title: String
    let artist: QobuzAlbumSearchArtist?
    let artists: [QobuzAlbumSearchArtist]?
    let image: QobuzSearchImage?
}

struct QobuzAlbumSearchArtist: Decodable {
    let id: Int?
    let name: String?
}

struct QobuzTrackSearchResponse: Decodable {
    let query: String?
    let tracks: QobuzTrackSearchData?
}

struct QobuzTrackSearchData: Decodable {
    let offset: Int?
    let items: [QobuzTrackSearchItem]?
}

struct QobuzTrackSearchItem: Decodable {
    let id: Int
    let title: String
    let performer: QobuzTrackPerformer?
    let album: QobuzTrackAlbum?
}

struct QobuzTrackPerformer: Decodable {
    let name: String?
}

struct QobuzTrackAlbum: Decodable {
    let title: String?
    let image: QobuzSearchImage?
}

struct QobuzArtistSearchResponse: Decodable {
    let query: String?
    let artists: QobuzArtistSearchData?
}

struct QobuzArtistSearchData: Decodable {
    let offset: Int?
    let items: [QobuzArtistSearchItem]?
}

struct QobuzArtistSearchItem: Decodable {
    let id: Int
    let name: String
    let image: QobuzSearchImage?
}

struct QobuzSearchImage: Decodable {
    let small: String?
    let thumbnail: String?
    let large: String?
}

struct QobuzTrack: Decodable {
    let id: Int
    let title: String
    let artist: String
    let album: String?
    let image: String?
    let url: String?
}

struct QobuzAlbum: Identifiable {
    let id: String
    let title: String
    let artist: String
    let image: String?
}

struct QobuzArtist: Identifiable {
    let id: Int
    let name: String
    let image: String?
}


// MARK: - Authentication Models
struct LoginResponse: Codable {
    let oauth2: OAuth2Response?
    let user: UserInfo?
}

struct OAuth2Response: Codable {
    let accessToken: String
    let refreshToken: String?
    let tokenType: String?
    let expiresIn: Int?
    
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
    }
}

struct UserInfo: Codable {
    let id: Int?
    let email: String?
    let login: String?
    let displayName: String?
    
    enum CodingKeys: String, CodingKey {
        case id, email, login
        case displayName = "display_name"
    }
}

// MARK: - New API Models for Artist/Album Details
struct ArtistPageResponse: Codable {
    let id: Int
    let name: LocalizedName
    let artistCategory: String?
    let biography: Biography?
    let images: ArtistImages?
    let releases: [ReleaseBucket]?
    let topTracks: [TopTrack]?
    
    enum CodingKeys: String, CodingKey {
        case id, name, biography, images, releases
        case artistCategory = "artist_category"
        case topTracks = "top_tracks"
    }
}

struct TopTrack: Codable {
    let id: Int
    let title: String
    let duration: Int?
    let album: AlbumRef?
}

struct AlbumRef: Codable {
    let id: String
    let title: String?
    let image: AlbumImages?
}

struct ArtistResponse: Codable { let success: Bool; let data: ArtistData? }
struct ArtistData: Codable { let artist: Artist; let releases: [ReleaseBucket]? }

struct Artist: Codable {
    let id: Int
    let name: LocalizedName
    let artistCategory: String?
    let biography: Biography?
    let images: ArtistImages?
    let releases: [ReleaseBucket]?
    enum CodingKeys: String, CodingKey { case id, name, biography, images, releases; case artistCategory = "artist_category" }
}

struct LocalizedName: Codable {
    let display: String
    init(display: String) { self.display = display }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self.display = s; return }
        struct Obj: Codable { let display: String }
        self.display = try c.decode(Obj.self).display
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(["display": display])
    }
}

struct Biography: Codable { let content: String? }
struct ArtistImages: Codable { let portrait: ImageDescriptor? }
struct ImageDescriptor: Codable { let hash: String?; let format: String? }

struct ReleaseBucket: Codable {
    let type: String
    let hasMore: Bool?
    let items: [ReleaseItem]?
    enum CodingKeys: String, CodingKey { case type, items; case hasMore = "has_more" }
}

struct ReleaseItem: Codable, Identifiable {
    let id: String
    let title: String
    let version: String?
    let tracksCount: Int?
    let image: AlbumImages?
    let label: LabelRef?
    let dates: ReleaseDates?
    let parentalWarning: Bool?
    let releaseType: String?
    enum CodingKeys: String, CodingKey {
        case id, title, version, image, label, dates
        case tracksCount = "tracks_count"
        case parentalWarning = "parental_warning"
        case releaseType = "release_type"
    }
}

struct AlbumImages: Codable { let small: String?; let thumbnail: String?; let large: String? }
struct LabelRef: Codable { let id: Int?; let name: String? }
struct ReleaseDates: Codable { let download: String?; let original: String?; let stream: String? }

struct DisplayAlbum: Identifiable, Hashable {
    let id: String
    let title: String
    let imageURL: URL?
    let label: String
    let releaseDate: Date?
    let tracksCount: Int?
    let isExplicit: Bool
}

// MARK: - Qobuz Album Get Response
struct QobuzAlbumGetResponse: Codable {
    let id: String?
    let title: String?
    let artist: QobuzAlbumGetArtist?
    let releaseDateDownload: String?
    let releaseDateOriginal: String?
    let genre: QobuzAlbumGenre?
    let tracks: QobuzAlbumTracks?
    
    enum CodingKeys: String, CodingKey {
        case id, title, artist, tracks, genre
        case releaseDateDownload = "release_date_download"
        case releaseDateOriginal = "release_date_original"
    }
}

struct QobuzAlbumGenre: Codable {
    let id: Int?
    let name: String?
    let slug: String?
}

struct QobuzAlbumGetArtist: Codable {
    let id: Int?
    let name: String?
}

struct QobuzAlbumTracks: Codable {
    let offset: Int?
    let limit: Int?
    let total: Int?
    let items: [QobuzAlbumTrackItem]?
}

struct QobuzAlbumTrackItem: Codable {
    let id: Int?
    let title: String?
    let duration: Int?
    let position: Int?
    let isrc: String?
    let parentalWarning: Bool?
    
    enum CodingKeys: String, CodingKey {
        case id, title, duration, position, isrc
        case parentalWarning = "parental_warning"
    }
}

struct AlbumResponse: Codable { let success: Bool; let data: AlbumData? }
struct AlbumData: Codable {
    let id: String?
    let artist: SimpleArtist?
    let releaseDateDownload: String?
    let trackIDs: [Int]?
    let tracks: TracksPage
    enum CodingKeys: String, CodingKey {
        case id, artist, tracks
        case trackIDs = "track_ids"
        case releaseDateDownload = "release_date_download"
    }
    
    init(id: String?, artist: SimpleArtist?, releaseDateDownload: String?, trackIDs: [Int]?, tracks: TracksPage) {
        self.id = id
        self.artist = artist
        self.releaseDateDownload = releaseDateDownload
        self.trackIDs = trackIDs
        self.tracks = tracks
    }
}

struct SimpleArtist: Codable { let id: Int?; let name: String? }
struct TracksPage: Codable { let offset: Int?; let items: [TrackItem]? }

struct TrackItem: Codable {
    let id: Int?
    let isrc: String?
    let title: String?
    let duration: Int?
    let trackNumber: Int?
    let parentalWarning: Bool?
    enum CodingKeys: String, CodingKey {
        case id, isrc, title, duration
        case trackNumber = "track_number"
        case parentalWarning = "parental_warning"
    }
    
    init(id: Int?, isrc: String?, title: String?, duration: Int?, trackNumber: Int?, parentalWarning: Bool?) {
        self.id = id
        self.isrc = isrc
        self.title = title
        self.duration = duration
        self.trackNumber = trackNumber
        self.parentalWarning = parentalWarning
    }
}

struct TrackRow: Identifiable, Hashable {
    let id: String
    let trackNumber: Int?
    let title: String
    let duration: Int?
    let isrc: String?
    let explicit: Bool
    let qobuzTrackId: Int?

    var durationString: String {
        let secs = duration ?? 0
        let m = secs / 60, s = secs % 60
        return "\(m):" + String(format: "%02d", s)
    }
}

enum APIError: LocalizedError {
    case invalidURL, badStatus(Int), decodingFailed, emptyData, unknown, authenticationRequired, authenticationFailed
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "The API URL is invalid."
        case .badStatus(let code): return "Server returned status \(code)."
        case .decodingFailed: return "Failed to decode server response."
        case .emptyData: return "No data found."
        case .unknown: return "Something went wrong."
        case .authenticationRequired: return "Please log in to continue."
        case .authenticationFailed: return "Login failed. Please check your credentials."
        }
    }
}

extension DateFormatter {
    static let yyyyMMdd: DateFormatter = {
        let df = DateFormatter()
        df.calendar = Calendar(identifier: .gregorian)
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return df
    }()
}// MARK: - Circular Progress View
struct CircularProgressView: View {
    let progress: Double   // 0.0 ... 1.0
    let size: CGFloat
    let lineWidth: CGFloat
    
    private var clamped: Double { max(0.0, min(1.0, progress)) }
    private var percentText: String { "\(Int(clamped * 100))%" }
    
    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(Color.white, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(percentText)
                .font(.system(size: max(10, size * 0.28), weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Player + Library managers
final class MusicPlayer: ObservableObject {
    @Published var currentSong: Any? = nil // Can be Song or TempSong
    @Published var isPlaying: Bool = false
    @Published var queue: [Song] = [] // Play order (used by UI / Up Next)
    private var baseQueue: [Song] = [] // Original order (recently added desc)
    @Published var currentIndex: Int? = nil
    @Published var isShuffling: Bool = false
    @Published var repeatMode: RepeatMode = .off

    enum RepeatMode { case off, one, all }

    init() {
        NotificationCenter.default.addObserver(self, selector: #selector(onPlaybackFinished(_:)), name: .audioPlayerDidFinish, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onRemoteNext(_:)), name: .remoteCommandNext, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(onRemotePrevious(_:)), name: .remoteCommandPrevious, object: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func rebuildPlayQueue(preserving current: Song?) {
        // Build play queue from base according to shuffle state
        if isShuffling {
            let shuffled = baseQueue.shuffled()
            // Ensure current stays in queue
            if let current, let idx = shuffled.firstIndex(of: current) {
                // Keep as-is, we'll set currentIndex below
                queue = shuffled
                currentIndex = idx
            } else {
                queue = shuffled
                currentIndex = nil
            }
        } else {
            queue = baseQueue
            if let current, let idx = baseQueue.firstIndex(of: current) {
                currentIndex = idx
            } else {
                currentIndex = nil
            }
        }
    }
    
    // MARK: - Queue management helpers
    var upcoming: [Song] {
        guard let idx = currentIndex, idx + 1 < queue.count else { return [] }
        return Array(queue.suffix(from: idx + 1))
    }

    func removeUpcoming(at offsets: IndexSet) {
        guard let idx = currentIndex else { return }
        let absolute = offsets.map { $0 + idx + 1 }.sorted(by: >)
        for i in absolute {
            if i < queue.count { queue.remove(at: i) }
        }
    }

    func moveUpcoming(from source: IndexSet, to destination: Int) {
        guard let idx = currentIndex else { return }
        let absDest = destination + idx + 1
        let sortedSources = source.sorted()
        var elements: [Song] = []
        for s in sortedSources {
            let abs = s + idx + 1
            if abs < queue.count { elements.append(queue[abs]) }
        }
        // Remove from highest to lowest absolute index to keep indices valid
        for abs in sortedSources.map({ $0 + idx + 1 }).sorted(by: >) {
            if abs < queue.count { queue.remove(at: abs) }
        }
        var insertAt = min(absDest, queue.count)
        for el in elements {
            if insertAt > queue.count { insertAt = queue.count }
            queue.insert(el, at: insertAt)
            insertAt += 1
        }
    }

    func clearUpcoming() {
        guard let idx = currentIndex, idx + 1 <= queue.count else { return }
        queue.removeSubrange((idx + 1)..<queue.count)
    }

    func enqueueNext(_ song: Song) {
        if let existing = queue.firstIndex(of: song) {
            // Adjust current index if needed when removing
            if let idx = currentIndex, existing <= idx { currentIndex = max(0, idx - 1) }
            queue.remove(at: existing)
        }
        if let idx = currentIndex {
            let insertIdx = min(idx + 1, queue.count)
            queue.insert(song, at: insertIdx)
        } else {
            queue.append(song)
        }
    }

    func enqueueLast(_ song: Song) {
        if let existing = queue.firstIndex(of: song) {
            if let idx = currentIndex, existing <= idx { currentIndex = max(0, idx - 1) }
            queue.remove(at: existing)
        }
        queue.append(song)
    }

    // MARK: - Play a custom list (e.g., playlist)
    func playPlaylist(songs: [Song], shuffle: Bool) {
        guard !songs.isEmpty else { return }
        isShuffling = shuffle
        baseQueue = songs
        // Build queue according to shuffle preference
        rebuildPlayQueue(preserving: nil)
        // Start from first item in the resulting queue
        currentIndex = 0
        let start = queue[0]
        currentSong = start
        AudioPlayer.shared.play(song: start)
    }

    @objc private func onPlaybackFinished(_ notification: Notification) {
        // Advance according to repeat mode and queue context
        if let _ = currentSong as? Song {
            // Library song with queue context
            if repeatMode == .one {
                AudioPlayer.shared.seek(to: 0)
                AudioPlayer.shared.resume()
                return
            }
            skipNext()
        } else {
            // Temp stream finished: clear playing flag only
            // Optionally could auto-advance if we had a radio queue
        }
    }

    @objc private func onRemoteNext(_ notification: Notification) {
        skipNext()
    }
    
    @objc private func onRemotePrevious(_ notification: Notification) {
        skipPrevious(currentTime: AudioPlayer.shared.currentTime)
    }

    func toggleShuffle() {
        // Preserve currently playing library song if any
        let currentLibrarySong = currentSong as? Song
        isShuffling.toggle()
        rebuildPlayQueue(preserving: currentLibrarySong)
    }

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
            baseQueue = all
            rebuildPlayQueue(preserving: song)
        } else {
            // Ensure index aligns with current play queue
            if let idx = queue.firstIndex(of: song) { currentIndex = idx }
        }
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
        guard !queue.isEmpty else { return }
        if repeatMode == .one {
            AudioPlayer.shared.seek(to: 0)
            AudioPlayer.shared.resume()
            return
        }
        if let idx = currentIndex {
            if isShuffling {
                // pick a random different index
                if queue.count == 1 {
                    play(song: queue[0]); currentIndex = 0; return
                }
                var newIndex = idx
                while newIndex == idx { newIndex = Int.random(in: 0..<queue.count) }
                currentIndex = newIndex
                play(song: queue[newIndex])
            } else {
                let nextIndex = idx + 1
                if nextIndex < queue.count {
                    currentIndex = nextIndex
                    play(song: queue[nextIndex])
                } else if repeatMode == .all {
                    currentIndex = 0
                    play(song: queue[0])
                }
            }
        }
    }
    
    func skipPrevious(currentTime: TimeInterval) {
        if repeatMode == .one {
            AudioPlayer.shared.seek(to: 0)
            AudioPlayer.shared.resume()
            return
        }
        if currentTime > 3 { AudioPlayer.shared.seek(to: 0); return }
        guard !queue.isEmpty else { AudioPlayer.shared.seek(to: 0); return }
        guard let idx = currentIndex else { AudioPlayer.shared.seek(to: 0); return }
        if isShuffling {
            if queue.count == 1 { play(song: queue[0]); currentIndex = 0; return }
            var newIndex = idx
            while newIndex == idx { newIndex = Int.random(in: 0..<queue.count) }
            currentIndex = newIndex
            play(song: queue[newIndex])
        } else if idx - 1 >= 0 {
            let prev = queue[idx - 1]
            currentIndex = idx - 1
            play(song: prev)
        } else if repeatMode == .all {
            let lastIndex = max(queue.count - 1, 0)
            currentIndex = lastIndex
            play(song: queue[lastIndex])
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

// MARK: - Search Content Type
enum SearchContentType: String, CaseIterable {
    case track = "Track"
    case artist = "Artist"
    case album = "Album"
}

// MARK: - Qobuz API Client
final class QobuzAPI: ObservableObject {
    @Published var results: [QobuzTrack] = []
    @Published var errorMessage: String? = nil
    @Published var albums: [QobuzAlbum] = []
    @Published var artists: [QobuzArtist] = []
    
    // Bearer token management
    private let appId = "650769754"
    private let appSecret = "4e7670746604f63d161aab2d9ff02d6f" // From bearer.py
    private let tokenKey = "qobuz_bearer_token"
    private let refreshTokenKey = "qobuz_refresh_token"
    private let tokenExpiryKey = "qobuz_token_expiry"
    
    private var bearerToken: String? {
        get { UserDefaults.standard.string(forKey: tokenKey) }
        set { UserDefaults.standard.set(newValue, forKey: tokenKey) }
    }
    
    // Public accessor for bearer token
    var currentBearerToken: String? {
        return bearerToken
    }
    
    private var refreshToken: String? {
        get { UserDefaults.standard.string(forKey: refreshTokenKey) }
        set { UserDefaults.standard.set(newValue, forKey: refreshTokenKey) }
    }
    
    private var tokenExpiry: Date? {
        get {
            guard let timeInterval = UserDefaults.standard.object(forKey: tokenExpiryKey) as? TimeInterval else { return nil }
            return Date(timeIntervalSince1970: timeInterval)
        }
        set {
            if let date = newValue {
                UserDefaults.standard.set(date.timeIntervalSince1970, forKey: tokenExpiryKey)
            } else {
                UserDefaults.standard.removeObject(forKey: tokenExpiryKey)
            }
        }
    }
    
    private func isTokenExpiringSoon() -> Bool {
        guard let expiry = tokenExpiry else { return true }
        // Consider token expiring if it expires within 5 minutes
        return expiry.timeIntervalSinceNow < 300
    }
    
    func ensureValidToken() async throws {
        if bearerToken == nil || isTokenExpiringSoon() {
            if let refresh = refreshToken {
                try await refreshBearerToken(refreshToken: refresh)
            } else {
                throw APIError.authenticationRequired
            }
        }
    }
    
    // MARK: - Authentication Methods
    func login(username: String, password: String) async throws {
        let timestamp = Int(Date().timeIntervalSince1970)
        
        // Hash password with MD5 (if not already hashed - 32 hex chars)
        let hashedPassword: String
        if password.count == 32 && password.range(of: "^[0-9a-fA-F]{32}$", options: .regularExpression) != nil {
            // Already hashed
            hashedPassword = password.lowercased()
        } else {
            hashedPassword = md5Hash(password)
        }
        
        // Generate request signature: oauth2loginpassword{password}username{username}{timestamp}{secret}
        let sigString = "oauth2loginpassword\(hashedPassword)username\(username)\(timestamp)\(appSecret)"
        let requestSig = md5Hash(sigString)
        
        guard var components = URLComponents(string: "https://www.qobuz.com/api.json/0.2/oauth2/login") else {
            throw APIError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: hashedPassword),
            URLQueryItem(name: "request_ts", value: String(timestamp)),
            URLQueryItem(name: "request_sig", value: requestSig)
        ]
        
        guard let url = components.url else { throw APIError.invalidURL }
        
        var request = URLRequest(url: url)
        request.setValue(appId, forHTTPHeaderField: "x-app-id")
        request.timeoutInterval = 20
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw APIError.unknown }
        
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw APIError.authenticationFailed
        }
        
        let decoder = JSONDecoder()
        let loginResponse = try decoder.decode(LoginResponse.self, from: data)
        
        guard let oauth2 = loginResponse.oauth2 else { throw APIError.emptyData }
        
        // Store tokens
        bearerToken = oauth2.accessToken
        refreshToken = oauth2.refreshToken
        
        // Calculate expiry (typically expires_in is in seconds)
        if let expiresIn = oauth2.expiresIn {
            tokenExpiry = Date().addingTimeInterval(TimeInterval(expiresIn))
        }
    }
    
    private func refreshBearerToken(refreshToken token: String) async throws {
        // OAuth2 refresh token endpoint
        // Note: This endpoint may need to be verified from Qobuz API documentation
        let timestamp = Int(Date().timeIntervalSince1970)
        
        // Generate request signature for refresh token
        // Pattern: oauth2refreshTokenrefresh_token{refresh_token}request_ts{timestamp}{secret}
        let sigString = "oauth2refreshTokenrefresh_token\(token)request_ts\(timestamp)\(appSecret)"
        let requestSig = md5Hash(sigString)
        
        guard var components = URLComponents(string: "https://www.qobuz.com/api.json/0.2/oauth2/refreshToken") else {
            throw APIError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "refresh_token", value: token),
            URLQueryItem(name: "request_ts", value: String(timestamp)),
            URLQueryItem(name: "request_sig", value: requestSig)
        ]
        
        guard let url = components.url else { throw APIError.invalidURL }
        
        var request = URLRequest(url: url)
        request.setValue(appId, forHTTPHeaderField: "x-app-id")
        request.timeoutInterval = 20
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw APIError.unknown }
        
        guard (200..<300).contains(httpResponse.statusCode) else {
            // If refresh fails, clear tokens and require re-authentication
            self.bearerToken = nil
            self.refreshToken = nil
            self.tokenExpiry = nil
            throw APIError.authenticationRequired
        }
        
        let decoder = JSONDecoder()
        let loginResponse = try decoder.decode(LoginResponse.self, from: data)
        
        guard let oauth2 = loginResponse.oauth2 else { throw APIError.emptyData }
        
        // Store new tokens
        bearerToken = oauth2.accessToken
        if let newRefreshToken = oauth2.refreshToken {
            self.refreshToken = newRefreshToken
        }
        
        // Calculate expiry
        if let expiresIn = oauth2.expiresIn {
            tokenExpiry = Date().addingTimeInterval(TimeInterval(expiresIn))
        }
    }
    
    private func md5Hash(_ string: String) -> String {
        let data = Data(string.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        _ = data.withUnsafeBytes { bytes in
            CC_MD5(bytes.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

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

    func finalSearch(query: String, contentType: SearchContentType) {
        errorMessage = nil
        
        switch contentType {
        case .track:
            searchTracks(query: query)
        case .artist:
            searchArtists(query: query)
        case .album:
            searchAlbums(query: query)
        }
    }
    
    private func searchTracks(query: String) {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.qobuz.com/api.json/0.2/track/search?limit=50&offset=0&query=\(encoded)&type=tracks") else { return }
        
        var request = URLRequest(url: url)
        request.setValue("650769754", forHTTPHeaderField: "x-app-id")
        
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                print("Track search request error:", error)
                DispatchQueue.main.async { self.errorMessage = "Search failed. Please try again." }
                return
            }
            guard let data = data else {
                DispatchQueue.main.async { self.errorMessage = "No data received." }
                return
            }
            do {
                let decoded = try JSONDecoder().decode(QobuzTrackSearchResponse.self, from: data)
                let mappedTracks = (decoded.tracks?.items ?? []).map { item in
                    QobuzTrack(
                        id: item.id,
                        title: item.title.trimmingCharacters(in: .whitespacesAndNewlines),
                        artist: item.performer?.name ?? "",
                        album: item.album?.title,
                        image: item.album?.image?.large ?? item.album?.image?.small ?? item.album?.image?.thumbnail,
                        url: nil
                    )
                }
                DispatchQueue.main.async {
                    self.results = mappedTracks
                    self.albums = []
                    self.artists = []
                    if mappedTracks.isEmpty {
                        self.errorMessage = "No results found."
                    } else {
                        self.errorMessage = nil
                    }
                }
            } catch {
                print("Track search decoding error:", error)
                DispatchQueue.main.async { self.errorMessage = "Unexpected response format." }
            }
        }.resume()
    }
    
    private func searchArtists(query: String) {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.qobuz.com/api.json/0.2/artist/search?limit=50&offset=0&query=\(encoded)&type=artists") else { return }
        
        var request = URLRequest(url: url)
        request.setValue("650769754", forHTTPHeaderField: "x-app-id")
        
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                print("Artist search request error:", error)
                DispatchQueue.main.async { self.errorMessage = "Search failed. Please try again." }
                return
            }
            guard let data = data else {
                DispatchQueue.main.async { self.errorMessage = "No data received." }
                return
            }
            do {
                let decoded = try JSONDecoder().decode(QobuzArtistSearchResponse.self, from: data)
                let mappedArtists = (decoded.artists?.items ?? []).map { item in
                    QobuzArtist(
                        id: item.id,
                        name: item.name,
                        image: item.image?.large ?? item.image?.small ?? item.image?.thumbnail
                    )
                }
                DispatchQueue.main.async {
                    self.results = []
                    self.albums = []
                    self.artists = mappedArtists
                    if mappedArtists.isEmpty {
                        self.errorMessage = "No results found."
                    } else {
                        self.errorMessage = nil
                    }
                }
            } catch {
                print("Artist search decoding error:", error)
                DispatchQueue.main.async { self.errorMessage = "Unexpected response format." }
            }
        }.resume()
    }
    
    private func searchAlbums(query: String) {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.qobuz.com/api.json/0.2/album/search?limit=50&offset=0&query=\(encoded)&type=albums") else { return }
        
        var request = URLRequest(url: url)
        request.setValue("650769754", forHTTPHeaderField: "x-app-id")
        
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error = error {
                print("Album search request error:", error)
                DispatchQueue.main.async { self.errorMessage = "Search failed. Please try again." }
                return
            }
            guard let data = data else {
                DispatchQueue.main.async { self.errorMessage = "No data received." }
                return
            }
            do {
                let decoded = try JSONDecoder().decode(QobuzAlbumSearchResponse.self, from: data)
                let mappedAlbums = (decoded.albums?.items ?? []).map { item in
                    QobuzAlbum(
                        id: item.id,
                        title: item.title.trimmingCharacters(in: .whitespacesAndNewlines),
                        artist: item.artist?.name ?? item.artists?.first?.name ?? "",
                        image: item.image?.large ?? item.image?.small ?? item.image?.thumbnail
                    )
                }
                DispatchQueue.main.async {
                    self.results = []
                    self.albums = mappedAlbums
                    self.artists = []
                    if mappedAlbums.isEmpty {
                        self.errorMessage = "No results found."
                    } else {
                        self.errorMessage = nil
                    }
                }
            } catch {
                print("Album search decoding error:", error)
                DispatchQueue.main.async { self.errorMessage = "Unexpected response format." }
            }
        }.resume()
    }

    private struct QQDLRoot: Decodable { let success: Bool; let data: QQDLData? }
    private struct QQDLData: Decodable { let tracks: QQDLTracks?; let albums: QQDLAlbums?; let artists: QQDLArtists? }
    private struct QQDLTracks: Decodable { let items: [QQDLTrackItem]? }
    private struct QQDLTrackItem: Decodable { let id: Int; let title: String; let version: String?; let performer: QQDLPerformer?; let album: QQDLAlbum? }
    private struct QQDLAlbums: Decodable { let items: [QQDLAlbumItem]? }
    private struct QQDLAlbumItem: Decodable { let id: String; let title: String; let artist: QQDLArtistRef?; let artists: [QQDLArtistRef]?; let image: QQDLImage? }
    private struct QQDLArtists: Decodable { let items: [QQDLArtistItem]? }
    private struct QQDLArtistItem: Decodable { let id: Int; let name: String; let image: QQDLImage? }
    private struct QQDLArtistRef: Decodable { let id: Int?; let name: String? }
    private struct QQDLPerformer: Decodable { let name: String }
    private struct QQDLAlbum: Decodable { let title: String?; let image: QQDLImage? }
    private struct QQDLImage: Decodable { let small: String?; let thumbnail: String?; let large: String? }

    // MARK: - New Artist/Album API Methods
    func getArtist(artistID: String) async throws -> ArtistData {
        // Ensure we have a valid bearer token
        try await ensureValidToken()
        
        guard let token = bearerToken else {
            throw APIError.authenticationRequired
        }
        
        guard var comps = URLComponents(string: "https://www.qobuz.com/api.json/0.2/artist/page") else {
            throw APIError.invalidURL
        }
        comps.queryItems = [
            URLQueryItem(name: "artist_id", value: artistID),
            URLQueryItem(name: "sort", value: "release_date"),
            URLQueryItem(name: "order", value: "desc"),
            URLQueryItem(name: "limit", value: "100")
        ]
        guard let url = comps.url else { throw APIError.invalidURL }

        var req = URLRequest(url: url)
        req.setValue(appId, forHTTPHeaderField: "x-app-id")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        req.timeoutInterval = 20
        
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.unknown }
        
        // If unauthorized, try refreshing token
        if http.statusCode == 401 {
            if let refresh = refreshToken {
                try await refreshBearerToken(refreshToken: refresh)
                // Retry with new token
                return try await getArtist(artistID: artistID)
            } else {
                throw APIError.authenticationRequired
            }
        }
        
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.badStatus(http.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        do {
            let parsed = try decoder.decode(ArtistPageResponse.self, from: data)
            
            // Convert to ArtistData format for compatibility
            let artist = Artist(
                id: parsed.id,
                name: parsed.name,
                artistCategory: parsed.artistCategory,
                biography: parsed.biography,
                images: parsed.images,
                releases: parsed.releases
            )
            
            return ArtistData(artist: artist, releases: parsed.releases)
        } catch {
            print("Decoding error: \(error)")
            throw APIError.decodingFailed
        }
    }

    func getAlbum(albumID: String) async throws -> AlbumData {
        // Ensure we have a valid bearer token
        try await ensureValidToken()
        
        guard let token = bearerToken else {
            throw APIError.authenticationRequired
        }
        
        guard var comps = URLComponents(string: "https://www.qobuz.com/api.json/0.2/album/get") else {
            throw APIError.invalidURL
        }
        comps.queryItems = [URLQueryItem(name: "album_id", value: albumID)]
        guard let url = comps.url else { throw APIError.invalidURL }

        var req = URLRequest(url: url)
        req.setValue(appId, forHTTPHeaderField: "x-app-id")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        req.timeoutInterval = 20
        
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw APIError.unknown }
        
        // If unauthorized, try refreshing token
        if http.statusCode == 401 {
            if let refresh = refreshToken {
                try await refreshBearerToken(refreshToken: refresh)
                // Retry with new token
                return try await getAlbum(albumID: albumID)
            } else {
                throw APIError.authenticationRequired
            }
        }
        
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.badStatus(http.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        do {
            // The Qobuz API returns the album data directly, not wrapped in a success/data structure
            let albumResponse = try decoder.decode(QobuzAlbumGetResponse.self, from: data)
            
            // Convert to AlbumData format for compatibility
            let artist = SimpleArtist(
                id: albumResponse.artist?.id,
                name: albumResponse.artist?.name
            )
            
            let tracksPage = TracksPage(
                offset: albumResponse.tracks?.offset,
                items: albumResponse.tracks?.items?.enumerated().map { index, track in
                    // Use position if available and > 0, otherwise use index + 1 (1-based track numbers)
                    let trackNum = (track.position != nil && track.position! > 0) ? track.position! : (index + 1)
                    return TrackItem(
                        id: track.id,
                        isrc: track.isrc,
                        title: track.title,
                        duration: track.duration,
                        trackNumber: trackNum,
                        parentalWarning: track.parentalWarning
                    )
                }
            )
            
            return AlbumData(
                id: albumResponse.id,
                artist: artist,
                releaseDateDownload: albumResponse.releaseDateDownload,
                trackIDs: albumResponse.tracks?.items?.compactMap { $0.id },
                tracks: tracksPage
            )
        } catch {
            print("Album decoding error: \(error)")
            throw APIError.decodingFailed
        }
    }}

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
                        .id(song.objectID)
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
    @State private var showUpNext = false

    // Use MusicPlayer's repeat mode

    private func format(_ t: TimeInterval) -> String {
        guard t.isFinite && !t.isNaN else { return "0:00" }
        let total = Int(t.rounded())
        let m = total / 60, s = total % 60
        return String(format: "%d:%02d", m, s)
    }
    private func skipForward() { player.skipNext() }
    private func skipBackward() { player.skipPrevious(currentTime: audio.currentTime) }

    var body: some View {
                    VStack(spacing: 20) {
                Capsule().fill(Color.white.opacity(0.25)).frame(width: 40, height: 5).padding(.top, 8)

                // Artwork
                if let song = player.currentSong as? Song {
                    LocalArtworkView(song: song, size: 300)
                        .id(song.objectID)
                        .frame(width: 300, height: 300)
                        .cornerRadius(16)
                        .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 12)
                        .offset(y: -70)
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
                    .offset(y: -70)
                }

                // Titles
                VStack(alignment: .leading, spacing: 4) {
                    if let song = player.currentSong as? Song {
                        Text(song.title ?? "Unknown Title").font(.title).fontWeight(.bold).foregroundColor(.white)
                        Text(song.artist ?? "Unknown Artist").font(.subheadline).foregroundColor(.white.opacity(0.85))
                    } else if let tempSong = player.currentSong as? TempSong {
                        Text(tempSong.title).font(.title).fontWeight(.bold).foregroundColor(.white)
                        Text(tempSong.artist).font(.subheadline).foregroundColor(.white.opacity(0.85))
                    }
                }
                .padding(.top, 4)
                .padding(.leading, 20)
                .padding(.leading, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                .offset(y: -8)

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
                .padding(.top, 6)

                // Playback controls
                HStack(spacing: 32) {
                    Button(action: { player.toggleShuffle() }) {
                        Image(systemName: "shuffle")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(player.isShuffling ? .white : .white.opacity(0.6))
                    }
                    Button(action: { skipBackward() }) {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(.white)
                    }
                    Button(action: {
                        if audio.isPlaying { AudioPlayer.shared.pause() } else { AudioPlayer.shared.resume() }
                    }) {
                        ZStack {
                            Image(systemName: "pause.fill")
                                .opacity(audio.isPlaying ? 1 : 0)
                            Image(systemName: "play.fill")
                                .opacity(audio.isPlaying ? 0 : 1)
                        }
                        .font(.system(size: 40, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 48, height: 48)
                    }
                    Button(action: { skipForward() }) {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(.white)
                    }
                    Button(action: {
                        switch player.repeatMode { case .off: player.repeatMode = .one; case .one: player.repeatMode = .all; case .all: player.repeatMode = .off }
                    }) {
                        let symbol: String = (player.repeatMode == .off ? "repeat" : (player.repeatMode == .one ? "repeat.1" : "repeat"))
                        Image(systemName: symbol)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(player.repeatMode == .off ? .white.opacity(0.6) : .white)
                    }
                }
                .font(.title2)

                // Volume (custom bar) above Up Next
                VolumeBar(value: Binding(get: { AudioPlayer.shared.volume }, set: { AudioPlayer.shared.setVolume($0) }))
                    .padding(.horizontal)
                    .padding(.top, 10)

                // Volume
                // Keeping system VolumeView hidden to preserve hardware control behavior if needed
                VolumeView()
                    .frame(height: 0)
                    .opacity(0)

                // Up Next / Options row
                HStack {
                    Button(action: { showUpNext.toggle() }) {
                        HStack(spacing: 8) {
                            // Animate bubble layout when selection changes
                            Image(systemName: "text.line.first.and.arrowtriangle.forward").foregroundColor(.white)
                            Text("Up Next").foregroundColor(.white)
                        }
                        .padding(.leading, 24)
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

            }
            .padding(.top, 120)
            .overlay(alignment: .top) {
                Capsule()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 40, height: 5)
                    .padding(.top, 8)
            }
            .padding(.bottom, 40)
            .background(Color.black.ignoresSafeArea())
            .sheet(isPresented: $showUpNext) {
                UpNextView().environmentObject(player)
            }
    }
}

// Custom volume bar matching scrubber aesthetic
struct VolumeBar: View {
    @Binding var value: Float
    @State private var isDragging = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "speaker.fill")
                .foregroundColor(.white.opacity(0.6))
                .font(.system(size: 14, weight: .regular))

            GeometryReader { geo in
                ZStack {
                    VStack {
                        Spacer()
                        ZStack(alignment: .leading) {
                    // Animate the entire ZStack content changes
                            Capsule().fill(Color.white.opacity(0.2)).frame(height: 6)
                            Capsule().fill(Color.white.opacity(0.6))
                                .frame(width: max(0, min(CGFloat(value) * geo.size.width, geo.size.width)), height: 6)
                        }
                        Spacer()
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        isDragging = true
                        let x = max(0, min(g.location.x, geo.size.width))
                        let ratio = (geo.size.width > 0 ? x / geo.size.width : 0)
                        value = Float(ratio)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
                )
            }
            .frame(height: 28)

            Image(systemName: "speaker.wave.3.fill")
                .foregroundColor(.white.opacity(0.6))
                .font(.system(size: 14, weight: .regular))
        }
        .frame(height: 28)
    }
}

// MARK: - Volume slider wrapper
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
                    // Animate the entire ZStack content changes
                    Capsule().fill(Color.white.opacity(0.25)).frame(height: 5)
                    Capsule().fill(Color.white).frame(width: progressWidth(total: geo.size.width), height: 5)
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
            .frame(height: 28)

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

// MARK: - Up Next View
struct UpNextView: View {
    @EnvironmentObject var player: MusicPlayer
    var body: some View {
        NavigationView {
            List {
                if let idx = player.currentIndex {
                    Section(header: Text("Up Next").foregroundColor(.white)) {
                        ForEach(Array(player.upcoming.enumerated()), id: \.element) { item in
                            let song = item.element
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
                        .onMove { indices, newOffset in
                            player.moveUpcoming(from: indices, to: newOffset)
                        }
                        .onDelete { offsets in
                            player.removeUpcoming(at: offsets)
                        }
                        if player.upcoming.isEmpty {
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
            .toolbar { EditButton() }
        }
    }
}

// MARK: - Local artwork extractor
final class ArtworkImageCache {
    static let shared = NSCache<NSString, UIImage>()
}

struct LocalArtworkView: View {
    @ObservedObject var song: Song
    let size: CGFloat
    @State private var image: UIImage?
    @State private var retryAttempts: Int = 0
    
    var body: some View {
        ZStack {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if let art = song.artwork, art.hasPrefix("http"), let url = URL(string: art) {
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
            
            // Progress overlay for downloading/queued
            ProgressOverlay(song: song, diameter: size * 0.7)
        }
        .onAppear(perform: load)
        .onChange(of: song.artwork) { _ in load() }
        .onChange(of: song.localFilePath) { _ in load() }
        .onChange(of: song.downloadStatus) { newStatus in
            if newStatus == DownloadStatus.downloaded.rawValue { load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .artworkUpdated)) { notif in
            if let id = notif.userInfo?["songId"] as? UUID, id == song.id {
                load()
            }
        }
    }
    
    private func load() {
        // Determine best local artwork path to load
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        var preferredPath: String? = nil
        if let id = song.id {
            let defaultLocal = documentsDirectory.appendingPathComponent("Artwork", isDirectory: true).appendingPathComponent("\(id.uuidString).jpg").path
            if FileManager.default.fileExists(atPath: defaultLocal) { preferredPath = defaultLocal }
        }
        if preferredPath == nil, let art = song.artwork, !art.isEmpty, !art.hasPrefix("http") {
            preferredPath = art
        }
        guard let pathToLoad = preferredPath else {
            // No local artwork available right now; retry in case it appears shortly
            image = nil
            scheduleRetry()
            return
        }
        let cacheKey = NSString(string: "\(pathToLoad)|\(Int(size))")
        if let cached = ArtworkImageCache.shared.object(forKey: cacheKey) {
            image = cached
            return
        }
        let fileExists = FileManager.default.fileExists(atPath: pathToLoad)
        guard fileExists else {
            // File may be written momentarily; retry briefly a few times
            scheduleRetry()
            image = nil
            return
        }
        let targetSize = CGSize(width: size * UIScreen.main.scale, height: size * UIScreen.main.scale)
        DispatchQueue.global(qos: .userInitiated).async {
            var ui = downsampleImage(atPath: pathToLoad, to: targetSize)
            // Fallback to direct load if downsample failed but file exists
            if ui == nil, let direct = UIImage(contentsOfFile: pathToLoad) {
                ui = direct
            }
            DispatchQueue.main.async {
                if let ui {
                    ArtworkImageCache.shared.setObject(ui, forKey: cacheKey)
                    image = ui
                    retryAttempts = 0
                } else {
                    // If decode failed, retry shortly in case file is still being finalized
                    image = nil
                    scheduleRetry()
                }
            }
        }
    }
    
    private func scheduleRetry() {
        guard retryAttempts < 3 else { return }
        retryAttempts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            load()
        }
    }
}

// MARK: - Progress Overlay helper
struct ProgressOverlay: View {
    @ObservedObject var manager = DownloadManager.shared
    @ObservedObject var song: Song
    let diameter: CGFloat
    
    private var show: Bool {
        guard let status = song.downloadStatus else { return false }
        return status == DownloadStatus.downloading.rawValue || status == DownloadStatus.queued.rawValue
    }
    
    private var progressValue: Double {
        guard let id = song.id, let p = manager.activeDownloads[id] else { return 0 }
        // If totalBytes is a fake 100 from poller, percentage will be downloadedBytes/100.
        return max(0.0, min(1.0, p.totalBytes == 0 ? 0 : Double(p.downloadedBytes) / Double(p.totalBytes)))
    }
    
    var body: some View {
        Group {
            if show {
                Circle()
                    .fill(Color.black.opacity(0.35))
                    .frame(width: diameter + 18, height: diameter + 18)
                    .overlay(
                        CircularProgressView(progress: progressValue, size: diameter, lineWidth: max(3, diameter * 0.08))
                    )
            }
        }
        .animation(.easeInOut(duration: 0.2), value: show)
    }
}

private func downsampleImage(atPath path: String, to size: CGSize) -> UIImage? {
    let url = URL(fileURLWithPath: path)
    let options: [CFString: Any] = [
        kCGImageSourceShouldCache: false
    ]
    guard let src = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else { return nil }
    let maxDim = max(size.width, size.height)
    let downsampleOptions: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxDim))
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, downsampleOptions as CFDictionary) else { return nil }
    return UIImage(cgImage: cg)
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
    
    private var recentlyAdded: [Song] { Array(songs.prefix(6)) }
    
    @EnvironmentObject var player: MusicPlayer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !recentlyAdded.isEmpty {
                    Text("Recently Added").font(.title2).bold().foregroundColor(.white).padding(.horizontal)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                        ForEach(recentlyAdded) { song in
                            VStack(alignment: .leading, spacing: 6) {
                                LocalArtworkView(song: song, size: 110)
                                    .id(song.objectID)
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
                                .id(song.objectID)
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
    @State private var showPlaylistSheet = false
    @State private var newPlaylistName: String = ""
    @ObservedObject private var playlists = PlaylistsStore.shared
 
    var body: some View {
        HStack {
            LocalArtworkView(song: song, size: 44)
            VStack(alignment: .leading) {
                Text(song.title ?? "Unknown Title").foregroundColor(.white)
                Text(song.artist ?? "Unknown Artist").font(.caption).foregroundColor(.white.opacity(0.8))
            }
            Spacer()
            Menu {
                Button(role: .destructive) { libraryManager.deleteSong(song) } label: {
                    Label("Delete from Library", systemImage: "trash")
                }
                Divider()
                Button(action: { showPlaylistSheet = true }) {
                    Label("Add to Playlist", systemImage: "text.badge.plus")
                }
                Divider()
                Button(action: { player.enqueueNext(song) }) {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Button(action: { player.enqueueLast(song) }) {
                    Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundColor(.white.opacity(0.8))
                    .font(.system(size: 18, weight: .semibold))
                    .padding(.leading, 8)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .contentShape(Rectangle())
        .overlay(alignment: .leading) {
            Color.clear
                .contentShape(Rectangle())
                .padding(.trailing, 56) // Exclude trailing area where the menu sits
                .onTapGesture { player.play(song: song) }
        }
        .padding(.horizontal)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { libraryManager.deleteSong(song) } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .sheet(isPresented: $showPlaylistSheet) {
            AddToPlaylistSheet(song: song) { showPlaylistSheet = false }
        }
    }
}

// MARK: - Placeholder sections
struct PlaylistsView: View {
    @ObservedObject private var store = PlaylistsStore.shared
    @Environment(\.managedObjectContext) private var viewContext
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    @State private var isEditing: Bool = false
    @State private var showingNewPlaylist: Bool = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(store.playlists) { pl in
                        ZStack(alignment: .topTrailing) {
                            NavigationLink(destination: PlaylistDetailView(playlist: pl)) {
                                VStack(alignment: .leading, spacing: 8) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.12))
                                        Image(systemName: "music.note.list").foregroundColor(.white)
                                    }
                                    .frame(height: 120)
                                    Text(pl.name)
                                        .foregroundColor(.white)
                                        .font(.headline)
                                        .lineLimit(1)
                                    Text("\(pl.songIds.count) song\(pl.songIds.count == 1 ? "" : "s")")
                                        .foregroundColor(.white.opacity(0.7))
                                        .font(.caption)
                                }
                                .padding(8)
                                .background(Color.white.opacity(0.06))
                                .cornerRadius(12)
                            }
                            .disabled(isEditing)

                            if isEditing {
                                Button(action: { store.deletePlaylist(pl.id) }) {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(.red)
                                        .shadow(radius: 1)
                                }
                                .padding(6)
                            }
                        }
                    }
                }
                .padding(12)
            }
            .navigationTitle("Playlists")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if isEditing {
                        Button(action: { showingNewPlaylist = true }) {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle")
                                Text("New Playlist")
                            }
                        }
                        .foregroundColor(.white)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(isEditing ? "Done" : "Edit") { isEditing.toggle() }
                        .foregroundColor(.white)
                }
            }
        }
        .sheet(isPresented: $showingNewPlaylist) {
            NewPlaylistSheet { name in
                _ = PlaylistsStore.shared.createPlaylist(named: name)
                showingNewPlaylist = false
            } onCancel: {
                showingNewPlaylist = false
            }
        }
    }
}

struct PlaylistDetailView: View {
    let playlist: Playlist
    @ObservedObject private var store = PlaylistsStore.shared
    @Environment(\.managedObjectContext) private var viewContext
    @EnvironmentObject var player: MusicPlayer
    
    private var songs: [Song] {
        store.songs(for: playlist, context: viewContext)
    }
    
    var body: some View {
        VStack(spacing: 12) {
            // Header controls
            HStack(spacing: 12) {
                Button(action: { player.playPlaylist(songs: songs, shuffle: false) }) {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("Play")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.white)
                    .foregroundColor(.black)
                    .cornerRadius(12)
                }
                Button(action: { player.playPlaylist(songs: songs, shuffle: true) }) {
                    HStack {
                        Image(systemName: "shuffle")
                        Text("Shuffle")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.12))
                    .foregroundColor(.white)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.3), lineWidth: 1)
                    )
                }
            }
            .padding(.horizontal)
            
            List {
                ForEach(songs) { song in
                    SongRow(song: song)
                }
                .onDelete { offsets in
                    let ids = offsets.compactMap { songs[$0].id }
                    for id in ids { store.removeSong(id, from: playlist.id) }
                }
            }
            .listStyle(.plain)
        }
        .navigationTitle(playlist.name)
    }
}

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

    @State private var contentType: SearchContentType = .track
    @State private var isSearching = false
    @State private var showPicker: Bool = false
    @State private var query = ""
    @State private var mode: SearchMode = .library
    @FocusState private var searchFocused: Bool
    @State private var filteredLibrary: [Song] = []
    @State private var addedSongs: Set<String> = [] // Track which songs were just added
    @State private var addingSongs: Set<String> = [] // Track which songs are currently being added

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                // ZStack to layer picker behind search bar
                ZStack(alignment: .top) {
                    // Picker layer (behind)
                    ZStack(alignment: .leading) {
                        // Animate the entire ZStack content changes
                        if showPicker {
                            Picker("", selection: $mode) {
                                ForEach(SearchMode.allCases, id: \.self) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .move(edge: .top).combined(with: .opacity)))
                        }
                        if isSearching {
                            HStack(spacing: 8) {
                                ForEach(SearchContentType.allCases, id: \.self) { type in
                                    Button(action: {
                                        withAnimation(.easeInOut(duration: 0.22)) { contentType = type }
                                    }) {
                                        Text(type.rawValue)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(contentType == type ? .black : .white)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .background(
                                                RoundedRectangle(cornerRadius: 14)
                                                    .fill(contentType == type ? Color.white : Color.white.opacity(0.2))
                                            )
                                    }
                                    .scaleEffect(contentType == type ? 1.0 : 0.96)
                                    .animation(.spring(response: 0.28, dampingFraction: 0.85), value: contentType)
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                            .padding(.leading, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .move(edge: .bottom).combined(with: .opacity)))
                        }
                    }
                    .animation(.easeInOut(duration: 0.35), value: showPicker || isSearching)
                    .frame(height: 34)
                    .padding(.horizontal)
                    .padding(.top, 50) // Position behind search bar
                    
                    // Search bar layer (on top)
                    TextField("Search", text: $query)
                        .padding(10)
                        .background(Color(white: 0.15).opacity(0.9))
                        .cornerRadius(10)
                        .foregroundColor(.white)
                        .padding(.horizontal)
                        .focused($searchFocused)
                        .onSubmit {
                            withAnimation(.easeOut(duration: 0.35)) {
                                isSearching = true
                                showPicker = false
                            }
                            searchFocused = false
                            if mode == .newMusic {
                                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty { qobuzAPI.finalSearch(query: trimmed, contentType: contentType) }
                            }
                        }
                        .onChange(of: query) { newValue in
                            qobuzAPI.errorMessage = nil
                            if !isSearching {
                                withAnimation(.easeOut(duration: 0.35)) {
                                    showPicker = searchFocused || !newValue.isEmpty
                                }
                            }
                            if mode == .newMusic, !newValue.isEmpty {
                                qobuzAPI.search(query: newValue)
                            } else if mode == .library {
                                // Only show library results when user has typed something
                                if newValue.isEmpty {
                                    filteredLibrary = []
                                } else {
                                    filteredLibrary = libraryManager.searchSongs(query: newValue)
                                }
                            }
                        }
                        .onChange(of: searchFocused) { focused in
                            if focused {
                                withAnimation(.easeOut(duration: 0.35)) {
                                    isSearching = false
                                    showPicker = true
                                }
                            } else if !isSearching {
                                withAnimation(.easeOut(duration: 0.35)) {
                                    showPicker = !query.isEmpty
                                }
                            }
                        }
                        .onChange(of: contentType) { newType in
                            if mode == .newMusic && isSearching {
                                let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty {
                                    qobuzAPI.finalSearch(query: trimmed, contentType: newType)
                                }
                            }
                        }
                }
                .frame(height: 84) // Height to accommodate search bar + picker
                
                if let error = qobuzAPI.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal)
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
                        switch contentType {
                        case .track:
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

                                    Button(action: {
                                        if !isInLibrary && !isAdding {
                                            addingSongs.insert(songKey)

                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                                let success = libraryManager.addSong(from: track)
                                                addingSongs.remove(songKey)

                                                if success {
                                                    addedSongs.insert(songKey)
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
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if let localSong = libraryManager.findSongMatching(track: track),
                                       let _ = DownloadManager.shared.getLocalFileURL(for: localSong) {
                                        player.play(song: localSong)
                                    } else {
                                        let temp = TempSong(from: track)
                                        player.play(tempSong: temp)
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
                        case .album:
                            ForEach(qobuzAPI.albums, id: \.id) { album in
                                NavigationLink(destination: AlbumDetailView(
                                    albumID: album.id,
                                    albumTitle: album.title,
                                    albumArt: URL(string: album.image ?? "")
                                )) {
                                    HStack {
                                        if let art = album.image, let url = URL(string: art) {
                                            AsyncImage(url: url) { phase in
                                                if let image = phase.image {
                                                    image.resizable()
                                                } else if phase.error != nil {
                                                    Image(systemName: "exclamationmark.triangle")
                                                        .resizable()
                                                        .foregroundColor(.gray)
                                                } else {
                                                    Image(systemName: "opticaldisc")
                                                        .resizable()
                                                        .foregroundColor(.gray)
                                                }
                                            }
                                            .frame(width: 44, height: 44)
                                            .cornerRadius(4)
                                        }
                                        VStack(alignment: .leading) {
                                            Text(album.title).foregroundColor(.white)
                                            Text(album.artist).font(.caption).foregroundColor(.white.opacity(0.8))
                                        }
                                        Spacer()
                                    }
                                    .listRowBackground(Color.clear)
                                }
                                .buttonStyle(.plain)
                            }
                        case .artist:
                            ForEach(qobuzAPI.artists, id: \.id) { artist in
                                NavigationLink(destination: ArtistDetailView(artist: artist)) {
                                    HStack {
                                        if let art = artist.image, let url = URL(string: art) {
                                            AsyncImage(url: url) { phase in
                                                if let image = phase.image {
                                                    image.resizable()
                                                } else if phase.error != nil {
                                                    Image(systemName: "exclamationmark.triangle")
                                                        .resizable()
                                                        .foregroundColor(.gray)
                                                } else {
                                                    Image(systemName: "person.crop.square")
                                                        .resizable()
                                                        .foregroundColor(.gray)
                                                }
                                            }
                                            .frame(width: 44, height: 44)
                                            .cornerRadius(4)
                                        } else {
                                            Image(systemName: "person.crop.square")
                                                .resizable()
                                                .foregroundColor(.gray)
                                                .frame(width: 44, height: 44)
                                                .cornerRadius(4)
                                        }
                                        VStack(alignment: .leading) {
                                            Text(artist.name).foregroundColor(.white)
                                        }
                                        Spacer()
                                    }
                                }
                                .listRowBackground(Color.clear)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Search")
            .onAppear {
                // Only show library results if there's a query
                if !query.isEmpty {
                    filteredLibrary = libraryManager.searchSongs(query: query)
                } else {
                    filteredLibrary = []
                }
            }
        }
    }
}

// MARK: - Login View
struct LoginView: View {
    @ObservedObject var qobuzAPI: QobuzAPI
    let onLoginSuccess: () -> Void
    
    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: LoginField?
    
    enum LoginField {
        case username, password
    }
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.white.opacity(0.8))
            
            Text("Login Required")
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Text("Please enter your Qobuz credentials to view artist details")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            VStack(spacing: 16) {
                TextField("Email or Username", text: $username)
                    .textContentType(.emailAddress)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)
                    .padding(12)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(10)
                    .foregroundColor(.white)
                    .focused($focusedField, equals: .username)
                    .submitLabel(.next)
                    .onSubmit {
                        focusedField = .password
                    }
                
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(10)
                    .foregroundColor(.white)
                    .focused($focusedField, equals: .password)
                    .submitLabel(.go)
                    .onSubmit {
                        Task { await performLogin() }
                    }
            }
            .padding(.horizontal)
            
            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            
            Button(action: {
                Task { await performLogin() }
            }) {
                HStack {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .black))
                    } else {
                        Text("Login")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(14)
                .background(isLoading ? Color.gray : Color.white)
                .foregroundColor(isLoading ? .white : .black)
                .cornerRadius(10)
            }
            .disabled(isLoading || username.isEmpty || password.isEmpty)
            .padding(.horizontal)
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
        .padding()
    }
    
    private func performLogin() async {
        guard !username.isEmpty && !password.isEmpty else { return }
        
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        
        do {
            try await qobuzAPI.login(username: username, password: password)
            // Login successful, call the success callback
            onLoginSuccess()
        } catch let error as APIError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = "Login failed: \(error.localizedDescription)"
        }
    }
}

struct ArtistDetailView: View {
    let artist: QobuzArtist
    @StateObject private var qobuzAPI = QobuzAPI()
    @State private var artistData: ArtistData?
    @State private var albums: [DisplayAlbum] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showLogin = false
    @State private var needsAuthentication = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Artist Header
                HStack(alignment: .center, spacing: 16) {
                    if let art = artist.image, let url = URL(string: art) {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image {
                                image.resizable()
                            } else if phase.error != nil {
                                Image(systemName: "exclamationmark.triangle")
                                    .resizable()
                                    .foregroundColor(.gray)
                            } else {
                                Image(systemName: "person.crop.square")
                                    .resizable()
                                    .foregroundColor(.gray)
                            }
                        }
                        .frame(width: 96, height: 96)
                        .cornerRadius(8)
                    } else {
                        Image(systemName: "person.crop.square")
                            .resizable()
                            .foregroundColor(.gray)
                            .frame(width: 96, height: 96)
                            .cornerRadius(8)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(artist.name)
                            .font(.title2).bold()
                            .foregroundColor(.white)
                        Text("Artist")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.7))
                    }
                    Spacer()
                }

                // Bio Section
                if let bio = artistData?.artist.biography?.content, !bio.isEmpty {
                    Divider().background(Color.white.opacity(0.1))
                    VStack(alignment: .leading, spacing: 8) {
                        Text("About")
                            .font(.headline)
                            .foregroundColor(.white)
                        Text(bioStripped(bio))
                            .font(.callout)
                            .foregroundColor(.white.opacity(0.8))
                            .lineLimit(6)
                            .overlay(
                                LinearGradient(
                                    colors: [.clear, Color.black],
                                    startPoint: .center, endPoint: .bottom
                                )
                                .frame(height: 30)
                                .allowsHitTesting(false),
                                alignment: .bottom
                            )
                    }
                }

                // Albums Section
                if !albums.isEmpty {
                    Divider().background(Color.white.opacity(0.1))
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Albums")
                            .font(.headline)
                            .foregroundColor(.white)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
                            ForEach(albums) { album in
                                NavigationLink(destination: AlbumDetailView(albumID: album.id, albumTitle: album.title, albumArt: album.imageURL)) {
                                    AlbumCard(album: album)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // Loading/Error States
                if isLoading {
                    HStack { Spacer(); ProgressView().padding(.vertical, 12); Spacer() }
                } else if needsAuthentication || (errorMessage?.contains("log in") ?? false) {
                    LoginView(qobuzAPI: qobuzAPI) {
                        // After successful login, retry fetching artist data
                        Task {
                            needsAuthentication = false
                            await fetchArtistData()
                        }
                    }
                } else if let error = errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                        Text(error).multilineTextAlignment(.center)
                        Button { Task { await fetchArtistData() } } label: {
                            Label("Try Again", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .padding()
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await fetchArtistData() }
        .refreshable { await fetchArtistData() }
    }

    private func bioStripped(_ raw: String) -> String {
        raw.replacingOccurrences(of: "<br />", with: "\n")
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "&copy", with: "©")
            .replacingOccurrences(of: "  ", with: " ")
    }

    private func fetchArtistData() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            let data = try await qobuzAPI.getArtist(artistID: String(artist.id))
            artistData = data
            
            let buckets = data.artist.releases ?? []
            
            // Get albums and singles/EPs
            let albumBucket = buckets.first { $0.type.lowercased().trimmingCharacters(in: .whitespaces) == "album" }
            let singleBucket = buckets.first { $0.type.lowercased().trimmingCharacters(in: .whitespaces) == "epsingle" }
            
            var allItems: [ReleaseItem] = []
            allItems.append(contentsOf: albumBucket?.items ?? [])
            allItems.append(contentsOf: singleBucket?.items ?? [])

            let mapped = allItems.map { mapAlbum($0) }
            albums = mapped.sorted { ($0.releaseDate ?? .distantPast) > ($1.releaseDate ?? .distantPast) }

            if albums.isEmpty { errorMessage = "No albums found for this artist." }
        } catch let error as APIError {
            switch error {
            case .authenticationRequired:
                needsAuthentication = true
                errorMessage = nil
            default:
                errorMessage = error.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func mapAlbum(_ item: ReleaseItem) -> DisplayAlbum {
        let imgURL = URL(string: item.image?.large ?? item.image?.small ?? item.image?.thumbnail ?? "")
        let label = item.label?.name ?? ""
        let date = item.dates?.original.flatMap { DateFormatter.yyyyMMdd.date(from: $0) }
        return DisplayAlbum(
            id: item.id,
            title: item.title + (item.version.map { " (\($0))" } ?? ""),
            imageURL: imgURL,
            label: label,
            releaseDate: date,
            tracksCount: item.tracksCount,
            isExplicit: item.parentalWarning ?? false
        )
    }
}
struct AlbumCard: View {
    let album: DisplayAlbum

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.1))
                if let url = album.imageURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .empty: ProgressView()
                        case .success(let img): img.resizable().scaledToFill()
                        case .failure:
                            Image(systemName: "opticaldisc").font(.largeTitle).foregroundColor(.white.opacity(0.6))
                        @unknown default: Color.clear
                        }
                    }
                } else {
                    Image(systemName: "opticaldisc").font(.largeTitle).foregroundColor(.white.opacity(0.6))
                }
            }
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 4) {
                Text(album.title).font(.headline).lineLimit(2).foregroundColor(.white)
                HStack(spacing: 8) {
                    if album.isExplicit {
                        Text("Explicit")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.red.opacity(0.15), in: Capsule())
                            .foregroundColor(.red)
                    }
                    if let tracks = album.tracksCount {
                        Label("\(tracks)", systemImage: "music.note.list")
                            .font(.caption).foregroundColor(.white.opacity(0.7))
                    }
                }
                if let d = album.releaseDate {
                    Text(d.formatted(.dateTime.year().month().day()))
                        .font(.caption).foregroundColor(.white.opacity(0.7))
                }
                if !album.label.isEmpty {
                    Text(album.label).font(.caption).foregroundColor(.white.opacity(0.7)).lineLimit(1)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.05))
                .shadow(radius: 2, x: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.white.opacity(0.1))
        )
    }
}

struct AlbumDetailView: View {
    let albumID: String
    let albumTitle: String
    let albumArt: URL?
    @StateObject private var qobuzAPI = QobuzAPI()
    @EnvironmentObject var libraryManager: LibraryManager
    @EnvironmentObject var player: MusicPlayer
    @State private var tracks: [TrackRow] = []
    @State private var albumArtist: String? = nil
    @State private var albumGenre: String? = nil
    @State private var albumYear: String? = nil
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var addedSongs: Set<String> = []
    @State private var addingSongs: Set<String> = []
    @State private var needsAuthentication = false

    var body: some View {
        List {
            // Album Header
            if let art = albumArt {
                Section {
                    HStack(alignment: .top, spacing: 16) {
                        AsyncImage(url: art) { phase in
                            switch phase {
                            case .empty: ProgressView()
                            case .success(let img): img.resizable().scaledToFill()
                            case .failure: Image(systemName: "opticaldisc").font(.largeTitle).foregroundColor(.white.opacity(0.6))
                            @unknown default: Color.clear
                            }
                        }
                        .frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                        VStack(alignment: .leading, spacing: 6) {
                            Text(albumTitle).font(.headline).lineLimit(3).foregroundColor(.white)
                            
                            // Artist name
                            if let artist = albumArtist {
                                Text(artist)
                                    .font(.subheadline)
                                    .foregroundColor(.white.opacity(0.8))
                            }
                            
                            // Genre and Year
                            HStack(spacing: 8) {
                                if let genre = albumGenre {
                                    Text(genre)
                                        .font(.caption)
                                        .foregroundColor(.white.opacity(0.7))
                                }
                                if let year = albumYear {
                                    if albumGenre != nil {
                                        Text("•")
                                            .font(.caption)
                                            .foregroundColor(.white.opacity(0.5))
                                    }
                                    Text(year)
                                        .font(.caption)
                                        .foregroundColor(.white.opacity(0.7))
                                }
                            }
                            
                            // Track count and duration
                            if !tracks.isEmpty {
                                Text("\(tracks.count) tracks • \(totalDuration())")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.7))
                            }
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            }

            // Loading/Error States
            if isLoading {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            } else if needsAuthentication || (errorMessage?.contains("log in") ?? false) {
                Section {
                    LoginView(qobuzAPI: qobuzAPI) {
                        // After successful login, retry fetching album data
                        Task {
                            needsAuthentication = false
                            await fetch()
                        }
                    }
                }
            } else if let error = errorMessage {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                        Text(error).multilineTextAlignment(.center)
                        Button { Task { await fetch() } } label: {
                            Label("Try Again", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                // Tracks Section
                Section(header: Text("Tracks").foregroundColor(.white)) {
                    ForEach(tracks) { track in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("\(track.trackNumber ?? 0)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundColor(.white.opacity(0.7))
                                .frame(width: 24, alignment: .trailing)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(track.title).font(.body).lineLimit(2).foregroundColor(.white)
                                    if track.explicit {
                                        Text("E")
                                            .font(.caption2.weight(.bold))
                                            .padding(.horizontal, 4).padding(.vertical, 1)
                                            .background(Color.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                                            .foregroundColor(.red)
                                    }
                                }
                                Text(track.durationString).font(.caption2).foregroundColor(.white.opacity(0.7))
                            }
                            Spacer()
                            
                            // Add to library button
                            let songKey = "\(track.title)-\(albumTitle)"
                            let isInLibrary = libraryManager.isSongInLibrary(title: track.title, artist: albumTitle)
                            let wasJustAdded = addedSongs.contains(songKey)
                            let isAdding = addingSongs.contains(songKey)
                            
                            Button(action: {
                                if !isInLibrary && !isAdding {
                                    addingSongs.insert(songKey)
                                    
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                        let qobuzTrack = QobuzTrack(
                                            id: track.qobuzTrackId ?? 0,
                                            title: track.title,
                                            artist: albumArtist ?? albumTitle,
                                            album: albumTitle,
                                            image: albumArt?.absoluteString,
                                            url: nil
                                        )
                                        let success = libraryManager.addSong(from: qobuzTrack)
                                        addingSongs.remove(songKey)
                                        
                                        if success {
                                            addedSongs.insert(songKey)
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
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Convert TrackRow to QobuzTrack for playing
                            let qobuzTrack = QobuzTrack(
                                id: track.qobuzTrackId ?? 0,
                                title: track.title,
                                artist: albumArtist ?? albumTitle,
                                album: albumTitle,
                                image: albumArt?.absoluteString,
                                url: nil
                            )
                            
                            // Prefer local if exists; else stream immediately
                            if let localSong = libraryManager.findSongMatching(track: qobuzTrack),
                               let _ = DownloadManager.shared.getLocalFileURL(for: localSong) {
                                player.play(song: localSong)
                            } else {
                                let temp = TempSong(from: qobuzTrack)
                                player.play(tempSong: temp)
                                DownloadManager.shared.resolveStreamURLForQobuz(trackId: qobuzTrack.id) { result in
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
        .listStyle(.plain)
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Album")
        .navigationBarTitleDisplayMode(.inline)
        .task { await fetch() }
        .refreshable { await fetch() }
    }

    private func totalDuration() -> String {
        let total = tracks.reduce(0) { $0 + ($1.duration ?? 0) }
        return mmss(total)
    }

    private func mmss(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return "\(m):" + String(format: "%02d", s)
    }

    private func fetch() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            let resp = try await qobuzAPI.getAlbum(albumID: albumID)
            
            // Store the artist name from the album data
            albumArtist = resp.artist?.name
            
            // Fetch full album details to get genre and release date
            try await fetchAlbumDetails()
            
            let items = resp.tracks.items ?? []
            var mapped: [TrackRow] = items.enumerated().map { index, item in
                // Use trackNumber from TrackItem, or fall back to position + 1 (1-based), or index + 1
                let trackNum = item.trackNumber ?? (index + 1)
                return TrackRow(
                    id: String(item.id ?? Int.random(in: 1...9_999_999)),
                    trackNumber: trackNum,
                    title: item.title ?? "Untitled",
                    duration: item.duration,
                    isrc: item.isrc,
                    explicit: item.parentalWarning ?? false,
                    qobuzTrackId: item.id
                )
            }
            // Sort by track number first, then by title if track numbers are equal
            mapped.sort {
                let a = $0.trackNumber ?? Int.max
                let b = $1.trackNumber ?? Int.max
                return a == b ? ($0.title < $1.title) : (a < b)
            }
            tracks = mapped
            if tracks.isEmpty { errorMessage = "No tracks found for this album." }
        } catch let error as APIError {
            switch error {
            case .authenticationRequired:
                needsAuthentication = true
                errorMessage = nil
            default:
                errorMessage = error.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    private func fetchAlbumDetails() async throws {
        // Fetch the full album response to get genre and release date
        // We'll decode the raw response directly
        try await qobuzAPI.ensureValidToken()
        
        guard let token = qobuzAPI.currentBearerToken else {
            return
        }
        
        guard var comps = URLComponents(string: "https://www.qobuz.com/api.json/0.2/album/get") else {
            return
        }
        comps.queryItems = [URLQueryItem(name: "album_id", value: albumID)]
        guard let url = comps.url else { return }

        var req = URLRequest(url: url)
        req.setValue("650769754", forHTTPHeaderField: "x-app-id")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        req.timeoutInterval = 20
        
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { return }
        
        guard (200..<300).contains(http.statusCode) else {
            return
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        do {
            let albumResponse = try decoder.decode(QobuzAlbumGetResponse.self, from: data)
            
            // Extract genre and year
            albumGenre = albumResponse.genre?.name
            
            // Extract year from release date
            if let releaseDate = albumResponse.releaseDateOriginal ?? albumResponse.releaseDateDownload {
                // Parse date string (format: "YYYY-MM-DD")
                let components = releaseDate.split(separator: "-")
                if let year = components.first {
                    albumYear = String(year)
                }
            }
        } catch {
            print("Failed to decode album details: \(error)")
        }
    }
}
// MARK: - Add To Playlist Sheet (Apple Music style)
struct AddToPlaylistSheet: View {
    let song: Song
    var onDismiss: () -> Void
    @ObservedObject private var store = PlaylistsStore.shared
    @State private var searchText: String = ""
    @State private var showingNewPlaylist = false
    
    private var filtered: [Playlist] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return store.playlists }
        return store.playlists.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
    
    var body: some View {
        NavigationView {
            List {
                if store.playlists.isEmpty {
                    Text("No Playlists").foregroundColor(.white.opacity(0.7))
                } else {
                    ForEach(filtered) { pl in
                        Button(action: {
                            PlaylistsStore.shared.addSong(song, to: pl.id)
                            onDismiss()
                        }) {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.12))
                                    Image(systemName: "music.note.list").foregroundColor(.white)
                                }
                                .frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pl.name).foregroundColor(.white).fontWeight(.semibold)
                                    let count = pl.songIds.count
                                    Text("\(count) song\(count == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundColor(.white.opacity(0.7))
                                }
                                Spacer()
                                Image(systemName: "plus.circle.fill").foregroundColor(.white)
                            }
                        }
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Playlists")
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Add to a Playlist")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel", action: onDismiss).foregroundColor(.white)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingNewPlaylist = true }) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle")
                            Text("New Playlist")
                        }
                    }
                    .foregroundColor(.white)
                }
            }
        }
        .sheet(isPresented: $showingNewPlaylist) {
            NewPlaylistSheet { name in
                let p = PlaylistsStore.shared.createPlaylist(named: name)
                PlaylistsStore.shared.addSong(song, to: p.id)
                showingNewPlaylist = false
                onDismiss()
            } onCancel: {
                showingNewPlaylist = false
            }
        }
    }
}

struct NewPlaylistSheet: View {
    var onCreate: (String) -> Void
    var onCancel: () -> Void
    @State private var name: String = ""
    
    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 16) {
                Text("New Playlist").font(.headline).foregroundColor(.white)
                TextField("Playlist Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                Spacer()
            }
            .padding()
            .background(Color.black.ignoresSafeArea())
            .navigationBarItems(
                leading: Button("Cancel") { onCancel() }.foregroundColor(.white),
                trailing: Button("Create") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    onCreate(trimmed)
                }.foregroundColor(.white)
            )
        }
    }
}
