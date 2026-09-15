"""Native Hermes platform: acknowledge only a durable, run-scoped local commit."""
import os
import sqlite3
import time
from pathlib import Path


def save_result(home, job_id, message, pid):
    home = Path(home).resolve()
    # Hermes owns this execution ledger. Never infer a run from wall-clock time
    # or message content: two identical outputs can be different executions.
    with sqlite3.connect((home / 'cron/executions.db').as_uri() + '?mode=ro', uri=True) as ledger:
        rows = ledger.execute(
            "SELECT id, started_at FROM executions WHERE job_id=? AND pid=? AND status='running'",
            (job_id, pid)).fetchall()
    if len(rows) != 1:
        raise ValueError('Woven Matter delivery requires one authoritative running cron execution')
    run_id, started_at = rows[0]
    directory = home / '.woven-matter'
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    database = directory / 'scheduled-results.sqlite'
    # Atomic creation with restrictive permissions, including before sqlite opens.
    fd = os.open(database, os.O_CREAT | os.O_WRONLY, 0o600)
    os.close(fd)
    with sqlite3.connect(database, timeout=30) as connection:
        connection.execute('PRAGMA journal_mode=WAL')
        connection.execute('PRAGMA synchronous=FULL')
        connection.execute('''CREATE TABLE IF NOT EXISTS results(
            job_id TEXT NOT NULL, run_id TEXT NOT NULL, output TEXT NOT NULL,
            started_at TEXT, saved_at REAL NOT NULL, PRIMARY KEY(job_id, run_id))''')
        connection.execute('BEGIN IMMEDIATE')
        previous = connection.execute('SELECT output FROM results WHERE job_id=? AND run_id=?', (job_id, run_id)).fetchone()
        if previous and previous[0] != message:
            raise ValueError('Conflicting output for an already stored execution')
        connection.execute('INSERT OR IGNORE INTO results VALUES(?,?,?,?,?)',
                           (job_id, run_id, message, started_at, time.time()))
    return run_id


async def send_result(config, chat_id, message, *, thread_id=None, media_files=None, force_document=False):
    from hermes_constants import get_hermes_home
    if media_files:
        return {'error': 'Woven Matter scheduled delivery currently requires textual output; attachments were not acknowledged'}
    try:
        run_id = save_result(get_hermes_home(), chat_id, message, os.getpid())
        return {'success': True, 'message_id': run_id}
    except Exception as error:
        return {'error': str(error)}


def adapter_factory(config):
    from gateway.config import Platform
    from gateway.platforms.base import BasePlatformAdapter, SendResult

    class DeliveryAdapter(BasePlatformAdapter):
        MAX_MESSAGE_LENGTH = 32 * 1024 * 1024

        def __init__(self, configuration):
            super().__init__(configuration, Platform('wovenmatter'))

        async def connect(self, *, is_reconnect=False):
            self._running = True
            return True

        async def disconnect(self):
            self._running = False

        async def send(self, chat_id, content, reply_to=None, metadata=None):
            result = await send_result(self.config, chat_id, content)
            return SendResult(success=bool(result.get('success')), message_id=result.get('message_id'), error=result.get('error'))

        async def get_chat_info(self, chat_id):
            return {'name': 'Woven Matter scheduled results', 'type': 'channel'}

    return DeliveryAdapter(config)


def register(ctx):
    ctx.register_platform(
        name='wovenmatter', label='Woven Matter', adapter_factory=adapter_factory,
        check_fn=lambda: True, validate_config=lambda config: True,
        cron_deliver_env_var='WOVENMATTER_CRON_DESTINATION', max_message_length=0,
        standalone_sender_fn=send_result)
