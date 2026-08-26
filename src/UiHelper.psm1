<#
.SYNOPSIS
    UI Helper module for Cloudflare Landing Zone Release Manager.
.DESCRIPTION
    Provides clean, styled terminal output adhering strictly to British English
    and zero emoji usage.
#>

function Write-ReleaseHeader {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Title,

        [Parameter(Mandatory = $false)]
        [string]$Subtitle = ""
    )

    $width = 76
    $border = "=" * $width
    Write-Host ""
    Write-Host $border -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor White
    if (-not [string]::IsNullOrWhiteSpace($Subtitle)) {
        Write-Host "  $Subtitle" -ForegroundColor DarkGray
    }
    Write-Host $border -ForegroundColor Cyan
    Write-Host ""
}

function Write-SectionHeader {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Title
    )

    Write-Host ""
    Write-Host "--- $Title ---" -ForegroundColor Cyan
    Write-Host ""
}

function Write-ReleaseInfo {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-ReleaseSuccess {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Host "[SUCCESS] $Message" -ForegroundColor Green
}

function Write-ReleaseWarning {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Warning "[WARNING] $Message"
}

function Write-ReleaseError {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Write-ReleaseStep {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [int]$StepNumber,

        [Parameter(Mandatory = $true)]
        [int]$TotalSteps,

        [Parameter(Mandatory = $true)]
        [string]$Description
    )

    Write-Host "[$StepNumber/$TotalSteps] $Description" -ForegroundColor Yellow
}

function Request-UserText {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Prompt,

        [Parameter(Mandatory = $false)]
        [string]$DefaultValue = "",

        [Parameter(Mandatory = $false)]
        [switch]$AsSecureString
    )

    $promptText = if ($DefaultValue) { "$($Prompt) [$DefaultValue]: " } else { "$($Prompt): " }

    if ($AsSecureString) {
        $secureInput = Read-Host -Prompt $promptText -AsSecureString
        return $secureInput
    }
    else {
        $inputVal = Read-Host -Prompt $promptText
        if ([string]::IsNullOrWhiteSpace($inputVal)) {
            return $DefaultValue
        }
        return $inputVal.Trim()
    }
}

function Request-UserChoice {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Prompt,

        [Parameter(Mandatory = $true)]
        [string[]]$Options,

        [Parameter(Mandatory = $false)]
        [int]$DefaultIndex = 0
    )

    Write-Host $Prompt -ForegroundColor Cyan
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $marker = if ($i -eq $DefaultIndex) { "*" } else { " " }
        Write-Host "  [$($i + 1)]$marker $($Options[$i])"
    }

    $defaultChoice = $DefaultIndex + 1
    $response = Read-Host -Prompt "Select an option [1-$($Options.Count), default: $defaultChoice]"
    if ([string]::IsNullOrWhiteSpace($response)) {
        return $Options[$DefaultIndex]
    }

    $parsedIndex = 0
    if ([int]::TryParse($response, [ref]$parsedIndex) -and $parsedIndex -ge 1 -and $parsedIndex -le $Options.Count) {
        return $Options[$parsedIndex - 1]
    }

    Write-ReleaseWarning "Invalid choice entered. Falling back to default: $($Options[$DefaultIndex])"
    return $Options[$DefaultIndex]
}

function Request-UserConfirmation {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Prompt,

        [Parameter(Mandatory = $false)]
        [bool]$DefaultYes = $true
    )

    $defaultStr = if ($DefaultYes) { "Y/n" } else { "y/N" }
    $response = Read-Host -Prompt "$Prompt [$defaultStr]"

    if ([string]::IsNullOrWhiteSpace($response)) {
        return $DefaultYes
    }

    return ($response.Trim().ToLower() -in @("y", "yes"))
}

Export-ModuleMember -Function @(
    "Write-ReleaseHeader",
    "Write-SectionHeader",
    "Write-ReleaseInfo",
    "Write-ReleaseSuccess",
    "Write-ReleaseWarning",
    "Write-ReleaseError",
    "Write-ReleaseStep",
    "Request-UserText",
    "Request-UserChoice",
    "Request-UserConfirmation"
)
