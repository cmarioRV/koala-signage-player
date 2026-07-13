import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if os(Linux)
import Glibc
#else
import Darwin
#endif

struct Configuration: Decodable, Sendable {
    let contentDirectory: String
    let playlistPath: String
    let mpvExecutable: String
    let mpvSocketPath: String
    let scanIntervalSeconds: UInt64
    let serverURL: String
    let playerName: String
    let installationID: String
    let appVersion: String
    let heartbeatIntervalSeconds: UInt64
    let manifestPollIntervalSeconds: UInt64
    let stagingDirectory: String
    let stateFilePath: String

    private enum CodingKeys: String, CodingKey {
        case contentDirectory
        case playlistPath
        case mpvExecutable
        case mpvSocketPath
        case scanIntervalSeconds
        case serverURL
        case playerName
        case installationID
        case appVersion
        case heartbeatIntervalSeconds
        case manifestPollIntervalSeconds
        case stagingDirectory
        case stateFilePath
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contentDirectory = try container.decode(String.self, forKey: .contentDirectory)
        playlistPath = try container.decode(String.self, forKey: .playlistPath)
        mpvExecutable = try container.decode(String.self, forKey: .mpvExecutable)
        mpvSocketPath = try container.decode(String.self, forKey: .mpvSocketPath)
        scanIntervalSeconds = try container.decode(UInt64.self, forKey: .scanIntervalSeconds)
        serverURL = try container.decode(String.self, forKey: .serverURL)
        playerName = try container.decode(String.self, forKey: .playerName)
        installationID = try container.decode(String.self, forKey: .installationID)
        appVersion = try container.decode(String.self, forKey: .appVersion)
        heartbeatIntervalSeconds = try container.decode(UInt64.self, forKey: .heartbeatIntervalSeconds)
        manifestPollIntervalSeconds = try container.decodeIfPresent(
            UInt64.self,
            forKey: .manifestPollIntervalSeconds
        ) ?? 30
        stagingDirectory = try container.decodeIfPresent(String.self, forKey: .stagingDirectory)
            ?? URL(fileURLWithPath: contentDirectory)
                .deletingLastPathComponent()
                .appendingPathComponent("staging", isDirectory: true)
                .path
        stateFilePath = try container.decode(String.self, forKey: .stateFilePath)
    }
}

struct RegisterPlayerRequest: Encodable {
    let name: String
    let installationID: String
    let appVersion: String
}

struct PlayerResponse: Decodable {
    let id: UUID
    let name: String
    let installationID: String
    let appVersion: String?
    let lastSeenAt: Date?
    let createdAt: Date?
}

struct HeartbeatRequest: Encodable {
    let appVersion: String
    let currentAssetID: UUID?
    let installedPlaylistVersion: Int?
    let freeStorageBytes: Int64?
}

struct PersistedState: Codable {
    var playerID: UUID?
    var installedPlaylistVersion: Int?

    init(playerID: UUID?, installedPlaylistVersion: Int? = nil) {
        self.playerID = playerID
        self.installedPlaylistVersion = installedPlaylistVersion
    }
}

struct ManifestResponse: Decodable, Equatable, Sendable {
    let playlistID: UUID
    let version: Int
    let generatedAt: Date
    let items: [ManifestItem]
}

struct ManifestItem: Decodable, Equatable, Sendable {
    let id: UUID
    let name: String
    let filename: String
    let relativeURL: String
    let sha256: String
    let sizeBytes: Int64
    let durationSeconds: Double?
    let position: Int
}

enum ManifestVersionComparison: Equatable {
    case updateAvailable
    case upToDate
    case localVersionAhead
}

func compareManifestVersion(installed: Int?, remote: Int) -> ManifestVersionComparison {
    guard let installed else { return .updateAvailable }
    if remote > installed { return .updateAvailable }
    if remote == installed { return .upToDate }
    return .localVersionAhead
}

enum AgentError: Error, CustomStringConvertible {
    case invalidArguments
    case invalidServerURL
    case invalidResponse
    case unexpectedStatus(Int)
    case socketConnectionFailed(Int32)
    case unsafeManifestFilename(String)
    case invalidMediaURL(String)
    case downloadedSizeMismatch(filename: String, expected: Int64, actual: Int64)

    var description: String {
        switch self {
        case .invalidArguments: return "Usage: koala-signage-player --config <path>"
        case .invalidServerURL: return "The server URL is invalid."
        case .invalidResponse: return "The server returned an invalid response."
        case .unexpectedStatus(let status): return "Unexpected HTTP status: \(status)"
        case .socketConnectionFailed(let code): return "Could not connect to mpv IPC socket. errno=\(code)"
        case .unsafeManifestFilename(let filename): return "Unsafe manifest filename: \(filename)"
        case .invalidMediaURL(let path): return "Invalid media URL in manifest: \(path)"
        case let .downloadedSizeMismatch(filename, expected, actual):
            return "Downloaded size mismatch for \(filename). Expected \(expected) bytes, received \(actual)."
        }
    }
}

struct Logger {
    func log(_ message: String) {
        let formatter = ISO8601DateFormatter()
        print("[\(formatter.string(from: Date()))] \(message)")
    }
}

final class StateStore: @unchecked Sendable {
    private let path: String
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(path: String) {
        self.path = path
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() -> PersistedState {
        guard let data = FileManager.default.contents(atPath: path),
              let state = try? decoder.decode(PersistedState.self, from: data) else {
            return PersistedState(playerID: nil)
        }
        return state
    }

    func save(_ state: PersistedState) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(state)
        try data.write(to: url, options: .atomic)
    }
}

actor ServerClient {
    private let baseURL: URL
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(serverURL: String) throws {
        guard let url = URL(string: serverURL) else { throw AgentError.invalidServerURL }
        self.baseURL = url
        self.session = URLSession(configuration: .default)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    func register(name: String, installationID: String, appVersion: String) async throws -> PlayerResponse {
        let url = baseURL.appending(path: "api/v1/players/register")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(RegisterPlayerRequest(
            name: name,
            installationID: installationID,
            appVersion: appVersion
        ))

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AgentError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw AgentError.unexpectedStatus(http.statusCode) }
        return try decoder.decode(PlayerResponse.self, from: data)
    }

    func sendHeartbeat(playerID: UUID, payload: HeartbeatRequest) async throws {
        let url = baseURL.appending(path: "api/v1/players/\(playerID.uuidString)/heartbeat")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(payload)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AgentError.invalidResponse }
        guard http.statusCode == 204 else { throw AgentError.unexpectedStatus(http.statusCode) }
    }

    func fetchManifest(playerID: UUID) async throws -> ManifestResponse {
        let url = baseURL.appending(path: "api/v1/players/\(playerID.uuidString)/manifest")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AgentError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw AgentError.unexpectedStatus(http.statusCode)
        }
        return try decoder.decode(ManifestResponse.self, from: data)
    }
}

struct PlaylistSnapshot: Equatable {
    let entries: [String]
    let fingerprint: String
}

final class PlaylistManager: @unchecked Sendable {
    private let config: Configuration
    private let logger: Logger

    init(config: Configuration, logger: Logger) {
        self.config = config
        self.logger = logger
    }

    func snapshot() throws -> PlaylistSnapshot {
        let directory = URL(fileURLWithPath: config.contentDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        .filter { ["mp4", "mov", "mkv", "webm"].contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        var fingerprintParts: [String] = []
        for file in files {
            let values = try file.resourceValues(forKeys: keys)
            let size = values.fileSize ?? 0
            let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            fingerprintParts.append("\(file.path)|\(size)|\(modified)")
        }
        return PlaylistSnapshot(entries: files.map(\.path), fingerprint: fingerprintParts.joined(separator: "\n"))
    }

    func write(_ snapshot: PlaylistSnapshot) throws {
        guard !snapshot.entries.isEmpty else {
            logger.log("Content directory is empty; keeping the current playlist.")
            return
        }
        let playlistURL = URL(fileURLWithPath: config.playlistPath)
        try FileManager.default.createDirectory(
            at: playlistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let body = snapshot.entries.joined(separator: "\n") + "\n"
        try body.write(to: playlistURL, atomically: true, encoding: .utf8)
        logger.log("Playlist generated with \(snapshot.entries.count) file(s).")
    }
}

final class MPVClient: @unchecked Sendable {
    private let socketPath: String

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func send(command: [String]) throws {
        #if os(Linux)
        let socketType = Int32(SOCK_STREAM.rawValue)
        #else
        let socketType = SOCK_STREAM
        #endif
        let descriptor = socket(AF_UNIX, socketType, 0)
        guard descriptor >= 0 else { throw AgentError.socketConnectionFailed(errno) }
        defer { close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < maxLength else { throw AgentError.socketConnectionFailed(ENAMETOOLONG) }

        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxLength) { chars in
                _ = socketPath.withCString { source in strcpy(chars, source) }
            }
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { throw AgentError.socketConnectionFailed(errno) }

        let payload = try JSONSerialization.data(withJSONObject: ["command": command]) + Data([0x0A])
        try payload.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var sent = 0
            while sent < buffer.count {
                let count = write(descriptor, base.advanced(by: sent), buffer.count - sent)
                guard count > 0 else { throw AgentError.socketConnectionFailed(errno) }
                sent += count
            }
        }
    }
}

final class MPVManager: @unchecked Sendable {
    private let config: Configuration
    private let logger: Logger
    private var process: Process?

    init(config: Configuration, logger: Logger) {
        self.config = config
        self.logger = logger
    }

    func ensureRunning() throws {
        if FileManager.default.fileExists(atPath: config.mpvSocketPath) {
            do {
                try MPVClient(socketPath: config.mpvSocketPath).send(command: ["get_property", "idle-active"])
                return
            } catch {
                logger.log("Stale mpv socket detected; removing it.")
                try? FileManager.default.removeItem(atPath: config.mpvSocketPath)
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.mpvExecutable)
        process.arguments = [
            "--fullscreen",
            "--no-border",
            "--idle=yes",
            "--loop-playlist=inf",
            "--hwdec=auto-safe",
            "--keep-open=yes",
            "--really-quiet",
            "--input-ipc-server=\(config.mpvSocketPath)",
            "--playlist=\(config.playlistPath)"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        try process.run()
        self.process = process
        logger.log("mpv launched with PID \(process.processIdentifier).")
    }

    func reloadPlaylist() throws {
        let client = MPVClient(socketPath: config.mpvSocketPath)
        var lastError: Error?
        for _ in 0..<20 {
            do {
                try client.send(command: ["loadlist", config.playlistPath, "replace"])
                logger.log("Playlist loaded through mpv IPC.")
                return
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        throw lastError ?? AgentError.invalidResponse
    }
}

func freeStorageBytes(at path: String) -> Int64? {
    guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: path),
          let value = attributes[.systemFreeSize] as? NSNumber else { return nil }
    return value.int64Value
}

struct DownloadSummary: Equatable, Sendable {
    var downloaded = 0
    var skipped = 0
    var failed = 0
}

func safeManifestFilename(_ filename: String) -> String? {
    guard !filename.isEmpty,
          filename != ".",
          filename != "..",
          !filename.contains("/"),
          !filename.contains("\\"),
          URL(fileURLWithPath: filename).lastPathComponent == filename else {
        return nil
    }
    return filename
}

func resolveManifestMediaURL(baseURL: URL, relativeURL: String) -> URL? {
    guard relativeURL.hasPrefix("/"),
          let components = URLComponents(string: relativeURL),
          components.scheme == nil,
          components.host == nil else {
        return nil
    }
    return URL(string: relativeURL, relativeTo: baseURL)?.absoluteURL
}

func fileMatchesExpectedSize(at url: URL, expectedSize: Int64) -> Bool {
    guard expectedSize >= 0,
          let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          let fileType = attributes[.type] as? FileAttributeType,
          fileType == .typeRegular,
          let size = attributes[.size] as? NSNumber else {
        return false
    }
    return size.int64Value == expectedSize
}

actor DownloadManager {
    private let baseURL: URL
    private let contentDirectory: URL
    private let stagingDirectory: URL
    private let logger: Logger
    private let session: URLSession
    private let fileManager: FileManager

    init(
        serverURL: String,
        contentDirectory: String,
        stagingDirectory: String,
        logger: Logger,
        session: URLSession = .shared,
        fileManager: FileManager = .default
    ) throws {
        guard let baseURL = URL(string: serverURL) else { throw AgentError.invalidServerURL }
        self.baseURL = baseURL
        self.contentDirectory = URL(fileURLWithPath: contentDirectory, isDirectory: true)
        self.stagingDirectory = URL(fileURLWithPath: stagingDirectory, isDirectory: true)
        self.logger = logger
        self.session = session
        self.fileManager = fileManager
    }

    func stageMissingAssets(from manifest: ManifestResponse) async throws -> DownloadSummary {
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        var summary = DownloadSummary()

        for item in manifest.items.sorted(by: { $0.position < $1.position }) {
            do {
                let filename = try validatedFilename(for: item)
                let contentURL = contentDirectory.appendingPathComponent(filename, isDirectory: false)
                let stagedURL = stagingDirectory.appendingPathComponent(filename, isDirectory: false)

                if fileMatchesExpectedSize(at: contentURL, expectedSize: item.sizeBytes) {
                    logger.log("Asset already available in content; skipping: \(filename)")
                    summary.skipped += 1
                    continue
                }

                if fileMatchesExpectedSize(at: stagedURL, expectedSize: item.sizeBytes) {
                    logger.log("Asset already staged; skipping: \(filename)")
                    summary.skipped += 1
                    continue
                }

                try await download(item: item, filename: filename, destination: stagedURL)
                summary.downloaded += 1
            } catch {
                summary.failed += 1
                logger.log("Asset download failed for \(item.filename). Error: \(error)")
            }
        }

        return summary
    }

    private func validatedFilename(for item: ManifestItem) throws -> String {
        guard let filename = safeManifestFilename(item.filename) else {
            throw AgentError.unsafeManifestFilename(item.filename)
        }
        return filename
    }

    private func download(item: ManifestItem, filename: String, destination: URL) async throws {
        guard let sourceURL = resolveManifestMediaURL(baseURL: baseURL, relativeURL: item.relativeURL) else {
            throw AgentError.invalidMediaURL(item.relativeURL)
        }

        logger.log("Downloading asset to staging: \(filename)")
        let (temporaryURL, response) = try await session.download(from: sourceURL)
        guard let http = response as? HTTPURLResponse else { throw AgentError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw AgentError.unexpectedStatus(http.statusCode)
        }

        let actualSize = try fileSize(at: temporaryURL)
        guard actualSize == item.sizeBytes else {
            throw AgentError.downloadedSizeMismatch(
                filename: filename,
                expected: item.sizeBytes,
                actual: actualSize
            )
        }

        let partialURL = destination.appendingPathExtension("part")
        try? fileManager.removeItem(at: partialURL)
        defer { try? fileManager.removeItem(at: partialURL) }

        try fileManager.copyItem(at: temporaryURL, to: partialURL)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: partialURL, to: destination)
        logger.log("Asset downloaded to staging: \(filename) (\(actualSize) bytes).")
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw AgentError.invalidResponse
        }
        return size.int64Value
    }
}

@main
enum KoalaSignagePlayer {
    static func main() async {
        let logger = Logger()
        do {
            let arguments = CommandLine.arguments
            guard let index = arguments.firstIndex(of: "--config"), arguments.indices.contains(index + 1) else {
                throw AgentError.invalidArguments
            }

            let configData = try Data(contentsOf: URL(fileURLWithPath: arguments[index + 1]))
            let config = try JSONDecoder().decode(Configuration.self, from: configData)
            logger.log("Koala Signage Player starting.")

            let playlistManager = PlaylistManager(config: config, logger: logger)
            let mpvManager = MPVManager(config: config, logger: logger)
            let stateStore = StateStore(path: config.stateFilePath)
            let serverClient = try ServerClient(serverURL: config.serverURL)
            let downloadManager = try DownloadManager(
                serverURL: config.serverURL,
                contentDirectory: config.contentDirectory,
                stagingDirectory: config.stagingDirectory,
                logger: logger
            )

            var snapshot = try playlistManager.snapshot()
            try playlistManager.write(snapshot)
            try mpvManager.ensureRunning()
            try mpvManager.reloadPlaylist()

            var state = stateStore.load()
            do {
                let response = try await serverClient.register(
                    name: config.playerName,
                    installationID: config.installationID,
                    appVersion: config.appVersion
                )
                state.playerID = response.id
                try stateStore.save(state)
                logger.log("Player registered with server: \(response.id.uuidString)")
            } catch {
                logger.log("Server registration failed; local playback will continue. Error: \(error)")
            }

            let heartbeatTask = Task {
                while !Task.isCancelled {
                    if let playerID = stateStore.load().playerID {
                        do {
                            try await serverClient.sendHeartbeat(
                                playerID: playerID,
                                payload: HeartbeatRequest(
                                    appVersion: config.appVersion,
                                    currentAssetID: nil,
                                    installedPlaylistVersion: stateStore.load().installedPlaylistVersion,
                                    freeStorageBytes: freeStorageBytes(at: config.contentDirectory)
                                )
                            )
                            logger.log("Heartbeat sent successfully.")
                        } catch {
                            logger.log("Heartbeat failed; playback is unaffected. Error: \(error)")
                        }
                    }
                    try? await Task.sleep(for: .seconds(config.heartbeatIntervalSeconds))
                }
            }

            let manifestTask = Task {
                while !Task.isCancelled {
                    if let playerID = stateStore.load().playerID {
                        do {
                            let manifest = try await serverClient.fetchManifest(playerID: playerID)
                            let installedVersion = stateStore.load().installedPlaylistVersion
                            let installedDescription = installedVersion.map(String.init) ?? "none"
                            logger.log(
                                "Manifest received. Remote version: \(manifest.version); "
                                + "installed version: \(installedDescription); items: \(manifest.items.count)."
                            )

                            switch compareManifestVersion(installed: installedVersion, remote: manifest.version) {
                            case .updateAvailable:
                                logger.log("Remote playlist update available; staging missing assets.")
                                do {
                                    let summary = try await downloadManager.stageMissingAssets(from: manifest)
                                    logger.log(
                                        "Staging sync completed. Downloaded: \(summary.downloaded); "
                                        + "skipped: \(summary.skipped); failed: \(summary.failed). "
                                        + "Local playback was not changed."
                                    )
                                } catch {
                                    logger.log("Staging sync failed; local playback is unaffected. Error: \(error)")
                                }
                            case .upToDate:
                                logger.log("Remote manifest matches the installed playlist version.")
                            case .localVersionAhead:
                                logger.log("Installed playlist version is ahead of the remote manifest.")
                            }
                        } catch {
                            logger.log("Manifest polling failed; local playback is unaffected. Error: \(error)")
                        }
                    }
                    try? await Task.sleep(for: .seconds(config.manifestPollIntervalSeconds))
                }
            }

            while true {
                try await Task.sleep(for: .seconds(config.scanIntervalSeconds))
                do {
                    try mpvManager.ensureRunning()
                    let updated = try playlistManager.snapshot()
                    if updated != snapshot && !updated.entries.isEmpty {
                        try playlistManager.write(updated)
                        try mpvManager.reloadPlaylist()
                        snapshot = updated
                        logger.log("Content change detected; playlist reloaded.")
                    }
                } catch {
                    logger.log("Player maintenance error: \(error)")
                }
            }

            heartbeatTask.cancel()
            manifestTask.cancel()
        } catch {
            logger.log("Fatal error: \(error)")
            exit(EXIT_FAILURE)
        }
    }
}
