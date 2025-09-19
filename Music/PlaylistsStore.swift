import Foundation
import Combine
import CoreData

struct Playlist: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var songIds: [UUID]
}

final class PlaylistsStore: ObservableObject {
    static let shared = PlaylistsStore()
    @Published private(set) var playlists: [Playlist] = []
    
    private let fileURL: URL
    private var cancellables: Set<AnyCancellable> = []
    
    private init() {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.fileURL = documentsDirectory.appendingPathComponent("playlists.json")
        load()
        // Auto-save on any change
        $playlists
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.save() }
            .store(in: &cancellables)
    }
    
    // MARK: - CRUD
    func createPlaylist(named name: String) -> Playlist {
        let playlist = Playlist(id: UUID(), name: name, songIds: [])
        DispatchQueue.main.async { [weak self] in
            self?.playlists.append(playlist)
        }
        return playlist
    }
    
    func renamePlaylist(_ playlistId: UUID, to newName: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let idx = self.playlists.firstIndex(where: { $0.id == playlistId }) else { return }
            self.playlists[idx].name = newName
        }
    }
    
    func deletePlaylist(_ playlistId: UUID) {
        DispatchQueue.main.async { [weak self] in
            self?.playlists.removeAll { $0.id == playlistId }
        }
    }
    
    func addSong(_ song: Song, to playlistId: UUID) {
        guard let songId = song.id else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let idx = self.playlists.firstIndex(where: { $0.id == playlistId }) else { return }
            if !self.playlists[idx].songIds.contains(songId) {
                self.playlists[idx].songIds.append(songId)
            }
        }
    }
    
    func removeSong(_ songId: UUID, from playlistId: UUID) {
        DispatchQueue.main.async { [weak self] in
            if let self = self, let idx = self.playlists.firstIndex(where: { $0.id == playlistId }) {
                self.playlists[idx].songIds.removeAll { $0 == songId }
            }
        }
    }
    
    func removeSongFromAllPlaylists(songId: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for i in self.playlists.indices {
                self.playlists[i].songIds.removeAll { $0 == songId }
            }
        }
    }
    
    func allPlaylists() -> [Playlist] { playlists }
    
    // Fetch songs for playlist using Core Data
    func songs(for playlist: Playlist, context: NSManagedObjectContext) -> [Song] {
        guard !playlist.songIds.isEmpty else { return [] }
        let request: NSFetchRequest<Song> = Song.fetchRequest()
        request.predicate = NSPredicate(format: "id IN %@", playlist.songIds)
        do { return try context.fetch(request) } catch { return [] }
    }
    
    // MARK: - Persistence
    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { playlists = []; return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode([Playlist].self, from: data)
            playlists = decoded
        } catch {
            print("Failed to load playlists: \(error)")
            playlists = []
        }
    }
    
    private func save() {
        do {
            let data = try JSONEncoder().encode(playlists)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("Failed to save playlists: \(error)")
        }
    }
} 