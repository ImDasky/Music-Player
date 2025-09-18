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
    
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var audioEngine: AVAudioEngine?
    private var audioPlayerNode: AVAudioPlayerNode?
    private var audioFile: AVAudioFile?
    
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
        currentSong = song
        currentTempSong = nil
        
        // Try to play local FLAC file first
        if let localURL = DownloadManager.shared.getLocalFileURL(for: song) {
            playFromURL(localURL, isLocalFile: true)
        } else if let urlString = song.url, let url = URL(string: urlString) {
            // Fallback to streaming
            playFromURL(url, isLocalFile: false)
        }
    }
    
    // MARK: - Play Temp Song (Streaming)
    func play(tempSong: TempSong) {
        currentTempSong = tempSong
        currentSong = nil
        
        if let urlString = tempSong.url, let url = URL(string: urlString) {
            playFromURL(url, isLocalFile: false)
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
            playWithAVPlayer(url: url)
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
            
            // Schedule the file for playback
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
            
            print("High-quality FLAC playback started")
            
        } catch {
            print("Failed to setup high-quality FLAC playback: \(error)")
            // Fallback to standard AVPlayer
            playWithAVPlayer(url: url)
        }
    }
    
    private func playWithAVPlayer(url: URL) {
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
            
            // Calculate current time based on player node
            if let lastRenderTime = playerNode.lastRenderTime,
               let playerTime = playerNode.playerTime(forNodeTime: lastRenderTime) {
                self.currentTime = Double(playerTime.sampleTime) / playerTime.sampleRate
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
    }
    
    func resume() {
        if let playerNode = audioPlayerNode {
            playerNode.play()
        } else {
            player?.play()
        }
        isPlaying = true
    }
    
    func stop() {
        // Stop high-quality engine
        audioEngine?.stop()
        audioEngine = nil
        audioPlayerNode = nil
        audioFile = nil
        
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
            // Seek in high-quality playback
            let sampleTime = AVAudioFramePosition(time * file.processingFormat.sampleRate)
            let playerTime = AVAudioTime(sampleTime: sampleTime, atRate: file.processingFormat.sampleRate)
            playerNode.stop()
            playerNode.scheduleFile(file, at: playerTime) { [weak self] in
                DispatchQueue.main.async {
                    self?.isPlaying = false
                    self?.currentTime = 0
                }
            }
            playerNode.play()
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
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "status" {
            if let playerItem = object as? AVPlayerItem {
                switch playerItem.status {
                case .readyToPlay:
                    print("Audio is ready to play")
                    isPlaying = true
                    updateNowPlayingInfo()
                case .failed:
                    print("Audio playback failed: \(playerItem.error?.localizedDescription ?? "Unknown error")")
                    isPlaying = false
                    updateNowPlayingInfo()
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
