# Makefile Reference

This document describes all available Make targets for managing the AKS infrastructure.

## Overview

The Makefile provides convenient commands to manage the Terraform infrastructure lifecycle, including initialization, planning, applying changes, and destroying resources.

## Configuration

### Environment Variable

- **ENV**: Specifies the environment/workspace (default: `dev`)
  - Valid values: `dev`, `prd`
  - Used to create and switch between Terraform workspaces

## Available Targets

### `init`

Initializes Terraform and selects/creates the appropriate workspace.

```bash
make init
# or
make init ENV=prd
```

**What it does:**
1. Runs `terraform init -upgrade` in the `aks-foundation` directory
2. Selects or creates the specified workspace (dev or prd)
3. Validates that ENV is either `dev` or `prd`

**Examples:**
```bash
# Initialize for dev environment (default)
make init

# Initialize for production environment
make init ENV=prd
```

### `plan`

Creates a Terraform execution plan.

```bash
make plan
# or
make plan ENV=prd
```

**What it does:**
1. Runs `init` target first
2. Generates a Terraform plan and saves it to `tfplan` file
3. Shows what changes will be made without applying them

**Output:** Creates `aks-foundation/tfplan` file

### `apply`

Applies the Terraform changes.

```bash
make apply
# or
make apply ENV=prd
```

**What it does:**
1. Runs `plan` target first (if tfplan doesn't exist)
2. Applies the changes from the tfplan file
3. Removes the tfplan file after successful application

**Notes:**
- If tfplan doesn't exist, it will automatically run `make plan` first
- This ensures you always review changes before applying

### `destroy`

Destroys all Terraform-managed infrastructure.

```bash
make destroy
```

**⚠️ WARNING:** This command is **DANGEROUS** and will destroy all infrastructure!

**What it does:**
1. Runs `terraform destroy` with `-auto-approve`
2. Uses `-lock=false` flag
3. Destroys all resources in the current workspace

**Safety note:** The message "TAKE CARE MAFREND!!!" reminds you to be careful!

### `upgrade`

Performs a complete upgrade cycle.

```bash
make upgrade
# or
make upgrade ENV=prd
```

**What it does:**
1. Runs `init`
2. Runs `plan`
3. Runs `apply`

**Use case:** Convenient for applying infrastructure updates in one command.

### `rm-tfplan`

Removes the Terraform plan file.

```bash
make rm-tfplan
```

**What it does:**
- Removes the `aks-foundation/tfplan` file

**Use case:** Clean up if you want to regenerate the plan without applying it.

## Commented Targets (Disabled)

The following targets are currently commented out but available for future use:

### `environment-up` (commented)

Would scale up environment resources:
- Annotates namespaces to force uptime
- Scales coredns to 2 replicas
- Scales karpenter to 2 replicas
- Scales ebs-csi-controller to 2 replicas

### `environment-down` (commented)

Would scale down environment resources to save costs:
- Removes uptime annotations from namespaces
- Scales coredns to 1 replica
- Scales karpenter to 1 replica
- Scales ebs-csi-controller to 1 replica

## Common Workflows

### Initial Deployment

```bash
# 1. Initialize and select workspace
make init ENV=dev

# 2. Review planned changes
make plan

# 3. Apply changes
make apply
```

### Update Existing Infrastructure

```bash
# Quick upgrade (all steps at once)
make upgrade ENV=dev
```

### Switch Between Environments

```bash
# Switch to production
make init ENV=prd
make plan
make apply

# Switch back to dev
make init ENV=dev
```

### Production Deployment

```bash
# Always use explicit ENV for production
make init ENV=prd
make plan ENV=prd
# Review the plan carefully!
make apply ENV=prd
```

### Clean Up Resources

```bash
# Be absolutely sure before running this!
make destroy
```

### Regenerate Plan

```bash
# Remove old plan
make rm-tfplan

# Create new plan
make plan
```

## Directory Structure

All Terraform commands are executed in the `aks-foundation` directory:

```
01-aks-tf/
├── makefile
├── aks-foundation/
│   ├── main.tf
│   ├── variables.tf
│   ├── tfplan (generated)
│   └── ...
└── docs/
```

## Terraform Workspaces

The Makefile uses Terraform workspaces to manage different environments:

- **dev**: Development environment
- **prd**: Production environment

Each workspace maintains its own state file, allowing you to manage multiple environments independently.

### Workspace Commands (Manual)

If you need to manage workspaces manually:

```bash
# List workspaces
terraform -chdir=./aks-foundation workspace list

# Select workspace
terraform -chdir=./aks-foundation workspace select dev

# Create new workspace
terraform -chdir=./aks-foundation workspace new staging

# Delete workspace
terraform -chdir=./aks-foundation workspace delete staging
```

## Error Handling

### Invalid Environment Value

If you provide an invalid ENV value:

```bash
make init ENV=staging
# Output: Invalid value (production run: make init ENV=prd)
# Exit code: 1
```

Valid values are only `dev` or `prd`.

### Missing tfplan File

If tfplan is missing during `apply`, it will automatically run `make plan` first.

## Best Practices

1. **Always review the plan** before applying changes
   ```bash
   make plan
   # Review output carefully
   make apply
   ```

2. **Use explicit ENV for production**
   ```bash
   make init ENV=prd
   ```

3. **Never run destroy without backup**
   - Ensure you have exported any critical data
   - Verify Terraform state is backed up

4. **Use workspaces for isolation**
   - Keep dev and prd in separate workspaces
   - Never apply prd changes while in dev workspace

5. **Review tfplan before applying**
   - The tfplan file shows exactly what will change
   - Use `terraform show tfplan` to review in detail

## Troubleshooting

### Workspace Already Exists

If you get an error that workspace already exists, the Makefile handles it automatically by selecting the existing workspace.

### Lock File Issues

The `destroy` target uses `-lock=false` to bypass lock file issues. For other commands, if you encounter lock issues:

```bash
terraform -chdir=./aks-foundation force-unlock <lock-id>
```

### State File Issues

If state file becomes corrupted or out of sync:

1. Check current state: `terraform -chdir=./aks-foundation state list`
2. Pull remote state: `terraform -chdir=./aks-foundation state pull`
3. Consider using state backup files

## Related Documentation

- [Quickstart Guide](../setup/quickstart.md)
- [AKS Foundation README](../../aks-foundation/README.md)
- [Terraform Best Practices](https://www.terraform.io/docs/cloud/guides/recommended-practices/index.html)
