<#
.SYNOPSIS
    Module source rewriting for the Cloudflare Landing Zone Release Manager.
.DESCRIPTION
    Upstream, a layer's module blocks point either at '../../../modules/<module>' or at a
    placeholder 'git::https://github.com/Your-Org/cloudflare-platform-modules//<module>'.
    Neither resolves in a published management repository: 'modules/' is not published
    with it, and the placeholder names a repository that does not exist. These functions
    repoint each such source at the module's own published repository, pinned to a tag,
    and grant the pipelines' modules-auth action read access to exactly those repositories.
#>

# Upstream references this tool knows how to repoint. Anything else, such as a registry
# module or a third-party Git source, is left exactly as written.
#
# A relative upstream reference climbs out of the layer with at least one '../'. A source
# such as './modules/schema' names a child module that lives inside the layer and ships
# with it, so it is not an upstream reference however its last segment is spelled.
$script:RelativeModulePattern = '^(?:\./)?(?:\.\./)+modules/(?<module>[A-Za-z0-9_-]+)/?$'
$script:PlaceholderModulePattern = '^git::https://github\.com/[^/]+/(?:cloudflare-platform-modules|CloudflareLandingZone)(?:\.git)?//(?:modules/)?(?<module>[A-Za-z0-9_-]+)/?(?:\?ref=[^"]*)?$'
$script:SourceLinePattern = '^(?<lead>\s*source\s*=\s*")(?<source>[^"]*)(?<trail>".*)$'

function Get-UpstreamModuleName {
    <#
    .SYNOPSIS
        Returns the upstream module directory a source string refers to, or $null.
    .EXAMPLE
        Get-UpstreamModuleName -Source "../../../modules/zone_base"                                          # zone_base
        Get-UpstreamModuleName -Source "git::https://github.com/Your-Org/cloudflare-platform-modules//waf"   # waf
        Get-UpstreamModuleName -Source "./modules/schema"                                                    # $null (a child module inside the layer)
        Get-UpstreamModuleName -Source "cloudflare/cloudflare"                                               # $null
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Source
    )

    foreach ($pattern in @($script:RelativeModulePattern, $script:PlaceholderModulePattern)) {
        $match = [regex]::Match($Source, $pattern)
        if ($match.Success) {
            return $match.Groups["module"].Value
        }
    }

    return $null
}

function Get-ModuleRepositorySource {
    <#
    .SYNOPSIS
        Builds the pinned Git source for a published module repository.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Owner,

        [Parameter(Mandatory = $true)]
        [string]$RepoName,

        [Parameter(Mandatory = $true)]
        [string]$Ref
    )

    return "git::https://github.com/$Owner/$RepoName.git?ref=$Ref"
}

function Test-SourceStaysWithin {
    <#
    .SYNOPSIS
        True when a relative module source, resolved from the file that declares it, stays
        inside -Directory.
    .DESCRIPTION
        Upstream's relative references climb out of the layers tree to the repository's
        'modules/' directory. A child module nested in a layer (for example
        'layers/zerotrust/modules/schema') can name a sibling as '../modules/<name>', which
        matches the upstream form textually but resolves inside the layer. Such a source is
        local to the published repository and must be left exactly as written.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$DeclaringFile,

        [Parameter(Mandatory = $true)]
        [string]$Directory
    )

    if ($Source -notmatch '^\.{1,2}/') { return $false }

    $separators = [char[]]@([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $boundary = [System.IO.Path]::GetFullPath($Directory).TrimEnd($separators) + [System.IO.Path]::DirectorySeparatorChar
    $fileDirectory = Split-Path -Path $DeclaringFile -Parent
    $resolved = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($fileDirectory, $Source)).TrimEnd($separators) + [System.IO.Path]::DirectorySeparatorChar

    return $resolved.StartsWith($boundary, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-LayerTerraformFile {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$LayersDirectory
    )

    if (-not (Test-Path -Path $LayersDirectory)) {
        return @()
    }

    return @(Get-ChildItem -Path $LayersDirectory -Recurse -File -Filter "*.tf" | Where-Object {
            $_.FullName -notmatch '[\\/]\.terraform[\\/]'
        })
}

function Find-LayerModuleReference {
    <#
    .SYNOPSIS
        Lists every active module source under a layers directory that points upstream.
    .DESCRIPTION
        Commented-out lines are skipped: upstream carries a commented example of the pinned
        form above each module block, and that is documentation rather than configuration.
        A reference to a module directory that is not in -KnownModules is still returned,
        flagged as unknown, so the caller can warn rather than publish a source that cannot
        resolve.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$LayersDirectory,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$KnownModules
    )

    $references = [System.Collections.Generic.List[object]]::new()

    foreach ($file in (Get-LayerTerraformFile -LayersDirectory $LayersDirectory)) {
        $lineNumber = 0
        foreach ($line in [System.IO.File]::ReadAllLines($file.FullName)) {
            $lineNumber++
            if ($line -match '^\s*(#|//)') { continue }

            $sourceMatch = [regex]::Match($line, $script:SourceLinePattern)
            if (-not $sourceMatch.Success) { continue }

            $source = $sourceMatch.Groups["source"].Value
            $moduleName = Get-UpstreamModuleName -Source $source
            if ($null -eq $moduleName) { continue }
            if (Test-SourceStaysWithin -Source $source -DeclaringFile $file.FullName -Directory $LayersDirectory) { continue }

            $references.Add([PSCustomObject]@{
                    File       = $file.FullName
                    Line       = $lineNumber
                    Source     = $source
                    ModuleName = $moduleName
                    Known      = ($moduleName -in $KnownModules)
                })
        }
    }

    return $references.ToArray()
}

function Update-LayerModuleSource {
    <#
    .SYNOPSIS
        Repoints upstream module sources under a layers directory at their published repositories.
    .DESCRIPTION
        -SourceMap maps an upstream module directory name to its replacement source string.
        Only the quoted value on an active 'source =' line is replaced, so alignment, comments
        and the rest of each file are left byte-for-byte as they were, and 'terraform fmt'
        output is unchanged. Line endings are preserved.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$LayersDirectory,

        [Parameter(Mandatory = $true)]
        [hashtable]$SourceMap
    )

    $rewrites = [System.Collections.Generic.List[object]]::new()

    foreach ($file in (Get-LayerTerraformFile -LayersDirectory $LayersDirectory)) {
        $content = [System.IO.File]::ReadAllText($file.FullName)
        $newline = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
        $lines = $content -split "\r?\n", 0
        $changed = $false

        for ($i = 0; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($line -match '^\s*(#|//)') { continue }

            $sourceMatch = [regex]::Match($line, $script:SourceLinePattern)
            if (-not $sourceMatch.Success) { continue }

            $source = $sourceMatch.Groups["source"].Value
            $moduleName = Get-UpstreamModuleName -Source $source
            if ($null -eq $moduleName -or -not $SourceMap.ContainsKey($moduleName)) { continue }
            if (Test-SourceStaysWithin -Source $source -DeclaringFile $file.FullName -Directory $LayersDirectory) { continue }

            $replacement = $SourceMap[$moduleName]
            $lines[$i] = $sourceMatch.Groups["lead"].Value + $replacement + $sourceMatch.Groups["trail"].Value
            $changed = $true

            $rewrites.Add([PSCustomObject]@{
                    File       = $file.FullName
                    Line       = $i + 1
                    ModuleName = $moduleName
                    OldSource  = $source
                    NewSource  = $replacement
                })
        }

        if ($changed) {
            $encoding = [System.Text.UTF8Encoding]::new($false)
            [System.IO.File]::WriteAllText($file.FullName, ($lines -join $newline), $encoding)
        }
    }

    return $rewrites.ToArray()
}

function Update-ModulesAuthRepository {
    <#
    .SYNOPSIS
        Points the management repository's modules-auth action at the published module repositories.
    .DESCRIPTION
        Upstream, '.github/actions/modules-auth' mints an App token for one repository,
        'cloudflare-platform-modules', and no caller overrides it. With one repository per
        module the token must cover each module repository the layers source. The action's
        default is rewritten to that comma-separated list, which actions/create-github-app-token
        accepts as-is, so no workflow call site needs an edit.

        Returns $false, changing nothing, when the action or its upstream default is absent.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$RootDirectory,

        [Parameter(Mandatory = $true)]
        [string[]]$Repositories
    )

    $actionPath = Join-Path -Path $RootDirectory -ChildPath ".github\actions\modules-auth\action.yml"
    if (-not (Test-Path -Path $actionPath)) {
        return [PSCustomObject]@{ Updated = $false; Path = $actionPath; Reason = "action not present" }
    }

    $content = [System.IO.File]::ReadAllText($actionPath)
    $pattern = '(?m)^(?<lead>[ \t]*default:[ \t]*)cloudflare-platform-modules[ \t]*(?=\r?$)'
    if ($content -notmatch $pattern) {
        return [PSCustomObject]@{ Updated = $false; Path = $actionPath; Reason = "upstream default 'cloudflare-platform-modules' not found" }
    }

    $list = (@($Repositories) | Sort-Object -Unique) -join ","
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator] ({ param($m) $m.Groups["lead"].Value + $list }.GetNewClosure())
    $updated = [regex]::new($pattern).Replace($content, $evaluator, 1)

    [System.IO.File]::WriteAllText($actionPath, $updated, [System.Text.UTF8Encoding]::new($false))

    return [PSCustomObject]@{ Updated = $true; Path = $actionPath; Reason = "" }
}

function Set-OrchestrationModuleSource {
    <#
    .SYNOPSIS
        Repoints a staged orchestration repository's layers at the published module repositories.
    .DESCRIPTION
        Finds every upstream module reference under the staged layers, works out the ref each
        module is pinned to, rewrites the sources and, for a management repository, the
        modules-auth action's repository list.

        With -ModuleSourceRef 'latest', -ResolveLatestTag is called with a module repository
        name and must return an object carrying 'Reachable' and 'Tag' (see Get-LatestSemVerTag).
        A repository with no release tag yet is pinned to v1.0.0, the first tag the module CI
        publishes on a green push to main.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$StagingDirectory,

        [Parameter(Mandatory = $true)]
        [ValidateSet("Management", "Deployment")]
        [string]$ComponentType,

        [Parameter(Mandatory = $true)]
        [hashtable]$ModuleRepoNames,

        [Parameter(Mandatory = $true)]
        [string]$Owner,

        [Parameter(Mandatory = $false)]
        [string]$ModuleSourceRef = "latest",

        [Parameter(Mandatory = $false)]
        [scriptblock]$ResolveLatestTag
    )

    if ($ModuleSourceRef -eq "latest" -and $null -eq $ResolveLatestTag) {
        throw [System.ArgumentException]::new("-ResolveLatestTag is required when -ModuleSourceRef is 'latest'.")
    }

    $layersDir = if ($ComponentType -eq "Management") {
        Join-Path -Path $StagingDirectory -ChildPath "deployment\layers"
    }
    else {
        Join-Path -Path $StagingDirectory -ChildPath "layers"
    }

    $references = @(Find-LayerModuleReference -LayersDirectory $layersDir -KnownModules @($ModuleRepoNames.Keys))
    $unknown = @($references | Where-Object { -not $_.Known } | ForEach-Object { $_.ModuleName } | Sort-Object -Unique)

    $sourceMap = @{}
    $pins = [System.Collections.Generic.List[object]]::new()
    foreach ($moduleName in @($references | Where-Object { $_.Known } | ForEach-Object { $_.ModuleName } | Sort-Object -Unique)) {
        $repoName = $ModuleRepoNames[$moduleName]
        $ref = $ModuleSourceRef
        $state = "fixed"

        if ($ModuleSourceRef -eq "latest") {
            $tagInfo = & $ResolveLatestTag $repoName
            if ($tagInfo.Tag) {
                $ref = $tagInfo.Tag
                $state = "latest tag"
            }
            else {
                $ref = "v1.0.0"
                $state = if ($tagInfo.Reachable) { "awaiting first CI tag" } else { "repository not found" }
            }
        }

        $sourceMap[$moduleName] = Get-ModuleRepositorySource -Owner $Owner -RepoName $repoName -Ref $ref
        $pins.Add([PSCustomObject]@{ Module = $moduleName; Repo = $repoName; Ref = $ref; State = $state })
    }

    $rewrites = @(Update-LayerModuleSource -LayersDirectory $layersDir -SourceMap $sourceMap)

    $modulesAuth = $null
    if ($ComponentType -eq "Management" -and $pins.Count -gt 0) {
        $modulesAuth = Update-ModulesAuthRepository -RootDirectory $StagingDirectory -Repositories @($pins | ForEach-Object { $_.Repo })
    }

    return [PSCustomObject]@{
        Rewrites       = $rewrites
        Pins           = $pins.ToArray()
        UnknownModules = $unknown
        LayerCount     = @($rewrites | ForEach-Object { Split-Path -Path (Split-Path -Path $_.File -Parent) -Leaf } | Sort-Object -Unique).Count
        ModulesAuth    = $modulesAuth
    }
}

Export-ModuleMember -Function @(
    "Get-UpstreamModuleName",
    "Get-ModuleRepositorySource",
    "Find-LayerModuleReference",
    "Update-LayerModuleSource",
    "Update-ModulesAuthRepository",
    "Set-OrchestrationModuleSource"
)
