#!/bin/bash
# PreToolUse-хук для Bash: страхует два правила из AGENTS.md, которые легко нарушить по ошибке.
# 1. Живые тесты (TEST_RUNNER_INKLING_LIVE_*) тратят лимит и память — только с подтверждения владельца.
# 2. Личное не попадает в коммит, даже если его добавили через `git add -f` (обычно его отсекает .gitignore).

cmd=$(jq -r '.tool_input.command // empty')

decide() {
  jq -n --arg d "$1" --arg r "$2" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: $d, permissionDecisionReason: $r}}'
  exit 0
}

if [[ "$cmd" == *TEST_RUNNER_INKLING_LIVE_* ]]; then
  decide ask "Живой тест с настоящим движком тратит лимит и память. Запускать только по просьбе владельца."
fi

if [[ "$cmd" =~ git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?commit ]]; then
  private=$(git -C "${CLAUDE_PROJECT_DIR:-.}" diff --cached --name-only 2>/dev/null |
    grep -E '^(Config/Signing\.xcconfig|TestData/real/|docs/LITERATURE\.local\.md|docs/cli-experiments/tmp/)')
  if [[ -n "$private" ]]; then
    decide deny "В индексе личные файлы: $(echo "$private" | tr '\n' ' ')— убери их (git restore --staged) и не коммить."
  fi
fi

exit 0
