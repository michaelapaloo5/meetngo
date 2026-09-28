#!/usr/bin/env python3
"""Refuse to build an APK with anything but the project's anon key.

The apps read their Supabase credentials with String.fromEnvironment, so the
values are compiled into the APK. The **anon** key is a public client
credential designed to ship that way: every read it authorises is already
filtered by the row level security policies in
supabase/migrations/20260927000001_init.sql, and it can only ever see rows
those policies permit.

The **service_role** key bypasses those policies entirely. If one were ever
committed to toolchain/apk-build.env by mistake, or pasted into a build
variable, it would be published inside a binary anyone can download. This
check runs in the build so that is a red build rather than an incident.

The role is read by decoding the JWT payload. A substring test for
"service_role" would not work: the role name lives inside the base64 payload,
so the literal text never appears in the token and the test would pass a real
service key straight through. Requiring the role to be exactly `anon` is
stricter than blacklisting the bad one.

Usage:  check_anon_key.py <key> [expected-project-ref]
Exit 0 when the key is an anon key, 1 otherwise, with the reason on stdout.
"""

import base64
import json
import sys


def main() -> int:
    if len(sys.argv) < 2 or not sys.argv[1].strip():
        print("::error::no key supplied")
        return 1
    key = sys.argv[1].strip()
    expected_ref = sys.argv[2] if len(sys.argv) > 2 else None

    parts = key.split(".")
    if len(parts) != 3:
        print("::error::the key is not a JWT (expected three dot-separated parts)")
        return 1

    payload = parts[1] + "=" * (-len(parts[1]) % 4)
    try:
        claims = json.loads(base64.urlsafe_b64decode(payload))
    except (ValueError, json.JSONDecodeError) as exc:
        print(f"::error::could not decode the key's payload: {exc}")
        return 1

    role = claims.get("role")
    if role != "anon":
        print(f"::error::key role is {role!r}, not 'anon'. Refusing to build.")
        return 1

    ref = claims.get("ref")
    if expected_ref and ref != expected_ref:
        print(
            f"::error::key belongs to project {ref!r}, "
            f"not {expected_ref!r}. Refusing to build."
        )
        return 1

    print(f"Key role: {role}  project: {ref}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
