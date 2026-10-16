#!/usr/bin/env bash
#
# Tests for scan-secrets.sh. Silent on success, one "FAIL:" line per failure
# in the form "got X, want Y", exit 1 if anything failed.
#
# Rules this file follows (details: MEM-0003):
#  * Fixtures that look like secrets are assembled at run time from fragments.
#    A literal secret-looking string here would be flagged by the scanner when
#    it scans this very repository.
#  * Tests assert the EXACT exit code. "non-zero" is not enough: exit 2
#    (scanner broken) or 127 (script missing) would be mistaken for exit 1
#    (secret found), and the test would pass for the wrong reason.
#  * The script path is derived from this file's location, never from the
#    current directory, so the tests work from any cwd.

set -uo pipefail   # no -e: we want to keep going after a failed expectation

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$SCRIPT_DIR/scan-secrets.sh"

failed=0
LAST_OUTPUT=""

base="$(mktemp -d "${TMPDIR:-/tmp}/scan-secrets-test.XXXXXX")" || exit 2
trap 'rm -rf "$base"' EXIT

# Fixture fragments. Each is split so that no literal secret-looking text
# exists in this file.
PW_WORD="pass""word"
KEY_WORD="api_""key"
FAKE_VALUE="not-a-real-value-0001"
OPENAI_LIKE="sk-""aaaaaaaaaaaaaaaaaaaaaaaa"      # 24 filler chars
PEM_HEADER="-----BEGIN ""PRIVATE KEY-----"
DB_URL="postgres:""//app:not-real-pw@db.example.test/app"

new_dir() { mktemp -d "$base/case.XXXXXX"; }

# expect_exit NAME WANT DIR - run the scanner, compare the exact exit code.
expect_exit() {
  local name="$1" want="$2" dir="$3" got
  LAST_OUTPUT="$("$SCAN" "$dir" 2>&1)"
  got=$?
  if [ "$got" -ne "$want" ]; then
    echo "FAIL: $name got $got, want $want" >&2
    failed=1
  fi
}

# --- clean inputs -----------------------------------------------------------

should_pass_when_directory_is_clean() {
  local d; d="$(new_dir)"
  echo "Hello, this is a normal file." > "$d/readme.md"
  expect_exit "${FUNCNAME[0]}" 0 "$d"
}

should_pass_when_directory_is_empty() {
  local d; d="$(new_dir)"
  expect_exit "${FUNCNAME[0]}" 0 "$d"
}

# Near misses: the rules must not over-match, or people learn to ignore them.
should_pass_when_text_only_resembles_a_secret() {
  local d; d="$(new_dir)"
  {
    echo "Read the task-force and risk-adjusted-return-calculation-method notes."
    printf '%s_file = "/run/secrets/db"\n' "$PW_WORD"
    printf '%s = ""\n' "$PW_WORD"
  } > "$d/notes.txt"
  expect_exit "${FUNCNAME[0]}" 0 "$d"
}

should_pass_when_line_carries_the_allow_marker() {
  local d; d="$(new_dir)"
  printf '%s = "%s" # scan-secrets:allow test fixture\n' "$PW_WORD" "$FAKE_VALUE" > "$d/ok.toml"
  expect_exit "${FUNCNAME[0]}" 0 "$d"
}

# --- detections -------------------------------------------------------------

should_fail_when_password_is_assigned_a_quoted_value() {
  local d; d="$(new_dir)"
  printf '%s = "%s"\n' "$PW_WORD" "$FAKE_VALUE" > "$d/config.toml"
  expect_exit "${FUNCNAME[0]}" 1 "$d"
}

should_fail_when_json_key_holds_an_api_key() {
  local d; d="$(new_dir)"
  printf '{"%s": "%s"}\n' "$KEY_WORD" "$FAKE_VALUE" > "$d/config.json"
  expect_exit "${FUNCNAME[0]}" 1 "$d"
}

should_fail_when_go_style_assignment_is_used() {
  local d; d="$(new_dir)"
  printf '%s := "%s"\n' "$PW_WORD" "$FAKE_VALUE" > "$d/main.go"
  expect_exit "${FUNCNAME[0]}" 1 "$d"
}

should_fail_when_openai_style_key_is_present() {
  local d; d="$(new_dir)"
  printf 'token: %s\n' "$OPENAI_LIKE" > "$d/notes.yaml"
  expect_exit "${FUNCNAME[0]}" 1 "$d"
}

should_fail_when_private_key_header_is_present() {
  local d; d="$(new_dir)"
  echo "$PEM_HEADER" > "$d/server.key"
  expect_exit "${FUNCNAME[0]}" 1 "$d"
}

should_fail_when_url_embeds_credentials() {
  local d; d="$(new_dir)"
  printf 'dsn = %s\n' "$DB_URL" > "$d/db.conf"
  expect_exit "${FUNCNAME[0]}" 1 "$d"
}

should_scan_files_whose_names_contain_spaces() {
  local d; d="$(new_dir)"
  printf '%s = "%s"\n' "$PW_WORD" "$FAKE_VALUE" > "$d/my config file.toml"
  expect_exit "${FUNCNAME[0]}" 1 "$d"
}

should_not_print_the_secret_value_when_reporting() {
  local d; d="$(new_dir)"
  printf '%s = "%s"\n' "$PW_WORD" "$FAKE_VALUE" > "$d/config.toml"
  expect_exit "${FUNCNAME[0]}" 1 "$d"
  if printf '%s' "$LAST_OUTPUT" | grep -qF -- "$FAKE_VALUE"; then
    echo "FAIL: ${FUNCNAME[0]} got the secret value in the output, want it hidden" >&2
    failed=1
  fi
  if ! printf '%s' "$LAST_OUTPUT" | grep -qF -- "config.toml:1:"; then
    echo "FAIL: ${FUNCNAME[0]} got no file:line in the output, want config.toml:1:" >&2
    failed=1
  fi
}

should_not_follow_symlinks_out_of_the_tree() {
  local d outside; d="$(new_dir)"; outside="$(new_dir)"
  printf '%s = "%s"\n' "$PW_WORD" "$FAKE_VALUE" > "$outside/secret.toml"
  ln -s "$outside/secret.toml" "$d/link.toml"
  expect_exit "${FUNCNAME[0]}" 0 "$d"
}

# --- git mode ---------------------------------------------------------------

should_skip_gitignored_files_when_inside_a_git_repo() {
  local d; d="$(new_dir)"
  git -C "$d" init -q >/dev/null 2>&1
  echo ".env" > "$d/.gitignore"
  printf '%s = "%s"\n' "$PW_WORD" "$FAKE_VALUE" > "$d/.env"
  echo "clean" > "$d/README.md"
  expect_exit "${FUNCNAME[0]}" 0 "$d"
}

should_scan_untracked_files_that_are_not_ignored() {
  local d; d="$(new_dir)"
  git -C "$d" init -q >/dev/null 2>&1
  echo ".env" > "$d/.gitignore"
  printf '%s = "%s"\n' "$PW_WORD" "$FAKE_VALUE" > "$d/leak.txt"
  expect_exit "${FUNCNAME[0]}" 1 "$d"
}

should_not_fail_when_a_tracked_file_was_deleted_from_disk() {
  local d; d="$(new_dir)"
  git -C "$d" init -q >/dev/null 2>&1
  echo "temporary" > "$d/gone.txt"
  git -C "$d" add gone.txt >/dev/null 2>&1
  rm "$d/gone.txt"
  expect_exit "${FUNCNAME[0]}" 0 "$d"
}

# --- usage errors: exit 2, never 1 -----------------------------------------

should_exit_2_when_directory_does_not_exist() {
  expect_exit "${FUNCNAME[0]}" 2 "$base/no-such-dir"
}

should_exit_2_when_given_too_many_arguments() {
  local got
  "$SCAN" a b >/dev/null 2>&1
  got=$?
  if [ "$got" -ne 2 ]; then
    echo "FAIL: ${FUNCNAME[0]} got $got, want 2" >&2
    failed=1
  fi
}

# --- run everything ---------------------------------------------------------

should_pass_when_directory_is_clean
should_pass_when_directory_is_empty
should_pass_when_text_only_resembles_a_secret
should_pass_when_line_carries_the_allow_marker
should_fail_when_password_is_assigned_a_quoted_value
should_fail_when_json_key_holds_an_api_key
should_fail_when_go_style_assignment_is_used
should_fail_when_openai_style_key_is_present
should_fail_when_private_key_header_is_present
should_fail_when_url_embeds_credentials
should_scan_files_whose_names_contain_spaces
should_not_print_the_secret_value_when_reporting
should_not_follow_symlinks_out_of_the_tree
should_skip_gitignored_files_when_inside_a_git_repo
should_scan_untracked_files_that_are_not_ignored
should_not_fail_when_a_tracked_file_was_deleted_from_disk
should_exit_2_when_directory_does_not_exist
should_exit_2_when_given_too_many_arguments

exit "$failed"
