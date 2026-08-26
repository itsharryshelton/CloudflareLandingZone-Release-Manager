<#
.SYNOPSIS
    Configuration Manager module for Cloudflare Landing Zone Release Manager.
.DESCRIPTION
    Handles discovery of source folders, validation of paths and credentials,
    and loading/saving configuration files.
#>

function Get-ReleaseDefaultConfig {
    [CmdletBinding()]
    param ()

    $workspaceParent = Split-Path -Path $PSScriptRoot -Parent
    $defaultSourceRoot = "D:\Git\CloudflareLandingZone\CloudflareLandingZone"
    if (-not (Test-Path -Path $defaultSourceRoot)) {
        $siblingPath = Join-Path -Path (Split-Path -Path $workspaceParent -Parent) -ChildPath "CloudflareLandingZone"
        if (Test-Path -Path $siblingPath) {
            $defaultSourceRoot = $siblingPath
        }
    }

    $defaultStaging = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "cflz-release-staging"

    return [PSCustomObject]@{
        SourceRoot          = $defaultSourceRoot
        UseUpstreamSource   = $false
        UpstreamRepoUrl     = "https://github.com/itsharryshelton/CloudflareLandingZone.git"
        UpstreamRef         = "main"
        Prefix              = "cflz"
        DeploymentRepoName  = "{prefix}-deployment"
        ModuleRepoPattern   = "terraform-cloudflare-lz-{module}"
        SeedDeploymentOnce  = $true
        Visibility          = "private"
        DefaultBranch       = "main"
        TargetOwner         = ""
        OwnerType           = "Auto"
        StagingDirectory    = $defaultStaging
        InitialCommitMsg    = "Initial release of Cloudflare Landing Zone component"
        UpdateCommitMsg     = "Update Cloudflare Landing Zone component release"
        IncludeModules      = @("All")
        ExcludeModules      = @()
        CleanStagingOnExit  = $true
    }
}

function ConvertTo-RepoSlug {
    <#
    .SYNOPSIS
        Normalises a name into lowercase kebab-case suitable for a GitHub repository.
    .DESCRIPTION
        Source directory names use snake_case and occasionally a leading underscore
        (for example '_TEMPLATE'). Repository names are published in lowercase kebab-case,
        so any run of characters outside [a-z0-9] collapses to a single hyphen and leading
        or trailing hyphens are trimmed.
    .EXAMPLE
        ConvertTo-RepoSlug -Name "account_governance"   # account-governance
        ConvertTo-RepoSlug -Name "_TEMPLATE"            # template
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Name
    )

    $slug = $Name.ToLowerInvariant()
    $slug = $slug -replace "[^a-z0-9]+", "-"
    $slug = $slug.Trim("-")

    return $slug
}

function Expand-RepoNameTemplate {
    <#
    .SYNOPSIS
        Resolves a repository name template into a lowercase kebab-case repository name.
    .DESCRIPTION
        Supported tokens are '{prefix}' and '{module}'. The expanded result is passed
        through ConvertTo-RepoSlug, so a template may be written in any casing.
    .EXAMPLE
        Expand-RepoNameTemplate -Template "{prefix}-deployment" -Prefix "cflz"
        # cflz-deployment

        Expand-RepoNameTemplate -Template "terraform-cloudflare-lz-{module}" -Prefix "cflz" -ModuleName "zone_base"
        # terraform-cloudflare-lz-zone-base
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Template,

        [Parameter(Mandatory = $false)]
        [string]$Prefix = "",

        [Parameter(Mandatory = $false)]
        [string]$ModuleName = ""
    )

    $expanded = $Template
    $expanded = $expanded -replace "\{prefix\}", (ConvertTo-RepoSlug -Name $Prefix)
    $expanded = $expanded -replace "\{module\}", (ConvertTo-RepoSlug -Name $ModuleName)

    $result = ConvertTo-RepoSlug -Name $expanded

    if ([string]::IsNullOrWhiteSpace($result)) {
        throw [System.ArgumentException]::new("Repository name template '$Template' resolved to an empty name.")
    }

    return $result
}

function Import-ReleaseConfigFile {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path)) {
        throw [System.IO.FileNotFoundException]::new("Configuration file was not found at path: $Path")
    }

    try {
        $rawContent = Get-Content -Path $Path -Raw -ErrorAction Stop
        $jsonObj = $rawContent | ConvertFrom-Json -ErrorAction Stop
        return $jsonObj
    }
    catch {
        throw [System.FormatException]::new("Failed to parse JSON configuration file at $($Path): $($_.Exception.Message)")
    }
}

function Export-ReleaseConfigFile {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$Config,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    # Avoid persisting secrets to config files
    $safeConfig = [PSCustomObject]@{
        SourceRoot         = $Config.SourceRoot
        UseUpstreamSource  = $Config.UseUpstreamSource
        UpstreamRepoUrl    = $Config.UpstreamRepoUrl
        UpstreamRef        = $Config.UpstreamRef
        Prefix             = $Config.Prefix
        DeploymentRepoName = $Config.DeploymentRepoName
        ModuleRepoPattern  = $Config.ModuleRepoPattern
        SeedDeploymentOnce = $Config.SeedDeploymentOnce
        Visibility         = $Config.Visibility
        DefaultBranch      = $Config.DefaultBranch
        TargetOwner        = $Config.TargetOwner
        OwnerType          = $Config.OwnerType
        StagingDirectory   = $Config.StagingDirectory
        InitialCommitMsg   = $Config.InitialCommitMsg
        UpdateCommitMsg    = $Config.UpdateCommitMsg
        IncludeModules     = $Config.IncludeModules
        ExcludeModules     = $Config.ExcludeModules
        CleanStagingOnExit = $Config.CleanStagingOnExit
    }

    $jsonContent = $safeConfig | ConvertTo-Json -Depth 5
    $targetDir = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($targetDir) -and -not (Test-Path -Path $targetDir)) {
        New-Item -Path $targetDir -ItemType Directory -Force | Out-Null
    }

    Set-Content -Path $Path -Value $jsonContent -Encoding utf8
}

function Merge-ReleaseConfig {
    <#
    .SYNOPSIS
        Applies overrides onto a base configuration object, rejecting unrecognised keys.
    .DESCRIPTION
        Assigning an unknown property to a PSCustomObject throws, so a configuration file
        carrying a stray or misspelt key would otherwise abort the run with an obscure error.
        Unknown keys are reported as warnings and skipped; null values leave the default intact.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object]$BaseConfig,

        [Parameter(Mandatory = $true)]
        [object]$Overrides
    )

    $knownKeys = $BaseConfig.PSObject.Properties.Name
    $unknownKeys = @()

    foreach ($prop in $Overrides.PSObject.Properties) {
        if ($prop.Name -notin $knownKeys) {
            $unknownKeys += $prop.Name
            continue
        }
        if ($null -ne $prop.Value) {
            $BaseConfig.$($prop.Name) = $prop.Value
        }
    }

    foreach ($key in $unknownKeys) {
        Write-Warning "Ignoring unrecognised configuration key: $key"
    }

    return [PSCustomObject]@{
        Config      = $BaseConfig
        UnknownKeys = $unknownKeys
    }
}

function Get-SourceDiscovery {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$SourceRoot
    )

    if (-not (Test-Path -Path $SourceRoot)) {
        throw [System.IO.DirectoryNotFoundException]::new("Source root directory does not exist: $SourceRoot")
    }

    $deploymentDir = Join-Path -Path $SourceRoot -ChildPath "deployment"
    $hasDeployment = Test-Path -Path $deploymentDir

    $modulesDir = Join-Path -Path $SourceRoot -ChildPath "modules"
    $moduleList = @()

    if (Test-Path -Path $modulesDir) {
        $moduleDirectories = Get-ChildItem -Path $modulesDir -Directory | Where-Object {
            $_.Name -notlike ".*"
        }

        foreach ($mod in $moduleDirectories) {
            $moduleList += [PSCustomObject]@{
                ModuleName = $mod.Name
                SourcePath = $mod.FullName
            }
        }
    }

    return [PSCustomObject]@{
        SourceRoot          = $SourceRoot
        DeploymentDirectory = if ($hasDeployment) { $deploymentDir } else { $null }
        HasDeployment       = $hasDeployment
        ModulesDirectory    = if (Test-Path -Path $modulesDir) { $modulesDir } else { $null }
        Modules             = $moduleList
    }
}

function Resolve-GitHubToken {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [object]$ExplicitToken
    )

    # 1. Check explicit token parameter (SecureString or String)
    if ($null -ne $ExplicitToken) {
        if ($ExplicitToken -is [System.Security.SecureString]) {
            $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ExplicitToken)
            try {
                $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
                if (-not [string]::IsNullOrWhiteSpace($plain)) {
                    return $plain.Trim()
                }
            }
            finally {
                [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            }
        }
        elseif ($ExplicitToken -is [string] -and -not [string]::IsNullOrWhiteSpace($ExplicitToken)) {
            return $ExplicitToken.Trim()
        }
    }

    # 2. Check environment variables GITHUB_TOKEN or GH_TOKEN
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
        return $env:GITHUB_TOKEN.Trim()
    }
    if (-not [string]::IsNullOrWhiteSpace($env:GH_TOKEN)) {
        return $env:GH_TOKEN.Trim()
    }

    # 3. Check gh CLI authentication if installed
    $ghPath = Get-Command -Name "gh" -ErrorAction SilentlyContinue
    if ($null -ne $ghPath) {
        try {
            $ghToken = & gh auth token 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($ghToken)) {
                return $ghToken.Trim()
            }
        }
        catch {
            # Ignore gh cli query failure and fall through
        }
    }

    return $null
}

Export-ModuleMember -Function @(
    "Get-ReleaseDefaultConfig",
    "ConvertTo-RepoSlug",
    "Expand-RepoNameTemplate",
    "Import-ReleaseConfigFile",
    "Export-ReleaseConfigFile",
    "Merge-ReleaseConfig",
    "Get-SourceDiscovery",
    "Resolve-GitHubToken"
)
