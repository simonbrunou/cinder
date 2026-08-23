#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 5 ]]; then
  echo "usage: $0 <worktree> <prompt-file> <events-jsonl> <last-message> <thread-file>" >&2
  exit 2
fi

worktree=$1
prompt_file=$2
events_file=$3
last_message=$4
thread_file=$5

for cmd in codex python3; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "missing required command: $cmd" >&2
    exit 127
  }
done

[[ -d "$worktree/.git" || -f "$worktree/.git" ]] || {
  echo "not a git worktree: $worktree" >&2
  exit 2
}
[[ -f "$prompt_file" ]] || {
  echo "prompt file not found: $prompt_file" >&2
  exit 2
}

mkdir -p "$(dirname "$events_file")" "$(dirname "$last_message")" "$(dirname "$thread_file")"
: >"$events_file"

args=(
  exec
  -C "$worktree"
  --sandbox workspace-write
  --ask-for-approval never
  --color never
  --json
  --output-last-message "$last_message"
)

if [[ -n "${CINDER_CODEX_MODEL:-}" ]]; then
  args+=(--model "$CINDER_CODEX_MODEL")
fi

expected_thread=""
if [[ -s "$thread_file" ]]; then
  expected_thread=$(tr -d '[:space:]' <"$thread_file")
  args+=(resume "$expected_thread" -)
else
  args+=(-)
fi

codex "${args[@]}" <"$prompt_file" | tee "$events_file"

actual_thread=$(python3 - "$events_file" <<'PY'
import json
import pathlib
import sys

for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        continue
    if event.get("type") == "thread.started" and event.get("thread_id"):
        print(event["thread_id"])
        break
PY
)

[[ -n "$actual_thread" ]] || {
  echo "Codex output contained no thread.started thread_id" >&2
  exit 1
}

if [[ -n "$expected_thread" && "$actual_thread" != "$expected_thread" ]]; then
  echo "refusing silent Codex resume drift: expected thread $expected_thread, got $actual_thread" >&2
  exit 1
fi

printf '%s\n' "$actual_thread" >"$thread_file"

[[ -s "$last_message" ]] || {
  echo "Codex produced no last-message artifact: $last_message" >&2
  exit 1
}
