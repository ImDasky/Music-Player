//
//  AudioPlayer.swift
//  Music
//
//  Created by Ben on 9/18/25.
//

import Foundation
import AVFoundation
import MediaPlayer

class AudioPlayer: NSObject, ObservableObject {
    static let shared = AudioPlayer()
    
    @Published var isPlaying = false
    @Published var currentSong: Song?
    @Published var currentTempSong: TempSong?
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var audioQuality: AudioQuality = .high
    @Published var volume: Float = 1.0
    
    private var player: AVPlayer?
    private var currentPlayerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var audioEngine: AVAudioEngine?
    private var audioPlayerNode: AVAudioPlayerNode?
    private var audioFile: AVAudioFile?
    private var hqStartTimeOffset: Double = 0
    // Guard flags for completion handling
    private var isSeekingHQ: Bool = false
    private var playbackGeneration: UInt64 = 0
    private var hqTimeObserverTimer: Timer?
    // Track if playback was interrupted (was playing when interruption began)
    private var wasPlayingBeforeInterruption: Bool = false
    
    // High-quality audio settings
    private let sampleRate: Double = 96000.0  // 96kHz for high quality
    
    // Helper to update isPlaying on main thread to ensure UI sync
    private func updateIsPlaying(_ value: Bool) {
        if Thread.isMainThread {
            isPlaying = value
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.isPlaying = value
            }
        }
    }
    
    enum AudioQuality: String, CaseIterable {
        case standard = "Standard (44.1kHz)"
        case high = "High (96kHz)"
        case lossless = "Lossless (192kHz)"
        
        var sampleRate: Double {
            switch self {
            case .standard: return 44100.0
            case .high: return 96000.0
            case .lossless: return 192000.0
            }
        }
        
        var bitDepth: Int {
            switch self {
            case .standard: return 16
            case .high: return 32
            case .lossless: return 32
            }
        }
    }
    
    private override init() {
        super.init()
        setupHighQualityAudioSession()
        setupRemoteCommandCenter()
        observeInterruptions()
        // Initialize default volume
        setVolume(volume)
    }
    
    private func setupHighQualityAudioSession() {
        do {
            // Configure for high-quality audio playback and background audio
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetooth])
            try audioSession.setPreferredSampleRate(audioQuality.sampleRate)
            try audioSession.setPreferredInputNumberOfChannels(2)
            try audioSession.setPreferredOutputNumberOfChannels(2)
            try audioSession.setActive(true)
        } catch {
            print("Failed to setup high-quality audio session: \(error)")
            setupStandardAudioSession()
        }
    }
    
    private func setupStandardAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to setup standard audio session: \(error)")
        }
    }
    
    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
        
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.resume()
            self?.updateNowPlayingInfo()
            return .success
        }
        
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            self?.updateNowPlayingInfo()
            return .success
        }
        
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            if self.isPlaying { self.pause() } else { self.resume() }
            self.updateNowPlayingInfo()
            return .success
        }

        commandCenter.nextTrackCommand.addTarget { _ in
            NotificationCenter.default.post(name: .remoteCommandNext, object: nil)
            return .success
        }
        commandCenter.previousTrackCommand.addTarget { _ in
            NotificationCenter.default.post(name: .remoteCommandPrevious, object: nil)
            return .success
        }
    }
    
    private func observeInterruptions() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleInterruption(_:)),
                                               name: AVAudioSession.interruptionNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleRouteChange(_:)),
                                               name: AVAudioSession.routeChangeNotification,
                                               object: nil)
    }
    
    @objc private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        
        // Ensure we're on main thread for UI updates
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if type == .began {
                // Remember if we were playing when interruption began
                // Only auto-resume later if we were actually playing (not manually paused)
                self.wasPlayingBeforeInterruption = self.isPlaying
                if self.isPlaying {
                    self.pause()
                }
            } else if type == .ended {
                // Only auto-resume if:
                // 1. System says we should resume (.shouldResume)
                // 2. We were actually playing when interruption began (not manually paused)
                if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    if options.contains(.shouldResume) && self.wasPlayingBeforeInterruption {
                        self.resume()
                    }
                }
                // Reset flag after handling interruption
                self.wasPlayingBeforeInterruption = false
            }
        }
    }
    
    @objc private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        
        // Ensure we're on main thread for UI updates
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Pause playback when audio route is disconnected (e.g., Bluetooth, headphones)
            switch reason {
            case .oldDeviceUnavailable:
                // Audio output device was disconnected (Bluetooth, headphones, etc.)
                if self.isPlaying {
                    self.pause()
                }
            case .newDeviceAvailable:
                // New audio output device became available - don't pause, just continue
                break
            case .categoryChange:
                // Audio session category changed - pause to be safe
                if self.isPlaying {
                    self.pause()
                }
            default:
                break
            }
        }
    }
    
    // MARK: - Play Song (Core Data)
    func play(song: Song) {
        print("=== PLAY SONG CALLED ===")
        // Stop any previous playback to avoid stale isPlaying state
        stop()
        
        // Set intent
        currentSong = song
        currentTempSong = nil
        
        // Debug song state
        print("Playing song: \(song.title ?? "Unknown")")
        print("Download status: \(song.downloadStatus ?? "nil")")
        print("Local file path: \(song.localFilePath ?? "nil")")
        if let path = song.localFilePath {
            print("File exists: \(FileManager.default.fileExists(atPath: path))")
        }
        
        // Try to play local FLAC file first
        if let localURL = DownloadManager.shared.getLocalFileURL(for: song) {
            print("Using local file: \(localURL.path)")
            playFromURL(localURL, isLocalFile: true)
        } else if let urlString = song.url, let url = URL(string: urlString) {
            print("Falling back to streaming: \(urlString)")
            // Fallback to streaming
            playFromURL(url, isLocalFile: false)
        } else {
            print("No local file or streaming URL available")
            // Nothing to play; clear state
            updateIsPlaying(false)
            currentSong = nil
            updateNowPlayingInfo()
        }
    }
    
    // MARK: - Play Temp Song (Streaming)
    func play(tempSong: TempSong) {
        // Stop any previous playback to avoid stale isPlaying state
        stop()
        
        currentTempSong = tempSong
        currentSong = nil
        
        if let urlString = tempSong.url, let url = URL(string: urlString) {
            playFromURL(url, isLocalFile: false)
        } else {
            updateIsPlaying(false)
            currentTempSong = nil
            updateNowPlayingInfo()
        }
    }
    
    private func playFromURL(_ url: URL, isLocalFile: Bool) {
        print("Playing audio from: \(url.lastPathComponent)")
        print("File type: \(url.pathExtension)")
        print("Is local file: \(isLocalFile)")
        
        // For FLAC files, use high-quality audio engine
        if url.pathExtension.lowercased() == "flac" && isLocalFile {
            playFLACWithHighQuality(url: url)
        } else {
            // Use standard AVPlayer for other formats or streaming
            var fallback: URL? = nil
            if url.scheme == "https", url.host == "us.doubledouble.top" {
                var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
                comps?.scheme = "http"
                fallback = comps?.url
            }
            playWithAVPlayer(url: url, fallbackURL: fallback)
        }
    }
    
    private func playFLACWithHighQuality(url: URL) {
        do {
            // Create audio engine for high-quality playback
            audioEngine = AVAudioEngine()
            audioPlayerNode = AVAudioPlayerNode()
            
            guard let engine = audioEngine, let playerNode = audioPlayerNode else {
                print("Failed to create audio engine components")
                playWithAVPlayer(url: url)
                return
            }
            
            // Create audio file first to obtain processing format
            audioFile = try AVAudioFile(forReading: url)
            guard let file = audioFile else {
                print("Failed to create audio file")
                playWithAVPlayer(url: url)
                return
            }
            let format = file.processingFormat
            
            // Attach player node to engine
            engine.attach(playerNode)
            
            // Connect using explicit file format to avoid format mismatch
            let mainMixer = engine.mainMixerNode
            engine.connect(playerNode, to: mainMixer, format: format)
            
            // Reset base offset
            hqStartTimeOffset = 0
            playbackGeneration &+= 1
            let generationAtSchedule = playbackGeneration
            
            // Schedule the file for playback from start
            playerNode.scheduleFile(file, at: nil) { [weak self] in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    // Ignore completion if a seek or new schedule occurred
                    if self.isSeekingHQ || generationAtSchedule != self.playbackGeneration { return }
                    self.updateIsPlaying(false)
                    self.currentTime = 0
                    self.postFinished()
                }
            }
            
            // Prepare and start the engine
            engine.prepare()
            do {
                try engine.start()
            } catch {
                print("Audio engine failed to start: \(error)")
                // Fallback to standard AVPlayer if engine can't start
                engine.stop()
                playWithAVPlayer(url: url)
                return
            }
            
            // Start playback only if engine is running
            guard engine.isRunning else {
                print("Audio engine not running; falling back to AVPlayer")
                engine.stop()
                playWithAVPlayer(url: url)
                return
            }
            
            playerNode.play()
            updateIsPlaying(true)
            
            // Get duration
            duration = Double(file.length) / file.processingFormat.sampleRate
            
            // Start time observer for high-quality playback
            startHighQualityTimeObserver()
            updateNowPlayingInfo()
            
            // Record recently played for library song
            if let s = currentSong { RecentlyPlayedStore.shared.record(s.id) }
            
            print("High-quality FLAC playback started")
            
        } catch {
            print("Failed to setup high-quality FLAC playback: \(error)")
            // Fallback to standard AVPlayer
            playWithAVPlayer(url: url)
        }
    }
    
    private func playWithAVPlayer(url: URL, fallbackURL: URL? = nil) {
        // Clean up previous player item observers before creating new one
        cleanupPlayerItem()
        
        // Create AVPlayerItem from URL
        let playerItem = AVPlayerItem(url: url)
        currentPlayerItem = playerItem
        player = AVPlayer(playerItem: playerItem)
        
        // Add observer for when the item is ready to play
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemDidReachEnd(_:)),
            name: .AVPlayerItemDidPlayToEndTime,
            object: playerItem
        )
        
        // Add observer for playback status
        playerItem.addObserver(self, forKeyPath: "status", options: [.new], context: nil)
        // Store fallback on the item via associated object using KVO key path trick
        if let fb = fallbackURL {
            objc_setAssociatedObject(playerItem, &AssociatedKeys.fallbackURLKey, fb, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        
        // Start playing (will actually start when ready)
        player?.play()
        updateIsPlaying(true)
        
        // Get duration
        let duration = playerItem.asset.duration
        self.duration = CMTimeGetSeconds(duration)
        
        // Start time observer
        startTimeObserver()
        updateNowPlayingInfo()
    }
    
    private func cleanupPlayerItem() {
        // Remove observers from previous player item
        if let previousItem = currentPlayerItem {
            NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: previousItem)
            previousItem.removeObserver(self, forKeyPath: "status")
            currentPlayerItem = nil
        }
    }
    
    private func startHighQualityTimeObserver() {
        // Invalidate any existing timer first
        hqTimeObserverTimer?.invalidate()
        
        // For high-quality playback, we need to track time differently
        hqTimeObserverTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self = self, let playerNode = self.audioPlayerNode else {
                timer.invalidate()
                return
            }
            
            if !self.isPlaying {
                timer.invalidate()
                return
            }
            
            // Calculate current time based on player node plus offset
            if let lastRenderTime = playerNode.lastRenderTime,
               let playerTime = playerNode.playerTime(forNodeTime: lastRenderTime) {
                self.currentTime = self.hqStartTimeOffset + (Double(playerTime.sampleTime) / playerTime.sampleRate)
            }
        }
    }
    
    func pause() {
        if let playerNode = audioPlayerNode {
            playerNode.pause()
            // Invalidate timer when pausing
            hqTimeObserverTimer?.invalidate()
            hqTimeObserverTimer = nil
        } else {
            player?.pause()
        }
        updateIsPlaying(false)
        updateNowPlayingInfo()
    }
    
    func resume() {
        // Ensure audio session is active before resuming
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to activate audio session on resume: \(error)")
            // If activation fails, try to reconfigure the session
            setupHighQualityAudioSession()
        }
        
        if let playerNode = audioPlayerNode, let engine = audioEngine {
            // Always check and restart engine if needed, as it may have stopped
            // even if it thinks it's running (e.g., after audio session deactivation)
            if !engine.isRunning {
                engine.prepare()
                do { 
                    try engine.start() 
                } catch { 
                    print("Engine failed to restart on resume: \(error)")
                    // Try to reactivate audio session and retry
                    do {
                        try AVAudioSession.sharedInstance().setActive(true)
                        engine.prepare()
                        try engine.start()
                    } catch {
                        print("Engine failed to restart after session reactivation: \(error)")
                        return
                    }
                }
            }
            
            // Ensure player node is playing
            if !playerNode.isPlaying {
                playerNode.play()
            }
            
            // Restart timer for high-quality playback to update currentTime
            startHighQualityTimeObserver()
        } else {
            // For AVPlayer, ensure it's actually playing
            if let player = player {
                player.play()
                // Double-check that playback actually started
                if player.rate == 0 {
                    // If rate is still 0, there might be an issue - try reactivating session
                    do {
                        try AVAudioSession.sharedInstance().setActive(true)
                        player.play()
                    } catch {
                        print("Failed to reactivate session for AVPlayer: \(error)")
                    }
                }
            }
        }
        updateIsPlaying(true)
        updateNowPlayingInfo()
    }
    
    func setVolume(_ value: Float) {
        // Clamp value between 0 and 1
        let clamped = max(0.0, min(value, 1.0))
        volume = clamped
        // AVPlayer volume
        player?.volume = clamped
        // AVAudioEngine main mixer volume (if using HQ path)
        audioEngine?.mainMixerNode.outputVolume = clamped
    }

    func stop() {
        // Stop high-quality engine
        audioPlayerNode?.stop()
        audioEngine?.stop()
        audioEngine = nil
        audioPlayerNode = nil
        audioFile = nil
        hqStartTimeOffset = 0
        isSeekingHQ = false
        playbackGeneration &+= 1
        
        // Clean up high-quality time observer
        hqTimeObserverTimer?.invalidate()
        hqTimeObserverTimer = nil
        
        // Clean up player item observers before stopping
        cleanupPlayerItem()
        
        // Stop AVPlayer
        player?.pause()
        player = nil
        
        updateIsPlaying(false)
        currentSong = nil
        currentTempSong = nil
        currentTime = 0
        duration = 0
        stopTimeObserver()
    }
    
    func seek(to time: TimeInterval) {
        if let playerNode = audioPlayerNode, let file = audioFile {
            // Seek in high-quality playback using scheduleSegment for accuracy
            let sampleRate = file.processingFormat.sampleRate
            let totalFrames = AVAudioFramePosition(file.length)
            let clampedTime = max(0, min(time, duration))
            let startFrame = AVAudioFramePosition(clampedTime * sampleRate)
            let framesToPlay = max(0, totalFrames - startFrame)
            
            // Keep engine running, just stop the node and reschedule
            isSeekingHQ = true
            playbackGeneration &+= 1
            let generationAtSchedule = playbackGeneration
            playerNode.stop()
            
            hqStartTimeOffset = clampedTime
            
            playerNode.scheduleSegment(file, startingFrame: startFrame, frameCount: AVAudioFrameCount(framesToPlay), at: nil) { [weak self] in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    // Ignore completion events that were caused by a seek or superseded schedule
                    if self.isSeekingHQ || generationAtSchedule != self.playbackGeneration { return }
                    self.updateIsPlaying(false)
                    self.currentTime = 0
                    self.postFinished()
                }
            }
            playerNode.play()
            
            // Maintain playing state
            updateIsPlaying(true)
            isSeekingHQ = false
        } else {
            // Seek in standard AVPlayer, preserve play/pause state
            let wasPlaying = isPlaying
            let cmTime = CMTime(seconds: time, preferredTimescale: 1000)
            player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    if wasPlaying { 
                        self.player?.play()
                        self.updateIsPlaying(true) 
                    } else { 
                        self.updateIsPlaying(false) 
                    }
                    self.updateNowPlayingInfo()
                }
            }
        }
        currentTime = time
    }
    
    func setAudioQuality(_ quality: AudioQuality) {
        audioQuality = quality
        setupHighQualityAudioSession()
    }
    
    private func startTimeObserver() {
        let interval = CMTime(seconds: 0.1, preferredTimescale: 1000)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.currentTime = CMTimeGetSeconds(time)
        }
    }
    
    private func stopTimeObserver() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
    }
    
    private func updateNowPlayingInfo() {
        let songTitle: String
        let songArtist: String
        let songAlbum: String?
        let songArtwork: String?
        
        if let song = currentSong {
            songTitle = song.title ?? "Unknown Title"
            songArtist = song.artist ?? "Unknown Artist"
            songAlbum = song.album
            songArtwork = song.artwork
        } else if let tempSong = currentTempSong {
            songTitle = tempSong.title
            songArtist = tempSong.artist
            songAlbum = tempSong.album
            songArtwork = tempSong.artwork
        } else {
            return
        }
        
        var nowPlayingInfo: [String: Any] = [
            MPMediaItemPropertyTitle: songTitle,
            MPMediaItemPropertyArtist: songArtist,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration
        ]
        
        if let album = songAlbum {
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = album
        }
        
        // Prefer local artwork for library songs if available
        if let libSong = currentSong, let id = libSong.id {
            let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let defaultLocal = documentsDirectory.appendingPathComponent("Artwork", isDirectory: true).appendingPathComponent("\(id.uuidString).jpg").path
            if FileManager.default.fileExists(atPath: defaultLocal), let image = UIImage(contentsOfFile: defaultLocal) {
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
                return
            }
        }

        if let artwork = songArtwork, let url = URL(string: artwork) {
            URLSession.shared.dataTask(with: url) { data, _, _ in
                if let data = data, let image = UIImage(data: data) {
                    let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
                } else {
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
                }
            }.resume()
        } else if let artworkPath = songArtwork, FileManager.default.fileExists(atPath: artworkPath), let image = UIImage(contentsOfFile: artworkPath) {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        } else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        }
    }
    
    @objc private func playerItemDidReachEnd(_ notification: Notification) {
        updateIsPlaying(false)
        currentTime = 0
        stopTimeObserver()
        postFinished()
    }
    
    private func postFinished() {
        NotificationCenter.default.post(name: .audioPlayerDidFinish, object: self)
    }
    
    private struct AssociatedKeys { 
        static var fallbackURLKey: UInt8 = 0
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "status" {
            if let playerItem = object as? AVPlayerItem {
                switch playerItem.status {
                case .readyToPlay:
                    print("Audio is ready to play")
                    updateIsPlaying(true)
                    // Record recently played for library song when streaming path used
                    if let s = currentSong { RecentlyPlayedStore.shared.record(s.id) }
                    updateNowPlayingInfo()
                case .failed:
                    print("Audio playback failed: \(playerItem.error?.localizedDescription ?? "Unknown error")")
                    // Try fallback URL if provided
                    if let fb = objc_getAssociatedObject(playerItem, &AssociatedKeys.fallbackURLKey) as? URL {
                        print("Retrying playback with fallback URL: \(fb.absoluteString)")
                        playWithAVPlayer(url: fb, fallbackURL: nil)
                    } else {
                        updateIsPlaying(false)
                        updateNowPlayingInfo()
                    }
                case .unknown:
                    print("Audio status unknown")
                @unknown default:
                    break
                }
            }
        }
    }
    
    deinit {
        stopTimeObserver()
        NotificationCenter.default.removeObserver(self)
        audioEngine?.stop()
    }
}

extension Notification.Name {
    static let audioPlayerDidFinish = Notification.Name("AudioPlayerDidFinish")
    static let remoteCommandNext = Notification.Name("RemoteCommandNext")
    static let remoteCommandPrevious = Notification.Name("RemoteCommandPrevious")
}
