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
        [ValidateSet("Management", "Deployment", "Module")]
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

    $componentSpecific = if ($ComponentType -eq "Management") {
        @"

# Exceptions. The management repository keeps the upstream layout, so 'deployment/'
# is still a directory under the repository root and the upstream paths apply as-is.
# Layer defaults are customer-agnostic. Account trees carry account identifiers and
# domains, which are configuration rather than secrets, and this repository is private
# with RBAC. API tokens and R2 keys are never present: they arrive at runtime as
# CLOUDFLARE_API_TOKEN / AWS_* environment variables.
!deployment/layers/*/defaults.auto.tfvars
!deployment/accounts/*/*.tfvars
"@
    }
    elseif ($ComponentType -eq "Deployment") {
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

function Get-GitTrackedFileSet {
    <#
    .SYNOPSIS
        Returns the files Git tracks under a directory, or $null when it is not in a work tree.
    .DESCRIPTION
        Paths are relative to -Directory and use forward slashes. A release cut from a local
        working tree is restricted to this set, so that untracked local files (agent settings,
        scratch notes, an operator's local.auto.tfvars) never reach a published repository.
        The publish step stages with 'git add --force', so the source's .gitignore cannot be
        relied on to keep them out.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Directory
    )

    $inside = Invoke-GitCommand -WorkingDirectory $Directory -Arguments @("rev-parse", "--is-inside-work-tree")
    if ($inside.ExitCode -ne 0 -or $inside.Output -ne "true") {
        return $null
    }

    $listed = Invoke-GitCommand -WorkingDirectory $Directory -Arguments @("ls-files", "-z")
    if ($listed.ExitCode -ne 0) {
        throw [System.InvalidOperationException]::new("Unable to list tracked files under '$Directory': $($listed.Error)")
    }

    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($path in ($listed.Output -split "`0")) {
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            $set.Add($path.Trim()) | Out-Null
        }
    }

    return , $set
}

function Copy-SourceDataAsIs {
    <#
    .SYNOPSIS
        Copies a component's source tree into a staging directory, minus ephemeral artefacts.
    .DESCRIPTION
        When the source sits in a Git work tree, only tracked files are copied (with their
        working-tree content). A fresh upstream clone tracks everything it holds, so this only
        narrows a release cut from a local checkout.

        -ExcludeTopLevel drops whole top-level directories, matched on the first path segment
        only. The management repository uses it to leave 'modules/' out of the source root.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$SourceDirectory,

        [Parameter(Mandatory = $true)]
        [string]$DestinationDirectory,

        [Parameter(Mandatory = $false)]
        [ValidateSet("Management", "Deployment", "Module")]
        [string]$ComponentType = "Deployment",

        [Parameter(Mandatory = $false)]
        [string[]]$ExcludeTopLevel = @()
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

    # Terraform reads the lock file of the root module only, so a module's own lock file is
    # never consulted by a layer that calls it. All it does in a module repository is pin the
    # module CI to whichever provider build, and whichever platform's hashes, the committer's
    # last local 'terraform init' produced - a Windows-only hash fails init on a Linux runner.
    # Root modules (layers, examples' callers) keep theirs.
    if ($ComponentType -eq "Module") {
        $excludeFiles += ".terraform.lock.hcl"
    }

    $trackedFiles = Get-GitTrackedFileSet -Directory $resolvedSource

    $copiedFiles = @()

    $items = Get-ChildItem -Path $resolvedSource -Recurse -Force | Where-Object {
        $relPath = $_.FullName.Substring($resolvedSource.Length).TrimStart('\', '/')
        $pathParts = $relPath.Split([char]0x5C, [char]0x2F)

        if ($pathParts[0] -in $ExcludeTopLevel) { return $false }

        if ($null -ne $trackedFiles) {
            # Directories are created on demand for the files beneath them, so an untracked
            # directory never appears in the release as an empty folder.
            if ($_.PSIsContainer) { return $false }
            if (-not $trackedFiles.Contains($relPath.Replace('\', '/'))) { return $false }
        }

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

function Copy-ComponentScaffold {
    <#
    .SYNOPSIS
        Overlays a scaffold (CI workflows, scanner configuration, agent context files) onto a staged release.
    .DESCRIPTION
        Module repositories are strict mirrors: anything added directly to one is deleted on the
        next release. CI therefore has to arrive with every release rather than be added to the
        published repository afterwards.

        A file the source component already carries wins over the scaffold, so an individual
        module can ship its own workflow without the scaffold silently replacing it.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ScaffoldDirectory,

        [Parameter(Mandatory = $true)]
        [string]$DestinationDirectory
    )

    if (-not (Test-Path -Path $ScaffoldDirectory)) {
        throw [System.IO.DirectoryNotFoundException]::new("Scaffold directory does not exist: $ScaffoldDirectory")
    }

    $resolvedScaffold = (Resolve-Path -Path $ScaffoldDirectory).ProviderPath.TrimEnd('\', '/')
    $addedFiles = @()
    $keptFiles = @()

    foreach ($file in (Get-ChildItem -Path $resolvedScaffold -Recurse -Force -File)) {
        $relPath = $file.FullName.Substring($resolvedScaffold.Length).TrimStart('\', '/')
        $destPath = Join-Path -Path $DestinationDirectory -ChildPath $relPath

        if (Test-Path -Path $destPath) {
            $keptFiles += $relPath
            continue
        }

        $destParent = Split-Path -Path $destPath -Parent
        if (-not (Test-Path -Path $destParent)) {
            New-Item -Path $destParent -ItemType Directory -Force | Out-Null
        }
        Copy-Item -Path $file.FullName -Destination $destPath -Force
        $addedFiles += $relPath
    }

    return [PSCustomObject]@{
        ScaffoldDirectory = $resolvedScaffold
        FileCount         = $addedFiles.Count
        Files             = $addedFiles
        KeptFromSource    = $keptFiles
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

# Set by Set-GitSshCommand for an SSH-transport release; applied to every Git process this
# module starts, and never written to the caller's environment or to any Git config.
$script:GitSshCommand = $null
$script:GitSshKeyPath = $null

function Get-GitSshCommand {
    <#
    .SYNOPSIS
        Builds the ssh command Git runs for an SSH-transport release.
    .DESCRIPTION
        IdentitiesOnly stops an ssh-agent offering some other key first, which GitHub would
        accept as some other account. BatchMode makes a passphrase or an unknown host key fail
        immediately instead of waiting on a prompt nobody can answer. Host keys are still
        checked against known_hosts.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$KeyPath
    )

    $command = "ssh -o BatchMode=yes"
    if (-not [string]::IsNullOrWhiteSpace($KeyPath)) {
        # Git hands GIT_SSH_COMMAND to a POSIX shell, so forward slashes and double quotes.
        $resolved = (Resolve-Path -Path $KeyPath -ErrorAction Stop).ProviderPath -replace '\\', '/'
        $command += " -o IdentitiesOnly=yes -i `"$resolved`""
    }

    return $command
}

function Set-GitSshCommand {
    <#
    .SYNOPSIS
        Sets (or, with no -KeyPath, clears) the ssh command used by Git processes this module starts.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$KeyPath,

        [Parameter(Mandatory = $false)]
        [switch]$Clear
    )

    if ($Clear.IsPresent) {
        $script:GitSshCommand = $null
        $script:GitSshKeyPath = $null
        return
    }

    $script:GitSshCommand = Get-GitSshCommand -KeyPath $KeyPath
    $script:GitSshKeyPath = if ([string]::IsNullOrWhiteSpace($KeyPath)) { $null } else { (Resolve-Path -Path $KeyPath -ErrorAction Stop).ProviderPath }
}

function Get-GitRemoteUrl {
    <#
    .SYNOPSIS
        Returns the URL Git uses to reach a GitHub repository for fetch, ls-remote and push.
    .DESCRIPTION
        'https' embeds the token as a transient credential; it is passed as a command argument
        only and never stored. 'ssh' authenticates with the SSH key instead. An SSH key is not
        subject to OAuth scopes, so it can push '.github/workflows/*' where a token without the
        'workflow' scope cannot. GitHub API calls still use the token either way.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet("https", "ssh")]
        [string]$Transport,

        [Parameter(Mandatory = $true)]
        [string]$Owner,

        [Parameter(Mandatory = $true)]
        [string]$RepoName,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Token
    )

    if ($Transport -eq "ssh") {
        return "git@github.com:$Owner/$RepoName.git"
    }

    if ([string]::IsNullOrWhiteSpace($Token)) {
        return "https://github.com/$Owner/$RepoName.git"
    }

    return "https://x-access-token:$Token@github.com/$Owner/$RepoName.git"
}

function ConvertFrom-GitHubSshGreeting {
    <#
    .SYNOPSIS
        Extracts the login from GitHub's 'ssh -T' greeting, or $null when authentication failed.
    .EXAMPLE
        ConvertFrom-GitHubSshGreeting -Text "Hi octocat! You've successfully authenticated, ..."   # octocat
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $match = [regex]::Match($Text, "Hi (?<login>[A-Za-z0-9-]+)(?:/[A-Za-z0-9._-]+)?! You've successfully authenticated")
    if ($match.Success) { return $match.Groups["login"].Value }
    return $null
}

function Test-GitHubSshIdentity {
    <#
    .SYNOPSIS
        Checks which GitHub account the configured SSH key authenticates as.
    .DESCRIPTION
        Run before anything is created, so a key that does not authenticate fails the release
        up front instead of after every repository has been created empty.
    #>
    [CmdletBinding()]
    param ()

    # Prefer the ssh bundled with Git for Windows, which is the one Git itself runs.
    $sshExe = "ssh"
    $gitCommand = Get-Command -Name "git" -ErrorAction SilentlyContinue
    if ($null -ne $gitCommand) {
        # git.exe sits in '<root>\cmd' or '<root>\mingw64\bin' depending on what is on PATH.
        $gitBin = Split-Path -Path $gitCommand.Source -Parent
        foreach ($root in @((Split-Path -Path $gitBin -Parent), (Split-Path -Path (Split-Path -Path $gitBin -Parent) -Parent))) {
            $bundled = Join-Path -Path $root -ChildPath "usr\bin\ssh.exe"
            if (Test-Path -Path $bundled) { $sshExe = $bundled; break }
        }
    }

    $pinfo = [System.Diagnostics.ProcessStartInfo]::new()
    $pinfo.FileName = $sshExe
    foreach ($arg in @("-o", "BatchMode=yes")) { $pinfo.ArgumentList.Add($arg) }
    if ($script:GitSshKeyPath) {
        foreach ($arg in @("-o", "IdentitiesOnly=yes", "-i", $script:GitSshKeyPath)) { $pinfo.ArgumentList.Add($arg) }
    }
    foreach ($arg in @("-T", "git@github.com")) { $pinfo.ArgumentList.Add($arg) }
    $pinfo.RedirectStandardOutput = $true
    $pinfo.RedirectStandardError = $true
    $pinfo.UseShellExecute = $false
    $pinfo.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::Start($pinfo)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    $text = ($stdout + "`n" + $stderr).Trim()
    return [PSCustomObject]@{
        Login  = ConvertFrom-GitHubSshGreeting -Text $text
        Output = $text
    }
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
    if ($script:GitSshCommand) {
        $pinfo.EnvironmentVariables["GIT_SSH_COMMAND"] = $script:GitSshCommand
    }

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
        [ValidateSet("Management", "Deployment", "Module")]
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

    # The management repository holds the same 'accounts/**' tree, one directory down.
    if ($ComponentType -in @("Deployment", "Management") -and $SeedDeploymentOnce -and -not $ForceDeploymentUpdate) {
        return [PSCustomObject]@{
            Action = "Skip"
            Reason = "$ComponentType repository has already been seeded. Operator edits under 'accounts/**' would be reverted by a re-release, so it is skipped. Use -ForceDeploymentUpdate to override."
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

function Get-LatestSemVerTag {
    <#
    .SYNOPSIS
        Returns the highest strict vX.Y.Z tag a remote repository carries.
    .DESCRIPTION
        Only strict SemVer tags are considered, matching the module CI's next-version.sh, so a
        hand-made tag such as 'v2-rc' can never be what a layer is pinned to. Reachable is
        $false when the remote cannot be queried, typically because the repository does not
        exist yet.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory = $true)]
        [string]$AuthenticatedUrl
    )

    $result = Invoke-GitCommand -WorkingDirectory $WorkingDirectory -Arguments @("ls-remote", "--tags", "--refs", $AuthenticatedUrl)
    if ($result.ExitCode -ne 0) {
        return [PSCustomObject]@{ Reachable = $false; Tag = $null; Error = $result.Error }
    }

    $tags = @(
        $result.Output -split "`r?`n" | ForEach-Object {
            ($_ -split "\s+")[-1] -replace "^refs/tags/", ""
        } | Where-Object { $_ -match '^v\d+\.\d+\.\d+$' }
    )

    $latest = $tags | Sort-Object -Property { [version]$_.Substring(1) } -Descending | Select-Object -First 1

    return [PSCustomObject]@{ Reachable = $true; Tag = $latest; Error = "" }
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
        # GitHub refuses a push that adds or changes .github/workflows/* unless the token carries
        # the 'workflow' scope, and its message does not say which setting to change.
        $hint = if ($pushRes.Error -match "workflow.*scope|without .workflow.") {
            " The release includes GitHub Actions workflows: a classic PAT needs the 'workflow' scope, and a fine-grained PAT needs 'Workflows: Read and write'. For the gh CLI token, run 'gh auth refresh -s workflow', or push with an SSH key instead: -GitTransport ssh -SshKeyPath <key>."
        }
        elseif ($pushRes.Error -match "Permission denied \(publickey\)|Host key verification failed") {
            " The SSH push could not authenticate. Check that -SshKeyPath names a key added to the GitHub account, that it has no passphrase (or is loaded in ssh-agent), and that github.com is in known_hosts."
        }
        # '[rejected]' only: '[remote rejected]' is the remote failing to store the push (an
        # unpacker error, a hook, a ruleset), which force-pushing would not fix.
        elseif (-not $AllowForcePush.IsPresent -and $pushRes.Error -match "non-fast-forward|fetch first|! \[rejected\]") {
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
    "Copy-ComponentScaffold",
    "Sync-UpstreamSource",
    "Get-ComponentReleaseAction",
    "Initialize-StagingRepository",
    "Get-RemoteRepositoryState",
    "Get-LatestSemVerTag",
    "Get-GitTrackedFileSet",
    "Publish-LocalRepository",
    "Get-GitSshCommand",
    "Set-GitSshCommand",
    "Get-GitRemoteUrl",
    "ConvertFrom-GitHubSshGreeting",
    "Test-GitHubSshIdentity",
    "Invoke-GitCommand",
    "Protect-GitOutput",
    "Get-ComponentGitIgnoreContent",
    "Get-StandardGitIgnoreContent"
)
