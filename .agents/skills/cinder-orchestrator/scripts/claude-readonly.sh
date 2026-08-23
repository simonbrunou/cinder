#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 5 || $# -gt 6 ]]; then
  echo "usage: $0 <repo> <prompt-file> <raw-json> <result-md> <session-file> [resume-session-id]" >&2
  exit 2
fi

repo=$1
prompt_file=$2
raw_json=$3
result_md=$4
session_file=$5
resume_id=${6:-}

for cmd in claude python3; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "missing required command: $cmd" >&2
    exit 127
  }
done

[[ -d "$repo/.git" || -f "$repo/.git" ]] || {
  echo "not a git worktree: $repo" >&2
  exit 2
}
[[ -f "$prompt_file" ]] || {
  echo "prompt file not found: $prompt_file" >&2
  exit 2
}

mkdir -p "$(dirname "$raw_json")" "$(dirname "$result_md")" "$(dirname "$session_file")"

model=${CINDER_CLAUDE_MODEL:-opus}
max_turns=${CINDER_CLAUDE_MAX_TURNS:-80}

args=(
  -p
  --model "$model"
  --permission-mode plan
  --output-format json
  --max-turns "$max_turns"
)

if [[ -n "$resume_id" ]]; then
  args+=(--resume "$resume_id")
fi

prompt=$(cat "$prompt_file")

(
  cd "$repo"
  claude "${args[@]}" "$prompt"
) >"$raw_json"

python3 - "$raw_json" "$result_md" "$session_file" <<'PY'
import json
import pathlib
import sys

raw_path = pathlib.Path(sys.argv[1])
result_path = pathlib.Path(sys.argv[2])
session_path = pathlib.Path(sys.argv[3])

try:
    payload = json.loads(raw_path.read_text())
except Exception as exc:
    raise SystemExit(f"invalid Claude JSON output: {exc}")

if payload.get("is_error"):
    raise SystemExit(f"Claude returned an error result: {payload.get('result', '')}")

result = payload.get("result")
session_id = payload.get("session_id")
if not isinstance(result, str) or not result.strip():
    raise SystemExit("Claude output contained no non-empty result")
if not isinstance(session_id, str) or not session_id.strip():
    raise SystemExit("Claude output contained no session_id")

result_path.write_text(result.rstrip() + "\n")
session_path.write_text(session_id.strip() + "\n")
PY
