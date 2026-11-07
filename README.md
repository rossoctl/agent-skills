# rossoctl Agent Skills

Agent Skills for GitHub PR review, local agent hosting, and HyperShift cluster
lifecycle management. Each skill teaches an AI agent how to perform a specific
task using shell scripts and structured instructions.

Built to the [Agent Skills specification](https://agentskills.io/specification).

## Skills

| Skill | Description |
|-------|-------------|
| [github-pr-review](skills/github-pr-review/) | Automated PR review: conventions, security, CI status, inline comments |
| [byo-rossoctl-cortex](skills/byo-rossoctl-cortex/) | Bring up a local rossoctl cortex (AuthBridge plugin pipeline) to host an agent; per-agent LiteLLM budget tracking isolated by env var |
| [hypershift](skills/hypershift/) | Full HyperShift (hosted OpenShift on AWS) cluster lifecycle across 7 skills — setup, preflight, quotas, create/destroy, debug, TTL-based cleanup; also needs `aws`, `oc`, `ansible` |

## Installation

### Claude Code (plugin marketplace)

```
/plugin marketplace add rossoctl/agent-skills
/plugin install <plugin-name>@rossoctl-agent-skills
```

Available plugins are `github-pr-review`, `byo-rossoctl-cortex`, and `hypershift`.
For a standalone PR review:

```
/plugin install github-pr-review@rossoctl-agent-skills
```

### RepoMan Migration

RepoMan-specific skills now live in [rossoctl/repoman](https://github.com/rossoctl/repoman)
to avoid duplicate, stale copies here. This includes `repoman`,
`link-health-scanner`, `link-health-fixer`, `dep-bump-scanner`, `dep-bump-fixer`,
`automation-health-dashboard`, `github-weekly-report`, and `repo-sync`, along
with the bundled engine and its vendoring tooling.

`github-pr-review` is the only RepoMan-related skill retained here, available
standalone without the RepoMan bundle.

Install RepoMan from its own marketplace:

```
/plugin marketplace add rossoctl/repoman
/plugin install repoman@rossoctl-repoman
```

If you previously installed a migrated plugin from `rossoctl-agent-skills`,
uninstall that old copy to avoid loading both versions. For the full bundle:

```
/plugin uninstall repoman@rossoctl-agent-skills
```

For individual plugins, replace `repoman` with the old plugin name:
`link-health`, `dep-bump`, `automation-health`, `github-weekly-report`, or
`repo-sync`. These plugins are also available from `rossoctl-repoman`.
Existing `~/.repoman/` configuration and enrolled repos stay in place; do not
delete them when switching marketplaces. Manually installed users should remove
the migrated directories from their local skill installation and use the copies
in `rossoctl/repoman`.

### Updating

To pick up new changes after they land upstream, refresh the marketplace and
update any installed plugins (a Claude Code restart applies plugin updates):

```
/plugin marketplace update rossoctl-agent-skills
/plugin update <plugin-name>@rossoctl-agent-skills
```

RepoMan users should update its separate marketplace and plugin:

```
/plugin marketplace update rossoctl-repoman
/plugin update repoman@rossoctl-repoman
```

### Manual

Copy the desired skill directory into your project's `.claude/skills/` directory:

```bash
cp -r skills/github-pr-review /path/to/project/.claude/skills/
```

## Prerequisites

All skills in this repo require:

- `bash` 3.2+ — every skill runs on the macOS system default; no bash-4 features
  are used.
- `gh` (GitHub CLI, authenticated)
- `jq`

Individual skills may have additional requirements documented in their `SKILL.md`.

## License

Apache-2.0. See [LICENSE](LICENSE).
