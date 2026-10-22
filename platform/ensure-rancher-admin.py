#!/usr/bin/env python3
"""Create a missing break-glass admin with the persisted bootstrap credential."""

import base64
import json
import os
from pathlib import Path
import re
import selectors
import subprocess
import sys
import urllib.error
import urllib.request

from rancher_readiness import auth_pending, retry_http, wait


def command(*args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=60)
    if result.returncode:
        # The recovery helper can print a password: never forward its output.
        raise RuntimeError("Rancher administrative initialization command failed")
    return result.stdout


def main():
    forward = None
    tokens = []
    try:
        git_dir = Path(command("git", "rev-parse", "--absolute-git-dir").strip())
        recovery_file = git_dir / "rancher-admin-recovery.json"
        users = json.loads(command("kubectl", "get", "users.management.cattle.io", "-o", "json"))["items"]
        if any(user.get("username") == "admin" for user in users) and not recovery_file.exists():
            print("Existing Rancher local admin retained; its password was not changed.")
            return 0
        wait(auth_pending, "Rancher local authentication", timeout=600)
        secret = json.loads(command("kubectl", "-n", "cattle-system", "get", "secret", "bootstrap-secret", "-o", "json"))
        password = base64.b64decode(secret["data"]["bootstrapPassword"]).decode()
        # Use an ephemeral local port and capture the generated port only.
        forward = subprocess.Popen(["kubectl", "-n", "cattle-system", "port-forward", "svc/rancher", ":80"],
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        port = None
        with selectors.DefaultSelector() as selector:
            selector.register(forward.stdout, selectors.EVENT_READ)
            if selector.select(timeout=30):
                match = re.search(r"127\.0\.0\.1:(\d+)", forward.stdout.readline())
                if match:
                    port = match[1]
        if port is None:
            raise RuntimeError("Could not open Rancher administrative verification connection")
        base = "http://127.0.0.1:" + port
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

        def request(path, data=None, token=None, method=None):
            headers = {"Content-Type": "application/json", "X-Forwarded-Proto": "https"}
            if token:
                headers["Authorization"] = "Bearer " + token
            payload = json.dumps(data).encode() if data is not None else None
            req = urllib.request.Request(base + path, data=payload, headers=headers, method=method)
            def send():
                with opener.open(req, timeout=15) as response:
                    output = response.read()
                    return json.loads(output) if output else {}
            # Cleanup is best effort: an already-expired token must not add
            # another retry window to successful initialization.
            return send() if method == "DELETE" else retry_http(send)

        # Official recovery creates a password only when the account is absent.
        # Capture it in memory, replace it immediately with our existing secret,
        # and never rotate the persisted credential or an existing admin account.
        if recovery_file.exists():
            recovery_password = json.loads(recovery_file.read_text())["password"]
        else:
            output = command("kubectl", "-n", "cattle-system", "exec", "deployment/rancher", "--", "ensure-default-admin")
            match = re.search(r"New password for default admin user[^\n]*:\s*\n([^\n]+)", output)
            if not match:
                raise RuntimeError("Missing admin recovery result; inspect the local account before retrying")
            recovery_password = match[1].strip()
            with open(recovery_file, "w", opener=lambda p, flags: os.open(p, flags, 0o600)) as stream:
                json.dump({"password": recovery_password}, stream)
        try:
            verified = request("/v3-public/localProviders/local?action=login", {
                "username": "admin", "password": password, "responseType": "json", "ttl": 120000})
            tokens.append(verified["token"])
            recovery_file.unlink()
            print("Persisted Rancher admin credential already reconciled.")
            return 0
        except urllib.error.HTTPError as error:
            if error.code != 401:
                raise
        login = request("/v3-public/localProviders/local?action=login", {
            "username": "admin", "password": recovery_password, "responseType": "json", "ttl": 120000})
        token = login["token"]
        tokens.append(token)
        # Login responses need not include userId; resolve the account from
        # Kubernetes after ensure-default-admin has created it.
        users = json.loads(command("kubectl", "get", "users.management.cattle.io", "-o", "json"))["items"]
        admin_id = next(user["metadata"]["name"] for user in users if user.get("username") == "admin")
        request("/v3/users/" + admin_id + "?action=setpassword", {"newPassword": password}, token)
        verified = request("/v3-public/localProviders/local?action=login", {
            "username": "admin", "password": password, "responseType": "json", "ttl": 120000})
        tokens.append(verified["token"])
        # Confirm the same authenticated inventory path used by the UI works.
        request("/v1/management.cattle.io.clusters?pagesize=100000", token=verified["token"])
        recovery_file.unlink()
        print("Rancher local admin initialized with the persisted bootstrap credential; authenticated inventory verified.")
        return 0
    except Exception as error:
        print("Rancher local admin initialization failed (" + type(error).__name__ + ": " +
              str(getattr(error, "code", "command")) + "); credentials and recovery output were suppressed.", file=sys.stderr)
        return 1
    finally:
        if forward is not None:
            for token in tokens:
                try:
                    request("/v3/tokens/" + token.split(":")[0], token=token, method="DELETE")
                except Exception:
                    pass  # Temporary sessions have a two-minute TTL.
            forward.terminate()
            try:
                forward.wait(timeout=10)
            except subprocess.TimeoutExpired:
                forward.kill()
                forward.wait(timeout=10)


if __name__ == "__main__":
    sys.exit(main())
