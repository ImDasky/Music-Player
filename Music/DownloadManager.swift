//
//  DownloadManager.swift
//  Music
//
//  Created by Ben on 9/18/25.
//

import Foundation
import AVFoundation
import CoreData

enum DownloadStatus: String, CaseIterable {
    case notDownloaded = "notDownloaded"
    case downloading = "downloading"
    case downloaded = "downloaded"
    case failed = "failed"
    case paused = "paused"
}

class DownloadManager: ObservableObject {
    static let shared = DownloadManager()
    
    @Published var activeDownloads: [UUID: DownloadProgress] = [:]
    
    private let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    private let musicDirectory: URL
    
    private init() {
        musicDirectory = documentsDirectory.appendingPathComponent("Music", isDirectory: true)
        createMusicDirectoryIfNeeded()
    }
    
    private func createMusicDirectoryIfNeeded() {
        if !FileManager.default.fileExists(atPath: musicDirectory.path) {
            try? FileManager.default.createDirectory(at: musicDirectory, withIntermediateDirectories: true)
        }
    }
    
    func downloadSong(_ song: Song, context: NSManagedObjectContext) {
        guard let urlString = song.url,
              let url = URL(string: urlString),
              song.downloadStatus != DownloadStatus.downloaded.rawValue else { return }
        
        // Update status to downloading
        song.downloadStatus = DownloadStatus.downloading.rawValue
        try? context.save()
        
        let downloadId = song.id ?? UUID()
        let progress = DownloadProgress(songId: downloadId, totalBytes: 0, downloadedBytes: 0)
        activeDownloads[downloadId] = progress
        
        // Create filename
        let fileName = "\(song.id?.uuidString ?? UUID().uuidString).mp3"
        let localURL = musicDirectory.appendingPathComponent(fileName)
        
        // Start download
        URLSession.shared.downloadTask(with: url) { [weak self] tempURL, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("Download failed: \(error)")
                    song.downloadStatus = DownloadStatus.failed.rawValue
                    self?.activeDownloads.removeValue(forKey: downloadId)
                    try? context.save()
                    return
                }
                
                guard let tempURL = tempURL else {
                    song.downloadStatus = DownloadStatus.failed.rawValue
                    self?.activeDownloads.removeValue(forKey: downloadId)
                    try? context.save()
                    return
                }
                
                // Move file to final location
                do {
                    if FileManager.default.fileExists(atPath: localURL.path) {
                        try FileManager.default.removeItem(at: localURL)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: localURL)
                    
                    // Update song with local file info
                    song.localFilePath = localURL.path
                    song.downloadStatus = DownloadStatus.downloaded.rawValue
                    song.fileSize = response?.expectedContentLength ?? 0
                    
                    // Get duration using AVFoundation
                    self?.getAudioDuration(for: song, at: localURL)
                    
                    self?.activeDownloads.removeValue(forKey: downloadId)
                    try? context.save()
                    
                } catch {
                    print("Error moving file: \(error)")
                    song.downloadStatus = DownloadStatus.failed.rawValue
                    self?.activeDownloads.removeValue(forKey: downloadId)
                    try? context.save()
                }
            }
        }.resume()
    }
    
    private func getAudioDuration(for song: Song, at url: URL) {
        let asset = AVAsset(url: url)
        let duration = asset.duration
        let durationSeconds = CMTimeGetSeconds(duration)
        
        DispatchQueue.main.async {
            song.duration = durationSeconds
            try? song.managedObjectContext?.save()
        }
    }
    
    func deleteDownloadedFile(for song: Song) {
        guard let localPath = song.localFilePath else { return }
        
        do {
            try FileManager.default.removeItem(atPath: localPath)
            song.localFilePath = nil
            song.downloadStatus = DownloadStatus.notDownloaded.rawValue
            song.fileSize = 0
            song.duration = 0
            try? song.managedObjectContext?.save()
        } catch {
            print("Error deleting file: \(error)")
        }
    }
    
    func getLocalFileURL(for song: Song) -> URL? {
        guard let localPath = song.localFilePath,
              FileManager.default.fileExists(atPath: localPath) else { return nil }
        return URL(fileURLWithPath: localPath)
    }
    
    func isDownloaded(_ song: Song) -> Bool {
        return song.downloadStatus == DownloadStatus.downloaded.rawValue && 
               song.localFilePath != nil &&
               FileManager.default.fileExists(atPath: song.localFilePath!)
    }
    
    func getDownloadProgress(for songId: UUID) -> DownloadProgress? {
        return activeDownloads[songId]
    }
}

struct DownloadProgress {
    let songId: UUID
    let totalBytes: Int64
    let downloadedBytes: Int64
    
    var percentage: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(downloadedBytes) / Double(totalBytes)
    }
}
