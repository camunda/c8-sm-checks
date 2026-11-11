# AGENTS.md

## Role and path map

This repository holds shell scripts that check the health of a Camunda 8 Self-Managed installation on Kubernetes and the connectivity to Zeebe.
The [README](README.md) gives the options, examples and dependencies of each check.

No path needs a review from a specific team. The repository has no `CODEOWNERS` file.

- `checks/kube/`: the cluster checks `deployment.sh`, `connectivity.sh` and `aws-irsa.sh`.
  - `checks/kube/lib/`: functions that the checks source. They call no `kubectl`, so the unit tests can run them.
- `checks/zeebe/`: `token.sh` gets an OAuth token. `connectivity.sh` calls the Zeebe Gateway over gRPC or REST.
- `test/`: [test/README.md](test/README.md) and `test/kube/`, one `*.test.sh` unit test for each file in `checks/kube/lib/`.
- `.github/`: workflows, `renovate.json5` (extends `default.json5` of camunda/infraex-common-config) and `zizmor.yml` (pinning policy of the `zizmor` hook).
  - `.github/workflows/crev-review.yml`: written by camunda/infraex-terraform from `modules/github-repo-defaults/crev-review.yml`. Change it there.
- `.pre-commit-config.yaml`: the hooks, including the unit tests. `lint.yml` runs them.
- `.yamllint.yaml`: configuration of the `yamllint` hook.
- `lychee-links.toml`: configuration of the link check in `links.yml`.
- `.tool-versions`: `just` and `pre-commit` versions for asdf.
- `justfile`: `just install-tooling` installs the tools of `.tool-versions` with asdf.
- `MAINTENANCE.md`: release and maintenance steps.
- `.gitignore`: ignores `gateway.proto`, which `checks/zeebe/connectivity.sh` downloads.
- `README.md` and `LICENSE` (MIT).

## Architecture

- The five check scripts run alone from a shell against a live installation. No CI job runs them.
- The kube checks use the current `kubectl` context. `deployment.sh` and `aws-irsa.sh` also call `helm`. `aws-irsa.sh` also calls the AWS CLI.
- `aws-irsa.sh` reads the release values with `helm get values` and the chart defaults from the Helm repository `camunda`. For a `0.0.0` chart, or when `helm show values` fails, it reads them from camunda/camunda-platform-helm on GitHub.
- By default `aws-irsa.sh` starts Jobs with the image `amazonlinux:latest` in the namespace. Option `-s` turns this off.
- For gRPC, `checks/zeebe/connectivity.sh` downloads `gateway.proto` from camunda/camunda into the current folder when `-f` gives no file.
- `connectivity.sh` and `aws-irsa.sh` in `checks/kube/` source `checks/kube/lib/`. The tests in `test/kube/` source the same files and need no cluster.
- `lint.yml` calls `lint-global.yml` of camunda/infraex-common-config on each PR and push to `main`. When `renovate[bot]` or `smx-misc[bot]` starts the run on a PR, it commits the hook fixes to the PR branch.
- `links.yml` runs on each push, each month and on PRs that change it. A failed scheduled run opens an issue and posts to Slack.
- `crev-review.yml` calls `crev-review-global.yml` of camunda/infraex-common-config when a PR comment is `/crev` or starts with `/crev `.

## Commit rules

- Commit titles use Conventional Commits with a scope: `type(scope): summary`. Source: the `conventional-pre-commit` hook (`--strict --force-scope`, stage `commit-msg`) in `.pre-commit-config.yaml`. It permits its default types, for example `feat`, `fix`, `docs`, `ci` and `chore`.
- PR titles become the squash commit titles on `main`, with `(#N)` at the end. Source: the titles of the last 20 commits on `main`. They use the scopes `deps`, `ci`, `kube`, `lint` and `zeebe`.
- No workflow checks commit titles or PR titles. CI runs `pre-commit run --all-files`, which skips the `commit-msg` stage.

## Commands

- `pre-commit run --all-files`: `lint.yml`, through `lint-global.yml`. It runs each hook of `.pre-commit-config.yaml` except `conventional-pre-commit`: the `pre-commit-hooks` checks, `actionlint`, `zizmor`, `renovate-config-validator`, `shellcheck`, `yamllint`, `yamlfmt` and `action-pin-spacing`.
- The unit tests `test/kube/*.test.sh` are local hooks in the same run. Run one with `./test/kube/<name>.test.sh`. The tests of `aws-irsa-opensearch` and `keycloak-mode` need `jq`.
- The `renovate annotations` job of `lint-global.yml` checks the Renovate annotation comments against the shared preset: `lint.yml`.
- lychee with `-c ./lychee-links.toml` over `*.md` and `./**/*.md`: `links.yml`.
- The `todos` CLI on the lines that a PR adds: `internal_global_pr_todo_checker.yml`, through `todo-checker-global.yml` of camunda/infraex-common-config.
- `.tool-versions` pins `pre-commit` and `just`. `lint-global.yml` fails when `pre-commit` has a different version. `.pre-commit-config.yaml` pins each hook repository with `rev`. The `actionlint-docker` hook needs Docker.
- No file pins `jq` or lychee for a local run.
