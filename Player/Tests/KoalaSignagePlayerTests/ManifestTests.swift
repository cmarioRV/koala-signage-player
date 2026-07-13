import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import KoalaSignagePlayer

private final class MediaURLProtocolStub: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "3"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data([0x01, 0x02, 0x03]))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Test func decodesConfirmedServerManifestContract() throws {
    let json = #"""
    {
      "items": [
        {
          "sizeBytes": 13046882,
          "durationSeconds": 14.96,
          "name": "Video principal Koala",
          "id": "BAFCF25D-41B0-4734-9EC5-F39B5875790E",
          "relativeURL": "/media/video_16_3_formatted.mp4",
          "sha256": "eadc38e4c646c1255a95f28e626b927650b6140d001dd9cd2d23df12dd229197",
          "position": 0,
          "filename": "video_16_3_formatted.mp4"
        }
      ],
      "playlistID": "BE7714C5-BA21-4E57-AF9E-1B0E1CD6DB37",
      "version": 2,
      "generatedAt": "2026-07-13T04:47:51Z"
    }
    """#

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(ManifestResponse.self, from: Data(json.utf8))

    #expect(manifest.playlistID == UUID(uuidString: "BE7714C5-BA21-4E57-AF9E-1B0E1CD6DB37"))
    #expect(manifest.version == 2)
    #expect(manifest.items.count == 1)
    #expect(manifest.items[0].id == UUID(uuidString: "BAFCF25D-41B0-4734-9EC5-F39B5875790E"))
    #expect(manifest.items[0].relativeURL == "/media/video_16_3_formatted.mp4")
    #expect(manifest.items[0].durationSeconds == 14.96)
}

@Test func comparesInstalledAndRemoteManifestVersions() {
    let installedPlaylistID = UUID()
    let differentPlaylistID = UUID()

    #expect(compareManifest(
        installedPlaylistID: nil,
        installedVersion: nil,
        remotePlaylistID: installedPlaylistID,
        remoteVersion: 2
    ) == .updateAvailable)
    #expect(compareManifest(
        installedPlaylistID: installedPlaylistID,
        installedVersion: 1,
        remotePlaylistID: installedPlaylistID,
        remoteVersion: 2
    ) == .updateAvailable)
    #expect(compareManifest(
        installedPlaylistID: installedPlaylistID,
        installedVersion: 2,
        remotePlaylistID: installedPlaylistID,
        remoteVersion: 2
    ) == .upToDate)
    #expect(compareManifest(
        installedPlaylistID: installedPlaylistID,
        installedVersion: 3,
        remotePlaylistID: installedPlaylistID,
        remoteVersion: 2
    ) == .localVersionAhead)
    #expect(compareManifest(
        installedPlaylistID: installedPlaylistID,
        installedVersion: 2,
        remotePlaylistID: differentPlaylistID,
        remoteVersion: 2
    ) == .updateAvailable)
}

@Test func decodesLegacyStateWithoutInstalledPlaylistVersion() throws {
    let json = #"{"playerID":"4CD47053-E101-4D16-BEB1-201EBFF40D1E"}"#
    let state = try JSONDecoder().decode(PersistedState.self, from: Data(json.utf8))

    #expect(state.playerID == UUID(uuidString: "4CD47053-E101-4D16-BEB1-201EBFF40D1E"))
    #expect(state.installedPlaylistID == nil)
    #expect(state.installedPlaylistVersion == nil)
}

@Test func defaultsManifestPollingIntervalForExistingConfiguration() throws {
    let json = #"""
    {
      "contentDirectory": "/var/lib/koala-signage/content",
      "playlistPath": "/var/lib/koala-signage/playlists/current.m3u",
      "mpvExecutable": "/usr/bin/mpv",
      "mpvSocketPath": "/tmp/koala-signage-mpv.sock",
      "scanIntervalSeconds": 3,
      "serverURL": "http://192.168.1.25:8080",
      "playerName": "Koala Wall 01",
      "installationID": "koala-wall-01",
      "appVersion": "0.1.2",
      "heartbeatIntervalSeconds": 30,
      "stateFilePath": "/var/lib/koala-signage/state/player-state.json"
    }
    """#

    let configuration = try JSONDecoder().decode(Configuration.self, from: Data(json.utf8))

    #expect(configuration.manifestPollIntervalSeconds == 30)
    #expect(configuration.stagingDirectory == "/var/lib/koala-signage/staging")
}

@Test func validatesManifestFilenamesBeforeBuildingLocalPaths() {
    #expect(safeManifestFilename("video_16_3_formatted.mp4") == "video_16_3_formatted.mp4")
    #expect(safeManifestFilename("../config.json") == nil)
    #expect(safeManifestFilename("nested/video.mp4") == nil)
    #expect(safeManifestFilename("nested\\video.mp4") == nil)
    #expect(safeManifestFilename("#comment.mp4") == nil)
    #expect(safeManifestFilename("video\nnext.mp4") == nil)
}

@Test func resolvesOnlyRelativeServerMediaURLs() throws {
    let baseURL = try #require(URL(string: "http://192.168.1.25:8080"))

    #expect(
        resolveManifestMediaURL(baseURL: baseURL, relativeURL: "/media/video.mp4")
            == URL(string: "http://192.168.1.25:8080/media/video.mp4")
    )
    #expect(resolveManifestMediaURL(baseURL: baseURL, relativeURL: "https://example.com/video.mp4") == nil)
    #expect(resolveManifestMediaURL(baseURL: baseURL, relativeURL: "media/video.mp4") == nil)
}

@Test func recognizesOnlyRegularFilesWithTheExpectedSize() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let file = directory.appendingPathComponent("asset.mp4")
    try Data([0x01, 0x02, 0x03]).write(to: file)

    #expect(fileMatchesExpectedSize(at: file, expectedSize: 3))
    #expect(!fileMatchesExpectedSize(at: file, expectedSize: 2))
    #expect(!fileMatchesExpectedSize(at: directory, expectedSize: 3))
}

@Test func downloadsMissingAssetToStagingWithoutChangingContent() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let content = root.appendingPathComponent("content", isDirectory: true)
    let staging = root.appendingPathComponent("staging", isDirectory: true)
    try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [MediaURLProtocolStub.self]
    let session = URLSession(configuration: sessionConfiguration)
    let manager = try DownloadManager(
        serverURL: "http://192.168.1.25:8080",
        contentDirectory: content.path,
        stagingDirectory: staging.path,
        logger: Logger(),
        session: session
    )
    let item = ManifestItem(
        id: UUID(),
        name: "Video principal Koala",
        filename: "video.mp4",
        relativeURL: "/media/video.mp4",
        sha256: "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81",
        sizeBytes: 3,
        durationSeconds: 1,
        position: 0
    )
    let manifest = ManifestResponse(
        playlistID: UUID(),
        version: 2,
        generatedAt: Date(),
        items: [item]
    )

    let firstSummary = try await manager.stageMissingAssets(from: manifest)
    let secondSummary = try await manager.stageMissingAssets(from: manifest)
    let release = try await manager.prepareRelease(from: manifest)
    let reusedRelease = try await manager.prepareRelease(from: manifest)

    #expect(firstSummary == DownloadSummary(downloaded: 1, skipped: 0, failed: 0))
    #expect(secondSummary == DownloadSummary(downloaded: 0, skipped: 1, failed: 0))
    #expect(try Data(contentsOf: staging.appendingPathComponent("video.mp4")) == Data([0x01, 0x02, 0x03]))
    #expect(!FileManager.default.fileExists(atPath: content.appendingPathComponent("video.mp4").path))
    #expect(!FileManager.default.fileExists(atPath: staging.appendingPathComponent("video.mp4.part").path))
    #expect(release.playlistID == manifest.playlistID)
    #expect(release.version == manifest.version)
    #expect(release.entries.count == 1)
    #expect(reusedRelease == release)
    #expect(release.entries[0].contains("/.remote/"))
    #expect(try Data(contentsOf: URL(fileURLWithPath: release.entries[0])) == Data([0x01, 0x02, 0x03]))
    #expect(FileManager.default.fileExists(atPath: staging.appendingPathComponent("video.mp4").path))

    let releasesRoot = URL(fileURLWithPath: release.directory).deletingLastPathComponent()
    let newerPreviousRelease = releasesRoot.appendingPathComponent("previous-newer", isDirectory: true)
    let olderPreviousRelease = releasesRoot.appendingPathComponent("previous-older", isDirectory: true)
    let interruptedRelease = releasesRoot.appendingPathComponent(".pending-interrupted", isDirectory: true)

    for directory in [newerPreviousRelease, olderPreviousRelease, interruptedRelease] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0x04]).write(to: directory.appendingPathComponent("video.mp4"))
    }
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 200)],
        ofItemAtPath: newerPreviousRelease.path
    )
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 100)],
        ofItemAtPath: olderPreviousRelease.path
    )

    let cleanup = try await manager.cleanupAfterActivation(activeRelease: release)

    #expect(cleanup.stagingEntriesRemoved == 1)
    #expect(cleanup.releasesRemoved == 2)
    #expect(cleanup.previousReleaseKept.map { URL(fileURLWithPath: $0).lastPathComponent } == "previous-newer")
    #expect(!FileManager.default.fileExists(atPath: staging.appendingPathComponent("video.mp4").path))
    #expect(FileManager.default.fileExists(atPath: release.directory))
    #expect(FileManager.default.fileExists(atPath: newerPreviousRelease.path))
    #expect(!FileManager.default.fileExists(atPath: olderPreviousRelease.path))
    #expect(!FileManager.default.fileExists(atPath: interruptedRelease.path))
}

@Test func calculatesSHA256ForAFileWithoutLoadingItIntoThePlayer() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let file = directory.appendingPathComponent("asset.mp4")
    try Data([0x01, 0x02, 0x03]).write(to: file)

    #expect(
        try SHA256Hasher().hashFile(at: file)
            == "039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81"
    )
    #expect(normalizedSHA256(String(repeating: "A", count: 64)) == String(repeating: "a", count: 64))
    #expect(normalizedSHA256("not-a-checksum") == nil)
}

@Test func rejectsChecksumMismatchWithoutFinalizingStagedFile() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let content = root.appendingPathComponent("content", isDirectory: true)
    let staging = root.appendingPathComponent("staging", isDirectory: true)
    try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let sessionConfiguration = URLSessionConfiguration.ephemeral
    sessionConfiguration.protocolClasses = [MediaURLProtocolStub.self]
    let manager = try DownloadManager(
        serverURL: "http://192.168.1.25:8080",
        contentDirectory: content.path,
        stagingDirectory: staging.path,
        logger: Logger(),
        session: URLSession(configuration: sessionConfiguration)
    )
    let item = ManifestItem(
        id: UUID(),
        name: "Corrupted video",
        filename: "corrupted.mp4",
        relativeURL: "/media/corrupted.mp4",
        sha256: String(repeating: "0", count: 64),
        sizeBytes: 3,
        durationSeconds: 1,
        position: 0
    )
    let manifest = ManifestResponse(
        playlistID: UUID(),
        version: 3,
        generatedAt: Date(),
        items: [item]
    )

    let summary = try await manager.stageMissingAssets(from: manifest)

    #expect(summary == DownloadSummary(downloaded: 0, skipped: 0, failed: 1))
    #expect(!FileManager.default.fileExists(atPath: staging.appendingPathComponent("corrupted.mp4").path))
    #expect(!FileManager.default.fileExists(atPath: staging.appendingPathComponent("corrupted.mp4.part").path))
}

@Test func persistsInstalledPlaylistIdentityAndVersion() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let stateFile = directory.appendingPathComponent("player-state.json")
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = StateStore(path: stateFile.path)
    let state = PersistedState(
        playerID: UUID(),
        installedPlaylistID: UUID(),
        installedPlaylistVersion: 4
    )
    try store.save(state)

    let restored = store.load()
    #expect(restored.playerID == state.playerID)
    #expect(restored.installedPlaylistID == state.installedPlaylistID)
    #expect(restored.installedPlaylistVersion == 4)
}

@Test func restoresOnlyCompleteAndUsableRemotePlaylistState() {
    let completeState = PersistedState(
        playerID: UUID(),
        installedPlaylistID: UUID(),
        installedPlaylistVersion: 4
    )
    let incompleteState = PersistedState(
        playerID: UUID(),
        installedPlaylistID: nil,
        installedPlaylistVersion: 4
    )

    #expect(shouldRestoreRemotePlaylist(state: completeState, playlistIsUsable: true))
    #expect(!shouldRestoreRemotePlaylist(state: completeState, playlistIsUsable: false))
    #expect(!shouldRestoreRemotePlaylist(state: incompleteState, playlistIsUsable: true))
}

@Test func atomicallyWritesAUsableRemotePlaylist() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let content = root.appendingPathComponent("content", isDirectory: true)
    let playlist = root.appendingPathComponent("playlists/current.m3u")
    let asset = root.appendingPathComponent("release/video.mp4")
    try FileManager.default.createDirectory(
        at: asset.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data([0x01]).write(to: asset)
    defer { try? FileManager.default.removeItem(at: root) }

    let configurationData = try JSONSerialization.data(withJSONObject: [
        "contentDirectory": content.path,
        "playlistPath": playlist.path,
        "mpvExecutable": "/usr/bin/mpv",
        "mpvSocketPath": root.appendingPathComponent("mpv.sock").path,
        "scanIntervalSeconds": 3,
        "serverURL": "http://192.168.1.25:8080",
        "playerName": "Koala Wall 01",
        "installationID": "koala-wall-01",
        "appVersion": "0.1.6",
        "heartbeatIntervalSeconds": 30,
        "manifestPollIntervalSeconds": 30,
        "stateFilePath": root.appendingPathComponent("state.json").path
    ])
    let configuration = try JSONDecoder().decode(Configuration.self, from: configurationData)
    let manager = PlaylistManager(config: configuration, logger: Logger())

    try manager.write(entries: [asset.path], description: "remote")

    #expect(manager.currentPlaylistIsUsable())
    #expect(try String(contentsOf: playlist, encoding: .utf8) == asset.path + "\n")
    try FileManager.default.removeItem(at: asset)
    #expect(!manager.currentPlaylistIsUsable())
}
