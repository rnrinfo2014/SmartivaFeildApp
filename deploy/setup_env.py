#!/usr/bin/env python3
"""Generate private deployment settings without displaying credentials."""
import argparse
import os
from pathlib import Path
import re
import secrets


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--host', required=True, help='DNS hostname you control, pointing to the VPS')
    args = parser.parse_args()
    hostname = args.host.strip().lower()
    label = r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?'
    if len(hostname) > 253 or not re.fullmatch(rf'{label}(?:\.{label})+', hostname):
        parser.error('Use a DNS hostname only, without https://, port, or path')
    target = Path(__file__).resolve().parent / '.env'
    values = (
        f'SMARTIVA_API_HOST={hostname}\n'
        f'POSTGRES_PASSWORD={secrets.token_urlsafe(36)}\n'
        f'SMARTIVA_API_TOKEN={secrets.token_urlsafe(36)}\n'
        'SMARTIVA_AI_PROVIDER=gemini\n'
        'SMARTIVA_GEMINI_API_KEY=\n'
        'SMARTIVA_GROQ_API_KEY=\n'
    )
    try:
        fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        parser.error('.env already exists; keep its database password and edit it securely')
    with os.fdopen(fd, 'w') as stream:
        stream.write(values)
    print('Created deploy/.env with private permissions. Add Gemini/Groq keys using a secure editor.')
    print('Do not paste .env, database credentials, or device tokens into chat or source control.')


if __name__ == '__main__':
    main()
