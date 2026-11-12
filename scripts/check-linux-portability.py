#!/usr/bin/env python3
"""Flag Apple-only Swift in the targets that the Linux library build compiles.

Automatic PR CI cannot compile Swift for Linux within its time budget, so this
static check catches the mistakes that broke the v0.4.0 release build: an
unguarded Apple framework import, a CoreFoundation-only call, or networking
types used without `import FoundationNetworking`. It evaluates `#if` blocks the
way a Linux compiler would. Manual `linux` validation remains the full compile.

usage: scripts/check-linux-portability.py [--root DIR] [FILE ...]
With no FILE it checks every Swift file in the Linux-built targets.
"""
import argparse
import re
import sys
from pathlib import Path

# Packages whose targets `scripts/test-linux-library.sh` builds and tests.
PACKAGES = ('app', 'shared')

# Modules that do not exist on Linux. Importing one there is a compile error.
APPLE_MODULES = frozenset('''
    AppKit AuthenticationServices Cocoa Combine CoreFoundation CoreGraphics
    CoreServices CryptoKit Darwin IOKit LocalAuthentication Network ObjectiveC
    OSLog Security ServiceManagement SQLite3 SwiftUI SystemConfiguration UIKit
    UniformTypeIdentifiers Vision WebKit os
'''.split())
# Modules a Linux build can import.
LINUX_MODULES = frozenset('''
    CSQLite Crypto Dispatch Foundation FoundationEssentials FoundationNetworking
    FoundationXML Glibc Musl Synchronization Testing XCTest
'''.split())
# Foundation types that live in FoundationNetworking on Linux. (URLError does not.)
NETWORKING_TYPES = ('URLSession', 'URLSessionConfiguration', 'URLSessionTask',
                    'URLSessionDataTask', 'URLSessionWebSocketTask', 'URLRequest',
                    'URLResponse', 'HTTPURLResponse', 'URLProtocol', 'URLCache',
                    'URLCredential')
NETWORKING = re.compile(r'\b(?:%s)\b' % '|'.join(NETWORKING_TYPES))
# Apple-only APIs that Foundation on Linux does not provide.
APPLE_APIS = (
    (re.compile(r'\bCF[A-Z]\w*\s*\('), 'CoreFoundation function'),
    (re.compile(r'\bkCF[A-Z]\w*'), 'CoreFoundation constant'),
    (re.compile(r'\b(?:os_log|os_signpost)\s*\('), 'os_log'),
    (re.compile(r'\bSec(?:Item|Key|Trust|AccessControl|Certificate|Code|Task)\w*\b'), 'Security framework API'),
    (re.compile(r'\bLAContext\b'), 'LocalAuthentication API'),
    (re.compile(r'\bNS(?:Workspace|Application|Pasteboard|Image|Color|Font|View|Window)\b'), 'AppKit type'),
    (re.compile(r'\bautoreleasepool\s*\{'), 'autoreleasepool'),
)
IMPORT = re.compile(r'^\s*(?:@[\w.]+(?:\([^)]*\))?\s+)*import\s+'
                    r'(?:(?:class|struct|enum|protocol|typealias|func|var|let)\s+)?([A-Za-z_]\w*)')
DIRECTIVE = re.compile(r'^\s*#\s*(if|elseif|else|endif)\b(.*)$')
TARGET_CALL = re.compile(r'\.(target|testTarget|executableTarget)\s*\(')

TRUE, FALSE, UNKNOWN = 'T', 'F', '?'


def _not(value):
    return {TRUE: FALSE, FALSE: TRUE}.get(value, UNKNOWN)


def _and(left, right):
    if FALSE in (left, right):
        return FALSE
    return TRUE if left == right == TRUE else UNKNOWN


def _or(left, right):
    if TRUE in (left, right):
        return TRUE
    return FALSE if left == right == FALSE else UNKNOWN


def evaluate(condition):
    """Evaluates a `#if` condition for a Linux build: T, F or ? (unknown)."""
    tokens = re.findall(r'&&|\|\||!|\(|\)|[A-Za-z_][\w.]*\s*\([^()]*\)|[A-Za-z_]\w*|[<>=]=?[^&|)]*', condition)
    position = 0

    def peek():
        return tokens[position] if position < len(tokens) else None

    def take():
        nonlocal position
        position += 1
        return tokens[position - 1]

    def primary():
        token = take() if peek() else None
        if token is None:
            return UNKNOWN
        if token == '!':
            return _not(primary())
        if token == '(':
            value = disjunction()
            if peek() == ')':
                take()
            return value
        call = re.fullmatch(r'([A-Za-z_]\w*)\s*\(\s*([^()]*?)\s*\)', token)
        if call:
            name, argument = call.groups()
            if name == 'os':
                return TRUE if argument == 'Linux' else FALSE
            if name == 'canImport':
                module = argument.split('.')[0].split(',')[0].strip()
                if module in APPLE_MODULES:
                    return FALSE
                return TRUE if module in LINUX_MODULES else UNKNOWN
            if name == 'targetEnvironment':
                return FALSE
            return UNKNOWN
        if token == 'true':
            return TRUE
        if token == 'false':
            return FALSE
        return UNKNOWN

    def conjunction():
        value = primary()
        while peek() == '&&':
            take()
            value = _and(value, primary())
        return value

    def disjunction():
        value = conjunction()
        while peek() == '||':
            take()
            value = _or(value, conjunction())
        return value

    return disjunction()


def code_lines(text):
    """Yields (line number, code) with comments and string contents removed."""
    in_block = 0
    in_multiline = False
    for number, line in enumerate(text.splitlines(), 1):
        out = []
        index = 0
        while index < len(line):
            if in_block:
                end = line.find('*/', index)
                start = line.find('/*', index)
                if start != -1 and (end == -1 or start < end):
                    in_block += 1
                    index = start + 2
                elif end != -1:
                    in_block -= 1
                    index = end + 2
                else:
                    index = len(line)
                continue
            if in_multiline:
                end = line.find('"""', index)
                if end == -1:
                    index = len(line)
                else:
                    in_multiline = False
                    out.append('""')
                    index = end + 3
                continue
            if line.startswith('//', index):
                break
            if line.startswith('/*', index):
                in_block = 1
                index += 2
                continue
            if line.startswith('"""', index):
                in_multiline = True
                index += 3
                continue
            if line[index] == '"':
                index += 1
                while index < len(line) and line[index] != '"':
                    index += 2 if line[index] == '\\' else 1
                out.append('""')
                index += 1
                continue
            out.append(line[index])
            index += 1
        yield number, ''.join(out)


def active_lines(text):
    """Yields (line number, code) for lines a Linux build may compile."""
    stack = []  # [current, any earlier branch taken, any earlier branch unknown]
    for number, code in code_lines(text):
        directive = DIRECTIVE.match(code)
        if directive:
            kind, condition = directive.group(1), directive.group(2).strip()
            if kind == 'if':
                value = evaluate(condition)
                stack.append([value, value == TRUE, value == UNKNOWN])
            elif kind == 'elseif' and stack:
                entry = stack[-1]
                value = FALSE if entry[1] else evaluate(condition)
                if value != FALSE and entry[2]:
                    value = UNKNOWN
                entry[0] = value
                entry[1] = entry[1] or value == TRUE
                entry[2] = entry[2] or value == UNKNOWN
            elif kind == 'else' and stack:
                entry = stack[-1]
                entry[0] = FALSE if entry[1] else (UNKNOWN if entry[2] else TRUE)
            elif kind == 'endif' and stack:
                stack.pop()
            continue
        if all(entry[0] != FALSE for entry in stack):
            yield number, code


def check_text(text):
    """Returns [(line number, message)] for Linux-incompatible code."""
    problems = []
    networking_import = False
    networking_use = None
    for number, code in active_lines(text):
        imported = IMPORT.match(code)
        if imported:
            module = imported.group(1)
            if module in APPLE_MODULES:
                problems.append((number, f'imports {module}, which Linux does not have; '
                                         f'guard it with #if canImport({module})'))
            if module == 'FoundationNetworking':
                networking_import = True
            continue
        for pattern, label in APPLE_APIS:
            found = pattern.search(code)
            if found:
                problems.append((number, f'uses {label} `{found.group(0).strip()}`, '
                                         'which Linux does not have; guard it with #if canImport(Darwin)'))
        if networking_use is None:
            found = NETWORKING.search(code)
            if found:
                networking_use = (number, found.group(0))
    if networking_use and not networking_import:
        number, name = networking_use
        problems.append((number, f'uses {name} without `import FoundationNetworking`; add '
                                 '#if canImport(FoundationNetworking) import FoundationNetworking #endif'))
    return problems


def _calls(manifest):
    """Yields (kind, call text) for each target declaration in a manifest."""
    for found in TARGET_CALL.finditer(manifest):
        depth, index = 1, found.end()
        while index < len(manifest) and depth:
            depth += {'(': 1, ')': -1}.get(manifest[index], 0)
            index += 1
        yield found.group(1), manifest[found.end():index - 1]


def linux_sources(root):
    """Swift files of the targets each package builds on Linux."""
    files = []
    for package in PACKAGES:
        manifest = (root / package / 'Package.swift').read_text()
        excluded = set()
        apple_only = re.search(r'appleOnlyTargets[^=]*=\s*\[([^\]]*)\]', manifest)
        if apple_only:
            excluded = set(re.findall(r'"([^"]+)"', apple_only.group(1)))
        for kind, call in _calls(manifest):
            name = re.search(r'name:\s*"([^"]+)"', call).group(1)
            if name in excluded:
                continue
            path = re.search(r'path:\s*"([^"]+)"', call)
            directory = root / package / (path.group(1) if path else
                                          ('Tests/' if kind == 'testTarget' else 'Sources/') + name)
            files.extend(sorted(directory.rglob('*.swift')))
    return files


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument('files', nargs='*', type=Path)
    arguments = parser.parse_args(argv)
    root = arguments.root.resolve()
    files = arguments.files or linux_sources(root)
    if not files:
        print('No Linux-built Swift sources found; check the package manifests.', file=sys.stderr)
        return 1
    failures = 0
    for path in files:
        for number, message in check_text(path.read_text(encoding='utf-8')):
            shown = path.resolve().relative_to(root) if path.resolve().is_relative_to(root) else path
            print(f'{shown}:{number}: {message}')
            failures += 1
    if failures:
        print(f'{failures} Linux portability problem(s) in Swift built for the Linux library. '
              'Fix them, or run the manual `linux` validation to confirm a false positive.',
              file=sys.stderr)
        return 1
    print(f'Linux portability: {len(files)} Swift files checked.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
