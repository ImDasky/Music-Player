//
//  FLACMetadataExtractor.swift
//  Music
//
//  Created by Ben on 9/18/25.
//

import Foundation
import AVFoundation
import CoreData

class FLACMetadataExtractor {
    
    static func extractMetadata(from url: URL, for song: Song) {
        let asset = AVAsset(url: url)
        
        // Extract basic metadata
        let metadataItems = asset.metadata
        
        for item in metadataItems {
            guard let key = item.commonKey?.rawValue,
                  let value = item.value else { continue }
            
            switch key {
            case AVMetadataKey.commonKeyTitle.rawValue:
                if let title = value as? String, !title.isEmpty {
                    song.title = title
                }
                
            case AVMetadataKey.commonKeyArtist.rawValue:
                if let artist = value as? String, !artist.isEmpty {
                    song.artist = artist
                }
                
            case AVMetadataKey.commonKeyAlbumName.rawValue:
                if let album = value as? String, !album.isEmpty {
                    song.album = album
                }
                
            case AVMetadataKey.commonKeyArtwork.rawValue:
                if let data = value as? Data {
                    saveArtwork(data: data, for: song)
                }
                
            default:
                break
            }
        }
        
        // Try to get artwork from other metadata formats
        extractArtworkFromMetadata(metadataItems, for: song)
        
        // Save the updated song
        try? song.managedObjectContext?.save()
    }
    
    private static func extractArtworkFromMetadata(_ metadataItems: [AVMetadataItem], for song: Song) {
        // Look for artwork in various metadata formats
        for item in metadataItems {
            if let key = item.key as? String {
                if key.contains("artwork") || key.contains("cover") || key.contains("picture") {
                    if let data = item.value as? Data {
                        saveArtwork(data: data, for: song)
                        break
                    }
                }
            }
        }
        
        // Also try to extract from common key artwork
        for item in metadataItems {
            if item.commonKey == .commonKeyArtwork {
                if let data = item.value as? Data {
                    saveArtwork(data: data, for: song)
                    break
                }
            }
        }
    }
    
    private static func saveArtwork(data: Data, for song: Song) {
        // Create artwork directory if it doesn't exist
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let artworkDirectory = documentsDirectory.appendingPathComponent("Artwork", isDirectory: true)
        
        if !FileManager.default.fileExists(atPath: artworkDirectory.path) {
            try? FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        }
        
        let artworkFileName = "\(song.id?.uuidString ?? UUID().uuidString).jpg"
        let artworkURL = artworkDirectory.appendingPathComponent(artworkFileName)
        
        do {
            try data.write(to: artworkURL)
            song.artwork = artworkURL.path
            print("Artwork saved to: \(artworkURL.path)")
        } catch {
            print("Failed to save artwork: \(error)")
        }
    }
    
    static func getArtworkImage(for song: Song) -> Data? {
        guard let artworkPath = song.artwork,
              FileManager.default.fileExists(atPath: artworkPath) else { return nil }
        
        return try? Data(contentsOf: URL(fileURLWithPath: artworkPath))
    }
}
