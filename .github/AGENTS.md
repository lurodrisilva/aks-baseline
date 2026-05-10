<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-04-24 | Updated: 2026-05-10 -->

# .github

## Purpose
GitHub repository configuration: CI workflows, dependabot, issue and PR templates.

## Key Files
| File | Description |
|------|-------------|
| `dependabot.yml` | Dependabot update schedule for Go modules / Terraform providers |
| `pull_request_template.md` | Default PR description template |

## Subdirectories
| Directory | Purpose |
|-----------|---------|
| `workflows/` | GitHub Actions workflows: `acc-test.yaml`, `breaking-change-detect.yaml`, `pr-check.yaml`, `weekly-codeql.yaml` (see `workflows/AGENTS.md`) |
| `ISSUE_TEMPLATE/` | Issue forms `Bug_Report.yml`, `Feature_Request.yml`, `config.yml` (see `ISSUE_TEMPLATE/AGENTS.md`) |

## For AI Agents

### Working In This Directory
- `acc-test.yaml` invokes the e2e Terratest suite — it provisions real Azure resources, gated on repo secrets. Don't add it to PR-trigger workflows without checking billing impact.
- `pr-check.yaml` is the lightweight gate for PRs (fmt, lint, unit tests).
- `breaking-change-detect.yaml` runs the upgrade tests and surfaces breaking module changes — keep it green before tagging a major release.
- `weekly-codeql.yaml` is a scheduled scan; if you change Go code paths, verify it still finds the right files.
- Never push to `master` directly — branch protection should reject it; if it doesn't, that's a config issue.

### Testing Requirements
- Workflow changes should be validated with `act` locally or in a fork.

### Common Patterns
- Workflow names mirror the file: `name:` field at the top should match the filename minus `.yaml`.
- Secrets used: typically `ARM_*` for Azure, `MSI_ID` for managed identity, `GITHUB_TOKEN` for tagging.

## Dependencies

### Internal
- `acc-test.yaml` and `breaking-change-detect.yaml` invoke tests in `../aks-foundation/test/`.

### External
- GitHub Actions runners; Azure credentials via OIDC or repo secrets.

<!-- MANUAL: -->
