#if OPENPOCKETCINE_DIAGNOSTICS
import Foundation

enum DiagnosticsExporter {
    static let fileNames = ["control-live.log", "live-frame-pacing.csv"]

    static func prepare(completion: @escaping (Result<[URL], Error>) -> Void) {
        LiveFramePacingDiagnostics.shared.flushPending {
            ControlLiveLog.flush {
                let result = exportURLs(fileManager: .default)
                DispatchQueue.main.async {
                    completion(result)
                }
            }
        }
    }

    static func exportURLs(fileManager: FileManager) -> Result<[URL], Error> {
        guard let documents = fileManager.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else {
            return .failure(ExportError.documentsUnavailable)
        }
        let urls = fileNames.map { documents.appendingPathComponent($0) }
        let missing = zip(fileNames, urls).compactMap { name, url in
            fileManager.fileExists(atPath: url.path) ? nil : name
        }
        guard missing.isEmpty else {
            return .failure(ExportError.filesMissing(missing))
        }
        return .success(urls)
    }

    enum ExportError: LocalizedError, Equatable {
        case documentsUnavailable
        case filesMissing([String])

        var errorDescription: String? {
            switch self {
            case .documentsUnavailable:
                return "The diagnostics Documents folder is unavailable."
            case .filesMissing(let names):
                return "Not created yet: \(names.joined(separator: ", ")). Display Nano LiveView for a few seconds, then try again."
            }
        }
    }
}
#endif
