# Cloudflare Landing Zone - Release Manager

Automated release management and synchronisation tool for the **Cloudflare Landing Zone** platform.

This tool automates the provisioning of private GitHub repositories and clean synchronisation of Terraform code for:
1. **The management repository**: the upstream repository root minus `modules/` - the plan / apply pipelines under `.github/`, `deployment/`, and the operator documentation.
2. **Every individual Landing Zone module** (each subdirectory in `modules/`), each in its own versioned repository.

---

## Key Features

- Automatically creates private GitHub repositories under any specified GitHub Organisation or User account via the GitHub REST API.
- Upstream Sourcing with `-UseUpstreamSource`, the release is cut from a fresh shallow clone of `https://github.com/itsharryshelton/CloudflareLandingZone`
- The management repository ships with the upstream pipelines and keeps `deployment/` at the path they expect, and its layers are repointed at the published module repositories, pinned to a tag. See [Management Repository](#management-repository).
- A release cut from a local checkout publishes Git-tracked files only, so untracked local files (agent settings, scratch notes, an operator's `local.auto.tfvars`) never reach a published repository.
- The monorepo `.gitignore` negates paths such as `deployment/accounts/*/*.tfvars`. Those negations stop matching once `deployment` becomes its own repository root in the flat layout, so the policy is restated relative to each published repository root. Without this, the blanket `*.tfvars` deny would silently withhold every account configuration file from the release.
- Where a target repository already exists, its branch tip is fetched and the release is applied as an ordinary fast-forward commit on top of existing history. Nothing is force-pushed unless `-AllowForcePush` is passed explicitly. Deletions at source propagate to the release; unchanged components are reported as `Unchanged` and produce no commit.
- Supports an interactive step-by-step wizard, fully automated CLI / CI parameterised execution, and JSON configuration files.
- Inspect planned repository names, targets, and visibility using the `-WhatIf` / `-DryRun` switch without modifying GitHub.

---

## Discovered Structure

When executed against the Cloudflare Landing Zone source repository, the release manager targets one repository per directory under `modules/`, then the management repository last:

| Component Type | Source Directory              | Default GitHub Repository Name                  |
| :---------------| :------------------------------| :------------------------------------------------|
| **Module**     | `modules/_TEMPLATE`           | `terraform-cloudflare-lz-template`              |
| **Module**     | `modules/account_governance`  | `terraform-cloudflare-lz-account-governance`    |
| **Module**     | `modules/zone_base`           | `terraform-cloudflare-lz-zone-base`             |
| ...            | ...                           | ...                                             |
| **Management** | repository root minus `modules/` | `cflz-management`                            |

Modules are discovered, not listed, so a module added upstream gets a repository on the next release with no change here. `_TEMPLATE` is published too unless it is listed under `-ExcludeModules`.

### Repository Naming

Repository names are built from templates and are always normalised to lowercase kebab-case, so a source directory named `account_governance` publishes as `terraform-cloudflare-lz-account-governance` and `_TEMPLATE` publishes as `terraform-cloudflare-lz-template`.

| Setting               | Default                            | Tokens                 |
| :----------------------| :-----------------------------------| :-----------------------|
| `-Prefix`             | `cflz`                             | n/a                    |
| `-ManagementRepoName` | `{prefix}-management`              | `{prefix}`             |
| `-DeploymentRepoName` | `{prefix}-deployment` (flat layout only) | `{prefix}`       |
| `-ModuleRepoPattern`  | `terraform-cloudflare-lz-{module}` | `{prefix}`, `{module}` |

Change the prefix alone and the management repository follows it:

```powershell
.\Invoke-CloudflareLandingZoneRelease.ps1 -TargetOwner "YourOrgOrUsername" -Prefix "acme" -WhatIf
# management -> acme-management
# modules    -> terraform-cloudflare-lz-waf, terraform-cloudflare-lz-zone-base, ...
```

Or override either template outright:

```powershell
.\Invoke-CloudflareLandingZoneRelease.ps1 `
    -TargetOwner "YourOrgOrUsername" `
    -Prefix "cflz" `
    -ManagementRepoName "{prefix}-landing-zone" `
    -ModuleRepoPattern "{prefix}-tf-{module}" `
    -WhatIf
# management -> cflz-landing-zone
# modules    -> cflz-tf-waf, cflz-tf-zone-base, ...
```

---

## Management Repository

Upstream, the pipelines live at the repository root - `.github/workflows`, `.github/scripts`, `.github/actions/modules-auth`, `.tflint.hcl` - and address the layers as `deployment/layers/*` and the accounts as `deployment/accounts/*`. The management repository therefore keeps the upstream layout and leaves out only `modules/`, which is published as one repository per module instead:

```text
cflz-management/
├── .github/            ci, plan, apply, state-forget, state-unlock, scripts, modules-auth
├── deployment/
│   ├── accounts/       per-account .tfvars - where operators work
│   └── layers/         one root module per product, sourcing the module repositories
├── docs/
├── .tflint.hcl  .betterleaks.toml  .gitignore
├── AGENTS.md  CLAUDE.md  README.md  CONTRIBUTING.md  VARIABLES_AND_SECRETS.md
└── LICENSE  NOTICE
```

The source's own `.gitignore`, `AGENTS.md` and `CLAUDE.md` are already written for this layout, so they are published as they are.

### Module sources are repointed and pinned

Upstream, a layer sources its modules from `../../../modules/<module>` or from a placeholder, `git::https://github.com/Your-Org/cloudflare-platform-modules//<module>`. Neither resolves once the management repository stands on its own, so each active `source` line is rewritten to the module's published repository:

```hcl
# upstream
source = "../../../modules/zone_base"
# management repository
source = "git::https://github.com/<owner>/terraform-cloudflare-lz-zone-base.git?ref=v1.0.0"
```

- **Which ref.** With `ModuleSourceRef` at its default, `latest`, each module is pinned to the highest `vX.Y.Z` tag its repository carries. A repository with no tag yet - a module published for the first time in the same run - is pinned to `v1.0.0`, which is the tag its CI publishes on the first green push to `main`. Pass `-ModuleSourceRef v1.2.0` (or any ref) to pin every module to the same ref instead.
- **Ordering.** Module repositories are released before the management repository in every run, so the tag lookup sees them.
- **What is left alone.** Commented lines (upstream carries a commented example above each module block), registry and provider sources, and any third-party Git source. A layer that sources an upstream module directory that does not exist is reported and left unchanged.
- **Taking a module update later.** The management repository is [seeded once](#the-management-repository-is-seeded-once), so its pins are never moved by a re-release. Bump a layer's `?ref=` by hand when you decide to take a module version.
- `-SkipSourceRewrite`, or `"RewriteModuleSources": false`, publishes the upstream sources unchanged.

`tf-matrix.sh` recognises a layer that creates zones by grepping for `/zone_base"` in its sources, which a per-module repository URL no longer contains. Apply ordering is unaffected - `zones` still lands in tier 2, as the `ci.yml` self-test asserts - but the guard that stops `zones` declaring itself into tier 3 in a `tier.tf` no longer fires.

### modules-auth is pointed at the module repositories

Upstream, `.github/actions/modules-auth` mints a GitHub App token for one repository, `cloudflare-platform-modules`. Its `repository` default is rewritten to the comma-separated list of module repositories the layers actually source (not `_TEMPLATE`), so no workflow call site needs editing. The App must be **installed on each of those repositories**.

### After the first release

The management repository's `ci.yml` runs on its first push and fails at `modules-auth` until the repository is configured. Follow `.github/workflows/README.md` and `VARIABLES_AND_SECRETS.md` in the published repository:

1. Create the modules-reader GitHub App (*Contents: Read-only*) and install it on every module repository.
2. Set `MODULES_APP_ID`, `MODULES_APP_PRIVATE_KEY`, `TF_BACKEND_BUCKET`, `TF_BACKEND_ENDPOINT`, `R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY`.
3. Run `.github/scripts/bootstrap-account-tokens.sh` and `bootstrap-environments.sh`, and complete the placeholders in `AGENTS.md`.

### The flat layout

`-DeploymentLayout Flat` (or `"DeploymentLayout": "Flat"`) restores the previous behaviour: only `deployment/` is published, as its own repository root, named by `-DeploymentRepoName`. It carries no pipelines - the upstream workflows address `deployment/layers/*` and cannot run against `layers/*` - so it suits operators who bring their own. Its layer sources are repointed in the same way.

---

## Module CI and Versioning

Every module repository is published with a CI scaffold from [templates/module](templates/module), adapted from the upstream Landing Zone pipelines:

| File | Purpose |
| :--- | :--- |
| `.github/workflows/ci.yml` | `terraform fmt`, `terraform init` / `validate`, offline `terraform plan`, and the release tag |
| `.github/workflows/secret-scanning.yml` | betterleaks plus the strict Cloudflare token-prefix guard. Called from `ci.yml` so the tag depends on it |
| `.github/scripts/next-version.sh` | Works out the next SemVer tag |
| `.betterleaks.toml` | Scanner rules, matching upstream |

The checks run on every pull request and every push to `main`. When all of them pass on a push to `main`, the commit is tagged.

### Version keywords

The bump is read from **every commit since the last tag**, not only the head commit, so a keyword anywhere in a multi-commit push or a merged pull request counts. The highest keyword wins.

| Commit message contains | `v1.0.0` becomes |
| :--- | :--- |
| `#major` | `v2.0.0` |
| `#minor` | `v1.1.0` |
| `#patch`, or no keyword | `v1.0.1` |

The first release of a repository is always `v1.0.0`. Keywords are case-insensitive and must stand alone, so `#minor-fix` or `#majority` do not match. Only strict `vX.Y.Z` tags are considered, and a commit that is already tagged is not tagged again.

Commits made by this tool use `InitialCommitMsg` / `UpdateCommitMsg`, which carry no keyword and so bump the patch version. To publish a release as a minor or major version, put the keyword in `UpdateCommitMsg` in a configuration file for that run.

### Offline plan fixtures

A module cannot be planned without input values. The offline plan uses each `examples/<name>/` directory as a fixture: a root module calling `source = "../.."` with representative inputs. `*.tfvars` files in an example are passed as `-var-file` (`terraform.tfvars` is never committable in a module repository). Without examples the module root is planned directly, which only succeeds when every variable has a default; otherwise the job warns and passes rather than failing. A module that declares a `data "cloudflare_*"` source is skipped, because it reads the API at plan time.

### Opting out and overriding

- `-SkipModuleCI`, or `"IncludeModuleCI": false`, publishes modules without the scaffold. Because module repositories are mirrors, this also removes previously published workflows on the next release.
- A module that ships its own file at the same path (for example `modules/waf/.github/workflows/ci.yml` upstream) keeps it; the scaffold copy is skipped and a warning is printed.
- Edits made directly to the workflows in a published module repository are reverted on the next release. Change `templates/module` here instead.

### Repository settings the tag job needs

- The job pushes tags with `GITHUB_TOKEN` and `contents: write`. If the organisation restricts workflow permissions to read-only at the organisation level, the tag push fails until that is relaxed for these repositories.
- A tag ruleset protecting `v*` blocks the push unless GitHub Actions is on its bypass list.

---

## Agent Context Files

Every published repository receives an `AGENTS.md` and a `CLAUDE.md` from [templates/agents](templates/agents), so coding agents working in it start with the right guidance:

| Template | Published to |
| :--- | :--- |
| [templates/agents/management](templates/agents/management) | The management repository, where upstream does not already ship a root `AGENTS.md` (it currently does, and that wins) |
| [templates/agents/deployment](templates/agents/deployment) | A flat-layout deployment repository |
| [templates/agents/module](templates/agents/module) | Every module repository (the same pair for all of them) |

`AGENTS.md` holds the guidance. `CLAUDE.md` contains only `@AGENTS.md`, which Claude Code resolves as an import, so both tools read one source and the two files cannot drift apart. This matches the upstream Landing Zone repository.

How updates reach published repositories follows the [re-run behaviour](#re-run-behaviour) of each component type:

- **Modules** receive the templates on every release. Editing `templates/agents/module` updates every module repository on the next run, and edits made directly to `AGENTS.md` / `CLAUDE.md` in a published module repository are reverted.
- **The management (or flat deployment) repository** receives the templates only when it is first seeded, or re-released with `-ForceDeploymentUpdate`. Operators can then tailor its `AGENTS.md` in place (customer name, active products) without it being overwritten.
- A component that ships its own `AGENTS.md` or `CLAUDE.md` at source keeps it; the template copy is skipped and a warning is printed.
- `-SkipAgentFiles`, or `"IncludeAgentFiles": false`, publishes without them. For modules this also removes previously published agent files on the next release.

These files are instructions that agents act on, and they are pushed to every repository the tool publishes. Review changes to the templates as you would review code. Never put tokens or other secrets in them, and keep the module template customer-agnostic: it reaches every module repository, including any published with `-Visibility public`.

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

### The management repository is seeded once

`deployment/accounts/**` is exactly where an operator enters real account identifiers and zones after the repository is handed over, and the layers' module pins are theirs to bump. Applying mirror semantics there would revert those edits and delete any account file added that does not exist upstream.

So by default the management repository (or, in the flat layout, the deployment repository) is published **once**. On any subsequent run, if it already exists and carries commits, it is skipped before anything is fetched, staged, or pushed:

```
[WARNING] Management repository has already been seeded. Operator edits under 'accounts/**'
          would be reverted by a re-release, so it is skipped. Use -ForceDeploymentUpdate to override.
management | cflz-management | Skipped
```

A repository that exists but carries no commits — creation succeeded, first push failed — is still treated as unseeded, so a retry completes the initial release.

To deliberately re-release it, overwriting operator changes and re-pinning every module to its latest tag:

```powershell
.\Invoke-CloudflareLandingZoneRelease.ps1 -TargetOwner "YourOrgOrUsername" -OnlyManagement -ForceManagementUpdate
```

`-OnlyManagement` and `-ForceManagementUpdate` are aliases of `-OnlyDeployment` and `-ForceDeploymentUpdate`; both spellings work for either layout.

Set `"SeedDeploymentOnce": false` in a configuration file to make the management repository behave as a strict mirror like the modules.

---

## Prerequisites

1. **PowerShell 7+** (`pwsh`).
2. **Git** (installed and present in `PATH`).
3. **GitHub Personal Access Token (PAT)** with `repo` and `workflow` permissions (or authenticated `gh` CLI). `workflow` is needed because every published repository carries GitHub Actions workflows; without it GitHub rejects the push. Alternatively, keep a `repo`-only token and push over SSH - see [Pushing over SSH](#pushing-over-ssh).

---

## Authentication Methods

The release manager automatically checks for GitHub authentication credentials in the following order:

1. **CLI Parameter:** `-GitHubToken "ghp_..."` or as a `[SecureString]`.
2. **Environment Variables:** `$env:GITHUB_TOKEN` or `$env:GH_TOKEN`.
3. **GitHub CLI (`gh`):** Active session from `gh auth login`.
4. **Interactive Prompt:** If no token is detected, the script securely prompts for token input.

### Pushing over SSH

The token always drives the GitHub API (owner lookup, repository creation). Git fetches and pushes use it too, unless `-GitTransport ssh` is passed, in which case they authenticate with an SSH key:

```powershell
.\Invoke-CloudflareLandingZoneRelease.ps1 `
    -TargetOwner "YourOrgOrUsername" `
    -UseUpstreamSource `
    -GitTransport ssh `
    -SshKeyPath "$HOME\.ssh\id_ed25519_work"
```

An SSH key is not subject to OAuth scopes, so this publishes the workflows in every repository even when the token lacks `workflow` - the usual state of a `gh auth login` token. Only the named key is offered (`IdentitiesOnly`), so an ssh-agent holding a key for another account cannot be used by mistake; ssh runs in batch mode, so the key must have no passphrase or already be loaded in the agent; and github.com must already be in `known_hosts`. Before anything is created, the tool checks which account the key authenticates as, stops if it authenticates as none, and warns if it differs from the token's account. The SSH settings apply only to the Git processes the tool starts.

---

## Targeting a GitHub Organisation

Set `-TargetOwner` to the organisation login. The owner type is resolved before anything is created: an organisation resolves via `GET /orgs/{owner}` and repositories are created with `POST /orgs/{owner}/repos`, whereas a user account uses `POST /user/repos`.

```powershell
.\Invoke-CloudflareLandingZoneRelease.ps1 `
    -TargetOwner "your-organisation" `
    -GitHubToken $env:GITHUB_TOKEN `
    -UseUpstreamSource `
    -Visibility "private"
```

Confirm the resolution line in the output before letting a run proceed:

```
[INFO] Target owner 'your-organisation' resolved as: Organization.
```

If the owner cannot be resolved, the run **fails before creating anything** rather than assuming a user account. Assuming would place every repository under the authenticated account while still reporting success, which is precisely what happens when an organisation enforcing SAML SSO returns 403 to an unauthorised token.

### Token requirements for organisations

| Token type | Requirement |
| :--- | :--- |
| Classic PAT | `repo` and `workflow` scopes. If the organisation enforces SAML SSO, the token must additionally be **authorised for that organisation** in your token settings |
| Fine-grained PAT | Resource owner must be **the organisation**, with *Administration: Read and write* to create repositories, *Contents: Read and write* to push, and *Workflows: Read and write* to publish the module CI |
| `gh` CLI fallback | Often lacks organisation scopes. Run `gh auth refresh -s admin:org` if relying on it |

The account must also hold repository-creation permission in the organisation. Some organisations restrict this to owners.

### Internal visibility

`-Visibility internal` requires an organisation on GitHub Enterprise Cloud. It is sent as an explicit `visibility` field, because sending only `private = true` would quietly create an ordinary private repository instead. Requesting `internal` against a user account is rejected up front rather than silently downgraded.

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
Inspect every planned repository (one per module, plus the management repository) and its remote URL without making changes or writing to GitHub:
```powershell
.\Invoke-CloudflareLandingZoneRelease.ps1 `
    -TargetOwner "YourOrgOrUsername" `
    -WhatIf
```

### 4. Release Only the Management Repository or Specific Modules
Release only the management repository. Its module pins resolve against the module repositories already published under the owner, so this is also how to seed it after the module CI has tagged every module:
```powershell
.\Invoke-CloudflareLandingZoneRelease.ps1 `
    -TargetOwner "YourOrgOrUsername" `
    -OnlyManagement
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
| `-SourceRoot` | String | `..\CloudflareLandingZone` beside this repository | Path to root CloudflareLandingZone directory. |
| `-UseUpstreamSource` | Switch | `false` | Cuts the release from a fresh clone of the upstream GitHub repository. |
| `-UpstreamRepoUrl` | String | `https://github.com/itsharryshelton/CloudflareLandingZone.git` | Upstream repository cloned when `-UseUpstreamSource` is set. |
| `-UpstreamRef` | String | `main` | Branch or tag to clone from upstream. |
| `-TargetOwner` | String | (Authenticated User) | GitHub Organisation or Username owning the repositories. |
| `-GitHubToken` | String / SecureString | (Env / CLI / Prompt) | GitHub Personal Access Token with `repo` scope. |
| `-Prefix` | String | `cflz` | Value substituted into the `{prefix}` token of every name template. |
| `-DeploymentLayout` | String | `Management` | `Management` publishes the source root minus `modules/`, pipelines included. `Flat` publishes `deployment/` alone. See [Management Repository](#management-repository). |
| `-ManagementRepoName` | String | `{prefix}-management` | Name template for the management repository. Supports `{prefix}`. |
| `-DeploymentRepoName` | String | `{prefix}-deployment` | Name template for the flat-layout deployment repository. Supports `{prefix}`. |
| `-ModuleRepoPattern` | String | `terraform-cloudflare-lz-{module}` | Name template for module repositories. Supports `{prefix}` and `{module}`. |
| `-Visibility` | String | `private` | Visibility of created repositories (`private`, `public`, `internal`). |
| `-GitTransport` | String | `https` | `https` pushes with the token; `ssh` pushes with an SSH key. See [Pushing over SSH](#pushing-over-ssh). |
| `-SshKeyPath` | String | (ssh config / agent) | Private key for `-GitTransport ssh`. |
| `-Modules` | String[] | All modules | Specific list of module folder names to publish. |
| `-ExcludeModules` | String[] | `@()` | Module folder names to omit from the release. |
| `-OnlyDeployment` / `-OnlyManagement` | Switch | `false` | When set, only processes the management (or flat deployment) repository. |
| `-OnlyModules` | Switch | `false` | When set, only processes modules. |
| `-ModuleSourceRef` | String | `latest` | The ref layer module sources are pinned to. `latest` resolves each module's highest `vX.Y.Z` tag, or `v1.0.0` where it has none yet. |
| `-SkipSourceRewrite` | Switch | `false` | Leaves the layers' upstream module sources unchanged. |
| `-ForceDeploymentUpdate` / `-ForceManagementUpdate` | Switch | `false` | Re-releases an already-seeded management (or flat deployment) repository, overwriting operator edits under `accounts/**`. |
| `-AllowForcePush` | Switch | `false` | Permits overwriting remote history. Without it, a target repository carrying unrelated commits is reported as failed rather than overwritten. |
| `-SkipModuleCI` | Switch | `false` | Publishes module repositories without the CI scaffold. See [Module CI and Versioning](#module-ci-and-versioning). |
| `-SkipAgentFiles` | Switch | `false` | Publishes repositories without `AGENTS.md` / `CLAUDE.md`. See [Agent Context Files](#agent-context-files). |
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
- **What is excluded from a release:** `.terraform/` provider and module caches, `*.tfstate` files, saved plans and crash logs are never copied. Terraform state in particular can contain secrets in plain text. When the source is a Git work tree, anything Git does not track is excluded as well, because the publish step stages with `git add --force` and the source `.gitignore` alone cannot keep a local file out.
- **What is included:** every tracked file under the component directory - for the management repository, the whole source root except `modules/` - including `deployment/accounts/**/*.tfvars`. Those files hold account identifiers and domains. This is intentional, matching the upstream policy for a private repository with RBAC, but review the contents before releasing to a new owner.
- **The management repository's pipelines run on its first push.** `ci.yml` and `secret-scanning.yml` trigger on push to `main`; neither holds a Cloudflare credential, and `terraform-plan.yml` / `terraform-apply.yml` are manual only, so publishing it changes nothing at Cloudflare.
- **Review before first use against production.** Run with `-WhatIf` first and confirm the target owner, repository names and visibility.

---

## Running Tests

Run the Pester test suite to validate discovery, configuration parsing, copy filtering, published ignore-rule correctness, module source rewriting and tag resolution, publishing and idempotency (against local bare repositories, so no GitHub access is required), and dry-run execution:

```powershell
Invoke-Pester -Path ".\tests\ReleaseManager.Tests.ps1" -Output Detailed
```

Most tests run against a small fixture monorepo built on the fly. A few also read a real upstream checkout - by default `..\CloudflareLandingZone` beside this repository, or wherever `$env:CFLZ_SOURCE_ROOT` points - and are skipped when there is none.
