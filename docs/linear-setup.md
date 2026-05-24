# Linear Setup For chess-3d-7

## Team

- team name: `Chess3d7`
- team key: `C37`
- GitHub repo: `welovekiteboarding/chess-3d-7`

## Workflow States

- `Todo`
- `In Progress`
- `Human Review`
- `Rework`
- `Merging`
- `Done`

## Environment Checklist

- set `LINEAR_API_KEY`
- confirm GitHub auth for `gh`
- confirm Codex is installed and available on the path

## Create The First Proof Issue

Create the first proof issue in Linear with:

- state: `Todo`
- title: `Create deterministic live-proof artifact`
- description: `Add a new file at docs/live-proof-setup-run-merge.md. Record only facts you can directly observe while working in this issue workspace. Use this exact structure:

  # Live Proof Setup Run Merge
  - Proof issue: <issue identifier>
  - Branch: <current git branch>
  - Commit evidence: <the current issue-specific git commit SHA and subject from local git history>
  - File evidence: <state that this proof artifact file was created for the deterministic live-proof issue>
  - Current scope: <state only what this issue actually proves at authoring time>

  Rules:
  - Before writing the proof note, inspect the local git history for the current issue branch and record the issue-specific commit SHA and subject that already exist there.
  - Use only facts visible in the issue prompt, workspace files, current branch name, or local git history.
  - Do not claim a PR, review result, merge result, or Linear workflow state unless that fact is already visible from local git data in the workspace.
  - Do not say evidence is missing if local git history already shows it.`

## Manual Notes

- `mix symphony.setup` will create the first proof issue through the Linear API after team and workflow bootstrap succeeds
- GitHub repo creation can be automated by `mix symphony.scaffold ... --github`
- run one queue cycle with `mix symphony.run --once`
- run the foreground queue with `mix symphony.run`
