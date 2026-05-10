<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-05-10 | Updated: 2026-05-10 -->

# .github/ISSUE_TEMPLATE

## Purpose
GitHub issue form templates. Inherited from the upstream `Azure/terraform-azurerm-aks` module shape — keep field names aligned with that module so triagers can search across forks.

## Key Files
| File | Description |
|------|-------------|
| `Bug_Report.yml` | Structured bug-report form: required fields for Terraform version, module version, AzureRM provider version, affected resources, config, tfvars, debug output. Greenfield/brownfield dropdown. Labels new issues `bug` |
| `Feature_Request.yml` | Structured feature-request form |
| `config.yml` | `blank_issues_enabled: false` — forces use of the structured templates |

## For AI Agents

### Working In This Directory
- These are **GitHub issue forms** (YAML), not GitHub Actions. Schema docs: <https://docs.github.com/en/communities/using-templates-to-encourage-useful-issues-and-pull-requests/syntax-for-issue-forms>.
- Required fields are enforced client-side by GitHub — adding `validations: { required: true }` blocks submission without that field.
- `blank_issues_enabled: false` in `config.yml` is intentional — keep it off so users can't bypass the structured forms.
- Field IDs (`id: terraform`, `id: module`, etc.) are stable contracts — don't rename without checking issue automation/labeling rules.

### Testing Requirements
- Validate by opening a draft issue in the GitHub UI and walking through the form.

### Common Patterns
- One form per issue type. Top-level `name:` becomes the picker label.
- `labels: [bug]` auto-applies labels on submission.

## Dependencies

### External
- GitHub issue forms platform (no runtime).

<!-- MANUAL: -->
