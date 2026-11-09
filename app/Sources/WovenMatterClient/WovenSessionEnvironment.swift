import Foundation
#if canImport(SystemConfiguration)
import SystemConfiguration
#endif

/// Sessions are often started from another device while nobody is at this Mac.
/// Every process Woven launches for a session therefore gets an environment in
/// which credential prompts fail at once with a message instead of hanging:
/// a `sudo` that runs the real sudo with `-n`, and an askpass helper that
/// refuses git, ssh and `sudo -A` prompts. The scripts are byte-for-byte the
/// Linux host's `remote/host/session-tools`, which tests verify.
public enum WovenSessionEnvironment {
    public static let sudoScript = #"""
    #!/bin/sh
    # Woven Matter session sudo. Sessions often start from another device, so nobody
    # can answer a password prompt here. Run the real sudo non-interactively: rules
    # that need no password (such as Full root) work, and anything else fails at once.
    real=${WOVENMATTER_REAL_SUDO:-/usr/bin/sudo}
    device=${WOVENMATTER_DEVICE_NAME:-$(hostname 2>/dev/null)}
    device=${device:-this device}
    if [ ! -x "$real" ]; then
      echo "Woven Matter: sudo is not installed on $device." >&2
      exit 1
    fi
    errors=$(mktemp "${TMPDIR:-/tmp}/woven-sudo.XXXXXX" 2>/dev/null) || exec "$real" -n "$@"
    "$real" -n "$@" 2>"$errors"
    status=$?
    cat "$errors" >&2
    if [ "$status" -ne 0 ]; then
      if grep -qi -e 'password is required' -e 'terminal is required' -e 'no askpass program' "$errors"; then
        echo "Woven Matter: This command needs $device's password. Sessions started by Woven Matter cannot answer password prompts, so it stopped instead of waiting. Run it yourself on $device, or use a way that does not need administrator rights." >&2
      elif grep -qi -e 'no new privileges' "$errors"; then
        echo "Woven Matter: This workspace runs agents with normal user permissions, so sudo is unavailable on $device." >&2
      fi
    fi
    rm -f "$errors"
    exit "$status"

    """#

    public static let askpassScript = #"""
    #!/bin/sh
    # Woven Matter askpass for sessions (git, ssh, sudo -A). Nobody may be at this
    # device's screen, so refuse at once instead of waiting for an answer.
    device=${WOVENMATTER_DEVICE_NAME:-$(hostname 2>/dev/null)}
    device=${device:-this device}
    echo "Woven Matter: ${1:-A credential prompt} was requested on $device. Sessions started by Woven Matter cannot answer password prompts, so it stopped instead of waiting." >&2
    exit 1

    """#

    public static var defaultDirectory: URL {
        LocalACPManagedRuntimePaths.applicationSupportDirectory
            .appending(path: "Session Tools", directoryHint: .isDirectory)
    }

    /// Writes the helpers when missing or changed. Returns nil when they cannot be
    /// written; the prompt-disabling variables still apply in that case.
    @discardableResult
    public static func install(in directory: URL = defaultDirectory) -> URL? {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, script) in [("sudo", sudoScript), ("askpass", askpassScript)] {
                let url = directory.appending(path: name)
                let data = Data(script.utf8)
                if (try? Data(contentsOf: url)) != data {
                    try data.write(to: url, options: .atomic)
                }
                let mode = (try? manager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
                if mode != 0o755 { try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
            }
            return directory
        } catch {
            return nil
        }
    }

    /// Installed once per process, on first use.
    public static let installedDirectory: URL? = install()

    /// The device name the helpers use in their messages, e.g. "Mac Mini".
    public static let deviceName: String = {
        #if canImport(SystemConfiguration)
        let name = SCDynamicStoreCopyComputerName(nil, nil) as String?
        return name?.isEmpty == false ? name! : "this Mac"
        #else
        let name = ProcessInfo.processInfo.hostName
        return name.isEmpty ? "this machine" : name
        #endif
    }()

    /// Applies the no-prompt overlay to a session process environment.
    public static func apply(to environment: inout [String: String],
                             toolsDirectory: URL? = installedDirectory,
                             deviceName: String = deviceName) {
        if let toolsDirectory {
            let tools = toolsDirectory.path
            let paths = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
                .split(separator: ":").map(String.init).filter { !$0.isEmpty && $0 != tools }
            environment["PATH"] = ([tools] + paths).joined(separator: ":")
            let askpass = toolsDirectory.appending(path: "askpass").path
            environment["GIT_ASKPASS"] = askpass
            environment["SSH_ASKPASS"] = askpass
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environment["SUDO_ASKPASS"] = askpass
        }
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GCM_INTERACTIVE"] = "never"
        environment["DEBIAN_FRONTEND"] = "noninteractive"
        if environment["WOVENMATTER_DEVICE_NAME"]?.isEmpty != false { environment["WOVENMATTER_DEVICE_NAME"] = deviceName }
    }
}
