"""Workspace-owned datasets. SQLite backups publish complete schema+data replicas."""
import base64
import fcntl
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import time
import uuid
from datetime import datetime, timezone

LIMIT = 32 * 1024 * 1024


def require(value, message):
    if not value:
        raise ValueError(message)


def write_catalog(root, rows):
    temporary = root / ('.catalog-' + str(uuid.uuid4()))
    try:
        temporary.write_text(json.dumps(rows))
        os.replace(temporary, root / 'catalog.json')
    finally:
        temporary.unlink(missing_ok=True)


def timestamp():
    return datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')


def database_path(root, identity):
    require(isinstance(identity, str) and str(uuid.UUID(identity)) == identity, 'Invalid database identity.')
    return root / (identity + '.sqlite')


def connect(path, writable=False):
    require(not path.is_symlink(), 'Database links are not supported.')
    if not writable:
        require(path.is_file(), 'The managed database file is unavailable.')
    connection = sqlite3.connect(str(path), timeout=5)
    if hasattr(connection, 'enable_load_extension'):
        connection.enable_load_extension(False)
    if hasattr(connection, 'setlimit'):
        connection.setlimit(sqlite3.SQLITE_LIMIT_LENGTH, LIMIT)
    deadline = time.monotonic() + 5
    connection.set_progress_handler(lambda: int(time.monotonic() > deadline), 1000)
    return connection


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



def snapshot(root, row):
    with tempfile.TemporaryDirectory(dir=root, prefix='.snapshot-') as temporary:
        path = Path(temporary) / 'data.sqlite'
        with connect(database_path(root, row['id'])) as source, sqlite3.connect(path) as target:
            source.backup(target)
            target.execute("PRAGMA journal_mode=DELETE")
        require(path.stat().st_size <= LIMIT, 'Database snapshot exceeds 32 MiB.')
        return {'database': row, 'sqliteBase64': base64.b64encode(path.read_bytes()).decode()}


def operation(directory, request):
    root = Path(directory).absolute()
    root.mkdir(parents=True, exist_ok=True)
    require(not root.is_symlink(), 'Managed database storage must not be linked.')
    lock = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX)
        owner_file = root / '.owner'
        if not owner_file.exists():
            owner_file.write_text('workspace:' + str(uuid.uuid4()))
        owner = owner_file.read_text()
        catalog = root / 'catalog.json'
        rows = json.loads(catalog.read_text()) if catalog.exists() else []
        for row in rows:
            with connect(database_path(root, row['id'])) as connection:
                row['revision'] = connection.execute('PRAGMA user_version').fetchone()[0]
        action = request.get('action')
        if action == 'list':
            return {'databases': sorted(rows, key=lambda row: row['name'].casefold())}
        if action in ('create', 'copy'):
            name = request.get('name') or request.get('databaseID')
            require(isinstance(name, str) and name.strip() and len(name) <= 128 and '\0' not in name, 'Enter a database name of 1–128 characters.')
            name = name.strip()
            require(not any(row['name'].casefold() == name.casefold() for row in rows), 'A database with that name already exists.')
            identity = str(uuid.uuid4())
            path = database_path(root, identity)
            if action == 'copy':
                incoming = request['snapshot']
                data = base64.b64decode(incoming['sqliteBase64'], validate=True)
                require(len(data) <= LIMIT and data.startswith(b'SQLite format 3\0'), 'Invalid SQLite snapshot.')
                path.write_bytes(data)
                with connect(path) as connection:
                    require(connection.execute('PRAGMA quick_check').fetchone()[0] == 'ok', 'Invalid SQLite snapshot.')
                    connection.execute('PRAGMA journal_mode=DELETE')
                    connection.execute('PRAGMA user_version=1')
            else:
                with connect(path, True) as connection:
                    connection.execute('PRAGMA journal_mode=WAL')
                    connection.execute('PRAGMA user_version=1')
            row = {'id': identity, 'name': name.strip(), 'revision': 1, 'updatedAt': timestamp(), 'owner': owner,
                   'url': path.as_uri(), 'preference': 'sqlite'}
            rows.append(row)
            write_catalog(root, rows)
            return row
        identity = request.get('databaseID')
        row = next((row for row in rows if row['id'] == identity), None)
        require(row and row['owner'] == owner, 'The writable database owner is unavailable.')
        path = database_path(root, identity)
        if action == 'snapshot':
            return snapshot(root, row)
        query = request.get('sqliteQuery') or request.get('sql')
        require(isinstance(query, str) and query and len(query.encode()) <= 262144, 'Enter SQL up to 256 KiB.')
        with connect(path, action == 'execute') as connection:
            if action == 'execute':
                connection.execute('BEGIN IMMEDIATE')
                forbidden = {sqlite3.SQLITE_ATTACH, sqlite3.SQLITE_DETACH, sqlite3.SQLITE_TRANSACTION, sqlite3.SQLITE_SAVEPOINT, sqlite3.SQLITE_PRAGMA}
                connection.set_authorizer(lambda action, a, b, db, origin: sqlite3.SQLITE_DENY if action in forbidden or (action == sqlite3.SQLITE_FUNCTION and b == 'load_extension') else sqlite3.SQLITE_OK)
                # Execute statement-by-statement without executescript's implicit COMMIT.
                pending = ''
                for character in query:
                    pending += character
                    if character == ';' and sqlite3.complete_statement(pending):
                        connection.execute(pending)
                        pending = ''
                if pending.strip():
                    connection.execute(pending)
                connection.set_authorizer(lambda *args: sqlite3.SQLITE_OK)
                connection.execute("PRAGMA user_version=" + str(row["revision"] + 1))
                connection.commit()
                row['revision'] += 1
                row['updatedAt'] = timestamp()
                write_catalog(root, rows)
                return row
            require(action in ('query', 'data'), 'Unsupported database operation.')
            connection.execute('PRAGMA query_only=ON')
            heap = connection.execute('PRAGMA hard_heap_limit=33554432').fetchone()
            if sys.platform == 'linux':
                require(heap and 0 < heap[0] <= 33554432, 'SQLite memory limits are unavailable.')
            allowed = {sqlite3.SQLITE_SELECT, sqlite3.SQLITE_READ, sqlite3.SQLITE_FUNCTION, sqlite3.SQLITE_RECURSIVE}
            connection.set_authorizer(lambda action, a, b, db, origin: sqlite3.SQLITE_OK if action in allowed and not (action == sqlite3.SQLITE_FUNCTION and b == 'load_extension') else sqlite3.SQLITE_DENY)
            cursor = connection.execute(query)
            columns = [column[0] for column in cursor.description or []]
            require(columns and len(columns) <= 128 and len(columns) == len(set(columns)), 'Use unique query column names.')
            values = []
            size = len(json.dumps({'contractVersion': 1, 'columns': columns, 'rows': []}).encode())
            for row in cursor:
                converted = []
                size += 2 + max(0, len(row) - 1) * 2 + (2 if values else 0)
                for value in row:
                    text, encoded_size = result_value(value, 1024 * 1024 - size)
                    converted.append(text)
                    size += encoded_size
                values.append(converted)
                if len(values) == 1000:
                    break
            result = {'contractVersion': 1, 'columns': columns, 'rows': values}
            return {'query': result}

    except MemoryError as error:
        # Python raises MemoryError for SQLITE_NOMEM, outside sqlite3.Error.
        # Keep the response bounded and useful to both HTTP and owner-local CLI callers.
        raise ValueError('The query exceeded the SQLite memory limit. Try a smaller query.') from error
    finally:
        os.close(lock)


if __name__ == '__main__':
    try:
        print(json.dumps(operation(sys.argv[1], json.load(sys.stdin))))
    except (ValueError, OSError, sqlite3.Error, KeyError) as error:
        print(json.dumps({'error': str(error)}))
        sys.exit(1)
