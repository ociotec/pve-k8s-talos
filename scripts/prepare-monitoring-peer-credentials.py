#!/usr/bin/env python3
"""Prepare one directed monitoring connection offline, without printing secrets."""

import argparse
import json
import os
from pathlib import Path
import secrets
import subprocess
import tempfile


def write_private(path, data):
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as handle:
        temporary = Path(handle.name)
        os.chmod(temporary, 0o600)
        json.dump(data, handle, indent=2)
        handle.write("\n")
    os.replace(temporary, path)


def prepare(publisher, consumer):
    publisher, consumer = publisher.resolve(), consumer.resolve()
    if publisher == consumer or any(path.name == "sample" for path in [publisher, consumer]):
        raise ValueError("Use two different real cluster directories, never sample.")
    paths = [path / "secrets/credentials.json" for path in [publisher, consumer]]
    # Require the established private credential stores. Never create credentials
    # under the shared repository, and never inspect OpenTofu or a remote API.
    documents = [json.loads(path.read_text()) for path in paths]
    readers = documents[0].setdefault("monitoring", {}).setdefault("intercluster_readers", {})
    imports = documents[1].setdefault("monitoring", {}).setdefault("remote_clusters", {})
    reader = readers.get(consumer.name)
    if reader is None:
        reader = {"username": "reader-" + secrets.token_hex(8), "password": secrets.token_urlsafe(32)}
        reader["htpasswd"] = subprocess.run(
            ["openssl", "passwd", "-apr1", "-stdin"], input=reader["password"] + "\n",
            text=True, capture_output=True, check=True,
        ).stdout.strip()
    if not all(reader.get(key) for key in ["username", "password", "htpasswd"]):
        raise ValueError("Existing publisher credentials are incomplete; repair them explicitly.")
    imported = {key: reader[key] for key in ["username", "password"]}
    if publisher.name in imports and imports[publisher.name] != imported:
        raise ValueError("Consumer credentials differ; reconcile or rotate them explicitly.")
    readers[consumer.name] = reader
    imports[publisher.name] = imported
    for path, data in zip(paths, documents):
        if json.loads(path.read_text()) != data:
            write_private(path, data)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--publisher", required=True, type=Path)
    parser.add_argument("--consumer", required=True, type=Path)
    args = parser.parse_args()
    try:
        prepare(args.publisher, args.consumer)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Unable to prepare monitoring credentials: {error}\n")
    print("Monitoring peer credentials prepared; no cluster contacted.")
