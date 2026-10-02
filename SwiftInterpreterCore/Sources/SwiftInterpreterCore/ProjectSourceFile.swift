import Foundation

/// Public information about the Swift file linked to one project.
public struct ProjectSourceFileReference: Codable, Equatable, Sendable {
    public let fileName: String
    public let linkedAt: Date

    public init(fileName: String, linkedAt: Date) {
        self.fileName = fileName
        self.linkedAt = linkedAt
    }
}

/// The UTF-8 source loaded from the linked file for one reload operation.
public struct ProjectSourceSnapshot: Equatable, Sendable {
    public let fileName: String
    public let source: String

    public init(fileName: String, source: String) {
        self.fileName = fileName
        self.source = source
    }
}

public enum ProjectSourceFileError: Error, LocalizedError, Sendable {
    case notAFileURL
    case notSwiftSource(String)
    case noLinkedSourceFile
    case invalidBookmark
    case invalidUTF8(String)
    case storageIsSymbolicLink
    case bookmarkFailed(String)
    case fileReadFailed(String)
    case fileCoordinationFailed(String)
    case storageFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notAFileURL:
            return "Choose a local .swift file from Files or iCloud Drive."
        case .notSwiftSource(let name):
            return "The linked project file must have a .swift extension: \(name)"
        case .noLinkedSourceFile:
            return "No Swift project file is linked to this project yet."
        case .invalidBookmark:
            return "The saved file reference can no longer be resolved. Link the project file again."
        case .invalidUTF8(let name):
            return "The linked Swift file is not valid UTF-8: \(name)"
        case .storageIsSymbolicLink:
            return "The saved project file reference must not be a symbolic link."
        case .bookmarkFailed(let message):
            return "Could not create or resolve the project file reference: \(message)"
        case .fileReadFailed(let message):
            return "Could not read the linked project file: \(message)"
        case .fileCoordinationFailed(let message):
            return "Could not coordinate access to the linked project file: \(message)"
        case .storageFailed(let message):
            return "Could not save the project file reference: \(message)"
        }
    }
}

private struct StoredProjectSourceFileReference: Codable, Sendable {
    let schemaVersion: Int
    let bookmarkData: Data
    let fileName: String
    let linkedAt: Date
}

/// Persists a security-scoped bookmark outside the interpreter's script sandbox.
///
/// Reads are coordinated with the file provider so an explicit Reload & Run
/// observes the current on-disk or iCloud Drive version of the selected file.
public struct ProjectSourceFileStore: Sendable {
    private let referenceURL: URL

    public init(workspace: ProjectWorkspace) {
        referenceURL = workspace.sourceReferenceURL
    }

    /// Links one user-selected `.swift` file to this project.
    public func link(_ url: URL) throws -> ProjectSourceFileReference {
        try validateSwiftFileURL(url)
        let acquiredScope = url.startAccessingSecurityScopedResource()
        defer {
            if acquiredScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let bookmarkData: Data
        do {
            bookmarkData = try makeBookmark(for: url)
        } catch {
            throw ProjectSourceFileError.bookmarkFailed(error.localizedDescription)
        }

        let linkedAt = Date()
        let stored = StoredProjectSourceFileReference(
            schemaVersion: 1,
            bookmarkData: bookmarkData,
            fileName: url.lastPathComponent,
            linkedAt: linkedAt
        )
        try save(stored)
        return ProjectSourceFileReference(fileName: stored.fileName, linkedAt: linkedAt)
    }

    public func linkedFile() throws -> ProjectSourceFileReference? {
        guard let stored = try load() else { return nil }
        return ProjectSourceFileReference(fileName: stored.fileName, linkedAt: stored.linkedAt)
    }

    /// Resolves the saved bookmark and reads the current file contents.
    public func readLinkedSource() throws -> ProjectSourceSnapshot {
        guard var stored = try load() else {
            throw ProjectSourceFileError.noLinkedSourceFile
        }

        var isStale = false
        let url: URL
        do {
            url = try resolveBookmark(stored.bookmarkData, isStale: &isStale)
        } catch {
            throw ProjectSourceFileError.bookmarkFailed(error.localizedDescription)
        }
        try validateSwiftFileURL(url)

        let acquiredScope = url.startAccessingSecurityScopedResource()
        defer {
            if acquiredScope {
                url.stopAccessingSecurityScopedResource()
            }
        }

        if isStale || stored.fileName != url.lastPathComponent {
            do {
                stored = StoredProjectSourceFileReference(
                    schemaVersion: stored.schemaVersion,
                    bookmarkData: try makeBookmark(for: url),
                    fileName: url.lastPathComponent,
                    linkedAt: stored.linkedAt
                )
                try save(stored)
            } catch {
                throw ProjectSourceFileError.bookmarkFailed(error.localizedDescription)
            }
        }

        let data: Data
        do {
            data = try coordinatedRead(at: url)
        } catch let error as ProjectSourceFileError {
            throw error
        } catch {
            throw ProjectSourceFileError.fileReadFailed(error.localizedDescription)
        }

        guard let source = String(data: data, encoding: .utf8) else {
            throw ProjectSourceFileError.invalidUTF8(url.lastPathComponent)
        }
        return ProjectSourceSnapshot(fileName: url.lastPathComponent, source: source)
    }

    public func unlink() throws {
        try ensureStorageIsNotSymbolicLink()
        guard FileManager.default.fileExists(atPath: referenceURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: referenceURL)
        } catch {
            throw ProjectSourceFileError.storageFailed(error.localizedDescription)
        }
    }

    private func load() throws -> StoredProjectSourceFileReference? {
        try ensureStorageIsNotSymbolicLink()
        guard FileManager.default.fileExists(atPath: referenceURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: referenceURL)
            let stored = try JSONDecoder().decode(StoredProjectSourceFileReference.self, from: data)
            guard stored.schemaVersion == 1 else { throw ProjectSourceFileError.invalidBookmark }
            return stored
        } catch let error as ProjectSourceFileError {
            throw error
        } catch {
            throw ProjectSourceFileError.storageFailed(error.localizedDescription)
        }
    }

    private func save(_ stored: StoredProjectSourceFileReference) throws {
        try ensureStorageIsNotSymbolicLink()
        do {
            let data = try JSONEncoder().encode(stored)
            try data.write(to: referenceURL, options: .atomic)
        } catch {
            throw ProjectSourceFileError.storageFailed(error.localizedDescription)
        }
    }

    private func ensureStorageIsNotSymbolicLink() throws {
        guard FileManager.default.fileExists(atPath: referenceURL.path) else { return }
        let values: URLResourceValues
        do {
            values = try referenceURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        } catch {
            throw ProjectSourceFileError.storageFailed(error.localizedDescription)
        }
        guard values.isSymbolicLink != true else {
            throw ProjectSourceFileError.storageIsSymbolicLink
        }
    }

    private func validateSwiftFileURL(_ url: URL) throws {
        guard url.isFileURL else { throw ProjectSourceFileError.notAFileURL }
        guard url.pathExtension.lowercased() == "swift" else {
            throw ProjectSourceFileError.notSwiftSource(url.lastPathComponent)
        }
    }

    private func makeBookmark(for url: URL) throws -> Data {
        #if os(macOS)
        return try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #elseif canImport(Darwin)
        // iOS document-picker URLs use ordinary bookmarks. Security-scoped
        // bookmark options are a macOS-only API; iOS restores its file access
        // through the bookmark and security-scoped URL lifetime instead.
        return try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #else
        return Data(url.absoluteString.utf8)
        #endif
    }

    private func resolveBookmark(_ data: Data, isStale: inout Bool) throws -> URL {
        #if os(macOS)
        return try URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        #elseif canImport(Darwin)
        return try URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        #else
        guard let string = String(data: data, encoding: .utf8),
              let url = URL(string: string),
              url.isFileURL else {
            throw ProjectSourceFileError.invalidBookmark
        }
        isStale = false
        return url
        #endif
    }

    private func coordinatedRead(at url: URL) throws -> Data {
        #if canImport(Darwin)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var readError: Error?
        var result: Data?

        coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            do {
                result = try Data(contentsOf: coordinatedURL, options: [.mappedIfSafe])
            } catch {
                readError = error
            }
        }

        if let coordinationError {
            throw ProjectSourceFileError.fileCoordinationFailed(coordinationError.localizedDescription)
        }
        if let readError {
            throw ProjectSourceFileError.fileReadFailed(readError.localizedDescription)
        }
        guard let result else {
            throw ProjectSourceFileError.fileReadFailed("The file provider returned no contents.")
        }
        return result
        #else
        return try Data(contentsOf: url, options: [.mappedIfSafe])
        #endif
    }
}
