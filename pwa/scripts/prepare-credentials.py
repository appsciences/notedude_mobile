"""Normalize an explicitly supplied credential without printing its contents."""
import base64
import json
import os
from pathlib import Path


def normalize(value):
    value = value.strip().lstrip('\ufeff')
    try:
        if value.startswith('{'):
            data = json.loads(value)
        else:
            data = json.loads(base64.b64decode(''.join(value.split()), validate=True))
        if data.get('type') != 'service_account' or not all(data.get(k) for k in ['client_email', 'private_key', 'token_uri']):
            raise ValueError()
        return json.dumps(data)
    except Exception:
        raise ValueError('The secret must contain a service-account JSON key or its base64 encoding; do not include a variable assignment or surrounding quotes.') from None


if __name__ == '__main__':
    try:
        normalized = normalize(os.environ.get('CREDENTIALS_B64', ''))
        path = Path(os.environ['RUNNER_TEMP']) / 'ideadude-service-account.json'
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as output:
            output.write(normalized)
        with open(os.environ['GITHUB_ENV'], 'a') as output:
            output.write(f'GOOGLE_APPLICATION_CREDENTIALS={path}\n')
        print('Service-account credential loaded securely.')
    except ValueError as error:
        print(f'::error::{error}')
        raise SystemExit(1)
