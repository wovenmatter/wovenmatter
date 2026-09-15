"""Confined workspace database operations. Invoked only by the authenticated service.

Descriptor-relative opens reject links at every component. SQLite runs against a
private, stable main+WAL snapshot, never an agent-controlled filename or sidecar.
"""
import base64
import contextlib
import json
import os
import sqlite3
import stat
import sys
import tempfile
import time
import uuid

FILE_LIMIT = 4 * 1024 * 1024
SNAPSHOT_LIMIT = 256 * 1024 * 1024
SQLITE_HEAP_LIMIT = 32 * 1024 * 1024
SCHEMA = 'wovenmatter.database.v1'


class CatalogError(Exception):
    pass


def require(value, message):
    if not value:
        raise CatalogError(message)


def name(value):
    require(isinstance(value, str) and 0 < len(value) <= 128
            and not value.startswith('.') and '/' not in value and '\\' not in value
            and all(ord(c) >= 32 and ord(c) != 127 for c in value), 'Invalid database name.')
    return value


def preference(value):
    require(value in ('none', 'json', 'sqlite'), 'Invalid data preference.')
    return value


@contextlib.contextmanager
def directory(path, parent=None):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
    try:
        yield fd
    finally:
        os.close(fd)


@contextlib.contextmanager
def regular(path, parent, optional=False):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    except FileNotFoundError:
        if not optional:
            raise
        yield None
        return
    try:
        require(stat.S_ISREG(os.fstat(fd).st_mode), 'Database data must be a regular file.')
        yield fd
    finally:
        os.close(fd)


def read(fd, limit):
    require(os.fstat(fd).st_size <= limit, 'Database data is too large.')
    data = bytearray()
    while True:
        chunk = os.read(fd, min(262144, limit + 1 - len(data)))
        if not chunk:
            return bytes(data)
        data.extend(chunk)
        require(len(data) <= limit, 'Database data is too large.')


def get_preference(db):
    try:
        with directory('.wovenmatter', db) as metadata:
            with regular('database.json', metadata) as fd:
                manifest = json.loads(read(fd, 16384))
        require(isinstance(manifest, dict) and manifest.get('schema') == SCHEMA, 'Unsupported database metadata.')
        return preference(manifest.get('preference'))
    except FileNotFoundError:
        return 'none'


def set_preference(db, value):
    value = preference(value)
    try:
        os.mkdir('.wovenmatter', mode=0o700, dir_fd=db)
    except FileExistsError:
        pass
    with directory('.wovenmatter', db) as metadata:
        temporary = '.database-' + str(uuid.uuid4())
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=metadata)
        try:
            with os.fdopen(fd, 'wb') as stream:
                stream.write(json.dumps({'schema': SCHEMA, 'preference': value}).encode())
                stream.flush()
                os.fsync(stream.fileno())
            os.rename(temporary, 'database.json', src_dir_fd=metadata, dst_dir_fd=metadata)
        finally:
            try:
                os.unlink(temporary, dir_fd=metadata)
            except FileNotFoundError:
                pass


def signature(status):
    return (status.st_dev, status.st_ino, status.st_size, status.st_mtime_ns, status.st_ctime_ns)


def result_value(value, remaining):
    """Check JSON wire size before allocating hex or escaped copies of a cell."""
    if isinstance(value, bytes):
        size = len(value) * 2 + 2  # Hex digits and JSON quotes.
        require(size <= remaining, 'The query result is too large.')
        return value.hex(), size
    text = '' if value is None else value if isinstance(value, str) else str(value)
    require(len(text) + 2 <= remaining, 'The query result is too large.')
    size = 2
    # Match json.dumps' default ensure_ascii encoding without allocating it.
    for character in text:
        code = ord(character)
        if code in (8, 9, 10, 12, 13, 34, 92):
            size += 2
        elif code < 32 or code >= 127:
            size += 6 if code <= 0xffff else 12
        else:
            size += 1
        require(size <= remaining, 'The query result is too large.')
    return text, size


def sqlite_query(parent, filename, query):
    require(isinstance(query, str) and 0 < len(query.encode()) <= 65536,
            'Enter a read-only SQLite query.')
    deadline = time.monotonic() + 5
    for attempt in range(3):
        with contextlib.ExitStack() as stack:
            files = {suffix: stack.enter_context(regular(filename + suffix, parent, optional=bool(suffix)))
                     for suffix in ('', '-wal', '-journal')}
            before = {suffix: os.fstat(fd) if fd is not None else None for suffix, fd in files.items()}
            journal = files['-journal']
            if journal is not None and before['-journal'].st_size > 512 and any(os.pread(journal, 8, 0)):
                continue  # A hot journal cannot be safely recovered without the live database locks.
            total = sum(s.st_size for suffix, s in before.items() if s is not None and suffix != '-journal')
            require(total <= SNAPSHOT_LIMIT, 'Database data is too large.')
            with tempfile.TemporaryDirectory(prefix='wovenmatter-database-') as temporary:
                target = os.path.join(temporary, 'snapshot.sqlite')
                copied = 0
                for suffix in ('', '-wal'):
                    fd = files[suffix]
                    if fd is None:
                        continue
                    with open(target + suffix, 'xb') as output:
                        while True:
                            chunk = os.read(fd, 262144)
                            if not chunk:
                                break
                            copied += len(chunk)
                            require(copied <= SNAPSHOT_LIMIT, 'Database data is too large.')
                            output.write(chunk)
                stable = True
                for suffix, fd in files.items():
                    try:
                        current = os.stat(filename + suffix, dir_fd=parent, follow_symlinks=False)
                    except FileNotFoundError:
                        current = None
                    original = before[suffix]
                    stable = stable and ((original is None and current is None) or
                        (original is not None and current is not None
                         and signature(original) == signature(current) == signature(os.fstat(fd))))
                if not stable:
                    continue
                connection = sqlite3.connect(target)
                try:
                    # SQLite materializes expression columns before Python can check
                    # the result budget. Bound that native heap as well as conversion.
                    heap = connection.execute(f'PRAGMA hard_heap_limit={SQLITE_HEAP_LIMIT}').fetchone()
                    # Linux is the service runtime. Apple's test-host SQLite disables
                    # memory accounting and reports zero for this pragma.
                    if sys.platform == 'linux':
                        require(heap and 0 < heap[0] <= SQLITE_HEAP_LIMIT, 'SQLite memory limits are unavailable.')
                    connection.execute('PRAGMA query_only=ON')
                    if hasattr(connection, 'enable_load_extension'):
                        connection.enable_load_extension(False)
                    # SELECT/read/function/recursive only: blocks ATTACH, PRAGMA, writes and schema changes.
                    allowed = {sqlite3.SQLITE_SELECT, sqlite3.SQLITE_READ, sqlite3.SQLITE_FUNCTION, sqlite3.SQLITE_RECURSIVE}
                    connection.set_authorizer(lambda action, a, b, database, source:
                        sqlite3.SQLITE_OK if action in allowed and not (action == sqlite3.SQLITE_FUNCTION and b == 'load_extension')
                        else sqlite3.SQLITE_DENY)
                    connection.set_progress_handler(lambda: int(time.monotonic() > deadline), 1000)
                    if hasattr(connection, 'setlimit'):
                        connection.setlimit(sqlite3.SQLITE_LIMIT_LENGTH, FILE_LIMIT)
                        connection.setlimit(sqlite3.SQLITE_LIMIT_COLUMN, 128)
                    cursor = connection.execute(query)
                    columns = [column[0] for column in cursor.description or []]
                    require(columns and len(columns) <= 128 and len(set(columns)) == len(columns), 'Use unique column names in the query.')
                    rows = []
                    size = len(json.dumps({'contractVersion': 1, 'columns': columns, 'rows': []}).encode())
                    for row in cursor:
                        size += (2 if rows else 0) + 2 + max(0, len(row) - 1) * 2
                        values = []
                        for value in row:
                            text, encoded_size = result_value(value, FILE_LIMIT - size)
                            values.append(text)
                            size += encoded_size
                        rows.append(values)
                        if len(rows) == 1000:
                            break
                    return {'contractVersion': 1, 'columns': columns, 'rows': rows}
                finally:
                    connection.close()
    raise CatalogError('Database is changing. Try refreshing again.')


def operation(root, request):
    action = request.get('action')
    with directory(root) as workspace, directory('Databases', workspace) as databases:
        if action == 'list':
            result = []
            # Scandir avoids allocating an unbounded list from an agent-controlled directory.
            with os.scandir(databases) as entries:
                for entry in entries:
                    if entry.name.startswith('.') or not entry.is_dir(follow_symlinks=False):
                        continue
                    database_name = name(entry.name)
                    with directory(database_name, databases) as db:
                        result.append({'id': database_name, 'name': database_name, 'preference': get_preference(db)})
                    require(len(result) <= 256, 'This workspace has too many databases to list.')
            return {'databases': sorted(result, key=lambda row: row['name'].casefold())}
        database_name = name(request.get('databaseID'))
        if action == 'create':
            preference(request.get('preference'))
            os.mkdir(database_name, mode=0o700, dir_fd=databases)
        with directory(database_name, databases) as db:
            if action in ('create', 'preference'):
                set_preference(db, request.get('preference'))
                return {'id': database_name, 'name': database_name, 'preference': request['preference']}
            require(action == 'data', 'Unsupported database operation.')
            path = request.get('relativePath')
            require(isinstance(path, str) and 0 < len(path.encode()) <= 4096 and '\\' not in path,
                    'The linked path must stay inside its database.')
            parts = path.split('/')
            require(len(parts) <= 64 and all(p and p not in ('.', '..') and not p.startswith('.')
                    and all(ord(c) >= 32 for c in p) for p in parts), 'The linked path must stay inside its database.')
            with contextlib.ExitStack() as stack:
                parent = db
                for part in parts[:-1]:
                    parent = stack.enter_context(directory(part, parent))
                extension = os.path.splitext(parts[-1])[1].lower()
                preferred = get_preference(db)
                if extension in ('.db', '.sqlite', '.sqlite3') or (extension != '.json' and preferred == 'sqlite'):
                    return {'query': sqlite_query(parent, parts[-1], request.get('sqliteQuery'))}
                require(extension == '.json' or preferred == 'json', 'Linked data supports JSON and read-only SQLite queries.')
                with regular(parts[-1], parent) as fd:
                    return {'jsonBase64': base64.b64encode(read(fd, FILE_LIMIT)).decode()}


if __name__ == '__main__':
    try:
        import resource
        resource.setrlimit(resource.RLIMIT_CPU, (8, 8))
        resource.setrlimit(resource.RLIMIT_FSIZE, (SNAPSHOT_LIMIT, SNAPSHOT_LIMIT))
        if sys.platform == 'linux':
            resource.setrlimit(resource.RLIMIT_AS, (128 * 1024 * 1024, 128 * 1024 * 1024))
        result = operation(sys.argv[1], json.load(sys.stdin))
        print(json.dumps(result))
    except MemoryError:
        print('{"error":"The query exceeds the memory limit. Use a smaller result."}')
        sys.exit(1)
    except (CatalogError, OSError, ValueError, sqlite3.Error, sqlite3.Warning) as error:
        if isinstance(error, FileExistsError):
            message = 'A database with that name already exists.'
        elif isinstance(error, OSError):
            message = 'Database folder or file is unavailable. Linked folders are not supported remotely.'
        elif isinstance(error, (sqlite3.Error, sqlite3.Warning)):
            message = 'The read-only SQLite query could not be completed.'
        else:
            message = str(error)
        print(json.dumps({'error': message}))
        sys.exit(1)
