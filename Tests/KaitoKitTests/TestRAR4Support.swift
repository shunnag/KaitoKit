import Foundation

enum RAR4TestSupport {
    static var corpusDirectory: URL? {
        environmentURL("KAITOKIT_RAR4_CORPUS", isDirectory: true)
    }

    static var ppmdSolidArchive: URL? {
        environmentURL("KAITOKIT_RAR4_PPMD_SOLID_ARCHIVE", isDirectory: false)
            ?? corpusDirectory?.appendingPathComponent("ppmd_solid_rar300.rar")
    }

    static var filterArchive: URL? {
        environmentURL("KAITOKIT_RAR4_FILTER_ARCHIVE", isDirectory: false)
            ?? corpusDirectory?.appendingPathComponent("st1200-pts.rar")
    }

    private static func environmentURL(
        _ name: String,
        isDirectory: Bool
    ) -> URL? {
        guard let path = ProcessInfo.processInfo.environment[name], !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: isDirectory)
    }
}
