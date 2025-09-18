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
    private var timeObserver: Any?
    private var audioEngine: AVAudioEngine?
    private var audioPlayerNode: AVAudioPlayerNode?
    private var audioFile: AVAudioFile?
    private var hqStartTimeOffset: Double = 0
    
    // High-quality audio settings
    private let sampleRate: Double = 96000.0  // 96kHz for high quality
    
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
    }
    
    private func observeInterruptions() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(handleInterruption(_:)),
                                               name: AVAudioSession.interruptionNotification,
                                               object: nil)
    }
    
    @objc private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        
        if type == .began {
            pause()
        } else if type == .ended {
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    resume()
                }
            }
        }
    }
    
    // MARK: - Play Song (Core Data)
    func play(song: Song) {
        // Stop any previous playback to avoid stale isPlaying state
        stop()
        
        // Set intent
        currentSong = song
        currentTempSong = nil
        
        // Try to play local FLAC file first
        if let localURL = DownloadManager.shared.getLocalFileURL(for: song) {
            playFromURL(localURL, isLocalFile: true)
        } else if let urlString = song.url, let url = URL(string: urlString) {
            // Fallback to streaming
            playFromURL(url, isLocalFile: false)
        } else {
            // Nothing to play; clear state
            isPlaying = false
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
            isPlaying = false
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
            
            // Attach player node to engine
            engine.attach(playerNode)
            
            // Connect to main mixer
            let mainMixer = engine.mainMixerNode
            engine.connect(playerNode, to: mainMixer, format: nil)
            
            // Create audio file
            audioFile = try AVAudioFile(forReading: url)
            
            guard let file = audioFile else {
                print("Failed to create audio file")
                playWithAVPlayer(url: url)
                return
            }
            
            // Configure for high quality
            let format = file.processingFormat
            print("Audio file format - Sample Rate: \(format.sampleRate)Hz, Channels: \(format.channelCount), Bit Depth: \(format.commonFormat.rawValue)")
            
            // Reset base offset
            hqStartTimeOffset = 0
            
            // Schedule the file for playback from start
            playerNode.scheduleFile(file, at: nil) { [weak self] in
                DispatchQueue.main.async {
                    self?.isPlaying = false
                    self?.currentTime = 0
                }
            }
            
            // Start the engine
            try engine.start()
            
            // Start playback
            playerNode.play()
            isPlaying = true
            
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
        // Create AVPlayerItem from URL
        let playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)
        
        // Add observer for when the item is ready to play
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemDidReachEnd),
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
        
        // Get duration
        let duration = playerItem.asset.duration
        self.duration = CMTimeGetSeconds(duration)
        
        // Start time observer
        startTimeObserver()
        updateNowPlayingInfo()
    }
    
    private func startHighQualityTimeObserver() {
        // For high-quality playback, we need to track time differently
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
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
        } else {
            player?.pause()
        }
        isPlaying = false
        updateNowPlayingInfo()
    }
    
    func resume() {
        if let playerNode = audioPlayerNode {
            playerNode.play()
            // Restart timer for high-quality playback to update currentTime
            startHighQualityTimeObserver()
        } else {
            player?.play()
        }
        isPlaying = true
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
        audioEngine?.stop()
        audioEngine = nil
        audioPlayerNode = nil
        audioFile = nil
        hqStartTimeOffset = 0
        
        // Stop AVPlayer
        player?.pause()
        player = nil
        
        isPlaying = false
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
            playerNode.stop()
            
            hqStartTimeOffset = clampedTime
            
            playerNode.scheduleSegment(file, startingFrame: startFrame, frameCount: AVAudioFrameCount(framesToPlay), at: nil) { [weak self] in
                DispatchQueue.main.async {
                    self?.isPlaying = false
                    self?.currentTime = 0
                }
            }
            playerNode.play()
            
            // Maintain playing state
            isPlaying = true
        } else {
            // Seek in standard AVPlayer
            let cmTime = CMTime(seconds: time, preferredTimescale: 1000)
            player?.seek(to: cmTime)
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
        } else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
        }
    }
    
    @objc private func playerItemDidReachEnd() {
        isPlaying = false
        currentTime = 0
        stopTimeObserver()
    }
    
    private struct AssociatedKeys { static var fallbackURLKey = "fallbackURLKey" }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "status" {
            if let playerItem = object as? AVPlayerItem {
                switch playerItem.status {
                case .readyToPlay:
                    print("Audio is ready to play")
                    isPlaying = true
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
                    isPlaying = false
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
