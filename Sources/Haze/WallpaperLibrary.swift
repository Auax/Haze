import AppKit
import Foundation

struct Wallpaper: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
    let thumbnailURL: URL?
}

enum WallpaperLibrary {
    static func bundledWallpapers() -> [Wallpaper] {
        guard let url = Bundle.module.url(forResource: "Wallpapers", withExtension: "json")
            ?? Bundle.main.url(forResource: "Wallpapers", withExtension: "json")
        else { return [] }

        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([Wallpaper].self, from: data)
        } catch {
            return []
        }
    }
}

actor WallpaperImageStore {
    static let shared = WallpaperImageStore()

    private init() {}

    func localThumbnailURL(for wallpaper: Wallpaper) async throws -> URL {
        try await localCachedImageURL(
            for: wallpaper,
            sourceURL: wallpaper.thumbnailURL ?? wallpaper.url,
            filenameSuffix: "thumb",
            invalidMessage: "Downloaded wallpaper thumbnail is not a valid image."
        )
    }

    func localImageURL(for wallpaper: Wallpaper) async throws -> URL {
        try await localCachedImageURL(
            for: wallpaper,
            sourceURL: wallpaper.url,
            filenameSuffix: "full",
            invalidMessage: "Downloaded wallpaper is not a valid image."
        )
    }

    private func localCachedImageURL(
        for wallpaper: Wallpaper,
        sourceURL: URL,
        filenameSuffix: String,
        invalidMessage: String
    ) async throws -> URL {
        let directory = try cacheDirectory()
        let destination = directory
            .appendingPathComponent("\(wallpaper.id)-\(filenameSuffix)")
            .appendingPathExtension(Self.fileExtension(for: sourceURL))

        if FileManager.default.fileExists(atPath: destination.path),
           NSImage(contentsOf: destination) != nil {
            return destination
        }

        let (temporaryURL, response) = try await URLSession.shared.download(from: sourceURL)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw RecorderError.message("Could not download \(wallpaper.name).")
        }

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)

        guard NSImage(contentsOf: destination) != nil else {
            try? FileManager.default.removeItem(at: destination)
            throw RecorderError.message(invalidMessage)
        }

        return destination
    }

    private func cacheDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base
            .appendingPathComponent("Haze", isDirectory: true)
            .appendingPathComponent("Wallpapers", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func fileExtension(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? "jpg" : ext
    }
}
