## Test

```prompt
What instructions are you loading from AGENTS.md and CLAUDE.md files at startup?
```

## Extra

```json
{
  "$schema": "https://opencode.ai/config.json",
  "instructions": ["https://raw.githubusercontent.com/datfinesoul/opencode-harness/some.md"]
}
```

## Read

- [Monorepo example](https://opencode.ai/docs/rules/#manual-instructions-in-agentsmd)

## Know Bugs

- https://github.com/anomalyco/opencode/issues/20307

  Permission module override after * not working

  ```json
  {
    "$schema": "https://opencode.ai/config.json",
    "permission": {
      "*": "ask",
      "read": "allow"
    }
  }
  ```
