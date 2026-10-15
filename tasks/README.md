# tasks

Action items for the current milestone, in the order to do them. `docs/40-engineering/19-build-roadmap.md` is the source of scope; this folder is the working list a person hands to Claude (or another engineer) one item at a time.

- `M0-action-items.md` — the live list for M0. Tick items as PRs merge; move finished items to the Done section with the PR number.
- One file per milestone. Do not put design decisions here; those go in `docs/` through a PR.

How to use with Claude Code from a local checkout:

```
claude "Work on tasks/M0-action-items.md item E1. Read the spec sections it lists before writing code."
```

Each item names its roadmap id, the spec sections that define it, what done looks like, and what it depends on.
