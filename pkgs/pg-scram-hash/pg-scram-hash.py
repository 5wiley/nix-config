#!/usr/bin/env python3
"""Generate PostgreSQL SCRAM-SHA-256 password hashes.

Produces the same format stored in pg_authid:
  SCRAM-SHA-256$<iterations>:<salt>:<StoredKey>:<ServerKey>

Usage:
  pg-scram-hash <password>
  echo "mypassword" | pg-scram-hash
"""

import base64
import hashlib
import hmac
import os
import sys


def scram_sha256(password: str, iterations: int = 4096) -> str:
    salt = os.urandom(16)
    salted_password = hashlib.pbkdf2_hmac(
        "sha256", password.encode("utf-8"), salt, iterations
    )
    client_key = hmac.new(salted_password, b"Client Key", "sha256").digest()
    stored_key = hashlib.sha256(client_key).digest()
    server_key = hmac.new(salted_password, b"Server Key", "sha256").digest()

    return "SCRAM-SHA-256${}:{}:{}:{}".format(
        iterations,
        base64.b64encode(salt).decode(),
        base64.b64encode(stored_key).decode(),
        base64.b64encode(server_key).decode(),
    )


def main():
    if len(sys.argv) > 1:
        password = sys.argv[1]
    elif not sys.stdin.isatty():
        password = sys.stdin.read().strip()
    else:
        print("Usage: pg-scram-hash <password>", file=sys.stderr)
        print("       echo 'password' | pg-scram-hash", file=sys.stderr)
        sys.exit(1)

    if not password:
        print("Error: empty password", file=sys.stderr)
        sys.exit(1)

    print(scram_sha256(password))


if __name__ == "__main__":
    main()
