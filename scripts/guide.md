# context-engine — workflow guide (version-matched)

The engine keeps a background sync agent running on this machine. The sync
agent claims maintenance tasks from the context-engine service and runs them
headlessly with the local codex CLI, using the engine's backend settings.

## Status

    bash ~/.claude/skills/context-engine/scripts/engine-setup.sh status

Shows whether the engine is provisioned, whether the sync agent is running,
and the last task results (`~/.context-engine/jobs/<id>/result.txt`).

## Re-run setup

Safe and idempotent — re-verifies activation and the backend settings, and
restarts the sync agent if needed:

    bash ~/.claude/skills/context-engine/scripts/engine-setup.sh setup

## How it works

- One detached sync agent claims a single task at a time; results are
  reported back to the service as a RESULT line.
- Backend settings live in `~/.context-engine/codex/config.toml` (a separate
  codex configuration; your own codex setup is never touched).
- Tasks are defined by the service, so behavior improves without any local
  changes — the local files stay thin and never go stale.
- Silent and failure-tolerant: if the service is unreachable the agent just
  waits for the next tick.
