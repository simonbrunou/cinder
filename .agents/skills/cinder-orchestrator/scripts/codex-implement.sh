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
: >"$last_message"

global_args=(--ask-for-approval never)
if [[ -n "${CINDER_CODEX_MODEL:-}" ]]; then
  global_args+=(--model "$CINDER_CODEX_MODEL")
fi

exec_args=(
  exec
  -C "$worktree"
  --sandbox workspace-write
  --color never
  --json
  --output-last-message "$last_message"
)

expected_thread=""
if [[ -s "$thread_file" ]]; then
  expected_thread=$(tr -d '[:space:]' <"$thread_file")
  exec_args+=(resume "$expected_thread" -)
else
  exec_args+=(-)
fi

# Codex can emit thread.started and then fail. Preserve that thread id before
# propagating the command failure so an operational retry resumes the same work.
set +e
codex "${global_args[@]}" "${exec_args[@]}" <"$prompt_file" | tee "$events_file"
pipeline_status=$?
codex_status=${PIPESTATUS[0]}
tee_status=${PIPESTATUS[1]}
set -e

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

if [[ -z "$actual_thread" ]]; then
  if (( codex_status != 0 )); then
    echo "Codex exited with status $codex_status before emitting thread.started" >&2
    exit "$codex_status"
  fi
  if (( tee_status != 0 )); then
    echo "failed to capture Codex events (tee status $tee_status)" >&2
    exit "$tee_status"
  fi
  echo "Codex output contained no thread.started thread_id" >&2
  exit 1
fi

if [[ -n "$expected_thread" && "$actual_thread" != "$expected_thread" ]]; then
  echo "refusing silent Codex resume drift: expected thread $expected_thread, got $actual_thread" >&2
  exit 1
fi

printf '%s\n' "$actual_thread" >"$thread_file"

if (( tee_status != 0 )); then
  echo "failed to capture Codex events (tee status $tee_status)" >&2
  exit "$tee_status"
fi
if (( codex_status != 0 )); then
  echo "Codex exited with status $codex_status; resumable thread saved to $thread_file" >&2
  exit "$codex_status"
fi
if (( pipeline_status != 0 )); then
  exit "$pipeline_status"
fi

[[ -s "$last_message" ]] || {
  echo "Codex produced no last-message artifact: $last_message" >&2
  exit 1
}
