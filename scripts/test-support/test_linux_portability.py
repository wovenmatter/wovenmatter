"""The PR portability check sees Swift the way a Linux compiler does."""
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('portability', ROOT / 'scripts/check-linux-portability.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def problems(source):
    return [message for _, message in module.check_text(source)]


# The exact mistakes that broke the v0.4.0 Linux library build.
assert any('CryptoKit' in m for m in problems('import CryptoKit\nimport Foundation\n'))
assert any('SQLite3' in m for m in problems('import Foundation\nimport SQLite3\n'))
assert any('CFGetTypeID' in m for m in problems(
    'import Foundation\nfunc f(n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }\n'))
assert any('FoundationNetworking' in m for m in problems(
    'import Foundation\nlet s = URLSession(configuration: .ephemeral)\n'))
assert any('HTTPURLResponse' in m for m in problems('import Foundation\nfunc f(_ r: HTTPURLResponse) {}\n'))
assert problems('@preconcurrency import Security\n')
assert problems('import class AppKit.NSWorkspace\n')

# Their fixes, and the guards the tree already uses, pass.
assert problems('''
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Foundation
let s = URLSession(configuration: .ephemeral)
#if canImport(Darwin)
func f(n: NSNumber) -> Bool { CFGetTypeID(n) == CFBooleanGetTypeID() }
#else
func f(n: NSNumber) -> Bool { String(cString: n.objCType) == "c" }
#endif
''') == []
assert problems('#if os(macOS)\nimport AppKit\nlet w = NSWorkspace.shared\n#endif\n') == []
assert problems('#if !os(Linux)\nimport OSLog\n#endif\n') == []
assert problems('#if os(Linux)\nimport Glibc\n#else\nimport Darwin\n#endif\n') == []
assert problems('#if os(Linux)\n#elseif os(macOS)\nimport AppKit\n#endif\n') == []
assert problems('#if canImport(Darwin) && DEBUG\nimport Darwin\n#endif\n') == []
assert problems('#if os(iOS) || os(macOS)\nimport UIKit\n#endif\n') == []
# URLError is part of Foundation on Linux.
assert problems('import Foundation\nthrow URLError(.badURL)\n') == []

# Unknown conditions can compile on Linux, so both branches are checked.
assert problems('#if DEBUG\nimport Security\n#endif\n')
assert problems('#if DEBUG\n#else\nimport Security\n#endif\n')
assert problems('#if canImport(Glibc)\n#else\nimport Darwin\n#endif\n') == []
assert problems('#if canImport(Darwin)\n#else\nimport Security\n#endif\n')
# Nested blocks inherit an inactive parent.
assert problems('#if os(macOS)\n#if DEBUG\nimport AppKit\n#endif\n#endif\n') == []

# Comments, strings and multi-line strings are not code.
assert problems('// import AppKit\n/* import Security\n CFGetTypeID(x) */\nlet s = "CFGetTypeID(x)"\n') == []
assert problems('let s = """\nURLSession\nimport AppKit\n"""\n') == []

# The Linux file set follows the manifests: portable targets in, Apple-only out.
files = {path.relative_to(ROOT).as_posix() for path in module.linux_sources(ROOT)}
for expected in ['app/Sources/WovenMatterCore/', 'app/Sources/WovenMatterClient/',
                 'app/Sources/WovenMatterDashboardStore/', 'app/Sources/WovenMatterLibraryHost/',
                 'app/Sources/WovenMatterLibraryDaemon/', 'app/Tests/WovenMatterCoreTests/',
                 'app/Tests/WovenMatterLibraryHostTests/', 'app/TestsSupport/WorkspaceFixtures/',
                 'shared/Sources/WovenMatterShared/']:
    assert any(path.startswith(expected) for path in files), expected
for excluded in ['app/App/', 'app/Sources/WovenMatterAutomation/', 'app/Tests/WovenMatterAppFacadeTests/',
                 'app/TestsSupport/CuaDesktopFixture/']:
    assert not any(path.startswith(excluded) for path in files), excluded
print('Linux portability check tests passed.')
