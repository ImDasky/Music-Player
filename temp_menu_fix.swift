            Menu {
                Button("Play Next", action: { player.addToPlayNext(song) })
                Button("Play Last", action: { player.addToPlayLast(song) })
                Button("Add to Playlist", action: { /* TODO: hook up playlists */ })
                Button("Delete from Library", role: .destructive, action: { libraryManager.deleteSong(song) })
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundColor(.white.opacity(0.7))
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
