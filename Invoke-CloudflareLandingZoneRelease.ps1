<#
.SYNOPSIS
    Automated Release Manager for Cloudflare Landing Zones.
.DESCRIPTION
    Provisions private GitHub repositories and synchronises source data as-is
    for the Cloudflare Landing Zone deployment framework and all individual modules.
.PARAMETER SourceRoot
    Path to the root CloudflareLandingZone repository containing 'deployment' and 'modules'.
.PARAMETER UseUpstreamSource
    Cuts the release from a fresh shallow clone of the upstream GitHub repository rather than
    from the local working tree, guaranteeing the published content matches what is on GitHub.
.PARAMETER UpstreamRepoUrl
    Upstream repository to clone when -UseUpstreamSource is specified.
    Default: 'https://github.com/itsharryshelton/CloudflareLandingZone.git'.
.PARAMETER UpstreamRef
    Branch or tag to clone from the upstream repository. Default: 'main'.
.PARAMETER TargetOwner
    Target GitHub Organisation or User account name where repositories will be created.
.PARAMETER GitHubToken
    GitHub Personal Access Token (PAT) with 'repo' scope. If not supplied, checks
    environment variables (GITHUB_TOKEN, GH_TOKEN), local 'gh' CLI, or prompts interactively.
.PARAMETER Prefix
    Short organisation prefix substituted into the '{prefix}' token of a repository name
    template. Default: 'cflz'.
.PARAMETER DeploymentRepoName
    Name template for the central deployment repository. Supports the '{prefix}' token.
    Default: '{prefix}-deployment', which resolves to 'cflz-deployment'.
.PARAMETER ModuleRepoPattern
    Name template for per-module repositories. Supports the '{prefix}' and '{module}' tokens.
    Default: 'terraform-cloudflare-lz-{module}'.
    All resolved names are normalised to lowercase kebab-case, so a module directory named
    'account_governance' publishes as 'terraform-cloudflare-lz-account-governance'.
.PARAMETER Visibility
    Repository visibility ('private', 'public', 'internal'). Default: 'private'.
.PARAMETER Modules
    Optional list of specific module names to release. If omitted, all discovered modules are released.
.PARAMETER ExcludeModules
    Optional list of module names to omit from the release.
.PARAMETER OnlyDeployment
    If specified, only creates and synchronises the deployment repository.
.PARAMETER OnlyModules
    If specified, only creates and synchronises the module repositories.
.PARAMETER ForceDeploymentUpdate
    Re-releases the deployment repository even though it has already been seeded.
    By default an existing deployment repository is skipped, because a release wipes and
    re-copies the working tree, which would revert operator edits under 'accounts/**' and
    delete any account file added there that does not exist upstream. Module repositories
    are unaffected: they carry no per-tenant content and are always re-synchronised.
.PARAMETER AllowForcePush
    Permits overwriting remote history when a target repository already carries unrelated commits.
    Without this switch such a repository is reported as failed rather than being overwritten.
.PARAMETER ConfigFile
    Path to a JSON configuration file to load settings from.
.PARAMETER SaveConfig
    Path to save the current configuration for reproducible future runs.
.PARAMETER Interactive
    Enables interactive wizard mode for parameter prompting.
.PARAMETER WhatIf
    Displays planned repository creations and synchronisations without executing changes.
.PARAMETER DryRun
    Alias for WhatIf.
.EXAMPLE
    # Interactive wizard mode:
    .\Invoke-CloudflareLandingZoneRelease.ps1 -Interactive

.EXAMPLE
    # Automated execution against the upstream GitHub source:
    .\Invoke-CloudflareLandingZoneRelease.ps1 `
        -TargetOwner "my-organisation" `
        -GitHubToken $token `
        -UseUpstreamSource `
        -Visibility "private"

.EXAMPLE
    # Inspect planned repository creation without making changes:
    .\Invoke-CloudflareLandingZoneRelease.ps1 -TargetOwner "my-organisation" -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param (
    [Parameter(Mandatory = $false)]
    [string]$SourceRoot,

    [Parameter(Mandatory = $false)]
    [switch]$UseUpstreamSource,

    [Parameter(Mandatory = $false)]
    [string]$UpstreamRepoUrl,

    [Parameter(Mandatory = $false)]
    [string]$UpstreamRef,

    [Parameter(Mandatory = $false)]
    [string]$TargetOwner,

    [Parameter(Mandatory = $false)]
    [object]$GitHubToken,

    [Parameter(Mandatory = $false)]
    [string]$Prefix,

    [Parameter(Mandatory = $false)]
    [string]$DeploymentRepoName,

    [Parameter(Mandatory = $false)]
    [string]$ModuleRepoPattern,

    [Parameter(Mandatory = $false)]
    [ValidateSet("private", "public", "internal")]
    [string]$Visibility,

    [Parameter(Mandatory = $false)]
    [string[]]$Modules = @(),

    [Parameter(Mandatory = $false)]
    [string[]]$ExcludeModules = @(),

    [Parameter(Mandatory = $false)]
    [switch]$OnlyDeployment,

    [Parameter(Mandatory = $false)]
    [switch]$OnlyModules,

    [Parameter(Mandatory = $false)]
    [switch]$ForceDeploymentUpdate,

    [Parameter(Mandatory = $false)]
    [switch]$AllowForcePush,

    [Parameter(Mandatory = $false)]
    [string]$ConfigFile,

    [Parameter(Mandatory = $false)]
    [string]$SaveConfig,

    [Parameter(Mandatory = $false)]
    [switch]$Interactive,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun,

    [Parameter(Mandatory = $false)]
    [bool]$CleanStaging = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Import internal modules
$moduleDir = Join-Path -Path $PSScriptRoot -ChildPath "src"
Import-Module (Join-Path -Path $moduleDir -ChildPath "UiHelper.psm1") -Force
Import-Module (Join-Path -Path $moduleDir -ChildPath "ConfigManager.psm1") -Force
Import-Module (Join-Path -Path $moduleDir -ChildPath "GitHubApi.psm1") -Force
Import-Module (Join-Path -Path $moduleDir -ChildPath "RepoPublisher.psm1") -Force

Write-ReleaseHeader -Title "Cloudflare Landing Zone - Release Manager" -Subtitle "Automated Private Repository Provisioning and Synchronisation"

# 1. Resolve and Load Configuration
$config = Get-ReleaseDefaultConfig

if (-not [string]::IsNullOrWhiteSpace($ConfigFile)) {
    Write-ReleaseInfo "Loading configuration from file: $ConfigFile"
    $fileConfig = Import-ReleaseConfigFile -Path $ConfigFile
    $merged = Merge-ReleaseConfig -BaseConfig $config -Overrides $fileConfig
    $config = $merged.Config
}

# Override config with explicit parameters if provided
if (-not [string]::IsNullOrWhiteSpace($SourceRoot)) { $config.SourceRoot = $SourceRoot }
if (-not [string]::IsNullOrWhiteSpace($TargetOwner)) { $config.TargetOwner = $TargetOwner }
if (-not [string]::IsNullOrWhiteSpace($Prefix)) { $config.Prefix = $Prefix }
if (-not [string]::IsNullOrWhiteSpace($DeploymentRepoName)) { $config.DeploymentRepoName = $DeploymentRepoName }
if (-not [string]::IsNullOrWhiteSpace($ModuleRepoPattern)) { $config.ModuleRepoPattern = $ModuleRepoPattern }
if (-not [string]::IsNullOrWhiteSpace($Visibility)) { $config.Visibility = $Visibility }
if (-not [string]::IsNullOrWhiteSpace($UpstreamRepoUrl)) { $config.UpstreamRepoUrl = $UpstreamRepoUrl }
if (-not [string]::IsNullOrWhiteSpace($UpstreamRef)) { $config.UpstreamRef = $UpstreamRef }
if ($UseUpstreamSource.IsPresent) { $config.UseUpstreamSource = $true }
if ($Modules.Count -gt 0) { $config.IncludeModules = $Modules }
if ($ExcludeModules.Count -gt 0) { $config.ExcludeModules = $ExcludeModules }

$isDryRun = $DryRun.IsPresent -or $WhatIfPreference
$stagingRoot = $config.StagingDirectory

# 2. Resolve GitHub Credentials
$token = Resolve-GitHubToken -ExplicitToken $GitHubToken

if ([string]::IsNullOrWhiteSpace($token) -and ($Interactive.IsPresent -or (-not $isDryRun -and [string]::IsNullOrWhiteSpace($config.TargetOwner)))) {
    Write-SectionHeader -Title "GitHub Authentication Required"
    Write-ReleaseInfo "A GitHub Personal Access Token (PAT) with 'repo' scope is required to create private repositories."
    $rawToken = Request-UserText -Prompt "Enter GitHub Personal Access Token" -AsSecureString
    $token = Resolve-GitHubToken -ExplicitToken $rawToken
}

$currentUser = $null
if (-not [string]::IsNullOrWhiteSpace($token)) {
    try {
        $currentUser = Get-GitHubCurrentUser -Token $token
        Write-ReleaseSuccess "Authenticated with GitHub as user '$($currentUser.Login)' ($($currentUser.Name))."
        if ([string]::IsNullOrWhiteSpace($config.TargetOwner)) {
            $config.TargetOwner = $currentUser.Login
        }
    }
    catch {
        Write-ReleaseWarning "Unable to authenticate with GitHub using resolved token: $($_.Exception.Message)"
    }
}

# 3. Resolve the Release Source
$upstreamInfo = $null
if ($config.UseUpstreamSource) {
    Write-SectionHeader -Title "Upstream Source Synchronisation"
    $upstreamWorkspace = Join-Path -Path $stagingRoot -ChildPath "_upstream"
    Write-ReleaseInfo "Cloning upstream source '$($config.UpstreamRepoUrl)' at ref '$($config.UpstreamRef)'..."

    if ($isDryRun) {
        Write-ReleaseInfo "Dry run: the upstream clone is skipped and the local source tree is inspected instead."
    }
    else {
        $upstreamAuthUrl = ""
        if (-not [string]::IsNullOrWhiteSpace($token) -and $config.UpstreamRepoUrl -match "^https://github\.com/") {
            $upstreamAuthUrl = $config.UpstreamRepoUrl -replace "^https://", "https://x-access-token:$token@"
        }

        $upstreamInfo = Sync-UpstreamSource `
            -RepositoryUrl $config.UpstreamRepoUrl `
            -DestinationPath $upstreamWorkspace `
            -Ref $config.UpstreamRef `
            -AuthenticatedUrl $upstreamAuthUrl

        $config.SourceRoot = $upstreamInfo.Path
        Write-ReleaseSuccess "Upstream source cloned at commit $($upstreamInfo.CommitSha.Substring(0, [Math]::Min(8, $upstreamInfo.CommitSha.Length))) - $($upstreamInfo.CommitSubject)"
    }
}

# 4. Discover Source Structure
Write-ReleaseInfo "Analysing source repository structure at '$($config.SourceRoot)'..."
try {
    $discovery = Get-SourceDiscovery -SourceRoot $config.SourceRoot
}
catch {
    Write-ReleaseError "Source directory discovery failed: $($_.Exception.Message)"
    throw
}

if (-not $discovery.HasDeployment -and -not $OnlyModules) {
    Write-ReleaseWarning "Deployment folder was not detected at '$($config.SourceRoot)\deployment'."
}

Write-ReleaseSuccess "Discovered $(@($discovery.Modules).Count) modules and deployment framework."

# Prompt interactively for missing core fields if Interactive switch is active
if ($Interactive.IsPresent) {
    Write-SectionHeader -Title "Interactive Configuration Wizard"
    $config.TargetOwner = Request-UserText -Prompt "Target GitHub Owner (Organisation or Username)" -DefaultValue $config.TargetOwner
    $config.Prefix = Request-UserText -Prompt "Repository name prefix" -DefaultValue $config.Prefix
    $config.DeploymentRepoName = Request-UserText -Prompt "Deployment repository name template (tokens: {prefix})" -DefaultValue $config.DeploymentRepoName
    $config.ModuleRepoPattern = Request-UserText -Prompt "Module repository name template (tokens: {prefix}, {module})" -DefaultValue $config.ModuleRepoPattern
    $config.Visibility = Request-UserChoice -Prompt "Repository Visibility" -Options @("private", "public", "internal") -DefaultIndex 0

    Write-ReleaseInfo "Deployment repository resolves to: $(Expand-RepoNameTemplate -Template $config.DeploymentRepoName -Prefix $config.Prefix)"
    Write-ReleaseInfo "Module repositories resolve to, for example: $(Expand-RepoNameTemplate -Template $config.ModuleRepoPattern -Prefix $config.Prefix -ModuleName 'zone_base')"
}

if ([string]::IsNullOrWhiteSpace($config.TargetOwner)) {
    throw [System.ArgumentException]::new("Target GitHub Owner must be specified via -TargetOwner or interactive prompt.")
}

# Determine Target Owner Type (Organisation vs User)
$ownerDetails = $null
if (-not [string]::IsNullOrWhiteSpace($token)) {
    try {
        $ownerDetails = Get-GitHubOwnerType -Token $token -Owner $config.TargetOwner
        if ($ownerDetails.Found) {
            Write-ReleaseInfo "Target owner '$($config.TargetOwner)' resolved as: $($ownerDetails.Type)."
        }
        else {
            Write-ReleaseWarning "Target owner '$($config.TargetOwner)' was not found or is inaccessible with current token."
        }
    }
    catch {
        Write-ReleaseWarning "Could not verify owner type: $($_.Exception.Message)"
    }
}

# 5. Build Release Execution Plan
Write-SectionHeader -Title "Release Execution Plan"

$releasePlan = @()

# Add deployment repository if selected
if (-not $OnlyModules.IsPresent -and $discovery.HasDeployment) {
    $repoName = Expand-RepoNameTemplate -Template $config.DeploymentRepoName -Prefix $config.Prefix
    $releasePlan += [PSCustomObject]@{
        ComponentType = "Deployment"
        ComponentName = "deployment"
        SourcePath    = $discovery.DeploymentDirectory
        RepoName      = $repoName
        TargetOwner   = $config.TargetOwner
        RemoteUrl     = "https://github.com/$($config.TargetOwner)/$repoName.git"
        Visibility    = $config.Visibility
    }
}

# Add module repositories if selected
if (-not $OnlyDeployment.IsPresent) {
    $selectedModules = @($discovery.Modules)
    if (@($config.IncludeModules).Count -gt 0 -and @($config.IncludeModules)[0] -ne "All") {
        $selectedModules = @($selectedModules | Where-Object { $_.ModuleName -in $config.IncludeModules })
    }
    if (@($config.ExcludeModules).Count -gt 0) {
        $selectedModules = @($selectedModules | Where-Object { $_.ModuleName -notin $config.ExcludeModules })
    }

    foreach ($mod in $selectedModules) {
        $repoName = Expand-RepoNameTemplate -Template $config.ModuleRepoPattern -Prefix $config.Prefix -ModuleName $mod.ModuleName
        $releasePlan += [PSCustomObject]@{
            ComponentType = "Module"
            ComponentName = $mod.ModuleName
            SourcePath    = $mod.SourcePath
            RepoName      = $repoName
            TargetOwner   = $config.TargetOwner
            RemoteUrl     = "https://github.com/$($config.TargetOwner)/$repoName.git"
            Visibility    = $config.Visibility
        }
    }
}

# Display plan table
Write-Host ("{0,-12} | {1,-26} | {2,-52} | {3,-10}" -f "Type", "Component", "Repository Name", "Visibility") -ForegroundColor Cyan
Write-Host ("-" * 108) -ForegroundColor DarkGray
foreach ($item in $releasePlan) {
    Write-Host ("{0,-12} | {1,-26} | {2,-52} | {3,-10}" -f $item.ComponentType, $item.ComponentName, $item.RepoName, $item.Visibility)
}
Write-Host ("-" * 108) -ForegroundColor DarkGray
Write-ReleaseInfo "Source: $($config.SourceRoot)"
Write-ReleaseInfo "Total repositories to release: $(@($releasePlan).Count)"

# Optional Save Configuration
if (-not [string]::IsNullOrWhiteSpace($SaveConfig)) {
    Export-ReleaseConfigFile -Config $config -Path $SaveConfig
    Write-ReleaseSuccess "Configuration saved to: $SaveConfig"
}

if ($isDryRun) {
    Write-SectionHeader -Title "Dry Run Complete"
    Write-ReleaseInfo "Dry-run / WhatIf requested. No remote repositories or commits were created."
    if (-not $OnlyModules.IsPresent -and $config.SeedDeploymentOnce -and -not $ForceDeploymentUpdate.IsPresent) {
        Write-ReleaseInfo "Note: an already-seeded deployment repository is skipped at execution time. Use -ForceDeploymentUpdate to re-release it."
    }
    return $releasePlan
}

# Prompt confirmation in interactive mode
if ($Interactive.IsPresent) {
    $proceed = Request-UserConfirmation -Prompt "Proceed with creating repositories and publishing data?" -DefaultYes $true
    if (-not $proceed) {
        Write-ReleaseWarning "Operation cancelled by user."
        return $null
    }
}

if ([string]::IsNullOrWhiteSpace($token)) {
    throw [System.InvalidOperationException]::new("A valid GitHub Personal Access Token is required to execute repository publishing.")
}

# 6. Execute Repository Creation and Publishing
Write-SectionHeader -Title "Executing Releases"

if (-not (Test-Path -Path $stagingRoot)) {
    New-Item -Path $stagingRoot -ItemType Directory -Force | Out-Null
}

$results = [System.Collections.Generic.List[object]]::new()
$stepIndex = 1
$totalSteps = @($releasePlan).Count
$ownerType = if ($ownerDetails -and $ownerDetails.Type -and $ownerDetails.Found) { $ownerDetails.Type } else { "User" }

foreach ($planItem in $releasePlan) {
    Write-ReleaseStep -StepNumber $stepIndex -TotalSteps $totalSteps -Description "Processing $($planItem.ComponentType) [$($planItem.ComponentName)] -> $($planItem.RepoName)"
    $stepIndex++

    $itemResult = [PSCustomObject]@{
        ComponentName = $planItem.ComponentName
        ComponentType = $planItem.ComponentType
        RepoName      = $planItem.RepoName
        RemoteUrl     = $planItem.RemoteUrl
        RepoCreated   = $false
        Published     = $false
        Committed     = $false
        FileCount     = 0
        Status        = "Pending"
        ErrorMessage  = ""
    }

    try {
        # A. Verify / Create Remote GitHub Repository
        Write-ReleaseInfo "Checking remote repository '$($planItem.TargetOwner)/$($planItem.RepoName)' on GitHub..."
        $existingRepo = Get-GitHubRepoDetails -Token $token -Owner $planItem.TargetOwner -RepoName $planItem.RepoName
        $authPushUrl = "https://x-access-token:$token@github.com/$($planItem.TargetOwner)/$($planItem.RepoName).git"

        $remoteHasCommits = $false
        if ($existingRepo.Exists) {
            $remoteState = Get-RemoteRepositoryState -WorkingDirectory $stagingRoot -AuthenticatedUrl $authPushUrl -DefaultBranch $config.DefaultBranch
            $remoteHasCommits = -not $remoteState.IsEmpty
        }

        $releaseAction = Get-ComponentReleaseAction `
            -ComponentType $planItem.ComponentType `
            -RepoExists $existingRepo.Exists `
            -RemoteHasCommits $remoteHasCommits `
            -SeedDeploymentOnce ([bool]$config.SeedDeploymentOnce) `
            -ForceDeploymentUpdate $ForceDeploymentUpdate.IsPresent

        if ($releaseAction.Action -eq "Skip") {
            $itemResult.Status = "Skipped"
            Write-ReleaseWarning $releaseAction.Reason
            $results.Add($itemResult)
            continue
        }

        if ($existingRepo.Exists) {
            Write-ReleaseInfo "Repository already exists on GitHub; the release will be applied as an update."
        }
        else {
            Write-ReleaseInfo "Creating new $($planItem.Visibility) repository '$($planItem.RepoName)' under '$($planItem.TargetOwner)'..."
            $desc = "Cloudflare Landing Zone - $($planItem.ComponentType): $($planItem.ComponentName)"
            $isPriv = ($planItem.Visibility -ne "public")
            New-GitHubRemoteRepository -Token $token -Owner $planItem.TargetOwner -OwnerType $ownerType -RepoName $planItem.RepoName -Description $desc -IsPrivate $isPriv | Out-Null
            $itemResult.RepoCreated = $true
            Write-ReleaseSuccess "Remote repository created successfully."
        }

        # B. Prepare the staging working tree, preserving any existing remote history
        $itemStagingDir = Join-Path -Path $stagingRoot -ChildPath $planItem.RepoName

        $stagingState = Initialize-StagingRepository `
            -StagingPath $itemStagingDir `
            -RemoteUrl $planItem.RemoteUrl `
            -AuthenticatedUrl $authPushUrl `
            -DefaultBranch $config.DefaultBranch

        # C. Copy Source Data As-Is
        Write-ReleaseInfo "Copying source data from '$($planItem.SourcePath)'..."
        $copyResult = Copy-SourceDataAsIs `
            -SourceDirectory $planItem.SourcePath `
            -DestinationDirectory $itemStagingDir `
            -ComponentType $planItem.ComponentType
        $itemResult.FileCount = $copyResult.FileCount
        Write-ReleaseInfo "Staged $($copyResult.FileCount) files for release."

        # D. Commit and Push
        $commitMessage = if ($stagingState.HistoryFetched) { $config.UpdateCommitMsg } else { $config.InitialCommitMsg }
        Write-ReleaseInfo "Publishing to remote '$($config.DefaultBranch)' branch..."

        $publishRes = Publish-LocalRepository `
            -StagingPath $itemStagingDir `
            -RemoteUrl $planItem.RemoteUrl `
            -AuthenticatedPushUrl $authPushUrl `
            -DefaultBranch $config.DefaultBranch `
            -CommitMessage $commitMessage `
            -AllowForcePush:$AllowForcePush

        $itemResult.Published = $true
        $itemResult.Committed = $publishRes.Committed
        $itemResult.Status = if ($publishRes.Committed) { "Completed" } else { "Unchanged" }

        if ($publishRes.Committed) {
            Write-ReleaseSuccess "Successfully published $($planItem.RepoName) to $($planItem.RemoteUrl)."
        }
        else {
            Write-ReleaseSuccess "$($planItem.RepoName) is already up to date; no commit was required."
        }
    }
    catch {
        $errMsg = $_.Exception.Message
        $itemResult.Status = "Failed"
        $itemResult.ErrorMessage = $errMsg
        Write-ReleaseError "Failed to release $($planItem.RepoName): $errMsg"
    }

    $results.Add($itemResult)
}

# 7. Clean Up Staging Directory
if ($CleanStaging -and (Test-Path -Path $stagingRoot)) {
    try {
        Remove-Item -Path $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        Write-ReleaseInfo "Staging workspace cleaned up."
    }
    catch {
        # Ignore cleanup lock issues
    }
}

# 8. Final Summary
Write-SectionHeader -Title "Release Execution Summary"
$successCount = @($results | Where-Object { $_.Status -in @("Completed", "Unchanged", "Skipped") }).Count
$failedCount = @($results | Where-Object { $_.Status -eq "Failed" }).Count

Write-Host ("{0,-28} | {1,-52} | {2,-12}" -f "Component", "Repository", "Status") -ForegroundColor Cyan
Write-Host ("-" * 98) -ForegroundColor DarkGray
foreach ($res in $results) {
    $col = switch ($res.Status) {
        "Completed" { [System.ConsoleColor]::Green }
        "Unchanged" { [System.ConsoleColor]::DarkGray }
        "Skipped" { [System.ConsoleColor]::Yellow }
        default { [System.ConsoleColor]::Red }
    }
    Write-Host ("{0,-28} | {1,-52} | {2,-12}" -f $res.ComponentName, $res.RepoName, $res.Status) -ForegroundColor $col
}
Write-Host ("-" * 98) -ForegroundColor DarkGray

if ($failedCount -eq 0) {
    Write-ReleaseSuccess "All $successCount repositories processed successfully."
}
else {
    Write-ReleaseWarning "Release completed with $successCount succeeded and $failedCount failed."
}

return $results.ToArray()
