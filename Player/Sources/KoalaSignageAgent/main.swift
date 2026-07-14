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
    let manifestCachePath: String

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
        case manifestCachePath
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
        manifestCachePath = try container.decodeIfPresent(String.self, forKey: .manifestCachePath)
            ?? URL(fileURLWithPath: stateFilePath)
                .deletingLastPathComponent()
                .appendingPathComponent("manifest-cache.json", isDirectory: false)
                .path
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
    var installedPlaylistID: UUID?
    var installedPlaylistVersion: Int?

    init(
        playerID: UUID?,
        installedPlaylistID: UUID? = nil,
        installedPlaylistVersion: Int? = nil
    ) {
        self.playerID = playerID
        self.installedPlaylistID = installedPlaylistID
        self.installedPlaylistVersion = installedPlaylistVersion
    }
}

struct ManifestResponse: Codable, Equatable, Sendable {
    let playlistID: UUID
    let version: Int
    let generatedAt: Date
    let items: [ManifestItem]
    let schedules: [ManifestSchedule]

    init(
        playlistID: UUID,
        version: Int,
        generatedAt: Date,
        items: [ManifestItem],
        schedules: [ManifestSchedule] = []
    ) {
        self.playlistID = playlistID
        self.version = version
        self.generatedAt = generatedAt
        self.items = items
        self.schedules = schedules
    }

    private enum CodingKeys: String, CodingKey {
        case playlistID
        case version
        case generatedAt
        case items
        case schedules
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        playlistID = try container.decode(UUID.self, forKey: .playlistID)
        version = try container.decode(Int.self, forKey: .version)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        items = try container.decode([ManifestItem].self, forKey: .items)
        schedules = try container.decodeIfPresent(
            [ManifestSchedule].self,
            forKey: .schedules
        ) ?? []
    }
}

struct ManifestSchedule: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let timezone: String
    let startMinute: Int
    let endMinute: Int
    let weekdayMask: Int
    let priority: Int
    let playlistID: UUID
    let version: Int
    let items: [ManifestItem]
}

struct ManifestItem: Codable, Equatable, Sendable {
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

func compareManifest(
    installedPlaylistID: UUID?,
    installedVersion: Int?,
    remotePlaylistID: UUID,
    remoteVersion: Int
) -> ManifestVersionComparison {
    guard installedPlaylistID == remotePlaylistID, let installedVersion else {
        return .updateAvailable
    }
    if remoteVersion > installedVersion { return .updateAvailable }
    if remoteVersion == installedVersion { return .upToDate }
    return .localVersionAhead
}

func selectedSchedule(from schedules: [ManifestSchedule], at date: Date) -> ManifestSchedule? {
    schedules
        .filter { scheduleIsActive($0, at: date) }
        .sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            if $0.startMinute != $1.startMinute { return $0.startMinute < $1.startMinute }
            return $0.id.uuidString < $1.id.uuidString
        }
        .first
}

private func scheduleIsActive(_ schedule: ManifestSchedule, at date: Date) -> Bool {
    guard
        let timezone = TimeZone(identifier: schedule.timezone),
        (0..<1_440).contains(schedule.startMinute),
        (1...1_440).contains(schedule.endMinute),
        schedule.startMinute != schedule.endMinute,
        (1...127).contains(schedule.weekdayMask)
    else {
        return false
    }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timezone
    let components = calendar.dateComponents([.weekday, .hour, .minute], from: date)
    guard let weekday = components.weekday, let hour = components.hour, let minute = components.minute else {
        return false
    }

    let minuteOfDay = (hour * 60) + minute
    let weekdayIndex = (weekday + 5) % 7 // Monday = bit 0; Sunday = bit 6.

    if schedule.startMinute < schedule.endMinute {
        return minuteOfDay >= schedule.startMinute
            && minuteOfDay < schedule.endMinute
            && weekdayIsEnabled(index: weekdayIndex, mask: schedule.weekdayMask)
    }

    if minuteOfDay >= schedule.startMinute {
        return weekdayIsEnabled(index: weekdayIndex, mask: schedule.weekdayMask)
    }
    if minuteOfDay < schedule.endMinute {
        let previousWeekdayIndex = (weekdayIndex + 6) % 7
        return weekdayIsEnabled(index: previousWeekdayIndex, mask: schedule.weekdayMask)
    }
    return false
}

private func weekdayIsEnabled(index: Int, mask: Int) -> Bool {
    (mask & (1 << index)) != 0
}

func shouldRestoreRemotePlaylist(state: PersistedState, playlistIsUsable: Bool) -> Bool {
    state.installedPlaylistID != nil
        && state.installedPlaylistVersion != nil
        && playlistIsUsable
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
    case invalidManifestChecksum(filename: String)
    case checksumToolUnavailable(String)
    case checksumToolFailed(Int32)
    case invalidChecksumOutput
    case checksumMismatch(filename: String)
    case emptyManifest
    case duplicateManifestPosition(Int)
    case conflictingManifestFilename(String)
    case assetNotReady(String)
    case invalidActiveReleasePath(String)

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
        case .invalidManifestChecksum(let filename): return "Invalid SHA-256 in manifest for \(filename)."
        case .checksumToolUnavailable(let path): return "SHA-256 tool is unavailable at \(path)."
        case .checksumToolFailed(let status): return "SHA-256 tool failed with status \(status)."
        case .invalidChecksumOutput: return "SHA-256 tool returned invalid output."
        case .checksumMismatch(let filename): return "SHA-256 mismatch for \(filename)."
        case .emptyManifest: return "The remote manifest contains no assets."
        case .duplicateManifestPosition(let position): return "Duplicate manifest position: \(position)."
        case .conflictingManifestFilename(let filename): return "Conflicting manifest filename: \(filename)."
        case .assetNotReady(let filename): return "No verified local source is available for \(filename)."
        case .invalidActiveReleasePath(let path): return "Active release is outside managed storage: \(path)."
        }
    }
}

struct Logger {
    private static let outputLock = NSLock()

    func log(_ message: String) {
        let formatter = ISO8601DateFormatter()
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        Self.outputLock.lock()
        defer { Self.outputLock.unlock() }
        FileHandle.standardOutput.write(data)
    }
}

final class CriticalSection: @unchecked Sendable {
    private let lock = NSLock()

    func withLock<Result>(_ operation: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}

final class StateStore: @unchecked Sendable {
    private let path: String
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let access = CriticalSection()

    init(path: String) {
        self.path = path
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() -> PersistedState {
        access.withLock {
            guard let data = FileManager.default.contents(atPath: path),
                  let state = try? decoder.decode(PersistedState.self, from: data) else {
                return PersistedState(playerID: nil)
            }
            return state
        }
    }

    func save(_ state: PersistedState) throws {
        try access.withLock {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(state)
            try data.write(to: url, options: .atomic)
        }
    }
}

final class ManifestStore: @unchecked Sendable {
    private let path: String
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let access = CriticalSection()

    init(path: String) {
        self.path = path
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func load() -> ManifestResponse? {
        access.withLock {
            guard let data = FileManager.default.contents(atPath: path) else { return nil }
            return try? decoder.decode(ManifestResponse.self, from: data)
        }
    }

    func save(_ manifest: ManifestResponse) throws {
        try access.withLock {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(manifest).write(to: url, options: .atomic)
        }
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
        try write(entries: snapshot.entries, description: "local")
    }

    func write(entries: [String], description: String) throws {
        guard !entries.isEmpty else { throw AgentError.emptyManifest }
        let playlistURL = URL(fileURLWithPath: config.playlistPath)
        try FileManager.default.createDirectory(
            at: playlistURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let body = entries.joined(separator: "\n") + "\n"
        try body.write(to: playlistURL, atomically: true, encoding: .utf8)
        logger.log("\(description.capitalized) playlist generated with \(entries.count) file(s).")
    }

    func currentPlaylistIsUsable() -> Bool {
        guard let body = try? String(contentsOfFile: config.playlistPath, encoding: .utf8) else {
            return false
        }
        let entries = body
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return !entries.isEmpty && entries.allSatisfy { FileManager.default.fileExists(atPath: $0) }
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

struct PreparedRelease: Equatable, Sendable {
    let playlistID: UUID
    let version: Int
    let directory: String
    let entries: [String]
}

struct CleanupSummary: Equatable, Sendable {
    let stagingEntriesRemoved: Int
    let releasesRemoved: Int
    let previousReleaseKept: String?
}

func normalizedSHA256(_ value: String) -> String? {
    let normalized = value.lowercased()
    guard normalized.utf8.count == 64,
          normalized.utf8.allSatisfy({ byte in
              (48...57).contains(byte) || (97...102).contains(byte)
          }) else {
        return nil
    }
    return normalized
}

struct SHA256Hasher: Sendable {
    func hashFile(at url: URL) throws -> String {
        #if os(Linux)
        let executable = "/usr/bin/sha256sum"
        let arguments = [url.path]
        #else
        let executable = "/usr/bin/shasum"
        let arguments = ["-a", "256", url.path]
        #endif

        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw AgentError.checksumToolUnavailable(executable)
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AgentError.checksumToolFailed(process.terminationStatus)
        }

        guard let line = String(data: data, encoding: .utf8),
              let firstField = line.split(whereSeparator: { $0.isWhitespace }).first,
              let checksum = normalizedSHA256(String(firstField)) else {
            throw AgentError.invalidChecksumOutput
        }
        return checksum
    }
}

func safeManifestFilename(_ filename: String) -> String? {
    guard !filename.isEmpty,
          filename != ".",
          filename != "..",
          !filename.hasPrefix("#"),
          !filename.contains("/"),
          !filename.contains("\\"),
          !filename.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
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
    private struct VerifiedFileFingerprint: Equatable {
        let size: Int64
        let modificationDate: Date?
        let expectedSHA256: String
    }

    private struct ManifestFileDefinition: Equatable {
        let size: Int64
        let checksum: String
    }

    private let baseURL: URL
    private let contentDirectory: URL
    private let stagingDirectory: URL
    private let logger: Logger
    private let session: URLSession
    private let fileManager: FileManager
    private let hasher: SHA256Hasher
    private var verifiedFiles: [String: VerifiedFileFingerprint] = [:]

    init(
        serverURL: String,
        contentDirectory: String,
        stagingDirectory: String,
        logger: Logger,
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        hasher: SHA256Hasher = SHA256Hasher()
    ) throws {
        guard let baseURL = URL(string: serverURL) else { throw AgentError.invalidServerURL }
        self.baseURL = baseURL
        self.contentDirectory = URL(fileURLWithPath: contentDirectory, isDirectory: true)
        self.stagingDirectory = URL(fileURLWithPath: stagingDirectory, isDirectory: true)
        self.logger = logger
        self.session = session
        self.fileManager = fileManager
        self.hasher = hasher
    }

    func stageMissingAssets(
        from manifest: ManifestResponse,
        allowDownloads: Bool = true
    ) async throws -> DownloadSummary {
        try validateAssetDefinitions(in: manifest)
        return try await stage(items: manifest.items, allowDownloads: allowDownloads)
    }

    func stageScheduledAssets(
        from manifest: ManifestResponse,
        allowDownloads: Bool = true
    ) async throws -> DownloadSummary {
        try validateAssetDefinitions(in: manifest)
        var filenames = Set<String>()
        var items: [ManifestItem] = []
        for item in manifest.schedules.flatMap(\.items) {
            let filename = try validatedFilename(for: item)
            if filenames.insert(filename).inserted {
                items.append(item)
            }
        }
        return try await stage(items: items, allowDownloads: allowDownloads)
    }

    func stageSelectedSchedule(
        _ schedule: ManifestSchedule,
        from manifest: ManifestResponse,
        allowDownloads: Bool = true
    ) async throws -> DownloadSummary {
        try validateAssetDefinitions(in: manifest)
        return try await stage(items: schedule.items, allowDownloads: allowDownloads)
    }

    private func stage(
        items: [ManifestItem],
        allowDownloads: Bool
    ) async throws -> DownloadSummary {
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        var summary = DownloadSummary()

        for item in items {
            do {
                let filename = try validatedFilename(for: item)
                let expectedChecksum = try validatedChecksum(for: item)
                let contentURL = contentDirectory.appendingPathComponent(filename, isDirectory: false)
                let stagedURL = stagingDirectory.appendingPathComponent(filename, isDirectory: false)

                if try fileMatchesManifest(
                    at: contentURL,
                    expectedSize: item.sizeBytes,
                    expectedChecksum: expectedChecksum
                ) {
                    logger.log("Asset already verified in content; skipping: \(filename)")
                    summary.skipped += 1
                    continue
                }

                if try fileMatchesManifest(
                    at: stagedURL,
                    expectedSize: item.sizeBytes,
                    expectedChecksum: expectedChecksum
                ) {
                    logger.log("Asset already verified in staging; skipping: \(filename)")
                    summary.skipped += 1
                    continue
                }

                if let releaseSource = try verifiedReleaseAsset(
                    filename: filename,
                    expectedSize: item.sizeBytes,
                    expectedChecksum: expectedChecksum
                ) {
                    try fileManager.copyItem(at: releaseSource, to: stagedURL)
                    cacheVerifiedFile(at: stagedURL, expectedChecksum: expectedChecksum)
                    logger.log("Recovered verified asset from a local release: \(filename)")
                    summary.skipped += 1
                    continue
                }

                guard allowDownloads else { throw AgentError.assetNotReady(filename) }

                try await download(
                    item: item,
                    filename: filename,
                    expectedChecksum: expectedChecksum,
                    destination: stagedURL
                )
                summary.downloaded += 1
            } catch {
                summary.failed += 1
                logger.log("Asset download failed for \(item.filename). Error: \(error)")
            }
        }

        return summary
    }

    private func verifiedReleaseAsset(
        filename: String,
        expectedSize: Int64,
        expectedChecksum: String
    ) throws -> URL? {
        let releasesRoot = contentDirectory.appendingPathComponent(".remote", isDirectory: true)
        guard fileManager.fileExists(atPath: releasesRoot.path) else { return nil }

        for release in try fileManager.contentsOfDirectory(
            at: releasesRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) {
            let values = try release.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let candidate = release.appendingPathComponent(filename, isDirectory: false)
            if try fileMatchesManifest(
                at: candidate,
                expectedSize: expectedSize,
                expectedChecksum: expectedChecksum
            ) {
                return candidate
            }
        }
        return nil
    }

    private func validateAssetDefinitions(in manifest: ManifestResponse) throws {
        var definitions: [String: ManifestFileDefinition] = [:]
        let allItems = manifest.items + manifest.schedules.flatMap(\.items)
        for item in allItems {
            let filename = try validatedFilename(for: item)
            let definition = ManifestFileDefinition(
                size: item.sizeBytes,
                checksum: try validatedChecksum(for: item)
            )
            if let existing = definitions[filename], existing != definition {
                throw AgentError.conflictingManifestFilename(filename)
            }
            definitions[filename] = definition
        }
    }

    func prepareRelease(from manifest: ManifestResponse) throws -> PreparedRelease {
        try prepareRelease(
            playlistID: manifest.playlistID,
            version: manifest.version,
            items: manifest.items
        )
    }

    func prepareRelease(from schedule: ManifestSchedule) throws -> PreparedRelease {
        try prepareRelease(
            playlistID: schedule.playlistID,
            version: schedule.version,
            items: schedule.items
        )
    }

    private func prepareRelease(
        playlistID: UUID,
        version: Int,
        items: [ManifestItem]
    ) throws -> PreparedRelease {
        let sortedItems = items.sorted(by: { $0.position < $1.position })
        guard !sortedItems.isEmpty else { throw AgentError.emptyManifest }

        var positions = Set<Int>()
        var definitions: [String: ManifestFileDefinition] = [:]
        for item in sortedItems {
            guard positions.insert(item.position).inserted else {
                throw AgentError.duplicateManifestPosition(item.position)
            }
            let filename = try validatedFilename(for: item)
            let definition = ManifestFileDefinition(
                size: item.sizeBytes,
                checksum: try validatedChecksum(for: item)
            )
            if let existing = definitions[filename], existing != definition {
                throw AgentError.conflictingManifestFilename(filename)
            }
            definitions[filename] = definition
        }

        let releasesRoot = contentDirectory.appendingPathComponent(".remote", isDirectory: true)
        try fileManager.createDirectory(at: releasesRoot, withIntermediateDirectories: true)
        let releaseName = "\(playlistID.uuidString.lowercased())-v\(version)"
        let preferredRelease = releasesRoot.appendingPathComponent(releaseName, isDirectory: true)

        if try releaseContainsManifest(preferredRelease, items: sortedItems) {
            logger.log("Verified release already exists: \(releaseName)")
            return preparedRelease(
                playlistID: playlistID,
                version: version,
                directory: preferredRelease,
                items: sortedItems
            )
        }

        let temporaryRelease = releasesRoot.appendingPathComponent(
            ".pending-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try fileManager.createDirectory(at: temporaryRelease, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRelease) }

        for item in sortedItems {
            let filename = try validatedFilename(for: item)
            let destination = temporaryRelease.appendingPathComponent(filename, isDirectory: false)
            if fileManager.fileExists(atPath: destination.path) { continue }

            let checksum = try validatedChecksum(for: item)
            let stagedSource = stagingDirectory.appendingPathComponent(filename, isDirectory: false)
            let contentSource = contentDirectory.appendingPathComponent(filename, isDirectory: false)
            let source: URL

            if try fileMatchesManifest(
                at: stagedSource,
                expectedSize: item.sizeBytes,
                expectedChecksum: checksum
            ) {
                source = stagedSource
            } else if try fileMatchesManifest(
                at: contentSource,
                expectedSize: item.sizeBytes,
                expectedChecksum: checksum
            ) {
                source = contentSource
            } else {
                throw AgentError.assetNotReady(filename)
            }

            try fileManager.copyItem(at: source, to: destination)
            guard try fileMatchesManifest(
                at: destination,
                expectedSize: item.sizeBytes,
                expectedChecksum: checksum
            ) else {
                throw AgentError.checksumMismatch(filename: filename)
            }
        }

        let finalRelease: URL
        if fileManager.fileExists(atPath: preferredRelease.path) {
            finalRelease = releasesRoot.appendingPathComponent(
                "\(releaseName)-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        } else {
            finalRelease = preferredRelease
        }
        try fileManager.moveItem(at: temporaryRelease, to: finalRelease)
        logger.log("Versioned release prepared: \(finalRelease.lastPathComponent)")
        return preparedRelease(
            playlistID: playlistID,
            version: version,
            directory: finalRelease,
            items: sortedItems
        )
    }

    func cleanupAfterActivation(
        activeRelease: PreparedRelease,
        removeStagingEntries: Bool = true
    ) throws -> CleanupSummary {
        let releasesRoot = contentDirectory
            .appendingPathComponent(".remote", isDirectory: true)
            .standardizedFileURL
        let activeDirectory = URL(
            fileURLWithPath: activeRelease.directory,
            isDirectory: true
        ).standardizedFileURL
        guard activeDirectory.deletingLastPathComponent() == releasesRoot else {
            throw AgentError.invalidActiveReleasePath(activeDirectory.path)
        }

        var stagingEntriesRemoved = 0
        if removeStagingEntries && fileManager.fileExists(atPath: stagingDirectory.path) {
            let stagedEntries = try fileManager.contentsOfDirectory(
                at: stagingDirectory,
                includingPropertiesForKeys: nil
            )
            for entry in stagedEntries {
                try fileManager.removeItem(at: entry)
                removeCachedFingerprints(under: entry)
                stagingEntriesRemoved += 1
            }
        }

        let releaseEntries = try fileManager.contentsOfDirectory(
            at: releasesRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        )
        var usablePreviousReleases: [(url: URL, modifiedAt: Date)] = []
        var releasesRemoved = 0

        for entry in releaseEntries {
            let standardizedEntry = entry.standardizedFileURL
            if standardizedEntry == activeDirectory { continue }

            let values = try entry.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
            )
            let isPending = entry.lastPathComponent.hasPrefix(".pending-")
            let isUsableDirectory = values.isDirectory == true
                && values.isSymbolicLink != true
                && releaseDirectoryContainsMedia(entry)

            if isPending || !isUsableDirectory {
                try fileManager.removeItem(at: entry)
                removeCachedFingerprints(under: entry)
                releasesRemoved += 1
                continue
            }

            usablePreviousReleases.append((
                url: entry,
                modifiedAt: values.contentModificationDate ?? .distantPast
            ))
        }

        usablePreviousReleases.sort { $0.modifiedAt > $1.modifiedAt }
        let previousRelease = usablePreviousReleases.first?.url
        for obsoleteRelease in usablePreviousReleases.dropFirst() {
            try fileManager.removeItem(at: obsoleteRelease.url)
            removeCachedFingerprints(under: obsoleteRelease.url)
            releasesRemoved += 1
        }

        return CleanupSummary(
            stagingEntriesRemoved: stagingEntriesRemoved,
            releasesRemoved: releasesRemoved,
            previousReleaseKept: previousRelease?.path
        )
    }

    private func releaseDirectoryContainsMedia(_ directory: URL) -> Bool {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            return false
        }
        return entries.contains { entry in
            (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    private func removeCachedFingerprints(under url: URL) {
        let path = url.standardizedFileURL.path
        let childPrefix = path + "/"
        let keysToRemove = verifiedFiles.keys.filter {
            $0 == path || $0.hasPrefix(childPrefix)
        }
        for key in keysToRemove {
            verifiedFiles.removeValue(forKey: key)
        }
    }

    private func releaseContainsManifest(_ directory: URL, items: [ManifestItem]) throws -> Bool {
        var verifiedFilenames = Set<String>()
        for item in items {
            let filename = try validatedFilename(for: item)
            if !verifiedFilenames.insert(filename).inserted { continue }
            guard try fileMatchesManifest(
                at: directory.appendingPathComponent(filename, isDirectory: false),
                expectedSize: item.sizeBytes,
                expectedChecksum: try validatedChecksum(for: item)
            ) else {
                return false
            }
        }
        return !items.isEmpty
    }

    private func preparedRelease(
        playlistID: UUID,
        version: Int,
        directory: URL,
        items: [ManifestItem]
    ) -> PreparedRelease {
        PreparedRelease(
            playlistID: playlistID,
            version: version,
            directory: directory.path,
            entries: items.map {
                directory.appendingPathComponent($0.filename, isDirectory: false).path
            }
        )
    }

    private func validatedFilename(for item: ManifestItem) throws -> String {
        guard let filename = safeManifestFilename(item.filename) else {
            throw AgentError.unsafeManifestFilename(item.filename)
        }
        return filename
    }

    private func validatedChecksum(for item: ManifestItem) throws -> String {
        guard let checksum = normalizedSHA256(item.sha256) else {
            throw AgentError.invalidManifestChecksum(filename: item.filename)
        }
        return checksum
    }

    private func download(
        item: ManifestItem,
        filename: String,
        expectedChecksum: String,
        destination: URL
    ) async throws {
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
        guard try hasher.hashFile(at: partialURL) == expectedChecksum else {
            throw AgentError.checksumMismatch(filename: filename)
        }
        logger.log("SHA-256 validated for downloaded asset: \(filename)")

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: partialURL, to: destination)
        cacheVerifiedFile(at: destination, expectedChecksum: expectedChecksum)
        logger.log("Asset downloaded to staging: \(filename) (\(actualSize) bytes).")
    }

    private func fileMatchesManifest(
        at url: URL,
        expectedSize: Int64,
        expectedChecksum: String
    ) throws -> Bool {
        guard let fingerprint = fingerprint(
            at: url,
            expectedSize: expectedSize,
            expectedChecksum: expectedChecksum
        ) else {
            verifiedFiles.removeValue(forKey: url.path)
            return false
        }

        if verifiedFiles[url.path] == fingerprint {
            return true
        }

        guard try hasher.hashFile(at: url) == expectedChecksum else {
            verifiedFiles.removeValue(forKey: url.path)
            return false
        }

        verifiedFiles[url.path] = fingerprint
        logger.log("SHA-256 validated for existing asset: \(url.lastPathComponent)")
        return true
    }

    private func fingerprint(
        at url: URL,
        expectedSize: Int64,
        expectedChecksum: String
    ) -> VerifiedFileFingerprint? {
        guard expectedSize >= 0,
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let fileType = attributes[.type] as? FileAttributeType,
              fileType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.int64Value == expectedSize else {
            return nil
        }
        return VerifiedFileFingerprint(
            size: size.int64Value,
            modificationDate: attributes[.modificationDate] as? Date,
            expectedSHA256: expectedChecksum
        )
    }

    private func cacheVerifiedFile(at url: URL, expectedChecksum: String) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return
        }
        verifiedFiles[url.path] = VerifiedFileFingerprint(
            size: size.int64Value,
            modificationDate: attributes[.modificationDate] as? Date,
            expectedSHA256: expectedChecksum
        )
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
            let manifestStore = ManifestStore(path: config.manifestCachePath)
            let playbackUpdates = CriticalSection()
            let serverClient = try ServerClient(serverURL: config.serverURL)
            let downloadManager = try DownloadManager(
                serverURL: config.serverURL,
                contentDirectory: config.contentDirectory,
                stagingDirectory: config.stagingDirectory,
                logger: logger
            )

            var state = stateStore.load()
            var snapshot = try playlistManager.snapshot()
            if shouldRestoreRemotePlaylist(
                state: state,
                playlistIsUsable: playlistManager.currentPlaylistIsUsable()
            ) {
                logger.log(
                    "Restoring installed remote playlist \(state.installedPlaylistID!.uuidString) "
                    + "version \(state.installedPlaylistVersion!)."
                )
            } else {
                if state.installedPlaylistID != nil || state.installedPlaylistVersion != nil {
                    logger.log("Installed remote playlist state is incomplete; returning to local playback.")
                    state.installedPlaylistID = nil
                    state.installedPlaylistVersion = nil
                    try stateStore.save(state)
                }
                try playlistManager.write(snapshot)
            }
            try mpvManager.ensureRunning()
            try mpvManager.reloadPlaylist()

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
                            let manifestResult: (manifest: ManifestResponse, isCached: Bool)
                            do {
                                let fetchedManifest = try await serverClient.fetchManifest(playerID: playerID)
                                try manifestStore.save(fetchedManifest)
                                manifestResult = (fetchedManifest, false)
                            } catch {
                                guard let cachedManifest = manifestStore.load() else { throw error }
                                manifestResult = (cachedManifest, true)
                                logger.log(
                                    "Manifest polling failed; evaluating cached manifest offline. "
                                    + "Error: \(error)"
                                )
                            }
                            let manifest = manifestResult.manifest
                            let isCachedManifest = manifestResult.isCached
                            let installedState = stateStore.load()
                            let installedVersion = installedState.installedPlaylistVersion
                            let installedDescription = installedVersion.map(String.init) ?? "none"
                            logger.log(
                                "Manifest received. Remote version: \(manifest.version); "
                                + "installed version: \(installedDescription); items: \(manifest.items.count); "
                                + "schedules: \(manifest.schedules.count)."
                            )
                            if isCachedManifest {
                                logger.log(
                                    "Cached manifest generated at \(ISO8601DateFormatter().string(from: manifest.generatedAt))."
                                )
                            }

                            if let schedule = selectedSchedule(from: manifest.schedules, at: Date()) {
                                logger.log("Scheduled playlist is active: \(schedule.name).")
                                let summary = try await downloadManager.stageSelectedSchedule(
                                    schedule,
                                    from: manifest,
                                    allowDownloads: !isCachedManifest
                                )
                                logger.log(
                                    "Scheduled asset cache completed. Downloaded: \(summary.downloaded); "
                                    + "skipped: \(summary.skipped); failed: \(summary.failed)."
                                )

                                switch compareManifest(
                                    installedPlaylistID: installedState.installedPlaylistID,
                                    installedVersion: installedVersion,
                                    remotePlaylistID: schedule.playlistID,
                                    remoteVersion: schedule.version
                                ) {
                                case .updateAvailable where summary.failed == 0:
                                    let release = try await downloadManager.prepareRelease(from: schedule)
                                    try playbackUpdates.withLock {
                                        try playlistManager.write(
                                            entries: release.entries,
                                            description: "scheduled"
                                        )
                                        try mpvManager.reloadPlaylist()
                                        var state = stateStore.load()
                                        state.installedPlaylistID = release.playlistID
                                        state.installedPlaylistVersion = release.version
                                        try stateStore.save(state)
                                    }
                                    logger.log(
                                        "Scheduled playlist activated atomically: \(schedule.name); "
                                        + "playlist \(release.playlistID.uuidString) version \(release.version)."
                                    )
                                    do {
                                        let cleanup = try await downloadManager.cleanupAfterActivation(
                                            activeRelease: release,
                                            removeStagingEntries: false
                                        )
                                        logger.log(
                                            "Post-activation cleanup completed. Staging entries removed: "
                                            + "\(cleanup.stagingEntriesRemoved); releases removed: "
                                            + "\(cleanup.releasesRemoved); previous release kept: "
                                            + "\(cleanup.previousReleaseKept ?? "none")."
                                        )
                                    } catch {
                                        logger.log(
                                            "Post-activation cleanup failed; active playback is unaffected. "
                                            + "Error: \(error)"
                                        )
                                    }
                                case .updateAvailable:
                                    logger.log(
                                        "Scheduled playlist was not activated because some assets failed."
                                    )
                                case .upToDate:
                                    logger.log("Active scheduled playlist matches the installed version.")
                                case .localVersionAhead:
                                    logger.log("Installed scheduled playlist is ahead of the remote version.")
                                }

                                if !isCachedManifest {
                                    let prefetch = try await downloadManager.stageScheduledAssets(from: manifest)
                                    logger.log(
                                        "Scheduled asset cache completed. Downloaded: \(prefetch.downloaded); "
                                        + "skipped: \(prefetch.skipped); failed: \(prefetch.failed)."
                                    )
                                }
                            } else {
                                switch compareManifest(
                                    installedPlaylistID: installedState.installedPlaylistID,
                                    installedVersion: installedVersion,
                                    remotePlaylistID: manifest.playlistID,
                                    remoteVersion: manifest.version
                                ) {
                                case .updateAvailable:
                                    logger.log("Fallback playlist selected; staging missing assets.")
                                    let summary = try await downloadManager.stageMissingAssets(
                                        from: manifest,
                                        allowDownloads: !isCachedManifest
                                    )
                                    logger.log(
                                        "Staging sync completed. Downloaded: \(summary.downloaded); "
                                        + "skipped: \(summary.skipped); failed: \(summary.failed)."
                                    )
                                    if summary.failed > 0 {
                                        logger.log("Fallback playlist was not activated because some assets failed.")
                                    } else {
                                        let release = try await downloadManager.prepareRelease(from: manifest)
                                        try playbackUpdates.withLock {
                                            try playlistManager.write(
                                                entries: release.entries,
                                                description: "remote"
                                            )
                                            try mpvManager.reloadPlaylist()
                                            var state = stateStore.load()
                                            state.installedPlaylistID = release.playlistID
                                            state.installedPlaylistVersion = release.version
                                            try stateStore.save(state)
                                        }
                                        logger.log(
                                            "Fallback playlist activated atomically: "
                                            + "\(release.playlistID.uuidString) version \(release.version)."
                                        )
                                        do {
                                            let cleanup = try await downloadManager.cleanupAfterActivation(
                                                activeRelease: release,
                                                removeStagingEntries: !isCachedManifest
                                            )
                                            logger.log(
                                                "Post-activation cleanup completed. Staging entries removed: "
                                                + "\(cleanup.stagingEntriesRemoved); releases removed: "
                                                + "\(cleanup.releasesRemoved); previous release kept: "
                                                + "\(cleanup.previousReleaseKept ?? "none")."
                                            )
                                        } catch {
                                            logger.log(
                                                "Post-activation cleanup failed; active playback is unaffected. "
                                                + "Error: \(error)"
                                            )
                                        }
                                    }
                                case .upToDate:
                                    logger.log("Fallback playlist matches the installed version.")
                                case .localVersionAhead:
                                    logger.log("Installed fallback playlist is ahead of the remote version.")
                                }

                                if !isCachedManifest && !manifest.schedules.isEmpty {
                                    let summary = try await downloadManager.stageScheduledAssets(from: manifest)
                                    logger.log(
                                        "Scheduled asset cache completed. Downloaded: \(summary.downloaded); "
                                        + "skipped: \(summary.skipped); failed: \(summary.failed)."
                                    )
                                }
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
                    try playbackUpdates.withLock {
                        try mpvManager.ensureRunning()
                        guard stateStore.load().installedPlaylistID == nil else { return }

                        let updated = try playlistManager.snapshot()
                        if updated != snapshot && !updated.entries.isEmpty {
                            try playlistManager.write(updated)
                            try mpvManager.reloadPlaylist()
                            snapshot = updated
                            logger.log("Content change detected; playlist reloaded.")
                        }
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
