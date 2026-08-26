<#
.SYNOPSIS
    Repository Publisher module for Cloudflare Landing Zone Release Manager.
.DESCRIPTION
    Handles staging directories, data copying as-is, Git initialisation,
    repository synchronisation, commit creation, and pushing to GitHub remotes.
#>

function Get-ComponentGitIgnoreContent {
    <#
    .SYNOPSIS
        Produces a .gitignore whose paths are correct relative to the published repository root.
    .DESCRIPTION
        The upstream monorepo .gitignore negates paths such as 'deployment/accounts/*/*.tfvars'.
        Once 'deployment' becomes the root of its own repository those negations no longer match,
        so the blanket '*.tfvars' deny would silently withhold every account configuration file
        from the release. This function restates the policy relative to each repository root.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [ValidateSet("Deployment", "Module")]
        [string]$ComponentType = "Deployment"
    )

    $common = @"
# ---- Terraform ----
# Local provider/module install directories
**/.terraform/*

# Keep the dependency lock file (it is committed) but ignore the plugin cache
!**/.terraform.lock.hcl

# State files - MUST never be committed (they contain resource data and secrets)
*.tfstate
*.tfstate.*
*.tfstate.backup

# Crash logs
crash.log
crash.*.log

# Saved plans
*.tfplan
tfplan
tfplan.json

# ---- Variable files ----
# Default-deny. Variable files are the most likely place for a tenant identifier
# or a pasted secret to end up, so nothing is committable unless listed below.
*.tfvars
*.tfvars.json
!*.tfvars.example
"@

    $componentSpecific = if ($ComponentType -eq "Deployment") {
        @"

# Exceptions, expressed relative to the root of THIS repository (the deployment tree).
# Layer defaults are customer-agnostic. Account trees carry account identifiers and
# domains, which are configuration rather than secrets, and this repository is private
# with RBAC. API tokens and R2 keys are never present: they arrive at runtime as
# CLOUDFLARE_API_TOKEN / AWS_* environment variables.
!layers/*/defaults.auto.tfvars
!accounts/*/*.tfvars
"@
    }
    else {
        @"

# Module repositories publish example variable files only. Real values live in the
# deployment repository.
!examples/**/*.tfvars
"@
    }

    $trailer = @"

# Operator-local overrides and real tenant values: never committable, anywhere.
# Re-stated after the exceptions above so that no negation can reach them.
**/local.auto.tfvars
**/terraform.tfvars
**/*.local.tfvars
**/*.auto.tfvars.json

# OS and editor files
.DS_Store
Thumbs.db
.vscode/
.idea/
"@

    return ($common + $componentSpecific + $trailer)
}

function Get-StandardGitIgnoreContent {
    <#
    .SYNOPSIS
        Returns the deployment variant of the .gitignore policy.
    #>
    [CmdletBinding()]
    param ()

    return (Get-ComponentGitIgnoreContent -ComponentType "Deployment")
}

function Copy-SourceDataAsIs {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$SourceDirectory,

        [Parameter(Mandatory = $true)]
        [string]$DestinationDirectory,

        [Parameter(Mandatory = $false)]
        [ValidateSet("Deployment", "Module")]
        [string]$ComponentType = "Deployment"
    )

    if (-not (Test-Path -Path $SourceDirectory)) {
        throw [System.IO.DirectoryNotFoundException]::new("Source directory does not exist: $SourceDirectory")
    }

    if (-not (Test-Path -Path $DestinationDirectory)) {
        New-Item -Path $DestinationDirectory -ItemType Directory -Force | Out-Null
    }

    $resolvedSource = (Resolve-Path -Path $SourceDirectory).ProviderPath.TrimEnd('\', '/')

    # Ephemeral local artefacts that must never be released. Note that '.terraform.lock.hcl'
    # is a file rather than a directory, so it survives the '.terraform' directory exclusion.
    $excludeDirs = @(".git", ".terraform", "bin", "obj", ".idea", ".vscode")
    $excludeFiles = @("*.tfstate", "*.tfstate.*", "*.tfplan", "crash.log", "crash.*.log")

    $copiedFiles = @()

    $items = Get-ChildItem -Path $resolvedSource -Recurse -Force | Where-Object {
        $relPath = $_.FullName.Substring($resolvedSource.Length).TrimStart('\', '/')
        $pathParts = $relPath.Split([char]0x5C, [char]0x2F)

        $isExcludedDir = $false
        foreach ($part in $pathParts) {
            if ($part -in $excludeDirs) {
                $isExcludedDir = $true
                break
            }
        }
        if ($isExcludedDir) { return $false }

        if (-not $_.PSIsContainer) {
            foreach ($exPattern in $excludeFiles) {
                if ($_.Name -like $exPattern) {
                    return $false
                }
            }
        }
        return $true
    }

    foreach ($item in $items) {
        $relPath = $item.FullName.Substring($resolvedSource.Length).TrimStart('\', '/')
        $destPath = Join-Path -Path $DestinationDirectory -ChildPath $relPath

        if ($item.PSIsContainer) {
            if (-not (Test-Path -Path $destPath)) {
                New-Item -Path $destPath -ItemType Directory -Force | Out-Null
            }
        }
        else {
            $destParent = Split-Path -Path $destPath -Parent
            if (-not (Test-Path -Path $destParent)) {
                New-Item -Path $destParent -ItemType Directory -Force | Out-Null
            }
            Copy-Item -Path $item.FullName -Destination $destPath -Force
            $copiedFiles += $relPath
        }
    }

    # Ensure a .gitignore is present, restated for this repository root where the source
    # only carries the monorepo-relative policy.
    $targetGitIgnore = Join-Path -Path $DestinationDirectory -ChildPath ".gitignore"
    if (-not (Test-Path -Path $targetGitIgnore)) {
        Set-Content -Path $targetGitIgnore -Value (Get-ComponentGitIgnoreContent -ComponentType $ComponentType) -Encoding utf8
    }

    return [PSCustomObject]@{
        SourceDirectory      = $resolvedSource
        DestinationDirectory = $DestinationDirectory
        FileCount            = $copiedFiles.Count
        Files                = $copiedFiles
    }
}

function Protect-GitOutput {
    <#
    .SYNOPSIS
        Redacts embedded credentials from Git output before it is logged or thrown.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return ""
    }

    return ($Text -replace "https://[^/@\s]+@", "https://***@")
}

function Invoke-GitCommand {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $pinfo = [System.Diagnostics.ProcessStartInfo]::new()
    $pinfo.FileName = "git"
    $pinfo.WorkingDirectory = $WorkingDirectory
    $pinfo.RedirectStandardOutput = $true
    $pinfo.RedirectStandardError = $true
    $pinfo.UseShellExecute = $false
    $pinfo.CreateNoWindow = $true

    # Never allow Git to block on an interactive credential or host prompt during automation.
    $pinfo.EnvironmentVariables["GIT_TERMINAL_PROMPT"] = "0"

    foreach ($arg in $Arguments) {
        $pinfo.ArgumentList.Add($arg)
    }

    $process = [System.Diagnostics.Process]::Start($pinfo)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    return [PSCustomObject]@{
        ExitCode = $process.ExitCode
        Output   = (Protect-GitOutput -Text $stdout).Trim()
        Error    = (Protect-GitOutput -Text $stderr).Trim()
    }
}

function Get-ComponentReleaseAction {
    <#
    .SYNOPSIS
        Decides whether a component should be created, updated, or skipped.
    .DESCRIPTION
        Module repositories are strict mirrors of the source: they carry no per-tenant content,
        so re-running always re-synchronises them.

        The deployment repository is different. Its 'accounts/**' tree is exactly where an
        operator enters real account identifiers and zones after the repository is handed over.
        Because a release wipes the working tree and re-copies from source, a re-run would revert
        those edits and delete any file the operator added that does not exist upstream. Under the
        default seed-once policy the deployment repository is therefore published exactly once and
        skipped on every subsequent run, unless an update is explicitly requested.

        A repository that exists but carries no commits (for example, creation succeeded but the
        first push failed) is still treated as unseeded, so a retry completes the initial release.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet("Deployment", "Module")]
        [string]$ComponentType,

        [Parameter(Mandatory = $true)]
        [bool]$RepoExists,

        [Parameter(Mandatory = $true)]
        [bool]$RemoteHasCommits,

        [Parameter(Mandatory = $false)]
        [bool]$SeedDeploymentOnce = $true,

        [Parameter(Mandatory = $false)]
        [bool]$ForceDeploymentUpdate = $false
    )

    if (-not $RepoExists -or -not $RemoteHasCommits) {
        return [PSCustomObject]@{
            Action = "Create"
            Reason = if ($RepoExists) { "Repository exists but carries no commits; completing the initial release." } else { "Repository does not exist yet." }
        }
    }

    if ($ComponentType -eq "Deployment" -and $SeedDeploymentOnce -and -not $ForceDeploymentUpdate) {
        return [PSCustomObject]@{
            Action = "Skip"
            Reason = "Deployment repository has already been seeded. Operator edits under 'accounts/**' would be reverted by a re-release, so it is skipped. Use -ForceDeploymentUpdate to override."
        }
    }

    return [PSCustomObject]@{
        Action = "Update"
        Reason = "Repository already exists; synchronising source content."
    }
}

function Sync-UpstreamSource {
    <#
    .SYNOPSIS
        Clones the upstream Cloudflare Landing Zone repository so that a release is cut from the
        authoritative published source rather than from a possibly stale local working tree.
    .DESCRIPTION
        A shallow clone of the requested ref is taken into a scratch workspace. Any pre-existing
        workspace is removed first so that each run starts from a clean, reproducible checkout.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$RepositoryUrl,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,

        [Parameter(Mandatory = $false)]
        [string]$Ref = "main",

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$AuthenticatedUrl
    )

    $cloneUrl = if (-not [string]::IsNullOrWhiteSpace($AuthenticatedUrl)) { $AuthenticatedUrl } else { $RepositoryUrl }

    if (Test-Path -Path $DestinationPath) {
        Remove-Item -Path $DestinationPath -Recurse -Force
    }

    $parentPath = Split-Path -Path $DestinationPath -Parent
    if (-not (Test-Path -Path $parentPath)) {
        New-Item -Path $parentPath -ItemType Directory -Force | Out-Null
    }

    $cloneRes = Invoke-GitCommand -WorkingDirectory $parentPath -Arguments @("clone", "--depth", "1", "--branch", $Ref, $cloneUrl, $DestinationPath)
    if ($cloneRes.ExitCode -ne 0) {
        throw [System.InvalidOperationException]::new("Unable to clone upstream source '$RepositoryUrl' at ref '$($Ref)': $($cloneRes.Error)")
    }

    # Strip any credential that the clone URL may have carried out of the on-disk Git config.
    Invoke-GitCommand -WorkingDirectory $DestinationPath -Arguments @("remote", "set-url", "origin", $RepositoryUrl) | Out-Null

    $shaRes = Invoke-GitCommand -WorkingDirectory $DestinationPath -Arguments @("rev-parse", "HEAD")
    $subjectRes = Invoke-GitCommand -WorkingDirectory $DestinationPath -Arguments @("log", "-1", "--pretty=%s")

    return [PSCustomObject]@{
        RepositoryUrl = $RepositoryUrl
        Ref           = $Ref
        Path          = $DestinationPath
        CommitSha     = $shaRes.Output
        CommitSubject = $subjectRes.Output
    }
}

function Get-RemoteRepositoryState {
    <#
    .SYNOPSIS
        Determines whether a remote repository already carries commits on the target branch.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory = $true)]
        [string]$AuthenticatedUrl,

        [Parameter(Mandatory = $false)]
        [string]$DefaultBranch = "main"
    )

    $result = Invoke-GitCommand -WorkingDirectory $WorkingDirectory -Arguments @("ls-remote", "--heads", $AuthenticatedUrl)

    if ($result.ExitCode -ne 0) {
        throw [System.InvalidOperationException]::new("Unable to query remote repository state: $($result.Error)")
    }

    $heads = @()
    if (-not [string]::IsNullOrWhiteSpace($result.Output)) {
        $heads = @(
            $result.Output -split "`r?`n" | ForEach-Object {
                ($_ -split "\s+")[-1] -replace "^refs/heads/", ""
            } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
    }

    return [PSCustomObject]@{
        IsEmpty       = ($heads.Count -eq 0)
        Branches      = $heads
        HasTargetHead = ($heads -contains $DefaultBranch)
    }
}

function Initialize-StagingRepository {
    <#
    .SYNOPSIS
        Prepares a staging working tree, preserving remote history where the repository already exists.
    .DESCRIPTION
        When the remote already carries the target branch, its tip is fetched and checked out so that
        the release becomes an ordinary fast-forward commit on top of existing history rather than a
        forced overwrite. Previously published content is then cleared from the working tree so that
        files removed at source are also removed from the release.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$StagingPath,

        [Parameter(Mandatory = $true)]
        [string]$RemoteUrl,

        [Parameter(Mandatory = $true)]
        [string]$AuthenticatedUrl,

        [Parameter(Mandatory = $false)]
        [string]$DefaultBranch = "main"
    )

    if (-not (Test-Path -Path $StagingPath)) {
        New-Item -Path $StagingPath -ItemType Directory -Force | Out-Null
    }

    $gitDir = Join-Path -Path $StagingPath -ChildPath ".git"
    if (-not (Test-Path -Path $gitDir)) {
        $initRes = Invoke-GitCommand -WorkingDirectory $StagingPath -Arguments @("init", "-b", $DefaultBranch)
        if ($initRes.ExitCode -ne 0) {
            # Fallback for Git versions predating 'init -b'
            $legacyInit = Invoke-GitCommand -WorkingDirectory $StagingPath -Arguments @("init")
            if ($legacyInit.ExitCode -ne 0) {
                throw [System.InvalidOperationException]::new("Git initialisation failed: $($legacyInit.Error)")
            }
            Invoke-GitCommand -WorkingDirectory $StagingPath -Arguments @("checkout", "-B", $DefaultBranch) | Out-Null
        }
    }

    # The clean remote URL is what is stored on disk. The authenticated URL is only ever
    # passed as a transient command argument, so the token never reaches .git/config.
    $remotes = Invoke-GitCommand -WorkingDirectory $StagingPath -Arguments @("remote")
    if ((@($remotes.Output -split "`r?`n")) -contains "origin") {
        Invoke-GitCommand -WorkingDirectory $StagingPath -Arguments @("remote", "set-url", "origin", $RemoteUrl) | Out-Null
    }
    else {
        Invoke-GitCommand -WorkingDirectory $StagingPath -Arguments @("remote", "add", "origin", $RemoteUrl) | Out-Null
    }

    # Guarantee a commit identity. Automation hosts and build agents frequently have no
    # global Git identity configured, which would otherwise fail the commit step.
    $emailCfg = Invoke-GitCommand -WorkingDirectory $StagingPath -Arguments @("config", "user.email")
    if ($emailCfg.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($emailCfg.Output)) {
        Invoke-GitCommand -WorkingDirectory $StagingPath -Arguments @("config", "user.email", "release-manager@cloudflare-landing-zone.local") | Out-Null
        Invoke-GitCommand -WorkingDirectory $StagingPath -Arguments @("config", "user.name", "Cloudflare Landing Zone Release Manager") | Out-Null
    }

    $state = Get-RemoteRepositoryState -WorkingDirectory $StagingPath -AuthenticatedUrl $AuthenticatedUrl -DefaultBranch $DefaultBranch
    $historyFetched = $false

    if ($state.HasTargetHead) {
        $fetchRes = Invoke-GitCommand -WorkingDirectory $StagingPath -Arguments @("fetch", "--depth", "1", $AuthenticatedUrl, "+refs/heads/$($DefaultBranch):refs/remotes/origin/$DefaultBranch")
        if ($fetchRes.ExitCode -ne 0) {
            throw [System.InvalidOperationException]::new("Unable to fetch existing remote history: $($fetchRes.Error)")
        }

        $checkoutRes = Invoke-GitCommand -WorkingDirectory $StagingPath -Arguments @("checkout", "-B", $DefaultBranch, "refs/remotes/origin/$DefaultBranch")
        if ($checkoutRes.ExitCode -ne 0) {
            throw [System.InvalidOperationException]::new("Unable to check out existing remote branch: $($checkoutRes.Error)")
        }

        $historyFetched = $true
    }

    # Clear previously published content so that deletions at source propagate to the release.
    Get-ChildItem -Path $StagingPath -Force | Where-Object { $_.Name -ne ".git" } | ForEach-Object {
        Remove-Item -Path $_.FullName -Recurse -Force
    }

    return [PSCustomObject]@{
        StagingPath    = $StagingPath
        Branch         = $DefaultBranch
        RemoteIsEmpty  = $state.IsEmpty
        HistoryFetched = $historyFetched
    }
}

function Publish-LocalRepository {
    <#
    .SYNOPSIS
        Commits the staged release content and pushes it to the GitHub remote.
    .DESCRIPTION
        Staging uses 'git add --all --force' so that the published repository matches the copied
        source exactly. The copy step has already removed state files, saved plans and provider
        caches, so the force flag guarantees fidelity rather than widening what is released.
        A normal (non-forced) push is used. Forced pushes must be requested with -AllowForcePush.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$StagingPath,

        [Parameter(Mandatory = $true)]
        [string]$RemoteUrl,

        [Parameter(Mandatory = $true)]
        [string]$AuthenticatedPushUrl,

        [Parameter(Mandatory = $false)]
        [string]$DefaultBranch = "main",

        [Parameter(Mandatory = $false)]
        [string]$CommitMessage = "Initial release of Cloudflare Landing Zone component",

        [Parameter(Mandatory = $false)]
        [switch]$AllowForcePush
    )

    if (-not (Test-Path -Path (Join-Path -Path $StagingPath -ChildPath ".git"))) {
        throw [System.InvalidOperationException]::new("Staging path '$StagingPath' is not an initialised Git repository. Call Initialize-StagingRepository first.")
    }

    # Force staging: the working tree is exactly what should be released, and the published
    # .gitignore must not be able to withhold source files from the release itself.
    $addRes = Invoke-GitCommand -WorkingDirectory $StagingPath -Arguments @("add", "--all", "--force", ".")
    if ($addRes.ExitCode -ne 0) {
        throw [System.InvalidOperationException]::new("Git staging failed: $($addRes.Error)")
    }

    $status = Invoke-GitCommand -WorkingDirectory $StagingPath -Arguments @("status", "--porcelain")
    $hasChanges = -not [string]::IsNullOrWhiteSpace($status.Output)

    if ($hasChanges) {
        $commitRes = Invoke-GitCommand -WorkingDirectory $StagingPath -Arguments @("commit", "-m", $CommitMessage)
        if ($commitRes.ExitCode -ne 0) {
            throw [System.InvalidOperationException]::new("Git commit failed: $($commitRes.Error)")
        }
    }

    $pushArgs = @("push", $AuthenticatedPushUrl, "HEAD:refs/heads/$DefaultBranch")
    if ($AllowForcePush.IsPresent) {
        $pushArgs += "--force"
    }

    $pushRes = Invoke-GitCommand -WorkingDirectory $StagingPath -Arguments $pushArgs
    if ($pushRes.ExitCode -ne 0) {
        $hint = if (-not $AllowForcePush.IsPresent -and $pushRes.Error -match "non-fast-forward|fetch first|rejected") {
            " The remote carries commits that are not present locally. Re-run with -AllowForcePush only if overwriting the remote history is intended."
        }
        else {
            ""
        }
        throw [System.InvalidOperationException]::new("Git push to remote failed: $($pushRes.Error)$hint")
    }

    return [PSCustomObject]@{
        Committed = $hasChanges
        Pushed    = $true
        Forced    = $AllowForcePush.IsPresent
        Branch    = $DefaultBranch
        Remote    = $RemoteUrl
    }
}

Export-ModuleMember -Function @(
    "Copy-SourceDataAsIs",
    "Sync-UpstreamSource",
    "Get-ComponentReleaseAction",
    "Initialize-StagingRepository",
    "Get-RemoteRepositoryState",
    "Publish-LocalRepository",
    "Invoke-GitCommand",
    "Protect-GitOutput",
    "Get-ComponentGitIgnoreContent",
    "Get-StandardGitIgnoreContent"
)
