import Foundation
import Testing
@testable import KoalaSignagePlayer

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
    #expect(compareManifestVersion(installed: nil, remote: 2) == .updateAvailable)
    #expect(compareManifestVersion(installed: 1, remote: 2) == .updateAvailable)
    #expect(compareManifestVersion(installed: 2, remote: 2) == .upToDate)
    #expect(compareManifestVersion(installed: 3, remote: 2) == .localVersionAhead)
}

@Test func decodesLegacyStateWithoutInstalledPlaylistVersion() throws {
    let json = #"{"playerID":"4CD47053-E101-4D16-BEB1-201EBFF40D1E"}"#
    let state = try JSONDecoder().decode(PersistedState.self, from: Data(json.utf8))

    #expect(state.playerID == UUID(uuidString: "4CD47053-E101-4D16-BEB1-201EBFF40D1E"))
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
}
