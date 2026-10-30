# Self-hosted CI runner

CI for this repository runs on a self-hosted runner. The two jobs split by label:

- `contract` → `self-hosted, dad, linux` (Node foundation checks).
- `ios` → `self-hosted, dad, macos` (Xcode / Swift via `scripts/check-ios.sh`).

A single Apple Silicon Mac can serve both: GitHub label matching is
case-insensitive, so the runner's auto-added `macOS` label satisfies `macos`,
and the `linux` label is added explicitly at registration.

## Runner prerequisites

- **Xcode** (full install, not just the Command Line Tools) for the `ios` job,
  with a simulator runtime matching what `scripts/check-ios.sh` expects.
- **Node.js 24** is installed per-job by `actions/setup-node`.

## Registration

`CoachCoe` is a GitHub user account, so the runner is registered per-repository.
Register from **Settings → Actions → Runners → New self-hosted runner** with both
labels:

```sh
./config.sh --url https://github.com/CoachCoe/DAD-iOS \
  --token <TOKEN_FROM_THE_RUNNERS_PAGE> \
  --labels dad,linux,macos --name dad-ios-1
./svc.sh install && ./svc.sh start
```

Do **not** merge this branch until the runner shows **online**, or CI will hang
waiting for a matching runner.
