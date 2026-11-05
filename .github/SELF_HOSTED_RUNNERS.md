# Self-hosted CI runner

CI for this repository runs on a self-hosted runner. The two jobs split by label:

- `contract` → `self-hosted, dad, macOS` (Node foundation checks).
- `ios` → `self-hosted, dad, macOS` (Xcode / Swift via `scripts/check-ios.sh`).

A single Apple Silicon Mac serves both. GitHub adds `self-hosted`, `macOS` and
`ARM64` automatically from what the host reports; `dad` is the custom label we add
at registration. (The runner was originally registered with a `linux` label too,
which was a misnomer for a macOS host and has been removed — do not re-add it.)

## Runner prerequisites

- **Xcode** (full install, not just the Command Line Tools) for the `ios` job,
  with a simulator runtime matching what `scripts/check-ios.sh` expects.
- **Node.js 24** is installed per-job by `actions/setup-node`.

## Registration

`pre-dad` is a GitHub organization, so the runner is registered per-repository.
Register from **Settings → Actions → Runners → New self-hosted runner** with the
`dad` label (the `macOS`/`ARM64`/`self-hosted` labels are auto-added by the host):

```sh
./config.sh --url https://github.com/pre-dad/DAD-iOS \
  --token <TOKEN_FROM_THE_RUNNERS_PAGE> \
  --labels dad --name dad-ios-1
./svc.sh install && ./svc.sh start
```

Do **not** merge this branch until the runner shows **online**, or CI will hang
waiting for a matching runner.
