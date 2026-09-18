public extension String {
    /// POSIX single-quoted form safe to embed in a shell command line.
    var shellQuoted: String {
        "'" + replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
