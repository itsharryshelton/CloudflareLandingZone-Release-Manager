<#
.SYNOPSIS
    GitHub REST API Client module for Cloudflare Landing Zone Release Manager.
.DESCRIPTION
    Provides authenticated interaction with GitHub REST API v3 (2022-11-28)
    for user verification, organisation lookup, repository status, and creation.
#>

function Get-GitHubHeaders {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Token
    )

    return @{
        "Authorization"        = "Bearer $Token"
        "Accept"               = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
        "User-Agent"           = "CloudflareLandingZone-ReleaseManager/1.0"
    }
}

function Get-GitHubErrorStatus {
    <#
    .SYNOPSIS
        Extracts the HTTP status code carried by an exception raised by Invoke-GitHubRestRequest.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $ex = $ErrorRecord.Exception
    while ($null -ne $ex) {
        if ($null -ne $ex.Data -and $ex.Data.Contains("StatusCode")) {
            return [int]$ex.Data["StatusCode"]
        }
        $ex = $ex.InnerException
    }

    return 0
}

function Get-GitHubErrorMessage {
    <#
    .SYNOPSIS
        Extracts the GitHub API error message carried by an exception, falling back to the exception text.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $ex = $ErrorRecord.Exception
    while ($null -ne $ex) {
        if ($null -ne $ex.Data -and $ex.Data.Contains("ErrorMessage")) {
            return [string]$ex.Data["ErrorMessage"]
        }
        $ex = $ex.InnerException
    }

    return $ErrorRecord.Exception.Message
}

function Invoke-GitHubRestRequest {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [string]$Token,

        [Parameter(Mandatory = $false)]
        [string]$Method = "GET",

        [Parameter(Mandatory = $false)]
        [object]$Body = $null
    )

    $headers = Get-GitHubHeaders -Token $Token
    $requestParams = @{
        Uri         = $Uri
        Headers     = $headers
        Method      = $Method
        ContentType = "application/json; charset=utf-8"
        ErrorAction = "Stop"
    }

    if ($null -ne $Body) {
        if ($Body -is [string]) {
            $requestParams.Body = $Body
        }
        else {
            $requestParams.Body = ($Body | ConvertTo-Json -Depth 5)
        }
    }

    try {
        $response = Invoke-RestMethod @requestParams
        return $response
    }
    catch {
        $httpEx = $_.Exception
        $statusCode = 0
        $responseBody = ""

        if ($_.Exception.Response) {
            $statusCode = [int]$_.Exception.Response.StatusCode
        }

        # PowerShell 7 buffers the failed response body into ErrorDetails and then disposes the
        # underlying HttpContent, so ErrorDetails must be read first. Reading the content stream
        # directly raises 'Cannot access a disposed object' and masks the original API error.
        if ($_.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($_.ErrorDetails.Message)) {
            $responseBody = $_.ErrorDetails.Message
        }
        elseif ($_.Exception.Response) {
            $resp = $_.Exception.Response
            try {
                if ($resp -is [System.Net.Http.HttpResponseMessage] -and $resp.Content) {
                    $responseBody = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                }
                elseif ($resp.PSObject.Methods["GetResponseStream"]) {
                    $stream = $resp.GetResponseStream()
                    if ($stream) {
                        $reader = [System.IO.StreamReader]::new($stream)
                        $responseBody = $reader.ReadToEnd()
                        $reader.Dispose()
                    }
                }
            }
            catch {
                # The response body is unavailable; the status code and exception text still stand.
                $responseBody = ""
            }
        }

        $parsedError = $null
        if (-not [string]::IsNullOrWhiteSpace($responseBody)) {
            try {
                $parsedError = $responseBody | ConvertFrom-Json
            }
            catch {
                # Could not parse JSON body
            }
        }

        $errorMessage = if ($parsedError -and $parsedError.message) {
            $parsedError.message
        }
        elseif (-not [string]::IsNullOrWhiteSpace($responseBody)) {
            $responseBody
        }
        else {
            $httpEx.Message
        }

        # A raw PSCustomObject cannot be thrown and re-inspected reliably: PowerShell
        # wraps it in an ErrorRecord, so '$_.StatusCode' resolves to $null in the
        # caller's catch block. Carry the detail on a real exception instead.
        $apiException = [System.Exception]::new($errorMessage, $httpEx)
        $apiException.Data["StatusCode"] = $statusCode
        $apiException.Data["ErrorMessage"] = $errorMessage
        $apiException.Data["Uri"] = $Uri
        throw $apiException
    }
}

function Get-GitHubCurrentUser {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Token
    )

    $uri = "https://api.github.com/user"
    try {
        $user = Invoke-GitHubRestRequest -Uri $uri -Token $Token -Method "GET"
        return [PSCustomObject]@{
            Login     = $user.login
            Name      = $user.name
            Type      = $user.type
            HtmlUrl   = $user.html_url
            Plan      = if ($user.plan) { $user.plan.name } else { "Unknown" }
        }
    }
    catch {
        if ((Get-GitHubErrorStatus -ErrorRecord $_) -eq 401) {
            throw [System.UnauthorizedAccessException]::new("GitHub authentication failed: Provided token is invalid or expired.")
        }
        throw [System.InvalidOperationException]::new("Failed to verify authenticated GitHub user: $(Get-GitHubErrorMessage -ErrorRecord $_)")
    }
}

function Get-GitHubOwnerType {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Token,

        [Parameter(Mandatory = $true)]
        [string]$Owner
    )

    # First test if owner is an organisation
    $orgUri = "https://api.github.com/orgs/$Owner"
    try {
        $org = Invoke-GitHubRestRequest -Uri $orgUri -Token $Token -Method "GET"
        return [PSCustomObject]@{
            OwnerName = $org.login
            Type      = "Organization"
            HtmlUrl   = $org.html_url
            Found     = $true
        }
    }
    catch {
        if ((Get-GitHubErrorStatus -ErrorRecord $_) -eq 404) {
            # Not an org, test if it is a user
            $userUri = "https://api.github.com/users/$Owner"
            try {
                $user = Invoke-GitHubRestRequest -Uri $userUri -Token $Token -Method "GET"
                return [PSCustomObject]@{
                    OwnerName = $user.login
                    Type      = "User"
                    HtmlUrl   = $user.html_url
                    Found     = $true
                }
            }
            catch {
                if ((Get-GitHubErrorStatus -ErrorRecord $_) -eq 404) {
                    return [PSCustomObject]@{
                        OwnerName = $Owner
                        Type      = "NotFound"
                        HtmlUrl   = $null
                        Found     = $false
                    }
                }
                throw
            }
        }
        throw
    }
}

function Get-GitHubRepoDetails {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Token,

        [Parameter(Mandatory = $true)]
        [string]$Owner,

        [Parameter(Mandatory = $true)]
        [string]$RepoName
    )

    $uri = "https://api.github.com/repos/$Owner/$RepoName"
    try {
        $repo = Invoke-GitHubRestRequest -Uri $uri -Token $Token -Method "GET"
        return [PSCustomObject]@{
            Exists        = $true
            Name          = $repo.name
            FullName      = $repo.full_name
            Private       = $repo.private
            HtmlUrl       = $repo.html_url
            CloneUrl      = $repo.clone_url
            SshUrl        = $repo.ssh_url
            DefaultBranch = $repo.default_branch
        }
    }
    catch {
        if ((Get-GitHubErrorStatus -ErrorRecord $_) -eq 404) {
            return [PSCustomObject]@{
                Exists        = $false
                Name          = $RepoName
                FullName      = "$Owner/$RepoName"
                Private       = $null
                HtmlUrl       = $null
                CloneUrl      = $null
                SshUrl        = $null
                DefaultBranch = $null
            }
        }
        throw
    }
}

function New-GitHubRemoteRepository {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Token,

        [Parameter(Mandatory = $true)]
        [string]$Owner,

        [Parameter(Mandatory = $true)]
        [string]$OwnerType, # "Organization" or "User"

        [Parameter(Mandatory = $true)]
        [string]$RepoName,

        [Parameter(Mandatory = $false)]
        [string]$Description = "",

        [Parameter(Mandatory = $false)]
        [bool]$IsPrivate = $true
    )

    $isOrg = ($OwnerType -eq "Organization")
    $uri = if ($isOrg) {
        "https://api.github.com/orgs/$Owner/repos"
    }
    else {
        "https://api.github.com/user/repos"
    }

    $payload = @{
        name        = $RepoName
        description = $Description
        private     = $IsPrivate
        auto_init   = $false
    }

    try {
        $created = Invoke-GitHubRestRequest -Uri $uri -Token $Token -Method "POST" -Body $payload
        return [PSCustomObject]@{
            Name          = $created.name
            FullName      = $created.full_name
            Private       = $created.private
            HtmlUrl       = $created.html_url
            CloneUrl      = $created.clone_url
            SshUrl        = $created.ssh_url
            DefaultBranch = $created.default_branch
        }
    }
    catch {
        throw [System.InvalidOperationException]::new("Failed to create repository '$RepoName' under $($Owner): $(Get-GitHubErrorMessage -ErrorRecord $_)")
    }
}

Export-ModuleMember -Function @(
    "Get-GitHubErrorStatus",
    "Get-GitHubErrorMessage",
    "Get-GitHubCurrentUser",
    "Get-GitHubOwnerType",
    "Get-GitHubRepoDetails",
    "New-GitHubRemoteRepository"
)
