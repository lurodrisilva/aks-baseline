<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-05-10 | Updated: 2026-05-10 -->

# .github/workflows

## Purpose
GitHub Actions workflow definitions. All workflows are thin shims that delegate to reusable workflows in `Azure/tfmod-scaffold@main`; the actual job bodies (fmt/lint/validate, e2e provisioning, breaking-change diff, CodeQL scan) live upstream and run inside the `azterraform` container with this repo mounted at `/src`.

## Key Files
| File | Description |
|------|-------------|
| `pr-check.yaml` | Calls `Azure/tfmod-scaffold/.github/workflows/pr-check.yaml@main` on PR open/sync. Triggers on `.github/**`, `**.go`, `**.tf`, `**.md`, `**/go.mod` |
| `acc-test.yaml` | E2E test gate. Skips on forks (warns in step summary), then calls `Azure/tfmod-scaffold/.github/workflows/tfvm_e2e.yaml@main` with `id-token: write`. 720-minute timeout |
| `breaking-change-detect.yaml` | Comment-on-PR worker. `workflow_run` after `Pre Pull Request Check` completes; delegates to `Azure/tfmod-scaffold/.github/workflows/breaking-change-detect.yaml@main` |
| `weekly-codeql.yaml` | Cron `0 0 * * 0` (weekly) + `workflow_dispatch`; delegates to `Azure/tfmod-scaffold/.github/workflows/weekly-codeql.yaml@main` |

## For AI Agents

### Working In This Directory
- Workflows are **callers**, not implementations. To change CI behavior, fix the matching `make` target in the parent `makefile` (`pr-check`, `e2e-test`, `build-test`, `version-upgrade-test`) — the upstream reusable workflow invokes those targets inside the azterraform container.
- E2E workflow is **fork-disabled** by `if: github.event.pull_request.head.repo.fork == false`. Do not remove the guard — secrets aren't shared with forks.
- The `paths:` filter on `pr-check.yaml` and `acc-test.yaml` controls when they run. Add new top-level file types here if introducing them (e.g. `**.yaml` if you start shipping K8s manifests).
- `breaking-change-detect.yaml` chains via `workflow_run` — its `name:` must match the upstream caller's `name:` (`Pre Pull Request Check`) exactly, or it never fires.

### Testing Requirements
- Validate locally with `act` before pushing, or test in a fork.
- E2E + CodeQL workflows require Azure OIDC (`id-token: write`) and repo secrets — won't run on forks.

### Common Patterns
- `uses: Azure/tfmod-scaffold/.github/workflows/<name>.yaml@main` — pin to a tag/SHA if you ever need reproducibility; `@main` floats by design here.
- `secrets: inherit` is intentional for downstream Azure auth.

## Dependencies

### Internal
- Parent `makefile` targets (`make pr-check`, `make e2e-test`, `make build-test`, `make version-upgrade-test`) — invoked by the upstream reusable workflows.

### External
- `Azure/tfmod-scaffold@main` — upstream reusable workflow library.
- GitHub-hosted runners (`ubuntu-latest`).
- Azure OIDC federated credentials for `ARM_CLIENT_ID` / `ARM_SUBSCRIPTION_ID` / `ARM_TENANT_ID`.

<!-- MANUAL: -->
