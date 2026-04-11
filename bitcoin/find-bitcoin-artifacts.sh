#!/usr/bin/env bash
# Read-only scan for common Bitcoin wallet files and key-like material.
# WARNING: Output may contain secrets. Redirect to a LUKS-encrypted volume or
# secure location; do not paste logs into chat. Use only on systems you own.
set -euo pipefail

STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

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
  OUTPUT_JSON     if set, write scan results to JSON path
  SAVE_MATCH_TEXT if 1 (default), store matched line text in JSON

Examples:
  find-bitcoin-artifacts.sh ~/backups
  MAXDEPTH=6 find-bitcoin-artifacts.sh /media/storage/backups
  BIP39_WORDLIST=~/Downloads/bip39-english.txt find-bitcoin-artifacts.sh ~
  OUTPUT_JSON=~/scan-results.json find-bitcoin-artifacts.sh /media/archive

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
OUTPUT_JSON="${OUTPUT_JSON:-}"
SAVE_MATCH_TEXT="${SAVE_MATCH_TEXT:-1}"

if [[ ! -d "$ROOT" ]]; then
  echo "Not a directory: $ROOT" >&2
  exit 1
fi

DEPTH_ARGS=()
if [[ -n "${MAXDEPTH:-}" ]]; then
  DEPTH_ARGS=(-maxdepth "$MAXDEPTH")
fi

JSON_MATCHES_TSV=""
if [[ -n "$OUTPUT_JSON" ]]; then
  JSON_MATCHES_TSV="$(mktemp)"
  trap 'rm -f "$JSON_MATCHES_TSV"' EXIT
fi

record_json_match() {
  local section="$1"
  local kind="$2"
  local file="$3"
  local line_no="$4"
  local match_text="$5"

  [[ -n "$OUTPUT_JSON" ]] || return 0

  local text_b64=""
  if [[ "$SAVE_MATCH_TEXT" == "1" ]]; then
    text_b64="$(printf '%s' "$match_text" | base64 | tr -d '\n')"
  fi

  printf '%s\t%s\t%s\t%s\t%s\n' "$section" "$kind" "$file" "$line_no" "$text_b64" >> "$JSON_MATCHES_TSV"
}

write_json_output() {
  [[ -n "$OUTPUT_JSON" ]] || return 0

  local output_dir
  output_dir="$(dirname "$OUTPUT_JSON")"
  mkdir -p "$output_dir"

  local depth_value
  depth_value="${MAXDEPTH:-null}"

  python3 - "$JSON_MATCHES_TSV" "$OUTPUT_JSON" "$ROOT" "$MAX_SCAN_MB" "$depth_value" "$QUIET_NAMES" "${BIP39_WORDLIST:-}" "$STARTED_AT" "$SAVE_MATCH_TEXT" <<'PY'
import base64
import json
import re
import sys

tsv_path, output_path, root, max_scan_mb, depth_value, quiet_names, bip39_wordlist, started_at, save_match_text = sys.argv[1:]

matches = []
by_section = {}
by_type = {}
files = set()

key_patterns = {
    "xprvLike": re.compile(r'(?:[xyzZ]prv[1-9A-HJ-NP-Za-km-z]{80,}|[tx]prv[1-9A-HJ-NP-Za-km-z]{80,})'),
    "xpubLike": re.compile(r'(?:[xyzZ]pub[1-9A-HJ-NP-Za-km-z]{80,}|[tx]pub[1-9A-HJ-NP-Za-km-z]{80,})'),
    "wifLike": re.compile(r'(?:^|[^1-9A-HJ-NP-Za-km-z])([5KL][1-9A-HJ-NP-Za-km-z]{50,51})(?:[^1-9A-HJ-NP-Za-km-z]|$)'),
    "hex64Like": re.compile(r'(?:^|[^0-9A-Fa-f])([0-9a-fA-F]{64})(?:[^0-9A-Fa-f]|$)')
}
address_patterns = {
    "addressLikeBase58": re.compile(r'(?:^|[^1-9A-HJ-NP-Za-km-z])([13][1-9A-HJ-NP-Za-km-z]{25,34})(?:[^1-9A-HJ-NP-Za-km-z]|$)'),
    "addressLikeBech32": re.compile(r'(?i)(?:^|[^a-z0-9])(bc1[ac-hj-np-z02-9]{11,71})(?:[^a-z0-9]|$)')
}
key_candidates = {k: [] for k in key_patterns}
key_seen = {k: set() for k in key_patterns}
address_candidates = {k: [] for k in address_patterns}
address_seen = {k: set() for k in address_patterns}

with open(tsv_path, "r", encoding="utf-8", errors="replace") as f:
    for raw in f:
        raw = raw.rstrip("\n")
        if not raw:
            continue
        parts = raw.split("\t")
        while len(parts) < 5:
            parts.append("")
        section, kind, file_path, line_no, text_b64 = parts[:5]
        line_no_num = int(line_no) if line_no and line_no.isdigit() else None
        match_text = ""
        if text_b64:
            try:
                match_text = base64.b64decode(text_b64).decode("utf-8", errors="replace")
            except Exception:
                match_text = ""

        entry = {
            "section": section,
            "type": kind,
            "file": file_path,
            "line": line_no_num
        }
        if match_text:
            entry["matchText"] = match_text

        matches.append(entry)
        by_section[section] = by_section.get(section, 0) + 1
        by_type[kind] = by_type.get(kind, 0) + 1
        if file_path:
            files.add(file_path)

        if match_text:
            for key_name, pattern in key_patterns.items():
                for m in pattern.finditer(match_text):
                    token = m.group(1) if pattern.groups else m.group(0)
                    token = token.strip()
                    if token and token not in key_seen[key_name]:
                        key_seen[key_name].add(token)
                        key_candidates[key_name].append(token)
            for key_name, pattern in address_patterns.items():
                for m in pattern.finditer(match_text):
                    token = m.group(1).strip()
                    if token and token not in address_seen[key_name]:
                        address_seen[key_name].add(token)
                        address_candidates[key_name].append(token)

all_address_candidates = sorted(set(address_candidates["addressLikeBase58"] + address_candidates["addressLikeBech32"]))

options = {
    "maxScanMb": int(max_scan_mb),
    "maxDepth": None if depth_value == "null" else int(depth_value),
    "quietNames": quiet_names == "1",
    "bip39Wordlist": bip39_wordlist if bip39_wordlist else None,
    "saveMatchText": save_match_text == "1"
}

result = {
    "schemaVersion": 1,
    "startedAt": started_at,
    "scannedRoot": root,
    "options": options,
    "summary": {
        "totalMatches": len(matches),
        "uniqueFilesMatched": len(files),
        "bySection": by_section,
        "byType": by_type,
        "keyCandidateCounts": {k: len(v) for k, v in key_candidates.items()},
        "addressCandidateCounts": {
            "addressLikeBase58": len(address_candidates["addressLikeBase58"]),
            "addressLikeBech32": len(address_candidates["addressLikeBech32"]),
            "addressLikeAny": len(all_address_candidates)
        }
    },
    "keyCandidates": {
        **key_candidates,
        **address_candidates,
        "addressLikeAny": all_address_candidates
    },
    "matches": matches
}

with open(output_path, "w", encoding="utf-8") as out:
    json.dump(result, out, indent=2, ensure_ascii=True)
    out.write("\n")
PY
}

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
  \) -type f 2>/dev/null | sort | while read -r f; do
    echo "$f"
    record_json_match "walletLikeFilename" "filename" "$f" "" ""
  done || true
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
    while IFS= read -r m; do
      line_no="${m%%:*}"
      match_text="${m#*:}"
      record_json_match "extendedKeysPrivate" "xprvLike" "$f" "$line_no" "$match_text"
    done <<< "$out"
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
    while IFS= read -r m; do
      line_no="${m%%:*}"
      match_text="${m#*:}"
      record_json_match "extendedKeysPublic" "xpubLike" "$f" "$line_no" "$match_text"
    done <<< "$out"
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
    while IFS= read -r m; do
      line_no="${m%%:*}"
      match_text="${m#*:}"
      record_json_match "wifLike" "wifLike" "$f" "$line_no" "$match_text"
    done <<< "$out"
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
    while IFS= read -r m; do
      line_no="${m%%:*}"
      match_text="${m#*:}"
      record_json_match "hex64Like" "hex64Like" "$f" "$line_no" "$match_text"
    done <<< "$out"
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
    while IFS= read -r m; do
      line_no="${m%%:*}"
      match_text="${m#*:}"
      record_json_match "mnemonicLanguage" "mnemonicLanguage" "$f" "$line_no" "$match_text"
    done <<< "$out"
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
    out=$(awk -v wf="$BIP39_WORDLIST" '
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
    ' "$BIP39_WORDLIST" "$f" 2>/dev/null) || true
    if [[ -n "${out:-}" ]]; then
      echo "$out"
      while IFS= read -r m; do
        file_path="${m%%:*}"
        rem="${m#*:}"
        line_no="${rem%%:*}"
        match_text="${rem#*: }"
        record_json_match "bip39Validated" "bip39Validated" "$file_path" "$line_no" "$match_text"
      done <<< "$out"
    fi
  done || true
else
  echo >&2
  echo "=== 7) BIP39 wordlist scan skipped (set BIP39_WORDLIST to english.txt) ===" >&2
fi

if [[ -n "$OUTPUT_JSON" ]]; then
  write_json_output
  echo "JSON results written: $OUTPUT_JSON" >&2
fi

echo >&2
echo "=== Done ===" >&2
