"""Silent scheduled entry point. Does not start model tasks or require an open terminal."""
import contextlib
import datetime as dt
import os
from pathlib import Path
import sys

STATE = Path(__file__).resolve().parent
os.environ['CODEX_MONITOR_HOME'] = str(STATE)
import monitor


def main():
    log = STATE / 'scheduler.log'
    if log.exists() and log.stat().st_size > 2 * 1024 * 1024:
        log.replace(STATE / 'scheduler.previous.log')
    with log.open('a', encoding='utf-8', buffering=1) as stream:
        with contextlib.redirect_stdout(stream), contextlib.redirect_stderr(stream):
            try:
                monitor.run(force='--force' in sys.argv)
                return 0
            except Exception as exc:
                print(dt.datetime.now(dt.timezone.utc).isoformat(), 'Monitor failed:', type(exc).__name__,
                      str(exc) if isinstance(exc, (RuntimeError, TimeoutError)) else '')
                return 1


if __name__ == '__main__':
    sys.exit(main())
