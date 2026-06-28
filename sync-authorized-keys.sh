#!/usr/bin/env bash
# Pull the operator's published SSH public keys from GitHub and authorize ALL of
# them for the RUNNING user. The GitHub account is the single trust root: every
# key on github.com/<user>.keys is the operator's own and is authorized as-is —
# manage who can log in by managing the account's keys (no in-image allowlist).
# GitHub supplies the key material (no keys in this repo, Build Principle 5).
# Re-running resyncs. Idempotent and defensive: it never wipes your existing keys
# if the fetch fails or returns nothing.
set -euo pipefail

GH_USER="${GH_KEYS_USER:-oso-gato}"
SSH_DIR="$HOME/.ssh"
AK="$SSH_DIR/authorized_keys"
NEW="$SSH_DIR/.authorized_keys.new"

install -d -m 700 "$SSH_DIR"
raw="$(mktemp)"; trap 'rm -f "$raw" "$NEW"' EXIT

if ! curl -fsSL --retry 3 "https://github.com/${GH_USER}.keys" -o "$raw" || [ ! -s "$raw" ]; then
    echo "WARN: fetch of github.com/${GH_USER}.keys failed or empty — authorized_keys left unchanged" >&2
    exit 0
fi

# Authorize every published key verbatim. Keep only well-formed public-key lines
# (ssh-keygen -lf validates), so a stray blank/garbage line never lands in the file.
: > "$NEW"; chmod 600 "$NEW"
n=0
while IFS= read -r key; do
    [ -n "$key" ] || continue
    printf '%s\n' "$key" | ssh-keygen -lf /dev/stdin >/dev/null 2>&1 || continue   # skip non-key lines
    printf '%s\n' "$key" >> "$NEW"
    n=$((n + 1))
done < "$raw"

if [ "$n" -lt 1 ]; then
    echo "WARN: no valid keys at github.com/${GH_USER}.keys — authorized_keys left unchanged" >&2
    exit 0
fi

mv -f "$NEW" "$AK"            # rename WITHIN ~/.ssh — keeps the ssh_home_t SELinux label
                             # (never mv from /tmp: that carries tmp_t and sshd can't read it)
# Belt-and-suspenders relabel; best-effort as the unprivileged user (the in-dir mv above
# already preserves ssh_home_t, so this needs no host privilege — no sudo).
command -v restorecon >/dev/null 2>&1 && restorecon -F "$AK" 2>/dev/null || true
echo "ssh keys: authorized $n key(s) from github.com/${GH_USER}.keys (all account keys)"
