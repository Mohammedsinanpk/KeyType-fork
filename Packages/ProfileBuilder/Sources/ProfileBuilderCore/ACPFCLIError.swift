import Foundation
import TokenProfiles

/// Errors raised by the `acpf-build` pipeline. Lives in `ProfileBuilderCore` so both
/// the CLI surface and the test target can match on the cases.
public enum ACPFCLIError: Error, CustomStringConvertible {
    case outputExists(path: String)
    case selfCheckFailed(failures: [ProfileSelfCheck.Failure])

    public var description: String {
        switch self {
        case .outputExists(let path):
            return "Refusing to overwrite existing profile at \(path); pass --force to override."
        case .selfCheckFailed(let failures):
            return "Profile self-check failed:\n" + failures.map { "  - \($0)" }.joined(separator: "\n")
        }
    }
}
