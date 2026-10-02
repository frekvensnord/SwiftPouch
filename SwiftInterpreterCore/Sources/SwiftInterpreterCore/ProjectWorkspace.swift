import Foundation

/// Stable identity for one interpreter project.
///
/// The target chat app already persists each conversation with a UUID, so it
/// can construct the matching project identity from that existing value.
public struct ProjectID: Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var directoryName: String {
        rawValue.uuidString.lowercased()
    }
}

/// A project-specific on-disk root used by the interpreter sandbox.
public struct ProjectWorkspace: Hashable, Sendable {
    public let id: ProjectID
    public let rootURL: URL
    let sourceReferenceURL: URL

    fileprivate init(id: ProjectID, rootURL: URL, sourceReferenceURL: URL) {
        self.id = id
        self.rootURL = rootURL
        self.sourceReferenceURL = sourceReferenceURL
    }
}

/// Creates and reopens isolated workspaces under one app-owned directory.
///
/// Pass a persisted `ProjectID` when reopening a project. The same ID always
/// resolves to the same child directory; different IDs never share a path.
public struct ProjectWorkspaceStore: Sendable {
    private let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public func workspace(for id: ProjectID) throws -> ProjectWorkspace {
        let fileManager = FileManager.default
        let workspaceURL = rootURL
            .appendingPathComponent(id.directoryName, isDirectory: true)
            .standardizedFileURL

        try fileManager.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: true
        )

        let metadataRootURL = rootURL.appendingPathComponent("InterpreterMetadata", isDirectory: true)
        try fileManager.createDirectory(
            at: metadataRootURL,
            withIntermediateDirectories: true
        )

        let values = try workspaceURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw ProjectWorkspaceError.symbolicLinkAtWorkspaceRoot(workspaceURL)
        }

        let metadataValues = try metadataRootURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard metadataValues.isSymbolicLink != true else {
            throw ProjectWorkspaceError.symbolicLinkAtMetadataRoot(metadataRootURL)
        }

        return ProjectWorkspace(
            id: id,
            rootURL: workspaceURL,
            sourceReferenceURL: metadataRootURL
                .appendingPathComponent(id.directoryName)
                .appendingPathExtension("json")
        )
    }
}

public enum ProjectWorkspaceError: Error, LocalizedError, Sendable {
    case symbolicLinkAtWorkspaceRoot(URL)
    case symbolicLinkAtMetadataRoot(URL)

    public var errorDescription: String? {
        switch self {
        case .symbolicLinkAtWorkspaceRoot(let url):
            return "The project workspace root must not be a symbolic link: \(url.path)"
        case .symbolicLinkAtMetadataRoot(let url):
            return "The interpreter metadata root must not be a symbolic link: \(url.path)"
        }
    }
}
