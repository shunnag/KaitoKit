import Foundation
import KaitoKit

func runDetect(_ arguments: [String]) throws {
    guard arguments.count == 1, let path = arguments.first else {
        throw CLIError.usage(usage)
    }
    print(try FormatDetector.detect(url: URL(fileURLWithPath: path)).rawValue)
}
