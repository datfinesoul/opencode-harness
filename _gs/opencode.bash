#!/usr/bin/env bash

# make sure that an AGENTS.md exists, even if we don't disable
# claude, this help reduce conflict.
opencode_config_root="$HOME/.config/opencode"
mkdir -p "$opencode_config_root"
touch "$opencode_config_root/AGENTS.md"

# Disable all .claude support
export OPENCODE_DISABLE_CLAUDE_CODE=1
# Disable only ~/.claude/CLAUDE.md
#export OPENCODE_DISABLE_CLAUDE_CODE_PROMPT=1
# Disable only .claude/skills
#export OPENCODE_DISABLE_CLAUDE_CODE_SKILLS=1
opencode "$(git rev-parse --show-toplevel)" "$@"
