#!/usr/bin/env bash
#
# scan-secrets.sh - heuristic scan for hard-coded secrets (spec section 4.3).
#
# Usage:   scan-secrets.sh [DIR]        (default: current directory)
#
# Exit codes (a contract the tests rely on; see MEM-0003):
#   0  clean
#   1  at least one potential secret found
#   2  the scan itself failed (bad usage, unreadable files, git/find error)
#
# Design: .agents/memories/MEM-0003-secret-scanning.md
#
# Portability: must run on macOS Big Sur, which ships bash 3.2 and BSD
# grep/find/xargs. Hence: no associative arrays, no mapfile, no `grep -P`,
# no `\s`/`\d` (use POSIX classes), no xargs, no `${arr[@]}` on empty arrays.

# NOTE: deliberately NOT using `set -e`. grep exits 1 for "no match", which is
# a normal result here; `set -e` would abort the scan on the first clean file.
# We check exit codes explicitly instead. `-u` and `pipefail` stay on.
set -uo pipefail

# NOTE: LC_ALL=C makes grep treat input as raw bytes. Without it, BSD grep on
# macOS can fail with "illegal byte sequence" on non-UTF-8 files and exit 2.
export LC_ALL=C

readonly ALLOW_MARKER='scan-secrets:allow'

# ---------------------------------------------------------------------------
# Rules (POSIX ERE, matched case-insensitively).
# Built from small pieces so each rule stays readable.
# ---------------------------------------------------------------------------
readonly Q="[\"']"                       # one quote character
readonly NQ="[^\"']+"                    # one or more non-quote chars (value must not be empty)
readonly KEY_END="[\"']?"                # optional closing quote, so JSON keys ("password": ...) match
readonly ASSIGN='[[:space:]]*[:=]+[[:space:]]*'   # `=`, `:`, `:=`, with optional spaces

RULE_NAMES=(
  "password-assignment"
  "secret-assignment"
  "api-key-assignment"
  "openai-style-key"
  "pem-private-key"
  "url-embedded-credentials"
)
RULE_REGEXES=(
  "password${KEY_END}${ASSIGN}${Q}${NQ}${Q}"
  "secret${KEY_END}${ASSIGN}${Q}${NQ}${Q}"
  "api[_-]?key${KEY_END}${ASSIGN}${Q}${NQ}${Q}"
  # Spec says `sk-[a-zA-Z0-9]`, which also matches "task-force". Require a
  # non-alphanumeric char before `sk-` and 20+ key characters after it.
  "(^|[^[:alnum:]])sk-[[:alnum:]_-]{20,}"
  "-----BEGIN ([A-Z]+ )*PRIVATE KEY-----"
  # Credentials inside a URL's authority part: user, colon, password, at-sign.
  # NOTE: do not spell out an example here; the scanner scans this file too.
  "[a-z][a-z0-9+.-]*://[^/[:space:]:@]+:[^/[:space:]@]+@"
)

# All rules OR-ed together. Used as a cheap first pass: most files are clean,
# so one grep per file is enough for them; per-rule greps run only on hits.
COMBINED=""
for _re in "${RULE_REGEXES[@]}"; do
  if [ -z "$COMBINED" ]; then COMBINED="(${_re})"; else COMBINED="${COMBINED}|(${_re})"; fi
done

findings=0
errors=0

err() { printf 'scan-secrets: %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
Usage: scan-secrets.sh [DIR]

Scans files under DIR (default: .) for hard-coded secrets.
Inside a git work tree it scans what could be committed (tracked files plus
untracked files that are not ignored). Elsewhere it scans every regular file.

Exit codes: 0 = clean, 1 = potential secrets found, 2 = scan error.
Suppress a reviewed false positive by adding the text "scan-secrets:allow"
and a reason to the same line.
EOF
}

# Prints a NUL-separated list of candidate files (paths relative to cwd).
# NUL, not newline, so file names with spaces or newlines survive intact.
list_files() {
  if command -v git >/dev/null 2>&1 \
     && [ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ]; then
    # NOTE: --exclude-standard honours .gitignore, so a local (ignored) .env
    # is not scanned; it can never be committed, and flagging it would make
    # `make check` fail on every developer machine. -z also stops git from
    # quoting non-ASCII file names.
    git ls-files -z --cached --others --exclude-standard
  else
    find . \( -name .git -o -name node_modules -o -name vendor \) -prune -o -type f -print0
  fi
}

# Scans one file; updates the global counters. Never prints matched content:
# CI logs are often public, and echoing a found secret would leak it again.
scan_file() {
  local f="$1" rc i name re lines ln

  # Pass 1: does any rule match at all? (-q: no output, -I: skip binary files)
  grep -qiEI -e "$COMBINED" -- "$f" 2>/dev/null
  rc=$?
  case $rc in
    0) ;;                      # candidate, continue to pass 2
    1) return 0 ;;             # clean
    *) err "cannot read: $f"; errors=$((errors + 1)); return 0 ;;
  esac

  # Pass 2: which rule(s), on which line(s)? Keep only the line numbers.
  i=0
  while [ "$i" -lt "${#RULE_NAMES[@]}" ]; do
    name="${RULE_NAMES[$i]}"
    re="${RULE_REGEXES[$i]}"
    lines=$(grep -niEI -e "$re" -- "$f" 2>/dev/null | grep -vF -e "$ALLOW_MARKER" | cut -d: -f1)
    # NOTE: here-string instead of `echo | while read`. A pipe would run the
    # loop in a subshell and the counter updates would be lost.
    while IFS= read -r ln; do
      [ -n "$ln" ] || continue
      printf '%s:%s: %s\n' "${f#./}" "$ln" "$name" >&2
      findings=$((findings + 1))
    done <<< "$lines"
    i=$((i + 1))
  done
}

main() {
  local target="."
  case $# in
    0) ;;
    1) case "$1" in
         -h|--help) usage; exit 0 ;;
         *) target="$1" ;;
       esac ;;
    *) usage >&2; exit 2 ;;
  esac

  if [ ! -d "$target" ]; then
    err "not a directory: $target"
    exit 2
  fi
  cd -- "$target" || exit 2

  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/scan-secrets.XXXXXX")" || { err "mktemp failed"; exit 2; }
  trap 'rm -rf "$tmp"' EXIT

  # Write the list to a file first instead of `done < <(list_files)`.
  # Process substitution hides the producer's exit status: if git or find
  # failed we would scan nothing and report "clean" (fail-open). Here a
  # failure is detected and the scan fails closed with exit 2.
  list_files > "$tmp/files" || { err "could not list files"; exit 2; }

  local f
  while IFS= read -r -d '' f; do
    [ -L "$f" ] && continue    # never follow symlinks out of the tree
    [ -f "$f" ] || continue    # tracked-but-deleted files are still listed by git
    scan_file "$f"
  done < "$tmp/files"

  if [ "$findings" -gt 0 ]; then
    err "$findings potential secret(s) found. Values are not printed on purpose."
    err "False positive? Add '$ALLOW_MARKER <reason>' to that line, then get it reviewed."
    exit 1
  fi
  [ "$errors" -eq 0 ] || exit 2
  exit 0
}

main "$@"
