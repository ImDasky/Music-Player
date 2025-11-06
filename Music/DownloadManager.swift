//
//  DownloadManager.swift
//  Music
//
//  Created by Ben on 9/18/25.
//

import Foundation
import AVFoundation
import CoreData
import UIKit

extension Notification.Name {
    static let artworkUpdated = Notification.Name("artworkUpdated")
}

enum DownloadStatus: String, CaseIterable {
    case notDownloaded = "notDownloaded"
    case downloading = "downloading"
    case downloaded = "downloaded"
    case failed = "failed"
    case paused = "paused"
    case queued = "queued"
}

class DownloadManager: ObservableObject {
    static let shared = DownloadManager()
    
    @Published var activeDownloads: [UUID: DownloadProgress] = [:]
    private var progressObservers: [UUID: NSKeyValueObservation] = [:]
    
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
    
    // MARK: - Qobuz Download API Flow
    func downloadSongFromQobuz(_ song: Song, trackId: Int, context: NSManagedObjectContext) {
        // Step 1: Request download from Qobuz API
        requestQobuzDownload(trackId: trackId) { [weak self] result in
            switch result {
            case .success(let downloadId):
                // Step 2: Start polling for download status
                self?.pollDownloadStatus(song: song, downloadId: downloadId, context: context)
            case .failure(let error):
                DispatchQueue.main.async {
                    song.downloadStatus = DownloadStatus.failed.rawValue
                    try? context.save()
                }
                print("Failed to request download: \(error)")
            }
        }
    }
    
    private func requestQobuzDownload(trackId: Int, completion: @escaping (Result<String, Error>) -> Void) {
        // Construct the download request URL
        let qobuzTrackURL = "https://open.qobuz.com/track/\(trackId)"
        guard let encodedURL = qobuzTrackURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            completion(.failure(DownloadError.invalidURL))
            return
        }
        
        let downloadRequestURL = "https://us.doubledouble.top/dl?url=\(encodedURL)&format=ogg"
        
        guard let url = URL(string: downloadRequestURL) else {
            completion(.failure(DownloadError.invalidURL))
            return
        }
        
        URLSession.shared.dataTask(with: url) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            
            guard let data = data else {
                completion(.failure(DownloadError.noData))
                return
            }
            
            do {
                let response = try JSONDecoder().decode(DownloadRequestResponse.self, from: data)
                if response.success {
                    completion(.success(response.id))
                } else {
                    completion(.failure(DownloadError.requestFailed))
                }
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
    
    private func pollDownloadStatus(song: Song, downloadId: String, context: NSManagedObjectContext) {
        let statusURL = "https://us.doubledouble.top/dl/\(downloadId)"
        
        guard let url = URL(string: statusURL) else {
            DispatchQueue.main.async {
                song.downloadStatus = DownloadStatus.failed.rawValue
                try? context.save()
            }
            return
        }
        
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            if let error = error {
                print("Error checking download status: \(error)")
                DispatchQueue.main.async {
                    song.downloadStatus = DownloadStatus.failed.rawValue
                    if let id = song.id { self?.activeDownloads.removeValue(forKey: id) }
                    try? context.save()
                }
                return
            }
            
            guard let data = data else {
                DispatchQueue.main.async {
                    song.downloadStatus = DownloadStatus.failed.rawValue
                    if let id = song.id { self?.activeDownloads.removeValue(forKey: id) }
                    try? context.save()
                }
                return
            }
            
            do {
                let statusResponse = try JSONDecoder().decode(DownloadStatusResponse.self, from: data)
                
                DispatchQueue.main.async {
                    // Update percent progress if available
                    if let id = song.id, let pct = statusResponse.percent {
                        let clamped = max(0, min(100, pct))
                        self?.activeDownloads[id] = DownloadProgress(songId: id, totalBytes: 100, downloadedBytes: Int64(clamped))
                        song.downloadStatus = DownloadStatus.downloading.rawValue
                    }
                    
                    switch statusResponse.status {
                    case "queued":
                        song.downloadStatus = DownloadStatus.queued.rawValue
                        try? context.save()
                        // Continue polling after a delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                            self?.pollDownloadStatus(song: song, downloadId: downloadId, context: context)
                        }
                        
                    case "done":
                        // Download is complete on server, now fetch the file
                        if let fileURL = statusResponse.url {
                            self?.downloadCompletedFile(song: song, fileURL: fileURL, context: context)
                        } else {
                            song.downloadStatus = DownloadStatus.failed.rawValue
                            if let id = song.id { self?.activeDownloads.removeValue(forKey: id) }
                            try? context.save()
                        }
                        
                    case "error", "failed":
                        song.downloadStatus = DownloadStatus.failed.rawValue
                        if let id = song.id { self?.activeDownloads.removeValue(forKey: id) }
                        try? context.save()
                        
                    default:
                        // Continue polling for other statuses
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                            self?.pollDownloadStatus(song: song, downloadId: downloadId, context: context)
                        }
                    }
                }
            } catch {
                print("Error decoding status response: \(error)")
                DispatchQueue.main.async {
                    song.downloadStatus = DownloadStatus.failed.rawValue
                    if let id = song.id { self?.activeDownloads.removeValue(forKey: id) }
                    try? context.save()
                }
            }
        }.resume()
    }
    
    private func downloadCompletedFile(song: Song, fileURL: String, context: NSManagedObjectContext) {
        print("Original fileURL from API: \(fileURL)") // Debug log
        
        // Construct the full download URL - comprehensive fix for extra dot issue
        let fullURL: String
        if fileURL.hasPrefix("http://") {
            // Replace http with https
            fullURL = fileURL.replacingOccurrences(of: "http://", with: "https://")
        } else if fileURL.hasPrefix("./") {
            // Add the base URL without extra dot
            fullURL = "https://us.doubledouble.top\(fileURL)"
        } else if fileURL.hasPrefix("/") {
            // Add the base URL without extra dot
            fullURL = "https://us.doubledouble.top\(fileURL)"
        } else {
            // For any other case, use the fileURL as-is but fix the dot issue
            fullURL = fileURL
        }
        
        // Fix the extra dot issue - this should catch all cases
        let correctedURL = fullURL.replacingOccurrences(of: "us.doubledouble.top./", with: "us.doubledouble.top/")
        
        print("Downloading from URL: \(correctedURL)") // Debug log
        
        guard let url = URL(string: correctedURL) else {
            print("Invalid URL: \(correctedURL)")
            song.downloadStatus = DownloadStatus.failed.rawValue
            if let id = song.id { activeDownloads.removeValue(forKey: id) }
            try? context.save()
            return
        }
        
        // Create filename
        let fileName = "\(song.id?.uuidString ?? UUID().uuidString).flac"
        let localURL = musicDirectory.appendingPathComponent(fileName)
        
        // Create a custom URLSession configuration with longer timeouts
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 60.0  // 60 seconds for request timeout
        config.timeoutIntervalForResource = 300.0  // 5 minutes for resource timeout
        
        // Create a custom session delegate to handle SSL issues
        let session = URLSession(configuration: config, delegate: InsecureURLSessionDelegate(), delegateQueue: nil)
        
        // Download the actual file with retry logic
        downloadFileWithRetry(session: session, url: url, song: song, localURL: localURL, context: context, retryCount: 0)
    }
    
    private func downloadFileWithRetry(session: URLSession, url: URL, song: Song, localURL: URL, context: NSManagedObjectContext, retryCount: Int) {
        let maxRetries = 3
        
        print("Attempting download (attempt \(retryCount + 1)/\(maxRetries + 1))")
        
        let songId = song.id ?? UUID()
        let task = session.downloadTask(with: url) { [weak self] tempURL, response, error in
            DispatchQueue.main.async {
                // Remove any live progress observer for this task/song
                self?.progressObservers[songId] = nil
                if let error = error {
                    print("Download failed (attempt \(retryCount + 1)): \(error)")
                    
                    // Check if it's a timeout error and we have retries left
                    if (error as NSError).code == NSURLErrorTimedOut && retryCount < maxRetries {
                        print("Retrying download in 5 seconds...")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                            self?.downloadFileWithRetry(session: session, url: url, song: song, localURL: localURL, context: context, retryCount: retryCount + 1)
                        }
                        return
                    }
                    
                    song.downloadStatus = DownloadStatus.failed.rawValue
                    if let id = song.id { self?.activeDownloads.removeValue(forKey: id) }
                    try? context.save()
                    return
                }
                
                guard let tempURL = tempURL else {
                    if retryCount < maxRetries {
                        print("No temp URL, retrying in 5 seconds...")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                            self?.downloadFileWithRetry(session: session, url: url, song: song, localURL: localURL, context: context, retryCount: retryCount + 1)
                        }
                        return
                    }
                    
                    song.downloadStatus = DownloadStatus.failed.rawValue
                    if let id = song.id { self?.activeDownloads.removeValue(forKey: id) }
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
                    
                    // Extract and persist embedded artwork/metadata for high quality covers
                    self?.extractAndSaveArtwork(from: localURL, for: song)
                    
                    if let id = song.id { self?.activeDownloads.removeValue(forKey: id) }
                    try? context.save()
                    print("Download completed successfully!")
                    
                } catch {
                    print("Error moving file: \(error)")
                    song.downloadStatus = DownloadStatus.failed.rawValue
                    if let id = song.id { self?.activeDownloads.removeValue(forKey: id) }
                    try? context.save()
                }
            }
        }
        // Observe task progress to update UI percentage while downloading
        let obs = task.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                let pct = max(0.0, min(1.0, progress.fractionCompleted))
                self.activeDownloads[songId] = DownloadProgress(songId: songId, totalBytes: 100, downloadedBytes: Int64(pct * 100))
                song.downloadStatus = DownloadStatus.downloading.rawValue
            }
        }
        progressObservers[songId] = obs
        task.resume()
    }
    
    // MARK: - Legacy Download Method (for non-Qobuz songs)
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
                    
                    // Extract and persist embedded artwork/metadata for high quality covers
                    self?.extractAndSaveArtwork(from: localURL, for: song)
                    
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
    
    // MARK: - Resolve Stream URL (reuse Qobuz flow without downloading)
    func resolveStreamURLForQobuz(trackId: Int, completion: @escaping (Result<URL, Error>) -> Void) {
        requestQobuzDownload(trackId: trackId) { [weak self] result in
            switch result {
            case .success(let downloadId):
                self?.pollForStreamURL(downloadId: downloadId, completion: completion)
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    private func pollForStreamURL(downloadId: String, completion: @escaping (Result<URL, Error>) -> Void) {
        let statusURL = "https://us.doubledouble.top/dl/\(downloadId)"
        guard let url = URL(string: statusURL) else {
            completion(.failure(DownloadError.invalidURL)); return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            if let error = error { completion(.failure(error)); return }
            guard let data = data else { completion(.failure(DownloadError.noData)); return }
            do {
                let statusResponse = try JSONDecoder().decode(DownloadStatusResponse.self, from: data)
                switch statusResponse.status {
                case "queued":
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        self?.pollForStreamURL(downloadId: downloadId, completion: completion)
                    }
                case "done":
                    if let fileURL = statusResponse.url {
                        let corrected = self?.correctedDownloadURL(from: fileURL)
                        guard let corrected, let maybeURL = URL(string: corrected) else {
                            completion(.failure(DownloadError.invalidURL)); return
                        }
                        // If URL looks like a final media file (has extension), return it; otherwise try to resolve JSON, else poll again
                        if !maybeURL.pathExtension.isEmpty {
                            completion(.success(maybeURL))
                        } else {
                            self?.resolveIfStatusURL(maybeURL) { result in
                                switch result {
                                case .success(let finalURL):
                                    if finalURL.pathExtension.isEmpty {
                                        // Still not a media URL; poll again
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                            self?.pollForStreamURL(downloadId: downloadId, completion: completion)
                                        }
                                    } else {
                                        completion(.success(finalURL))
                                    }
                                case .failure:
                                    // Could not resolve; poll again
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                        self?.pollForStreamURL(downloadId: downloadId, completion: completion)
                                    }
                                }
                            }
                        }
                    } else {
                        // No URL yet; poll again
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            self?.pollForStreamURL(downloadId: downloadId, completion: completion)
                        }
                    }
                case "error", "failed":
                    completion(.failure(DownloadError.downloadFailed))
                default:
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        self?.pollForStreamURL(downloadId: downloadId, completion: completion)
                    }
                }
            } catch {
                // If not JSON (unexpected), poll again briefly
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self?.pollForStreamURL(downloadId: downloadId, completion: completion)
                }
            }
        }.resume()
    }

    private func correctedDownloadURL(from fileURL: String) -> String {
        let fullURL: String
        if fileURL.hasPrefix("http://") {
            fullURL = fileURL.replacingOccurrences(of: "http://", with: "https://")
        } else if fileURL.hasPrefix("./") {
            fullURL = "https://us.doubledouble.top\(fileURL)"
        } else if fileURL.hasPrefix("/") {
            fullURL = "https://us.doubledouble.top\(fileURL)"
        } else {
            fullURL = fileURL
        }
        return fullURL.replacingOccurrences(of: "us.doubledouble.top./", with: "us.doubledouble.top/")
    }

    private func resolveIfStatusURL(_ url: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        // If URL appears to be a status endpoint (no extension or contains /dl/), try to fetch it and extract media URL
        if url.pathExtension.isEmpty || url.path.contains("/dl/") {
            URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
                if let error = error { completion(.failure(error)); return }
                guard let data = data else { completion(.failure(DownloadError.noData)); return }
                if let status = try? JSONDecoder().decode(DownloadStatusResponse.self, from: data), let nested = status.url {
                    let corrected = self?.correctedDownloadURL(from: nested) ?? nested
                    if let final = URL(string: corrected) {
                        completion(.success(final))
                    } else {
                        completion(.failure(DownloadError.invalidURL))
                    }
                } else {
                    // If not JSON or no nested URL, return original and let player attempt
                    completion(.success(url))
                }
            }.resume()
        } else {
            completion(.success(url))
        }
    }
    
    // MARK: - Embedded artwork extraction for local files
    private func extractAndSaveArtwork(from url: URL, for song: Song) {
        let asset = AVAsset(url: url)
        // Try common metadata first
        if let data = extractArtworkData(from: asset.commonMetadata) {
            saveArtwork(data: data, for: song)
            return
        }
        // Try all available formats
        for fmt in asset.availableMetadataFormats {
            if let data = extractArtworkData(from: asset.metadata(forFormat: fmt)) {
                saveArtwork(data: data, for: song)
                return
            }
        }
        // Fallback: parse FLAC PICTURE block manually
        if url.pathExtension.lowercased() == "flac", let data = parseFLACPicture(at: url) {
            saveArtwork(data: data, for: song)
            return
        }
    }
    
    private func extractArtworkData(from items: [AVMetadataItem]) -> Data? {
        // Prefer items marked as artwork
        var fallbackData: Data? = nil
        for item in items {
            if let key = item.commonKey, key == .commonKeyArtwork {
                if let data = item.dataValue { return data }
                if let data = item.value as? Data { return data }
            }
            // Record a generic data-bearing item as a last resort
            if fallbackData == nil {
                if let data = item.dataValue { fallbackData = data }
                else if let data = item.value as? Data { fallbackData = data }
            }
        }
        return fallbackData
    }
    
    private func saveArtwork(data: Data, for song: Song) {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let artworkDirectory = documentsDirectory.appendingPathComponent("Artwork", isDirectory: true)
        if !FileManager.default.fileExists(atPath: artworkDirectory.path) {
            try? FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        }
        
        // Validate that data is a decodable image; avoid writing corrupt or non-art data
        guard UIImage(data: data) != nil else {
            print("Artwork data is not a valid image; skipping save")
            return
        }
        
        // Create filename based on album and artist to share artwork across songs from same album
        let artworkFileName: String
        if let album = song.album, !album.isEmpty, let artist = song.artist, !artist.isEmpty {
            // Use album + artist for filename (sanitized for filesystem)
            let sanitizedAlbum = sanitizeFilename(album)
            let sanitizedArtist = sanitizeFilename(artist)
            artworkFileName = "\(sanitizedArtist)_\(sanitizedAlbum).jpg"
        } else {
            // Fallback to song ID if no album/artist info
            artworkFileName = "\(song.id?.uuidString ?? UUID().uuidString).jpg"
        }
        
        let artworkURL = artworkDirectory.appendingPathComponent(artworkFileName)
        
        // Check if artwork file already exists (for same album)
        if FileManager.default.fileExists(atPath: artworkURL.path) {
            // Artwork already exists for this album, just reference it
            song.artwork = artworkURL.path
            // Notify UI listeners that artwork was updated for this song
            if let id = song.id {
                NotificationCenter.default.post(name: .artworkUpdated, object: nil, userInfo: ["songId": id])
            }
            return
        }
        
        // Save new artwork file
        do {
            try data.write(to: artworkURL, options: .atomic)
            song.artwork = artworkURL.path
            // Notify UI listeners that artwork was updated for this song
            if let id = song.id {
                NotificationCenter.default.post(name: .artworkUpdated, object: nil, userInfo: ["songId": id])
            }
        } catch {
            print("Failed to save artwork: \(error)")
        }
    }
    
    // Helper function to sanitize filenames for filesystem
    private func sanitizeFilename(_ filename: String) -> String {
        let invalidChars = CharacterSet(charactersIn: "/\\?%*|\"<>")
        let sanitized = filename.components(separatedBy: invalidChars).joined(separator: "_")
        // Limit length to avoid filesystem issues
        let maxLength = 100
        if sanitized.count > maxLength {
            return String(sanitized.prefix(maxLength))
        }
        return sanitized
    }

    
    // Parse FLAC METADATA_BLOCK of type 6 (PICTURE) to extract embedded cover image
    private func parseFLACPicture(at url: URL) -> Data? {
        guard let fileData = try? Data(contentsOf: url) else { return nil }
        var idx = 0
        
        // Helper to read bytes
        func readBytes(_ count: Int) -> Data? {
            guard idx + count <= fileData.count else { return nil }
            let data = fileData.subdata(in: idx..<idx+count)
            idx += count
            return data
        }
        
        // Helper to read big-endian integer
        func readBEInt(_ count: Int) -> UInt32? {
            guard let data = readBytes(count) else { return nil }
            var result: UInt32 = 0
            for byte in data {
                result = (result << 8) | UInt32(byte)
            }
            return result
        }
        
        // Check FLAC header
        guard let header = readBytes(4), String(data: header, encoding: .ascii) == "fLaC" else { return nil }
        
        // Parse metadata blocks
        while idx < fileData.count {
            guard let blockHeader = readBytes(1) else { break }
            let isLast = (blockHeader[0] & 0x80) != 0
            let blockType = blockHeader[0] & 0x7F
            let blockLength = readBEInt(3) ?? 0
            
            if blockType == 6 { // PICTURE block
                // Skip picture type (4 bytes)
                guard readBytes(4) != nil else { break }
                
                // Read MIME type length and MIME type
                guard let mimeLength = readBEInt(4), let _ = readBytes(Int(mimeLength)) else { break }
                
                // Skip description length and description
                guard let descLength = readBEInt(4), let _ = readBytes(Int(descLength)) else { break }
                
                // Skip width, height, color depth, colors used
                guard readBytes(16) != nil else { break }
                
                // Read picture data length and data
                guard let dataLength = readBEInt(4) else { break }
                if let pictureData = readBytes(Int(dataLength)) {
                    return pictureData
                }
            } else {
                // Skip this block
                if let _ = readBytes(Int(blockLength)) {
                    if isLast { break }
                } else {
                    break
                }
            }
            
            if isLast { break }
        }
        
        return nil
    }}

// MARK: - Insecure URLSession Delegate
class InsecureURLSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Accept all certificates for this specific domain
        if challenge.protectionSpace.host == "us.doubledouble.top" {
            let credential = URLCredential(trust: challenge.protectionSpace.serverTrust!)
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - Download Models
struct DownloadRequestResponse: Decodable {
    let success: Bool
    let id: String
}

struct DownloadStatusResponse: Decodable {
    let status: String
    let lastPing: Int64?
    let service: String?
    let friendlyStatus: String?
    let percent: Int?
    let current: DownloadCurrent?
    let url: String?
}

struct DownloadCurrent: Decodable {
    let name: String
    let artist: String
    let cover: String
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

enum DownloadError: Error {
    case invalidURL
    case noData
    case requestFailed
    case downloadFailed
}
