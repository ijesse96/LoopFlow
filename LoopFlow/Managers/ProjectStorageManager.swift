import Foundation
import AVFoundation

@MainActor
final class ProjectStorageManager {
    static let shared = ProjectStorageManager()

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    var documentsURL: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var projectsRootURL: URL {
        documentsURL.appendingPathComponent("Projects", isDirectory: true)
    }

    func projectDirectory(for projectID: UUID) -> URL {
        projectsRootURL.appendingPathComponent(projectID.uuidString, isDirectory: true)
    }

    func audioDirectory(for projectID: UUID) -> URL {
        projectDirectory(for: projectID).appendingPathComponent("Audio", isDirectory: true)
    }

    func projectFileURL(for projectID: UUID) -> URL {
        projectDirectory(for: projectID).appendingPathComponent("project.json")
    }

    func ensureProjectFolders(for projectID: UUID) throws {
        try fileManager.createDirectory(at: audioDirectory(for: projectID), withIntermediateDirectories: true)
    }

    func save(_ project: LoopFlowProject) throws {
        var project = project
        project.updatedAt = Date()
        try ensureProjectFolders(for: project.id)
        let data = try encoder.encode(project)
        try data.write(to: projectFileURL(for: project.id), options: .atomic)
        try saveLastOpened(projectID: project.id)
    }

    func load(projectID: UUID) throws -> LoopFlowProject {
        let data = try Data(contentsOf: projectFileURL(for: projectID))
        return try decoder.decode(LoopFlowProject.self, from: data)
    }

    func loadLastOpenedOrCreate() throws -> LoopFlowProject {
        try fileManager.createDirectory(at: projectsRootURL, withIntermediateDirectories: true)
        if let lastID = loadLastOpenedID(),
           fileManager.fileExists(atPath: projectFileURL(for: lastID).path) {
            return try load(projectID: lastID)
        }
        let project = LoopFlowProject()
        try save(project)
        return project
    }

    func absoluteURL(for relativePath: String, projectID: UUID) -> URL {
        projectDirectory(for: projectID).appendingPathComponent(relativePath)
    }

    func importInstrumental(from sourceURL: URL, projectID: UUID) throws -> (relativePath: String, duration: Double) {
        try ensureProjectFolders(for: projectID)
        let ext = sourceURL.pathExtension.isEmpty ? "wav" : sourceURL.pathExtension
        let relative = "Audio/instrumental.\(ext)"
        let dest = absoluteURL(for: relative, projectID: projectID)
        if fileManager.fileExists(atPath: dest.path) {
            try fileManager.removeItem(at: dest)
        }
        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { sourceURL.stopAccessingSecurityScopedResource() }
        }
        try fileManager.copyItem(at: sourceURL, to: dest)
        let duration = try audioDuration(url: dest)
        return (relative, duration)
    }

    func makeTakeRelativePath(regionIndex: Int, takeNumber: Int) -> String {
        "Audio/takes/region_\(regionIndex)_take_\(takeNumber).wav"
    }

    func takeFileURL(projectID: UUID, relativePath: String) throws -> URL {
        let url = absoluteURL(for: relativePath, projectID: projectID)
        let dir = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return url
    }

    func audioDuration(url: URL) throws -> Double {
        let file = try AVAudioFileBridge.duration(url: url)
        return file
    }

    func listProjectIDs() -> [UUID] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: projectsRootURL,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return contents.compactMap { UUID(uuidString: $0.lastPathComponent) }
    }

    // MARK: - Last opened

    private var lastOpenedURL: URL {
        documentsURL.appendingPathComponent("last_opened.txt")
    }

    private func saveLastOpened(projectID: UUID) throws {
        try projectID.uuidString.write(to: lastOpenedURL, atomically: true, encoding: .utf8)
    }

    private func loadLastOpenedID() -> UUID? {
        guard let text = try? String(contentsOf: lastOpenedURL, encoding: .utf8) else { return nil }
        return UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

enum AVAudioFileBridge {
    static func duration(url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }
}
