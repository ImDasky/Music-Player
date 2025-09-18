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
    case queued = "queued"
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
                    try? context.save()
                }
                return
            }
            
            guard let data = data else {
                DispatchQueue.main.async {
                    song.downloadStatus = DownloadStatus.failed.rawValue
                    try? context.save()
                }
                return
            }
            
            do {
                let statusResponse = try JSONDecoder().decode(DownloadStatusResponse.self, from: data)
                
                DispatchQueue.main.async {
                    switch statusResponse.status {
                    case "queued":
                        song.downloadStatus = DownloadStatus.queued.rawValue
                        try? context.save()
                        // Continue polling after a delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                            self?.pollDownloadStatus(song: song, downloadId: downloadId, context: context)
                        }
                        
                    case "done":
                        // Download is complete, get the file
                        if let fileURL = statusResponse.url {
                            self?.downloadCompletedFile(song: song, fileURL: fileURL, context: context)
                        } else {
                            song.downloadStatus = DownloadStatus.failed.rawValue
                            try? context.save()
                        }
                        
                    case "error", "failed":
                        song.downloadStatus = DownloadStatus.failed.rawValue
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
        
        session.downloadTask(with: url) { [weak self] tempURL, response, error in
            DispatchQueue.main.async {
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
                    
                    try? context.save()
                    print("Download completed successfully!")
                    
                } catch {
                    print("Error moving file: \(error)")
                    song.downloadStatus = DownloadStatus.failed.rawValue
                    try? context.save()
                }
            }
        }.resume()
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
                        if let corrected,
                           let maybeURL = URL(string: corrected) {
                            self?.resolveIfStatusURL(maybeURL, completion: completion)
                        } else {
                            completion(.failure(DownloadError.invalidURL))
                        }
                    } else {
                        completion(.failure(DownloadError.noData))
                    }
                case "error", "failed":
                    completion(.failure(DownloadError.downloadFailed))
                default:
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        self?.pollForStreamURL(downloadId: downloadId, completion: completion)
                    }
                }
            } catch {
                completion(.failure(error))
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
}

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
