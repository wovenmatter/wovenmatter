"""Woven Matter's documented in-process commands, executed by real CPython/WASM.

This is intentionally not a POSIX shell. argv is an array; no pipes, substitutions,
subprocesses or implicit network access. Python provides the full bundled stdlib.
"""
import ast, asyncio, contextlib, inspect, io, json, os, pathlib, re, runpy, shutil, sqlite3, sys, traceback

COMMANDS = {
    "python": "python [-c SOURCE | -m MODULE | FILE] [ARGS...]; supports top-level await",
    "python3": "Alias of python (CPython 3.14.2)",
    "wovenmatter": "wovenmatter GROUP COMMAND [OPTIONS...]; native Woven Matter CLI bridge",
    "pwd": "pwd",
    "ls": "ls [-a] [PATH...]",
    "cat": "cat [FILE...]; no files reads stdin",
    "mkdir": "mkdir [-p] PATH...",
    "cp": "cp [-r] SOURCE DESTINATION",
    "mv": "mv SOURCE DESTINATION",
    "rm": "rm [-r] [-f] PATH...",
    "find": "find [DIRECTORY]; lists descendants",
    "grep": "grep [-i] [-n] REGEX [FILE...]; no files reads stdin",
    "sqlite3": "sqlite3 DATABASE SQL; prints rows as JSON arrays",
    "help": "help; lists these exact supported commands",
}

async def wovenmatter(arguments):
    """Use await wovenmatter(['calendar', ...]) from Python; returns decoded CLI JSON."""
    from woven_native import command
    arguments = list(arguments)
    require(all(isinstance(value, str) for value in arguments), "CLI arguments must be strings")
    offset = 2 if arguments[:1] == ["--target"] else 0
    group, action = (arguments[offset:offset + 2] + ["", ""])[:2]
    # These are the shared CLI's only file-input commands. Resolve against the
    # running virtual cwd, not the native workspace's pre-command snapshot.
    inline = {("executor", "execute"): "--code", ("notes", "apply"): "--json", ("notes", "set-html"): "--html"}.get((group, action))
    if inline:
        index = offset + 2
        while index < len(arguments):
            value = arguments[index]
            if value in ("--help", "-h"):
                index += 1; continue
            if value == "--file":
                require(index + 1 < len(arguments), "--file requires a workspace path")
                path = pathlib.Path(arguments[index + 1]).resolve()
                require(path.is_relative_to("/workspace"), "CLI input file must be inside /workspace")
                require(path.stat().st_size <= 4 * 1024 * 1024, "The command input file is too large (maximum 4 MiB).")
                arguments[index] = inline
                arguments[index + 1] = path.read_text(encoding="utf-8", errors="strict")
            index += 2 if value.startswith("--") else 1
    return json.loads(await command(json.dumps(arguments)))


def require(condition, usage):
    if not condition:
        raise ValueError(usage)


def flags(arguments, accepted):
    selected, rest, parsing = set(), [], True
    for value in arguments:
        if parsing and value == "--":
            parsing = False
        elif parsing and value.startswith("-") and value != "-":
            require(all(letter in accepted for letter in value[1:]), "Unsupported option: " + value)
            selected.update(value[1:])
        else:
            rest.append(value)
    return selected, rest


async def execute(argv, stdin=""):
    require(bool(argv), "Specify an argv array; use ['help'] to list commands.")
    command, args = argv[0], argv[1:]
    require(command in COMMANDS, "Command not bundled: " + command + ". Use help; arbitrary OS processes are unavailable.")
    original_argv, original_stdin = sys.argv, sys.stdin
    sys.stdin = io.StringIO(stdin)
    try:
        if command in ("python", "python3"):
            require(bool(args), COMMANDS[command])
            namespace = {"__name__": "__main__", "__builtins__": __builtins__, "wovenmatter": wovenmatter}
            if args[0] == "-c":
                require(len(args) >= 2, COMMANDS[command])
                sys.argv = ["-c"] + args[2:]
                source, filename = args[1], "<command>"
            elif args[0] == "-m":
                require(len(args) >= 2, COMMANDS[command])
                sys.argv = [args[1]] + args[2:]
                runpy.run_module(args[1], run_name="__main__", alter_sys=True)
                return 0
            else:
                require(not args[0].startswith("-"), COMMANDS[command])
                sys.argv = list(args)
                filename = str(pathlib.Path(args[0]).resolve())
                namespace["__file__"] = filename
                source = pathlib.Path(filename).read_text()
            result = eval(compile(source, filename, "exec", flags=ast.PyCF_ALLOW_TOP_LEVEL_AWAIT), namespace)
            if inspect.isawaitable(result):
                await result
        elif command == "wovenmatter":
            print(json.dumps(await wovenmatter(args), ensure_ascii=False))
        elif command == "help":
            import pyodide
            print(json.dumps({"runtime": "CPython " + sys.version.split()[0] + " / Pyodide " + pyodide.__version__, "commands": COMMANDS,
              "modules": ["json", "csv", "sqlite3", "re", "statistics", "decimal", "pathlib", "zipfile", "tarfile", "unittest", "asyncio"],
              "limits": "No OS processes, sockets, package downloads, or native extension installs. Files persist only under /workspace. Native CLI uses awaited wovenmatter(arguments)."}, indent=2))
        elif command == "pwd":
            require(not args, COMMANDS[command]); print(os.getcwd())
        elif command == "ls":
            opts, paths = flags(args, "a")
            for path in paths or ["."]:
                p = pathlib.Path(path)
                if p.is_dir():
                    for child in sorted(p.iterdir()):
                        if "a" in opts or not child.name.startswith("."):
                            print(child.name + ("/" if child.is_dir() else ""))
                else:
                    require(p.exists(), "Path does not exist: " + path); print(path)
        elif command == "cat":
            for path in args or ["-"]:
                print(sys.stdin.read() if path == "-" else pathlib.Path(path).read_text(), end="")
        elif command == "mkdir":
            opts, paths = flags(args, "p"); require(paths, COMMANDS[command])
            for path in paths: pathlib.Path(path).mkdir(parents="p" in opts, exist_ok="p" in opts)
        elif command == "cp":
            opts, paths = flags(args, "r"); require(len(paths) == 2, COMMANDS[command])
            source, destination = map(pathlib.Path, paths)
            if destination.is_dir(): destination /= source.name
            if source.is_dir():
                require("r" in opts, "Use cp -r for directories")
                shutil.copytree(source, destination, dirs_exist_ok=True)
            else: shutil.copy2(source, destination)
        elif command == "mv":
            require(len(args) == 2, COMMANDS[command]); shutil.move(*args)
        elif command == "rm":
            opts, paths = flags(args, "rf"); require(paths, COMMANDS[command])
            for path in paths:
                p = pathlib.Path(path)
                if not p.exists() and not p.is_symlink() and "f" in opts: continue
                if p.is_dir() and not p.is_symlink():
                    require("r" in opts, "Use rm -r for directories"); shutil.rmtree(p)
                else: p.unlink()
        elif command == "find":
            require(len(args) <= 1, COMMANDS[command])
            p = pathlib.Path(args[0] if args else ".")
            require(p.exists(), "Path does not exist: " + str(p))
            print(str(p))
            for root, directories, files in os.walk(p, followlinks=False):
                directories.sort(); files.sort()
                for name in directories + files: print(str(pathlib.Path(root) / name))
        elif command == "grep":
            opts, paths = flags(args, "in"); require(paths, COMMANDS[command])
            pattern = re.compile(paths[0], re.IGNORECASE if "i" in opts else 0)
            count = 0
            for path in paths[1:] or ["-"]:
                stream = contextlib.nullcontext(sys.stdin) if path == "-" else open(path)
                with stream as lines:
                    for number, line in enumerate(lines, 1):
                        if pattern.search(line):
                            count += 1
                            print((str(number) + ":" if "n" in opts else "") + line, end="" if line.endswith("\n") else "\n")
            return 0 if count else 1
        elif command == "sqlite3":
            require(len(args) == 2, COMMANDS[command])
            with sqlite3.connect(args[0]) as database:
                rows = database.execute(args[1])
                for row in rows: print(json.dumps(row, ensure_ascii=False))
        return 0
    except SystemExit as error:
        if error.code is None: return 0
        if isinstance(error.code, int): return error.code
        print(str(error.code), file=sys.stderr); return 1
    except BaseException:
        traceback.print_exc(); return 1
    finally:
        sys.argv, sys.stdin = original_argv, original_stdin
