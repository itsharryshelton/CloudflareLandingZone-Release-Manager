# Cloudflare Landing Zone - Release Manager

Automated release management and synchronisation tool for the **Cloudflare Landing Zone** platform.

This tool automates the provisioning of private GitHub repositories and clean synchronisation of Terraform code for:
1. **The Deployment Framework** (`deployment/` directory).
2. **Every individual Landing Zone module** (each subdirectory in `modules/`).

---

## Key Features

- Automatically creates private GitHub repositories under any specified GitHub Organisation or User account via the GitHub REST API.
-  Upstream Sourcing with `-UseUpstreamSource`, the release is cut from a fresh shallow clone of `https://github.com/itsharryshelton/CloudflareLandingZone`
- The monorepo `.gitignore` negates paths such as `deployment/accounts/*/*.tfvars`. Those negations stop matching once `deployment` becomes its own repository root, so the policy is restated relative to each published repository root. Without this, the blanket `*.tfvars` deny would silently withhold every account configuration file from the release.
- Where a target repository already exists, its branch tip is fetched and the release is applied as an ordinary fast-forward commit on top of existing history. Nothing is force-pushed unless `-AllowForcePush` is passed explicitly. Deletions at source propagate to the release; unchanged components are reported as `Unchanged` and produce no commit.
- Supports an interactive step-by-step wizard, fully automated CLI / CI parameterised execution, and JSON configuration files.
- Inspect planned repository names, targets, and visibility using the `-WhatIf` / `-DryRun` switch without modifying GitHub.

---

## Discovered Structure

When executed against the Cloudflare Landing Zone source repository, the release manager targets:

| Component Type | Source Directory        | Default GitHub Repository Name                  |
| :---------------| :------------------------| :------------------------------------------------|
| **Deployment** | `deployment`            | `cflz-deployment`                               |
| **Module**     | `_TEMPLATE`             | `terraform-cloudflare-lz-template`              |
| **Module**     | `account_governance`    | `terraform-cloudflare-lz-account-governance`    |
| **Module**     | `bulk_redirect_list`    | `terraform-cloudflare-lz-bulk-redirect-list`    |
and so on...

### Repository Naming

Repository names are built from templates and are always normalised to lowercase kebab-case, so a source directory named `account_governance` publishes as `terraform-cloudflare-lz-account-governance` and `_TEMPLATE` publishes as `terraform-cloudflare-lz-template`.

| Setting               | Default                            | Tokens                 |
| :----------------------| :-----------------------------------| :-----------------------|
| `-Prefix`             | `cflz`                             | n/a                    |
| `-DeploymentRepoName` | `{prefix}-deployment`              | `{prefix}`             |
| `-ModuleRepoPattern`  | `terraform-cloudflare-lz-{module}` | `{prefix}`, `{module}` |

Change the prefix alone and the deployment repository follows it:

```powershell
.\Invoke-CloudflareLandingZoneRelease.ps1 -TargetOwner "YourOrgOrUsername" -Prefix "cflz" -WhatIf
# deployment -> cflz-deployment
# modules    -> terraform-cloudflare-lz-waf, terraform-cloudflare-lz-zone-base, ...
```

Or override either template outright:

```powershell
.\Invoke-CloudflareLandingZoneRelease.ps1 `
    -TargetOwner "YourOrgOrUsername" `
    -Prefix "cflz" `
    -DeploymentRepoName "{prefix}-landing-zone" `
    -ModuleRepoPattern "{prefix}-tf-{module}" `
    -WhatIf
# deployment -> cflz-landing-zone
# modules    -> cflz-tf-waf, cflz-tf-zone-base, ...
```

---

## Re-run Behaviour

Re-running against the same GitHub account is safe and idempotent, but the two component types deliberately behave differently.

### Module repositories are strict mirrors

Every run wipes the staging working tree, re-copies from source, and commits the difference. Source content always wins:

| Situation | Result |
| :--- | :--- |
| Source unchanged | No commit. Reported as `Unchanged` |
| Source changed | One commit on top of existing history. Reported as `Completed` |
| File removed at source | Deletion is committed |
| File edited directly in the published repo | **Reverted** to source content |
| File added directly in the published repo | **Deleted** — it does not exist at source |

The last two matter. A published module repository is a mirror, not a working copy. Edits made directly to it are undone on the next release. The overwriting commit is ordinary Git history, so the change is recoverable with `git revert`, but nobody is notified that it happened. Consumers should fork or vendor these repositories rather than editing them in place.

### The deployment repository is seeded once

`accounts/**` is exactly where an operator enters real account identifiers and zones after the repository is handed over. Applying mirror semantics there would revert those edits and delete any account file added that does not exist upstream.

So by default the deployment repository is published **once**. On any subsequent run, if it already exists and carries commits, it is skipped before anything is fetched, staged, or pushed:

```
[WARNING] Deployment repository has already been seeded. Operator edits under 'accounts/**'
          would be reverted by a re-release, so it is skipped. Use -ForceDeploymentUpdate to override.
deployment | cflz-deployment | Skipped
```

A repository that exists but carries no commits — creation succeeded, first push failed — is still treated as unseeded, so a retry completes the initial release.

To deliberately re-release it, overwriting operator changes:

```powershell
.\Invoke-CloudflareLandingZoneRelease.ps1 -TargetOwner "YourOrgOrUsername" -OnlyDeployment -ForceDeploymentUpdate
```

Set `"SeedDeploymentOnce": false` in a configuration file to make the deployment repository behave as a strict mirror like the modules.

---

## Prerequisites

1. **PowerShell 7+** (`pwsh`).
2. **Git** (installed and present in `PATH`).
3. **GitHub Personal Access Token (PAT)** with `repo` permissions (or authenticated `gh` CLI).

---

## Authentication Methods

The release manager automatically checks for GitHub authentication credentials in the following order:

1. **CLI Parameter:** `-GitHubToken "ghp_..."` or as a `[SecureString]`.
2. **Environment Variables:** `$env:GITHUB_TOKEN` or `$env:GH_TOKEN`.
3. **GitHub CLI (`gh`):** Active session from `gh auth login`.
4. **Interactive Prompt:** If no token is detected, the script securely prompts for token input.

---

## Usage Examples

### 1. Interactive Wizard Mode
Run without parameters or with `-Interactive` to be guided through credentials, target owner, repository prefix, and confirmation:
```powershell
.\Invoke-CloudflareLandingZoneRelease.ps1 -Interactive
```

### 2. Fully Automated Execution (CI / Headless)
Pass explicit parameters for unattended release pipelines:
```powershell
.\Invoke-CloudflareLandingZoneRelease.ps1 `
    -TargetOwner "YourOrgOrUsername" `
    -GitHubToken $env:GITHUB_TOKEN `
    -Visibility "private"
```

Cut the release from the upstream GitHub source rather than the local working tree:
```powershell
.\Invoke-CloudflareLandingZoneRelease.ps1 `
    -TargetOwner "YourOrgOrUsername" `
    -GitHubToken $env:GITHUB_TOKEN `
    -UseUpstreamSource `
    -UpstreamRef "main"
```

### 3. Dry-Run / Plan Inspection
Inspect all 15 repositories and planned remote URLs without making changes or writing to GitHub:
```powershell
.\Invoke-CloudflareLandingZoneRelease.ps1 `
    -TargetOwner "YourOrgOrUsername" `
    -WhatIf
```

### 4. Release Only Deployment or Specific Modules
Release only the central deployment repository:
```powershell
.\Invoke-CloudflareLandingZoneRelease.ps1 `
    -TargetOwner "YourOrgOrUsername" `
    -OnlyDeployment
```

Release specific modules:
```powershell
.\Invoke-CloudflareLandingZoneRelease.ps1 `
    -TargetOwner "YourOrgOrUsername" `
    -Modules @("waf", "zerotrust", "gateway")
```

Release every module except the scaffold template:
```powershell
.\Invoke-CloudflareLandingZoneRelease.ps1 `
    -TargetOwner "YourOrgOrUsername" `
    -OnlyModules `
    -ExcludeModules "_TEMPLATE"
```

### 5. Using Configuration Files
Load settings from a reusable configuration file:
```powershell
.\Invoke-CloudflareLandingZoneRelease.ps1 -ConfigFile "release-config.example.json"
```

Save current settings to a new configuration file:
```powershell
.\Invoke-CloudflareLandingZoneRelease.ps1 `
    -TargetOwner "YourOrgOrUsername" `
    -SaveConfig "my-release-config.json" `
    -WhatIf
```

---

## Parameter Reference

| Parameter | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `-SourceRoot` | String | `D:\Git\CloudflareLandingZone\CloudflareLandingZone` | Path to root CloudflareLandingZone directory. |
| `-UseUpstreamSource` | Switch | `false` | Cuts the release from a fresh clone of the upstream GitHub repository. |
| `-UpstreamRepoUrl` | String | `https://github.com/itsharryshelton/CloudflareLandingZone.git` | Upstream repository cloned when `-UseUpstreamSource` is set. |
| `-UpstreamRef` | String | `main` | Branch or tag to clone from upstream. |
| `-TargetOwner` | String | (Authenticated User) | GitHub Organisation or Username owning the repositories. |
| `-GitHubToken` | String / SecureString | (Env / CLI / Prompt) | GitHub Personal Access Token with `repo` scope. |
| `-Prefix` | String | `cflz` | Value substituted into the `{prefix}` token of either name template. |
| `-DeploymentRepoName` | String | `{prefix}-deployment` | Name template for the deployment repository. Supports `{prefix}`. |
| `-ModuleRepoPattern` | String | `terraform-cloudflare-lz-{module}` | Name template for module repositories. Supports `{prefix}` and `{module}`. |
| `-Visibility` | String | `private` | Visibility of created repositories (`private`, `public`, `internal`). |
| `-Modules` | String[] | All modules | Specific list of module folder names to publish. |
| `-ExcludeModules` | String[] | `@()` | Module folder names to omit from the release. |
| `-OnlyDeployment` | Switch | `false` | When set, only processes the deployment framework. |
| `-OnlyModules` | Switch | `false` | When set, only processes modules. |
| `-ForceDeploymentUpdate` | Switch | `false` | Re-releases an already-seeded deployment repository, overwriting operator edits under `accounts/**`. |
| `-AllowForcePush` | Switch | `false` | Permits overwriting remote history. Without it, a target repository carrying unrelated commits is reported as failed rather than overwritten. |
| `-ConfigFile` | String | `$null` | Path to JSON configuration file. |
| `-SaveConfig` | String | `$null` | Path to export current configuration JSON. |
| `-Interactive` | Switch | `false` | Activates interactive console wizard. |
| `-WhatIf` / `-DryRun` | Switch | `false` | Displays release execution plan without executing changes. |


---

## Security Considerations

Read this before running the tool against a real GitHub account.

- **The token is a credential with write access to your repositories.** A PAT with `repo` scope can create, read and write every repository the account can reach. Supply it via `$env:GITHUB_TOKEN`, an authenticated `gh` CLI session, or the interactive `SecureString` prompt. Do not hard-code it into a script or commit it to a configuration file.
- **The token is never written to disk by this tool.** Staging repositories store only the clean `https://github.com/<owner>/<repo>.git` remote URL. The authenticated URL is passed as a transient command argument to `git fetch` and `git push` only, so it never reaches `.git/config`. Git output is redacted before being logged or included in an error message.
- **`-SaveConfig` never persists secrets.** Only non-sensitive settings are exported.
- **Repositories are created as private by default.** Passing `-Visibility public` publishes the Terraform tree, including the `deployment/accounts/**` variable files that carry Cloudflare account identifiers and domain names, to the open internet. Treat that as a deliberate disclosure decision, not a formatting choice.
- **What is excluded from a release:** `.terraform/` provider and module caches, `*.tfstate` files, saved plans and crash logs are never copied. Terraform state in particular can contain secrets in plain text.
- **What is included:** everything else under the component directory, including `deployment/accounts/**/*.tfvars`. Those files hold account identifiers and domains. This is intentional, matching the upstream policy for a private repository with RBAC, but review the contents before releasing to a new owner.
- **Review before first use against production.** Run with `-WhatIf` first and confirm the target owner, repository names and visibility.

---

## Running Tests

Run the Pester test suite to validate discovery, configuration parsing, copy filtering, published ignore-rule correctness, publishing and idempotency (against a local bare repository, so no GitHub access is required), and dry-run execution:

```powershell
Invoke-Pester -Path ".\tests\ReleaseManager.Tests.ps1" -Output Detailed
```
