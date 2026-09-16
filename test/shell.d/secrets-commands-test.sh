#!/bin/bash

# Behavioral coverage for bin/omarchy-secrets-*: the commands are driven
# against an in-memory Secret Service stub (gi is stubbed in sys.modules) and
# stub wl-paste/wl-copy binaries, so no real keyring or clipboard is touched.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command python3

TEST_BIN=$(mktemp -d)
trap 'rm -rf "$TEST_BIN"' EXIT

# Stub clipboard tools: the clipboard is a file in the stub dir.
cat >"$TEST_BIN/wl-paste" <<'EOF'
#!/bin/bash
cat "$CLIP_FILE" 2>/dev/null
EOF
cat >"$TEST_BIN/wl-copy" <<'EOF'
#!/bin/bash
if [[ ${1:-} == "--clear" ]]; then : >"$CLIP_FILE"; exit 0; fi
cat >"$CLIP_FILE"
EOF
chmod +x "$TEST_BIN/wl-paste" "$TEST_BIN/wl-copy"

CLIP_FILE="$TEST_BIN/clipboard"
export CLIP_FILE
export PATH="$TEST_BIN:$PATH"

python3 - "$ROOT/bin" <<'PY'
import importlib.machinery
import importlib.util
import io
import json
import sys
import types
from unittest import mock

BIN = sys.argv[1]
failures = []


def check(name, cond, detail=""):
    if cond:
        print(f"ok - {name}")
    else:
        print(f"not ok - {name} {detail}")
        failures.append(name)


# ---- fake gi.repository.Secret -------------------------------------------
class Flags(int):
    def __or__(self, other):
        return Flags(int(self) | int(other))


class Schema:
    def __init__(self, name, flags, attrs):
        self.name = name

    @classmethod
    def new(cls, name, flags, attrs):
        return cls(name, flags, attrs)


class Value:
    def __init__(self, text, length, ctype):
        self.text = text

    def get_text(self):
        return self.text

    @classmethod
    def new(cls, text, length, ctype):
        return cls(text, length, ctype)


class Item:
    def __init__(self, label, attrs, secret):
        self.label = label
        self.attrs = attrs
        self.secret = secret
        self.deleted = False

    def get_attributes(self):
        return self.attrs

    def get_label(self):
        return self.label

    def get_created(self):
        return 1

    def get_modified(self):
        return 2

    def get_secret(self):
        return self.secret

    def set_secret_sync(self, value, cancellable):
        self.secret = value

    def delete_sync(self, cancellable):
        self.deleted = True
        STORE["items"].remove(self)


STORE = {"items": []}


class Service:
    @classmethod
    def get_sync(cls, flags, cancellable):
        return cls()

    @classmethod
    def search_sync(cls, svc, schema, attrs, flags, cancellable):
        if not attrs:
            return list(STORE["items"])
        return [
            i
            for i in STORE["items"]
            if i.attrs.get("service") == attrs.get("service")
            and i.attrs.get("account") == attrs.get("account")
        ]


def password_store_sync(schema, attrs, collection, label, secret, cancellable):
    STORE["items"].append(Item(label, dict(attrs), Value(secret, -1, "text/plain")))


def password_lookup_sync(schema, attrs, cancellable):
    for i in STORE["items"]:
        if i.attrs.get("service") == attrs.get("service") and i.attrs.get(
            "account"
        ) == attrs.get("account"):
            return i.secret.text
    return None


Secret = types.ModuleType("Secret")
Secret.Schema = Schema
Secret.SchemaFlags = types.SimpleNamespace(NONE=0, DONT_MATCH_NAME=1)
Secret.SchemaAttributeType = types.SimpleNamespace(STRING=0)
Secret.SearchFlags = types.SimpleNamespace(ALL=1, UNLOCK=2, LOAD_SECRETS=4)
Secret.ServiceFlags = types.SimpleNamespace(NONE=0)
Secret.Service = Service
Secret.Value = Value
Secret.COLLECTION_DEFAULT = "default"
Secret.password_store_sync = password_store_sync
Secret.password_lookup_sync = password_lookup_sync

GLib = types.ModuleType("GLib")


class GError(Exception):
    def __init__(self, message):
        self.message = message
        super().__init__(message)


GLib.Error = GError

gi = types.ModuleType("gi")
gi.require_version = lambda *a: None
repository = types.ModuleType("gi.repository")
repository.Secret = Secret
repository.GLib = GLib
gi.repository = repository

sys.modules["gi"] = gi
sys.modules["gi.repository"] = repository
sys.modules["gi.repository.Secret"] = Secret
sys.modules["gi.repository.GLib"] = GLib


def load(name):
    loader = importlib.machinery.SourceFileLoader(name, f"{BIN}/omarchy-secrets-{name}")
    spec = importlib.util.spec_from_loader(name, loader)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def run(name, argv, stdin_text=""):
    mod = load(name)
    out, err = io.StringIO(), io.StringIO()
    code = 0
    with mock.patch.object(sys, "argv", ["omarchy-secrets-" + name] + argv):
        with mock.patch("sys.stdin", io.StringIO(stdin_text)):
            try:
                with mock.patch("sys.stdout", out), mock.patch("sys.stderr", err):
                    mod.main()
            except SystemExit as e:
                code = e.code if isinstance(e.code, int) else 1
                if isinstance(e.code, str):
                    err.write(e.code + "\n")
    return code, out.getvalue(), err.getvalue()


# ---- usage / argument handling --------------------------------------------
code, _, _ = run("get", ["onlyone"])
check("get rejects missing account", code != 0)
code, _, _ = run("set", ["svc"], "pw")
check("set rejects missing account", code != 0)
code, _, _ = run("delete", [], "x")
check("delete rejects missing args", code != 0)
code, _, _ = run("clipclear", [], "x")
check("clipclear rejects missing args", code != 0)

# ---- set ------------------------------------------------------------------
code, _, err = run("set", ["svc", "acct"], "")
check("set rejects empty stdin", code != 0 and "empty" in err)
code, _, err = run("set", ["svc", "acct"], "pw1")
check("set creates a new item", code == 0 and "created" in err)
check("new item stamped app=omarchy", STORE["items"][0].attrs.get("app") == "omarchy")
code, _, err = run("set", ["svc", "acct"], "pw2")
check("set updates the existing item", code == 0 and "updated 1" in err)
check("updated value persisted", STORE["items"][0].secret.text == "pw2")

# duplicate pair: every copy updates
STORE["items"].append(Item("dup", {"service": "svc", "account": "acct", "app": "ext"}, Value("old", -1, "x")))
code, _, err = run("set", ["svc", "acct"], "pw3")
check("set updates every duplicate", code == 0 and "updated 2" in err)
check("duplicates coherent after set", all(i.secret.text == "pw3" for i in STORE["items"]))

# ---- get ------------------------------------------------------------------
code, out, err = run("get", ["svc", "acct"])
check("get returns the stored value verbatim", code == 0 and out == "pw3")
check("get warns on duplicate matches", "2 items match" in err)
code, _, err = run("get", ["svc", "missing"])
check("get errors on no match", code != 0 and "no secret" in err)

# ---- list -----------------------------------------------------------------
STORE["items"].append(Item("other", {"service": "b", "account": "c"}, Value("x", -1, "x")))
code, out, _ = run("list", [])
rows = [json.loads(l) for l in out.strip().splitlines()]
check("list emits one JSON row per item", code == 0 and len(rows) == 3)
check("list never prints secret values", "pw3" not in out and '"secret"' not in out)
check("list exposes provenance", any(r.get("app") == "omarchy" for r in rows))
check("list sorts by service/account", [r["service"] for r in rows] == ["b", "svc", "svc"])

# ---- clipclear -------------------------------------------------------------
with open(__import__("os").environ["CLIP_FILE"], "w") as f:
    f.write("pw3")
code, _, _ = run("clipclear", ["svc", "acct"])
with open(__import__("os").environ["CLIP_FILE"]) as f:
    check("clipclear clears a matching clipboard", f.read() == "")

with open(__import__("os").environ["CLIP_FILE"], "w") as f:
    f.write("something-else")
code, _, _ = run("clipclear", ["svc", "acct"])
with open(__import__("os").environ["CLIP_FILE"]) as f:
    check("clipclear preserves newer clipboard content", f.read() == "something-else")

code, _, err = run("clipclear", ["svc", "missing"])
check("clipclear errors when the pair is gone", code != 0 and "no secret" in err)

# ---- delete ----------------------------------------------------------------
code, _, err = run("delete", ["svc", "acct"])
check("delete removes every duplicate", code == 0 and "deleted 2" in err)
check("namespace clean after delete", all(i.attrs.get("service") != "svc" for i in STORE["items"]))
code, _, err = run("delete", ["svc", "acct"])
check("delete errors when nothing remains", code != 0 and "no secret" in err)

sys.exit(1 if failures else 0)
PY
