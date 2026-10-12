#!/usr/bin/env python3
"""Small host utility. Never execute .env as shell code or print its secrets."""
import json
import os
import re
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


def atomic_json(path, value):
    path = Path(path)
    fd, temporary = tempfile.mkstemp(prefix=path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o660)
        if os.geteuid() == 0:
            os.chown(temporary, int(os.environ.get('HIVEPANEL_RUNTIME_UID', '33')), int(os.environ.get('HIVEPANEL_RUNTIME_GID', '33')))
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def env_value(path, key):
    for line in Path(path).read_text().splitlines():
        match = re.match(r'^\s*(?:export\s+)?' + re.escape(key) + r'\s*=\s*(.*)$', line)
        if match:
            value = match[1].strip()
            if value.startswith(('"', "'")):
                quote = value[0]
                end = value.rfind(quote)
                if end <= 0:
                    raise ValueError('Invalid quoted environment value: ' + key)
                return value[1:end]
            return re.split(r'\s+#', value, maxsplit=1)[0].rstrip()
    return ''


def main():
    command, *args = sys.argv[1:]
    if command == 'env':
        print(env_value(*args))
    elif command == 'validate-env':
        path = args[0]
        for key in ('HIVEPANEL_VERSION', 'PANEL_DOMAIN', 'APP_KEY', 'DB_PASSWORD', 'DB_ROOT_PASSWORD', 'REDIS_PASSWORD'):
            if not env_value(path, key):
                raise ValueError('Required environment value missing: ' + key)
    elif command == 'version':
        value = json.loads(Path(args[0]).read_text()).get('version')
        if not isinstance(value, str) or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)(\.[0-9]+)?)?', value):
            raise ValueError('Invalid update request version')
        print(value)
    elif command == 'status':
        path, state, version, message, backup = args
        atomic_json(path, dict(state=state, version=version, message=message, backup=backup, updated_at=datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')))
    elif command == 'metadata':
        path, version = args
        value = json.loads(Path(path).read_text())
        value.update(version=version, updated_at=datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))
        atomic_json(path, value)
    elif command == 'set-version':
        path, version = args
        target = Path(path)
        value = target.read_text()
        value, count = re.subn(r'^HIVEPANEL_VERSION=.*$', 'HIVEPANEL_VERSION=' + version, value, flags=re.M)
        if count != 1:
            raise ValueError('Expected one HIVEPANEL_VERSION entry')
        fd, temporary = tempfile.mkstemp(prefix='.env.', dir=target.parent)
        try:
            with os.fdopen(fd, 'w') as stream:
                stream.write(value)
            stat = target.stat()
            os.chmod(temporary, stat.st_mode & 0o777)
            os.chown(temporary, stat.st_uid, stat.st_gid)
            os.replace(temporary, target)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    else:
        raise ValueError('Unknown host command')


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
