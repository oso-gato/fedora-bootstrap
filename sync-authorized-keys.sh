#!/usr/bin/env bash
# Pull the operator's published SSH public keys from GitHub and authorize the ones
# on the ALLOWLIST below for the RUNNING user, tagging each with
# environment="LOGIN_KEY=<name>" so every login is attributable to the key/device
# that authenticated. The fingerprint allowlist IS the access policy: only these
# keys are authorized — ANY OTHER key on the GitHub account is ignored. GitHub
# supplies the key material (no keys in this repo, Build Principle 5); this script
# is the gate. Re-running resyncs. Idempotent and defensive: it never wipes your
# existing keys if the fetch fails or matches nothing on the allowlist.
set -euo pipefail

GH_USER="${GH_KEYS_USER:-oso-gato}"
SSH_DIR="$HOME/.ssh"
AK="$SSH_DIR/authorized_keys"
NEW="$SSH_DIR/.authorized_keys.new"

# ALLOWLIST: a SHORT, uniquely-identifying slice of each key's SHA256 fingerprint
# -> LOGIN_KEY label. Fingerprints derive from the PUBLIC keys (so they're not
# secret); we store only a fragment — enough to match, minimal to expose. Each
# fragment is a prefix of the base64 fingerprint and matches the first characters
# GitHub shows in Settings -> SSH keys. Enrol a device: add its fragment + name
# here and re-run. Any key whose fingerprint doesn't match a fragment is ignored.
label_for() {
    case "${1#SHA256:}" in
        lzwcN0O7*) printf 'oSo' ;;
        ozn1vY4/*) printf 'Alchemist' ;;
        Kc4nBP37*) printf 'Fatima' ;;
        *) return 1 ;;                                  # not on the allowlist
    esac
}

install -d -m 700 "$SSH_DIR"
raw="$(mktemp)"; trap 'rm -f "$raw" "$NEW"' EXIT

if ! curl -fsSL --retry 3 "https://github.com/${GH_USER}.keys" -o "$raw"; then
    echo "WARN: fetch of github.com/${GH_USER}.keys failed — authorized_keys left unchanged" >&2
    exit 0
fi

: > "$NEW"; chmod 600 "$NEW"
n=0
while IFS= read -r key; do
    [ -n "$key" ] || continue
    fp="$(printf '%s\n' "$key" | ssh-keygen -lf /dev/stdin 2>/dev/null | awk '{print $2}')" || fp=""
    [ -n "$fp" ] || continue                            # skip non-key lines
    slice="${fp#SHA256:}"; slice="SHA256:${slice:0:8}..."   # show only a small portion
    if name="$(label_for "$fp")"; then
        printf 'environment="LOGIN_KEY=%s" %s\n' "$name" "$key" >> "$NEW"
        echo "  + $name ($slice)"
        n=$((n + 1))
    else
        echo "  - $slice is not on the allowlist — ignored" >&2
    fi
done < "$raw"

if [ "$n" -lt 1 ]; then
    echo "WARN: no allowlisted keys at github.com/${GH_USER}.keys — authorized_keys left unchanged" >&2
    exit 0
fi

mv -f "$NEW" "$AK"            # rename WITHIN ~/.ssh — keeps the ssh_home_t SELinux label
                             # (never mv from /tmp: that carries tmp_t and sshd can't read it)
command -v restorecon >/dev/null 2>&1 && sudo restorecon -F "$AK" >/dev/null 2>&1 || true
echo "ssh keys: authorized $n allowlisted key(s) from github.com/${GH_USER}.keys, tagged via LOGIN_KEY"
