# kagenti Agent Skills

Agent Skills for automated maintenance of GitHub organizations. Each skill teaches an AI agent how to perform a specific task using shell scripts and structured instructions.

Built to the [Agent Skills specification](https://agentskills.io/specification).

## Skills

| Skill | Description |
|-------|-------------|
| [link-health-scanner](skills/link-health-scanner/) | Scan repos for broken links, create GitHub issues for findings |
| [link-health-fixer](skills/link-health-fixer/) | Re-verify and fix broken links, open PRs for fixes |

## Installation

### Claude Code (plugin marketplace)

```
/plugin marketplace add kagenti/agent-skills
/plugin install link-health@kagenti-agent-skills
```

### Manual

Copy the desired skill directory into your project's `.claude/skills/` directory:

```bash
cp -r skills/link-health-scanner /path/to/project/.claude/skills/
```

## Prerequisites

All skills in this repo require:

- `bash` 4+
- `gh` (GitHub CLI, authenticated)
- `jq`

Individual skills may have additional requirements documented in their `SKILL.md`.

## License

Apache-2.0. See [LICENSE](LICENSE).
