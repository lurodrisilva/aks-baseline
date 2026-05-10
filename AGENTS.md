<!-- Generated: 2026-04-24 | Updated: 2026-05-10 -->

# 03-plat-eng-aks-foundation

## Purpose
Terraform-managed Azure Kubernetes Service (AKS) foundation that provisions the cluster, networking, identity, log analytics, and bootstraps the in-cluster platform components — ArgoCD (GitOps), Crossplane (cloud control plane), Vault (secrets), and the Azure Service Operator credentials. This sub-project is one of several independent repos in the wider `03-platform-engieeering/` workspace; once it provisions the cluster and ArgoCD, GitOps from `00-baseline-addons/` takes over for in-cluster addons.

## Key Files
| File | Description |
|------|-------------|
| `README.md` | Top-level project overview, features, quick reference |
| `makefile` | Workspace-aware entrypoint: `make init/plan/apply/destroy/upgrade ENV=dev|prd` |
| `LICENSE` | Project license |
| `.checkov_config.yaml` | Checkov IaC scanning config (skips listed CKV rules; framework=all, kubernetes/dockerfile excluded) |
| `.gitignore` | Excludes `tfplan`, `.terraform/`, build artifacts |
| `claude-debug.log`, `latest` | Local debug log + symlink (do not commit; ephemeral tooling output) |

## Subdirectories
| Directory | Purpose |
|-----------|---------|
| `aks-foundation/` | All Terraform code, fixtures, and Go tests (see `aks-foundation/AGENTS.md`) |
| `docs/` | Setup, guides, architecture, and reference documentation (see `docs/AGENTS.md`) |
| `.devcontainer/` | VSCode dev container using `mcr.microsoft.com/azterraform` (see `.devcontainer/AGENTS.md`) |
| `.github/` | CI workflows, issue/PR templates, dependabot (see `.github/AGENTS.md`) |
| `.sisyphus/` | Sisyphus runner state and per-task evidence — tooling output, do not edit by hand |
| `.omc/` | oh-my-claudecode session/state output — tooling output, ignored by git |

## For AI Agents

### Working In This Directory
- This is one sub-project inside `/Users/lucianosilva/src/03-platform-engieeering/`. Always `cd` here before running commands; the parent is **not** a repo.
- Terraform code lives in `aks-foundation/`, but the `makefile` is at this root and uses `terraform -chdir=./aks-foundation`. Never run `terraform` from `aks-foundation/` directly via the Makefile contract.
- `ENV` selects the Terraform workspace (`dev` or `prd`); anything else is rejected by `make init`.
- Never push to `master`. Feature branch + PR. Run `terraform fmt -recursive` and `checkov -d aks-foundation/` before pushing.

### Testing Requirements
- Go-based unit tests live under `aks-foundation/test/unit/` and use a stripped-down fixture in `aks-foundation/unit-test-fixture/` to avoid hitting Azure.
- E2E and upgrade tests in `aks-foundation/test/e2e/` and `aks-foundation/test/upgrade/` provision real Azure resources — gate them on credentials.
- Run a single test from `aks-foundation/`: `cd aks-foundation && go test ./test/unit/ -v -run TestName`.

### Common Patterns
- Provider versions are pinned in `aks-foundation/versions.tf` (`azurerm >= 4.16, < 5`, `azapi >= 2.0, < 3`).
- Workspace-conditional values appear inline (e.g. `terraform.workspace == "prd" ? true : false` in `aks_addons_argocd.tf`).
- `time_sleep` resources gate dependent steps on Helm/ArgoCD reconciliation (see `crossplane_argocd.tf`).

## Dependencies

### Internal (workspace siblings)
- `00-baseline-addons/` — App-of-Apps GitOps repo that ArgoCD (bootstrapped here) reconciles after cluster is up.
- `02-plat-eng-commons-package/`, `04-...-database/`, `05-...-cache/` — Helm building blocks deployed onto this cluster downstream; they don't directly depend on this repo's Terraform.

### External
- Terraform `>= 1.3` with providers: `azurerm`, `azuread`, `azapi`, `kubernetes`, `helm`, `kubectl` (alekc).
- Azure CLI authentication (`az login`, `ARM_SUBSCRIPTION_ID`).
- Helm charts from `argoproj.github.io/argo-helm` (ArgoCD `8.1.0`), `helm.releases.hashicorp.com` (Vault `0.31.0`), `charts.crossplane.io/stable` (Crossplane `2.1.3`).
- Go `1.23+` toolchain for Terratest.

<!-- MANUAL: -->
