#!/usr/bin/env bash
# Read-only scan for common Bitcoin wallet files and key-like material.
# WARNING: Output may contain secrets. Redirect to a LUKS-encrypted volume or
# secure location; do not paste logs into chat. Use only on systems you own.
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: find-bitcoin-artifacts.sh [SEARCH_ROOT]

Environment:
  MAXDEPTH        e.g. 8  (passed to find -maxdepth; unset = unlimited)
  MAX_SCAN_MB     skip content scan for files larger than this (default 50);
                    wallet-like names are still listed regardless of size
  BIP39_WORDLIST  path to english.txt (one word per line); if set, lines in
                    text files that look like 12/15/18/21/24-word mnemonics
                    are flagged when all words appear in the list
  QUIET_NAMES     if 1, skip the "find by filename" section

Examples:
  find-bitcoin-artifacts.sh ~/backups
  MAXDEPTH=6 find-bitcoin-artifacts.sh /media/storage/backups
  BIP39_WORDLIST=~/Downloads/bip39-english.txt find-bitcoin-artifacts.sh ~

Fetch official BIP39 English wordlist (verify checksum / source yourself):
  https://github.com/bitcoin/bips/blob/master/bip-0039/english.txt
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

ROOT="${1:-$HOME}"
MAX_SCAN_MB="${MAX_SCAN_MB:-50}"
QUIET_NAMES="${QUIET_NAMES:-0}"

if [[ ! -d "$ROOT" ]]; then
  echo "Not a directory: $ROOT" >&2
  exit 1
fi

DEPTH_ARGS=()
if [[ -n "${MAXDEPTH:-}" ]]; then
  DEPTH_ARGS=(-maxdepth "$MAXDEPTH")
fi

echo "=== 1) Wallet-like filenames under: $ROOT ===" >&2
if [[ "$QUIET_NAMES" != "1" ]]; then
  # Bitcoin Core, forks; Electrum; some mobile exports; generic patterns
  find "$ROOT" "${DEPTH_ARGS[@]}" \( \
    -name 'wallet.dat' -o \
    -name 'wallet.dat-journal' -o \
    -name '*.wallet' -o \
    -name 'default_wallet' -o \
    -name 'electrum.dat' -o \
    -name '*.aes.json' -o \
    -name 'mnemonic.txt' -o \
    -name '*seed*.txt' -o \
    -name '*recovery*.txt' -o \
    -iname '*bitcoin*wallet*' \
  \) -type f 2>/dev/null | sort || true
fi

echo >&2
echo "=== 2) Extended keys (xprv/tprv/yprv/zprv + long base58 tail) ===" >&2
# Base58check payload length varies; keep a conservative minimum length.
find "$ROOT" "${DEPTH_ARGS[@]}" -type f \
  ! -path '*/node_modules/*' \
  ! -path '*/.git/*' \
  \( -size "-${MAX_SCAN_MB}M" -o -name 'wallet.dat' -o -name '*.wallet' -o -name 'default_wallet' -o -name 'electrum.dat' \) \
  2>/dev/null | while read -r f; do
  if [[ ! -r "$f" ]]; then
    continue
  fi
  if out=$(grep -a -nE '[xyzZ]prv[1-9A-HJ-NP-Za-km-z]{80,}|[tx]prv[1-9A-HJ-NP-Za-km-z]{80,}' "$f" 2>/dev/null); then
    echo "-- $f"
    echo "$out"
  fi
done || true

echo >&2
echo "=== 3) xpub/ypub/zpub (public — still sensitive in some contexts) ===" >&2
find "$ROOT" "${DEPTH_ARGS[@]}" -type f \
  ! -path '*/node_modules/*' \
  ! -path '*/.git/*' \
  -size "-${MAX_SCAN_MB}M" \
  2>/dev/null | while read -r f; do
  [[ -r "$f" ]] || continue
  if out=$(grep -a -nE '[xyzZ]pub[1-9A-HJ-NP-Za-km-z]{80,}|[tx]pub[1-9A-HJ-NP-Za-km-z]{80,}' "$f" 2>/dev/null); then
    echo "-- $f"
    echo "$out"
  fi
done || true

echo >&2
echo "=== 4) WIF-like lines (mainnet 51/52-char base58; many false positives) ===" >&2
find "$ROOT" "${DEPTH_ARGS[@]}" -type f \
  ! -path '*/node_modules/*' \
  ! -path '*/.git/*' \
  -size "-${MAX_SCAN_MB}M" \
  2>/dev/null | while read -r f; do
  [[ -r "$f" ]] || continue
  if out=$(grep -a -nE '(^|[^1-9A-HJ-NP-Za-km-z])[5KL][1-9A-HJ-NP-Za-km-z]{50,51}([^1-9A-HJ-NP-Za-km-z]|$)' "$f" 2>/dev/null); then
    echo "-- $f"
    echo "$out"
  fi
done || true

echo >&2
echo "=== 5) Hex private key-shaped tokens (64 hex; very noisy — hashes, IDs) ===" >&2
find "$ROOT" "${DEPTH_ARGS[@]}" -type f \
  ! -path '*/node_modules/*' \
  ! -path '*/.git/*' \
  -size "-${MAX_SCAN_MB}M" \
  2>/dev/null | while read -r f; do
  [[ -r "$f" ]] || continue
  # Word boundaries: avoid \b for BSD grep; exclude longer hex runs
  if out=$(grep -a -nE '(^|[^0-9A-Fa-f])([0-9a-fA-F]{64})([^0-9A-Fa-f]|$)' "$f" 2>/dev/null); then
    echo "-- $f"
    echo "$out"
  fi
done || true

echo >&2
echo "=== 6) Obvious mnemonic / seed language (coarse) ===" >&2
find "$ROOT" "${DEPTH_ARGS[@]}" -type f \
  ! -path '*/node_modules/*' \
  ! -path '*/.git/*' \
  -size "-${MAX_SCAN_MB}M" \
  2>/dev/null | while read -r f; do
  [[ -r "$f" ]] || continue
  if out=$(grep -a -niE 'mnemonic|seed phrase|seed_phrase|recovery phrase|recovery_phrase|bip39|electrum seed|wallet words|twelve words|twenty.four words' "$f" 2>/dev/null); then
    echo "-- $f"
    echo "$out"
  fi
done || true

if [[ -n "${BIP39_WORDLIST:-}" && -f "$BIP39_WORDLIST" ]]; then
  echo >&2
  echo "=== 7) BIP39 wordlist validation (BIP39_WORDLIST=$BIP39_WORDLIST) ===" >&2
  export BIP39_WORDLIST
  # shellcheck disable=SC2016
  find "$ROOT" "${DEPTH_ARGS[@]}" -type f \
    ! -path '*/node_modules/*' \
    ! -path '*/.git/*' \
    -size "-${MAX_SCAN_MB}M" \
    2>/dev/null | while read -r f; do
    [[ -r "$f" ]] || continue
    if ! file "$f" | grep -qiE 'text|ascii|utf-8|empty|json|script'; then
      continue
    fi
    awk -v wf="$BIP39_WORDLIST" '
      FNR == NR { w[$1]=1; next }
      {
        line = tolower($0)
        gsub(/[^a-z ]/, " ", line)
        n = split(line, a, / +/)
        if (n < 12) next
        for (start = 1; start <= n - 11; start++) {
          for (len = 12; len <= 24; len += 3) {
            if (start + len - 1 > n) break
            ok = 1
            for (i = 0; i < len; i++) {
              if (!(a[start + i] in w)) { ok = 0; break }
            }
            if (ok) {
              printf "%s:%d: possible BIP39 (%d words): ", FILENAME, NR, len
              for (i = 0; i < len; i++) printf "%s%s", a[start+i], (i<len-1 ? " " : "")
              print ""
            }
          }
        }
      }
    ' "$BIP39_WORDLIST" "$f" 2>/dev/null
  done || true
else
  echo >&2
  echo "=== 7) BIP39 wordlist scan skipped (set BIP39_WORDLIST to english.txt) ===" >&2
fi

echo >&2
echo "=== Done ===" >&2
