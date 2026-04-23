# Multi-Machine Default Model Configuration in OpenCode

## Problem

OpenCode's `model` config field accepts a single string — there is no native fallback/coalesce list. When working across machines with different providers (e.g. GitHub Copilot on one machine, Minimax on another), you need a way to set per-machine defaults without maintaining separate config files.

## Solution: Environment Variable Substitution

OpenCode supports `{env:VAR_NAME}` substitution in config values. Set the model in your **global config** using an env var, then export the correct value per machine in each machine's shell profile.

### 1. Global config (`~/.config/opencode/opencode.json`)

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "{env:OPENCODE_MODEL}"
}
```

### 2. Per-machine shell profile (`.bashrc`, `.zshrc`, etc.)

On a Copilot machine:

```sh
export OPENCODE_MODEL="github-copilot/claude-sonnet-4.6"
```

On a Minimax machine:

```sh
export OPENCODE_MODEL="minimax/m2.7"
```

### How it works

OpenCode reads `OPENCODE_MODEL` at startup and substitutes it into the config. The machine-specific default lives in the machine's environment rather than in a versioned config file, keeping your dotfiles/global config portable.

If `OPENCODE_MODEL` is unset, OpenCode receives an empty string for `model` and falls back to its built-in default model selection behavior.

## What Doesn't Exist

There is no built-in "try model A, fall back to model B" coalescing. OpenCode does not support an array of fallback models for the `model` field.

## Alternative: Per-machine Local Override Config

If env vars are not preferred, use a higher-priority local config on each machine. Set `OPENCODE_CONFIG` to point to a machine-local file that only overrides `model`:

```sh
export OPENCODE_CONFIG=~/.config/opencode/local.json
```

`~/.config/opencode/local.json`:

```json
{
  "model": "github-copilot/claude-sonnet-4.6"
}
```

This file is not shared/synced and overrides the global config per the [config precedence order](https://opencode.ai/docs/config/#precedence-order).

## Sources

- [OpenCode Config docs](https://opencode.ai/docs/config/) — variable substitution, precedence order, `model` field
