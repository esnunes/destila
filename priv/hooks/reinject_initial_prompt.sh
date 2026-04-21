#!/bin/sh
# Managed by Destila. Do not edit by hand.
#
# SessionStart(compact) hook: re-inject the wrapped initial phase prompt so the
# model retains task context after context compaction.

set -eu

prompt_file="${CLAUDE_PROJECT_DIR:-.}/.claude/destila/initial_prompt.txt"

if [ ! -f "$prompt_file" ]; then
  exit 0
fi

cat "$prompt_file"
printf '\n\nIn the `<initial-prompt>` tag above you can find the initial user prompt for reference.\n'
