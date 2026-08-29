import Darwin
import Foundation

/// Cursor CLI ACP helpers aligned with T3 Code's Cursor driver.
///
/// Current Cursor still ships both `agent` and `cursor-agent` as symlinks to
/// the same binary. T3 Code and Buzz spawn the unambiguous `cursor-agent`
/// name because `agent` collides with other CLIs on PATH. Login remains
/// `agent login`; ACP auth is `cursor_login`.
public enum CursorACPSupport: Sendable {
    public static let commandName = "cursor-agent"
    public static let arguments = ["acp"]
    public static let authMethodID = "cursor_login"
    public static let loginCommand = "agent login"
    public static let aboutTimeout: TimeInterval = 8

    public enum AuthStatus: Equatable, Sendable {
        case authenticated(email: String?)
        case unauthenticated
        case unknown
    }

    public struct AboutResult: Equatable, Sendable {
        public let version: String?
        public let auth: AuthStatus
        public let message: String?

        public init(
            version: String?,
            auth: AuthStatus,
            message: String? = nil
        ) {
            self.version = version
            self.auth = auth
            self.message = message
        }

    }

    public static func baseModelID(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "default" }
        if let bracket = trimmed.firstIndex(of: "[") {
            return String(trimmed[..<bracket])
        }
        return trimmed
    }

    public static func parseAbout(
        stdout: String,
        stderr: String = "",
        exitCode: Int32
    ) -> AboutResult {
        let combined = "\(stdout)\n\(stderr)"
        if let json = jsonPayload(in: stdout) {
            return parseAboutJSON(json, exitCode: exitCode)
        }
        let lower = combined.lowercased()
        if lower.contains("unknown command")
            || lower.contains("unrecognized command")
            || lower.contains("unexpected argument") {
            return AboutResult(
                version: nil,
                auth: .unknown,
                message: "The `about` command is unavailable in this version of the Cursor Agent CLI."
            )
        }
        let plain = stripANSI(combined)
        let version = aboutField(plain, key: "CLI Version")
        let userEmail = aboutField(plain, key: "User Email")
        return parseAboutEmail(
            version: version,
            userEmail: userEmail,
            emailFieldPresent: userEmail != nil,
            exitCode: exitCode
        )
    }

    public static func probeAbout(executable: URL) -> AboutResult {
        let jsonResult = runAbout(
            executable: executable,
            arguments: ["about", "--format", "json"]
        )
        if jsonFormatUnsupported(jsonResult) {
            let plain = runAbout(executable: executable, arguments: ["about"])
            return parseAbout(stdout: plain.output, exitCode: plain.status)
        }
        return parseAbout(
            stdout: jsonResult.output,
            exitCode: jsonResult.status
        )
    }

    public static func unauthenticatedDetail() -> String {
        "Cursor CLI is installed, but you are not logged in. Run “\(loginCommand)” in Terminal."
    }

    public static func readyDetail(email: String?) -> String {
        if let email, !email.isEmpty {
            return "Cursor is installed with native ACP. Signed in as \(email)."
        }
        return "Cursor is installed with native ACP."
    }

    private struct CommandResult {
        var output: String
        var status: Int32
    }

    private static func runAbout(
        executable: URL,
        arguments: [String]
    ) -> CommandResult {
        let output = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            return CommandResult(
                output: error.localizedDescription,
                status: 127
            )
        }
        output.fileHandleForWriting.closeFile()
        let deadline = Date().addingTimeInterval(aboutTimeout)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            let killDeadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < killDeadline {
                usleep(10_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            return CommandResult(
                output: "",
                status: 124
            )
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return CommandResult(
            output: String(decoding: data, as: UTF8.self),
            status: process.terminationStatus
        )
    }

    private static func jsonFormatUnsupported(_ result: CommandResult) -> Bool {
        let lower = result.output.lowercased()
        return lower.contains("unknown option '--format'")
            || lower.contains("unexpected argument '--format'")
            || lower.contains("unrecognized option '--format'")
            || lower.contains("unknown argument '--format'")
    }

    private static func jsonPayload(in stdout: String) -> [String: Any]? {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    private static func parseAboutJSON(
        _ json: [String: Any],
        exitCode: Int32
    ) -> AboutResult {
        let version = (json["cliVersion"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let emailPresent = json.keys.contains("userEmail")
        let rawEmail = json["userEmail"]
        let userEmail: String?
        if rawEmail is NSNull {
            userEmail = nil
        } else {
            userEmail = (rawEmail as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if emailPresent, rawEmail is NSNull {
            return AboutResult(
                version: version,
                auth: .unauthenticated,
                message: unauthenticatedDetail()
            )
        }
        return parseAboutEmail(
            version: version,
            userEmail: userEmail,
            emailFieldPresent: emailPresent,
            exitCode: exitCode
        )
    }

    private static func parseAboutEmail(
        version: String?,
        userEmail: String?,
        emailFieldPresent: Bool,
        exitCode: Int32
    ) -> AboutResult {
        guard let userEmail, !userEmail.isEmpty else {
            if emailFieldPresent {
                return AboutResult(
                    version: version,
                    auth: .unauthenticated,
                    message: unauthenticatedDetail()
                )
            }
            if exitCode == 0 {
                return AboutResult(version: version, auth: .unknown)
            }
            return AboutResult(
                version: version,
                auth: .unknown,
                message: "Could not verify Cursor Agent authentication status."
            )
        }
        let lower = userEmail.lowercased()
        if lower == "not logged in"
            || lower.contains("login required")
            || lower.contains("authentication required") {
            return AboutResult(
                version: version,
                auth: .unauthenticated,
                message: unauthenticatedDetail()
            )
        }
        return AboutResult(
            version: version,
            auth: .authenticated(email: userEmail)
        )
    }

    private static func aboutField(_ text: String, key: String) -> String? {
        let pattern = "^\(NSRegularExpression.escapedPattern(for: key))\\s{2,}(.+)$"
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.anchorsMatchLines, .caseInsensitive]
        ) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let value = text[valueRange].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func stripANSI(_ text: String) -> String {
        let escape = "\u{001B}"
        return text.replacingOccurrences(
            of: "\(escape)\\[[0-9;]*[A-Za-z]|\(escape)\\].*?\u{0007}",
            with: "",
            options: .regularExpression
        )
    }
}
