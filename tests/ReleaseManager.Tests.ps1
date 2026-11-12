<#
.SYNOPSIS
    Test suite for Cloudflare Landing Zone Release Manager.
.DESCRIPTION
    Validates module discovery, configuration parsing, file copy mechanics,
    repository naming, publishing behaviour, and dry-run execution plans.
#>

BeforeDiscovery {
    # The real upstream checkout is optional: tests that read it are skipped when it is absent.
    # Set CFLZ_SOURCE_ROOT to point at a checkout elsewhere; the default is the sibling directory.
    $discoveryRoot = if ($env:CFLZ_SOURCE_ROOT) { $env:CFLZ_SOURCE_ROOT } else {
        Join-Path -Path (Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent) -ChildPath "CloudflareLandingZone"
    }
    $script:NoSourceMonorepo = -not (Test-Path -Path (Join-Path -Path $discoveryRoot -ChildPath "modules"))
}

BeforeAll {
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    $srcDir = Join-Path -Path $repoRoot -ChildPath "src"

    Import-Module (Join-Path -Path $srcDir -ChildPath "UiHelper.psm1") -Force
    Import-Module (Join-Path -Path $srcDir -ChildPath "ConfigManager.psm1") -Force
    Import-Module (Join-Path -Path $srcDir -ChildPath "GitHubApi.psm1") -Force
    Import-Module (Join-Path -Path $srcDir -ChildPath "RepoPublisher.psm1") -Force
    Import-Module (Join-Path -Path $srcDir -ChildPath "SourceRewriter.psm1") -Force

    $script:SourceMonorepo = if ($env:CFLZ_SOURCE_ROOT) { $env:CFLZ_SOURCE_ROOT } else {
        Join-Path -Path (Split-Path -Path $repoRoot -Parent) -ChildPath "CloudflareLandingZone"
    }
    $script:ScriptPath = Join-Path -Path $repoRoot -ChildPath "Invoke-CloudflareLandingZoneRelease.ps1"

    function New-TestWorkspace {
        $path = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "cflz-test-$([System.Guid]::NewGuid())"
        New-Item -Path $path -ItemType Directory -Force | Out-Null
        return $path
    }

    function Set-TestFile {
        param([string]$Root, [string]$RelativePath, [string]$Content)
        $path = Join-Path -Path $Root -ChildPath $RelativePath
        $parent = Split-Path -Path $path -Parent
        if (-not (Test-Path -Path $parent)) { New-Item -Path $parent -ItemType Directory -Force | Out-Null }
        # LF endings, as a Git checkout on Linux CI would have them.
        [System.IO.File]::WriteAllText($path, ($Content -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
    }

    # A small monorepo with the upstream shape: root pipelines, deployment/ and modules/,
    # and layers referencing modules in each of the upstream source styles.
    function New-FixtureMonorepo {
        $root = New-TestWorkspace

        Set-TestFile $root ".gitignore" "*.tfvars`n!deployment/accounts/*/*.tfvars`n**/local.auto.tfvars`n"
        Set-TestFile $root "AGENTS.md" "upstream agent guidance"
        Set-TestFile $root "CLAUDE.md" "@AGENTS.md"
        Set-TestFile $root "README.md" "upstream readme"
        Set-TestFile $root ".github/workflows/ci.yml" "name: CI"
        Set-TestFile $root ".github/actions/modules-auth/action.yml" @"
inputs:
  repository:
    description: 'Modules repository name, without the owner.'
    required: false
    default: cloudflare-platform-modules
"@
        Set-TestFile $root "deployment/README.md" "deployment readme"
        Set-TestFile $root "deployment/accounts/account_a/zones.tfvars" "zones = {}"
        Set-TestFile $root "deployment/layers/zones/terraform.tf" @"
terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.7"
    }
  }
}
"@
        Set-TestFile $root "deployment/layers/zones/zones.tf" @"
module "zones" {
  # Pin downstream:
  #   source = "git::https://github.com/yourorg/CloudflareLandingZone//modules/zone_base?ref=v1.0.0"
  source   = "../../../modules/zone_base"
  for_each = var.zones
}
"@
        Set-TestFile $root "deployment/layers/dns/dns.tf" @"
module "dns" {
  source = "git::https://github.com/Your-Org/cloudflare-platform-modules//dns_records"
}
"@
        Set-TestFile $root "deployment/layers/rules/rules.tf" @"
module "cache_rules" {
  source = "git::https://github.com/Your-Org/cloudflare-platform-modules//cache_rules?ref=v1.0.0"
}

module "zone_rules" {
  source = "../../../modules/zone_rules"
}
"@
        Set-TestFile $root "deployment/layers/legacy/legacy.tf" @"
module "legacy" {
  source = "../../../modules/retired_module"
}
"@
        # A layer with child modules of its own, as zerotrust carries modules/schema. Both
        # children are named after a published module so a false match would be repointed.
        Set-TestFile $root "deployment/layers/access/access.tf" @"
module "schema" {
  source = "./modules/zone_base"
}
"@
        Set-TestFile $root "deployment/layers/access/modules/zone_base/main.tf" @"
module "sibling" {
  source = "../modules/zone_rules"
}
"@
        foreach ($m in @("_TEMPLATE", "zone_base", "dns_records", "cache_rules", "zone_rules")) {
            Set-TestFile $root "modules/$m/main.tf" "# $m"
        }

        return $root
    }

    function New-BareRemoteWithTags {
        param([string]$Root, [string]$Name, [string[]]$Tags = @())
        $remote = Join-Path -Path $Root -ChildPath "$Name.git"
        $work = Join-Path -Path $Root -ChildPath "$Name-work"
        Invoke-GitCommand -WorkingDirectory $Root -Arguments @("init", "--bare", "-b", "main", $remote) | Out-Null
        if ($Tags.Count -gt 0) {
            New-Item -Path $work -ItemType Directory -Force | Out-Null
            Invoke-GitCommand -WorkingDirectory $work -Arguments @("init", "-b", "main") | Out-Null
            Invoke-GitCommand -WorkingDirectory $work -Arguments @("config", "user.email", "test@localhost") | Out-Null
            Invoke-GitCommand -WorkingDirectory $work -Arguments @("config", "user.name", "Test") | Out-Null
            Set-Content -Path (Join-Path $work "main.tf") -Value "# $Name"
            Invoke-GitCommand -WorkingDirectory $work -Arguments @("add", "-A") | Out-Null
            Invoke-GitCommand -WorkingDirectory $work -Arguments @("commit", "-m", "init") | Out-Null
            foreach ($t in $Tags) { Invoke-GitCommand -WorkingDirectory $work -Arguments @("tag", $t) | Out-Null }
            Invoke-GitCommand -WorkingDirectory $work -Arguments @("push", $remote, "main", "--tags") | Out-Null
        }
        return $remote
    }
}

Describe "Configuration Manager" {
    Context "Default Configuration" {
        It "Should generate default configuration with expected values" {
            $config = Get-ReleaseDefaultConfig
            $config.Prefix | Should -Be "cflz"
            $config.DeploymentLayout | Should -Be "Management"
            $config.ManagementRepoName | Should -Be "{prefix}-management"
            $config.DeploymentRepoName | Should -Be "{prefix}-deployment"
            $config.ModuleRepoPattern | Should -Be "terraform-cloudflare-lz-{module}"
            $config.RewriteModuleSources | Should -Be $true
            $config.ModuleSourceRef | Should -Be "latest"
            $config.SeedDeploymentOnce | Should -Be $true
            $config.Visibility | Should -Be "private"
            $config.DefaultBranch | Should -Be "main"
            $config.UpstreamRepoUrl | Should -Be "https://github.com/itsharryshelton/CloudflareLandingZone.git"
            $config.UpstreamRef | Should -Be "main"
        }
    }

    Context "Config Import & Export" {
        It "Should export and re-import config JSON accurately" {
            $tempConfigPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "cflz-test-config.json"
            $testConfig = Get-ReleaseDefaultConfig
            $testConfig.TargetOwner = "TestOrg"
            $testConfig.Visibility = "private"

            try {
                Export-ReleaseConfigFile -Config $testConfig -Path $tempConfigPath
                Test-Path -Path $tempConfigPath | Should -Be $true

                $imported = Import-ReleaseConfigFile -Path $tempConfigPath
                $imported.TargetOwner | Should -Be "TestOrg"
                $imported.Visibility | Should -Be "private"
                $imported.UpstreamRepoUrl | Should -Be "https://github.com/itsharryshelton/CloudflareLandingZone.git"
                $imported.DeploymentLayout | Should -Be "Management"
                $imported.ManagementRepoName | Should -Be "{prefix}-management"
                $imported.ModuleSourceRef | Should -Be "latest"
            }
            finally {
                if (Test-Path -Path $tempConfigPath) {
                    Remove-Item -Path $tempConfigPath -Force
                }
            }
        }

        It "Should apply known overrides and skip unrecognised configuration keys" {
            $base = Get-ReleaseDefaultConfig
            $overrides = [PSCustomObject]@{
                TargetOwner     = "focus-group"
                Visibility      = "internal"
                NotARealSetting = "should be ignored"
                DefaultBranch   = $null
            }

            $result = Merge-ReleaseConfig -BaseConfig $base -Overrides $overrides -WarningAction SilentlyContinue

            $result.Config.TargetOwner | Should -Be "focus-group"
            $result.Config.Visibility | Should -Be "internal"
            $result.Config.DefaultBranch | Should -Be "main"
            $result.UnknownKeys | Should -Contain "NotARealSetting"
        }

        It "Should accept every key in the shipped example configuration" {
            $example = Import-ReleaseConfigFile -Path (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath "release-config.example.json")
            $result = Merge-ReleaseConfig -BaseConfig (Get-ReleaseDefaultConfig) -Overrides $example -WarningAction SilentlyContinue
            $result.UnknownKeys | Should -BeNullOrEmpty
        }
    }
}

Describe "Repository Naming" {
    Context "ConvertTo-RepoSlug" {
        It "Should normalise source directory names into lowercase kebab-case" {
            ConvertTo-RepoSlug -Name "account_governance" | Should -Be "account-governance"
            ConvertTo-RepoSlug -Name "waf" | Should -Be "waf"
            ConvertTo-RepoSlug -Name "_TEMPLATE" | Should -Be "template"
            ConvertTo-RepoSlug -Name "Bulk_Redirect_List" | Should -Be "bulk-redirect-list"
            ConvertTo-RepoSlug -Name "workers_kv_namespace" | Should -Be "workers-kv-namespace"
        }
    }

    Context "Expand-RepoNameTemplate" {
        It "Should resolve the default management, deployment and module templates" {
            Expand-RepoNameTemplate -Template "{prefix}-management" -Prefix "cflz" | Should -Be "cflz-management"
            Expand-RepoNameTemplate -Template "{prefix}-deployment" -Prefix "cflz" | Should -Be "cflz-deployment"
            Expand-RepoNameTemplate -Template "terraform-cloudflare-lz-{module}" -Prefix "cflz" -ModuleName "zone_base" |
            Should -Be "terraform-cloudflare-lz-zone-base"
        }

        It "Should honour a custom prefix in both templates" {
            Expand-RepoNameTemplate -Template "{prefix}-deployment" -Prefix "Focus_Group" | Should -Be "focus-group-deployment"
            Expand-RepoNameTemplate -Template "{prefix}-module-{module}" -Prefix "fg" -ModuleName "zero_trust" |
            Should -Be "fg-module-zero-trust"
        }

        It "Should reject a template that resolves to an empty name" {
            { Expand-RepoNameTemplate -Template "{prefix}" -Prefix "" } | Should -Throw
        }
    }
}

Describe "GitHub API Error Handling" {
    Context "Status code propagation" {
        It "Should surface the HTTP status code carried by an API exception" {
            $ex = [System.Exception]::new("Not Found")
            $ex.Data["StatusCode"] = 404
            $ex.Data["ErrorMessage"] = "Not Found"
            $record = [System.Management.Automation.ErrorRecord]::new($ex, "GitHubApiError", [System.Management.Automation.ErrorCategory]::InvalidResult, $null)

            Get-GitHubErrorStatus -ErrorRecord $record | Should -Be 404
            Get-GitHubErrorMessage -ErrorRecord $record | Should -Be "Not Found"
        }

        It "Should return zero for an exception carrying no status code" {
            $record = [System.Management.Automation.ErrorRecord]::new(
                [System.Exception]::new("Connection reset"), "Generic", [System.Management.Automation.ErrorCategory]::NotSpecified, $null)

            Get-GitHubErrorStatus -ErrorRecord $record | Should -Be 0
            Get-GitHubErrorMessage -ErrorRecord $record | Should -Be "Connection reset"
        }
    }
}

Describe "Source Repository Discovery" {
    Context "Fixture Discovery" {
        It "Should discover the deployment directory, the pipelines and every module directory" {
            $fixture = New-FixtureMonorepo
            try {
                $discovery = Get-SourceDiscovery -SourceRoot $fixture
                $discovery.HasDeployment | Should -Be $true
                $discovery.HasPipelines | Should -Be $true
                @($discovery.Modules).Count | Should -Be 5
                ($discovery.Modules | ForEach-Object { $_.ModuleName }) | Should -Contain "_TEMPLATE"
            }
            finally {
                Remove-Item -Path $fixture -Recurse -Force
            }
        }
    }

    Context "Real Source Directory Discovery" {
        It "Should discover the deployment directory and one module per directory under modules/" -Skip:$script:NoSourceMonorepo {
            $discovery = Get-SourceDiscovery -SourceRoot $script:SourceMonorepo
            $discovery.HasDeployment | Should -Be $true
            $discovery.HasPipelines | Should -Be $true

            # Counted rather than hard-coded: upstream adds modules regularly.
            $expected = @(Get-ChildItem -Path (Join-Path $script:SourceMonorepo "modules") -Directory | Where-Object { $_.Name -notlike ".*" }).Count
            @($discovery.Modules).Count | Should -Be $expected

            $moduleNames = $discovery.Modules | ForEach-Object { $_.ModuleName }
            foreach ($name in @("waf", "gateway", "zerotrust", "r2_bucket", "zone_base", "zone_rules", "dns_records", "_TEMPLATE")) {
                $moduleNames | Should -Contain $name
            }
        }

        It "Should find every layer module source pointing upstream at a known module" -Skip:$script:NoSourceMonorepo {
            $discovery = Get-SourceDiscovery -SourceRoot $script:SourceMonorepo
            $known = @($discovery.Modules | ForEach-Object { $_.ModuleName })
            $refs = @(Find-LayerModuleReference -LayersDirectory (Join-Path $script:SourceMonorepo "deployment\layers") -KnownModules $known)

            $refs.Count | Should -BeGreaterThan 0
            @($refs | Where-Object { -not $_.Known }) | Should -BeNullOrEmpty
            ($refs | ForEach-Object { $_.ModuleName }) | Should -Contain "zone_base"
        }
    }
}

Describe "Source Copy and Filter Logic" {
    Context "Copy-SourceDataAsIs" {
        It "Should copy source files while excluding ephemeral caches and adding gitignore" {
            $tempSource = New-TestWorkspace
            $tempDest = New-TestWorkspace

            try {
                New-Item -Path "$tempSource\subdir" -ItemType Directory -Force | Out-Null
                New-Item -Path "$tempSource\.terraform\cache" -ItemType Directory -Force | Out-Null
                New-Item -Path "$tempSource\.git\objects" -ItemType Directory -Force | Out-Null

                Set-Content -Path "$tempSource\main.tf" -Value "resource test {}"
                Set-Content -Path "$tempSource\.terraform.lock.hcl" -Value "# lockfile"
                Set-Content -Path "$tempSource\.terraform\cache\plugin.exe" -Value "binary"
                Set-Content -Path "$tempSource\terraform.tfstate" -Value "state"
                Set-Content -Path "$tempSource\subdir\helper.tf" -Value "output {}"

                $result = Copy-SourceDataAsIs -SourceDirectory $tempSource -DestinationDirectory $tempDest -ComponentType "Module"

                Test-Path -Path "$tempDest\main.tf" | Should -Be $true
                Test-Path -Path "$tempDest\subdir\helper.tf" | Should -Be $true
                Test-Path -Path "$tempDest\.gitignore" | Should -Be $true

                # Ephemeral and ignored files must NOT be copied
                Test-Path -Path "$tempDest\.terraform" | Should -Be $false
                Test-Path -Path "$tempDest\.git" | Should -Be $false
                Test-Path -Path "$tempDest\terraform.tfstate" | Should -Be $false

                # A module's lock file is never read by its callers, and a stale one breaks the module CI.
                Test-Path -Path "$tempDest\.terraform.lock.hcl" | Should -Be $false

                $result.FileCount | Should -Be 2
                $result.Files | Should -Contain "main.tf"
            }
            finally {
                if (Test-Path -Path $tempSource) { Remove-Item -Path $tempSource -Recurse -Force }
                if (Test-Path -Path $tempDest) { Remove-Item -Path $tempDest -Recurse -Force }
            }
        }

        It "Should keep a root module's lock file in a deployment release" {
            $tempSource = New-TestWorkspace
            $tempDest = New-TestWorkspace
            try {
                Set-TestFile $tempSource "layers/zones/zones.tf" "# layer"
                Set-TestFile $tempSource "layers/zones/.terraform.lock.hcl" "# lock"
                Copy-SourceDataAsIs -SourceDirectory $tempSource -DestinationDirectory $tempDest -ComponentType "Deployment" | Out-Null
                Test-Path -Path "$tempDest\layers\zones\.terraform.lock.hcl" | Should -Be $true
            }
            finally {
                Remove-Item -Path $tempSource, $tempDest -Recurse -Force
            }
        }

        It "Should copy the full deployment tree including account variable files" -Skip:$script:NoSourceMonorepo {
            $tempDest = New-TestWorkspace
            try {
                $result = Copy-SourceDataAsIs `
                    -SourceDirectory (Join-Path -Path $script:SourceMonorepo -ChildPath "deployment") `
                    -DestinationDirectory $tempDest `
                    -ComponentType "Deployment"

                $result.FileCount | Should -BeGreaterThan 100
                ($result.Files | Where-Object { $_ -like "accounts\*\*.tfvars" }).Count | Should -BeGreaterThan 0
                ($result.Files | Where-Object { $_ -like "*.terraform\*" }).Count | Should -Be 0
            }
            finally {
                if (Test-Path -Path $tempDest) { Remove-Item -Path $tempDest -Recurse -Force }
            }
        }
    }

    Context "Management repository copy" {
        It "Should copy the source root minus modules/, keeping the pipelines and the deployment/ path" {
            $fixture = New-FixtureMonorepo
            $dest = New-TestWorkspace
            try {
                $result = Copy-SourceDataAsIs -SourceDirectory $fixture -DestinationDirectory $dest -ComponentType "Management" -ExcludeTopLevel @("modules")

                Test-Path -Path (Join-Path $dest ".github\workflows\ci.yml") | Should -Be $true
                Test-Path -Path (Join-Path $dest ".github\actions\modules-auth\action.yml") | Should -Be $true
                Test-Path -Path (Join-Path $dest "deployment\layers\zones\zones.tf") | Should -Be $true
                Test-Path -Path (Join-Path $dest "deployment\accounts\account_a\zones.tfvars") | Should -Be $true
                Test-Path -Path (Join-Path $dest "AGENTS.md") | Should -Be $true
                Test-Path -Path (Join-Path $dest "modules") | Should -Be $false
                @($result.Files | Where-Object { $_ -like "modules*" }) | Should -BeNullOrEmpty

                # The source root's own .gitignore already uses deployment/-relative paths.
                (Get-Content -Path (Join-Path $dest ".gitignore") -Raw) | Should -Match "!deployment/accounts/\*/\*\.tfvars"
            }
            finally {
                Remove-Item -Path $fixture, $dest -Recurse -Force
            }
        }

        It "Should only exclude a top-level directory, not one of the same name further down" {
            $fixture = New-FixtureMonorepo
            $dest = New-TestWorkspace
            try {
                Set-TestFile $fixture "deployment/layers/zones/modules/keep.txt" "nested"
                Copy-SourceDataAsIs -SourceDirectory $fixture -DestinationDirectory $dest -ComponentType "Management" -ExcludeTopLevel @("modules") | Out-Null
                Test-Path -Path (Join-Path $dest "deployment\layers\zones\modules\keep.txt") | Should -Be $true
            }
            finally {
                Remove-Item -Path $fixture, $dest -Recurse -Force
            }
        }

        It "Should release only Git-tracked files when the source is a local work tree" {
            $fixture = New-FixtureMonorepo
            $dest = New-TestWorkspace
            try {
                Invoke-GitCommand -WorkingDirectory $fixture -Arguments @("init", "-b", "main") | Out-Null
                Invoke-GitCommand -WorkingDirectory $fixture -Arguments @("config", "user.email", "test@localhost") | Out-Null
                Invoke-GitCommand -WorkingDirectory $fixture -Arguments @("config", "user.name", "Test") | Out-Null
                Invoke-GitCommand -WorkingDirectory $fixture -Arguments @("add", "-A") | Out-Null
                Invoke-GitCommand -WorkingDirectory $fixture -Arguments @("commit", "-m", "fixture") | Out-Null

                # Local, uncommitted state an operator's checkout typically carries.
                Set-TestFile $fixture ".claude/settings.local.json" "{}"
                Set-TestFile $fixture "deployment/layers/zones/local.auto.tfvars" "api_token = `"secret`""
                Set-TestFile $fixture "scratch-notes.md" "notes"
                # An uncommitted edit to a tracked file is still released.
                Set-TestFile $fixture "README.md" "edited locally"

                Copy-SourceDataAsIs -SourceDirectory $fixture -DestinationDirectory $dest -ComponentType "Management" -ExcludeTopLevel @("modules") | Out-Null

                Test-Path -Path (Join-Path $dest ".claude") | Should -Be $false
                Test-Path -Path (Join-Path $dest "deployment\layers\zones\local.auto.tfvars") | Should -Be $false
                Test-Path -Path (Join-Path $dest "scratch-notes.md") | Should -Be $false
                (Get-Content -Path (Join-Path $dest "README.md") -Raw).Trim() | Should -Be "edited locally"
                Test-Path -Path (Join-Path $dest "deployment\accounts\account_a\zones.tfvars") | Should -Be $true -Because "account trees are negated in the source .gitignore, so they are tracked"
            }
            finally {
                Remove-Item -Path $fixture, $dest -Recurse -Force
            }
        }
    }

    Context "Published .gitignore path correctness" {
        It "Should keep account variable files committable at their management repository path" {
            $workspace = New-TestWorkspace
            try {
                Invoke-GitCommand -WorkingDirectory $workspace -Arguments @("init") | Out-Null
                Set-Content -Path (Join-Path -Path $workspace -ChildPath ".gitignore") `
                    -Value (Get-ComponentGitIgnoreContent -ComponentType "Management") -Encoding utf8

                (Invoke-GitCommand -WorkingDirectory $workspace -Arguments @("check-ignore", "deployment/accounts/account_a/waf.tfvars")).ExitCode | Should -Be 1
                (Invoke-GitCommand -WorkingDirectory $workspace -Arguments @("check-ignore", "deployment/layers/waf/defaults.auto.tfvars")).ExitCode | Should -Be 1
                (Invoke-GitCommand -WorkingDirectory $workspace -Arguments @("check-ignore", "deployment/layers/waf/local.auto.tfvars")).ExitCode | Should -Be 0
                (Invoke-GitCommand -WorkingDirectory $workspace -Arguments @("check-ignore", "deployment/layers/waf/terraform.tfstate")).ExitCode | Should -Be 0
            }
            finally {
                Remove-Item -Path $workspace -Recurse -Force
            }
        }

        It "Should not withhold deployment account variable files from the release" {
            # The monorepo policy negates 'deployment/accounts/*/*.tfvars'. Once 'deployment'
            # becomes its own repository root, that negation no longer matches and the blanket
            # '*.tfvars' deny would silently drop every account configuration file.
            $workspace = New-TestWorkspace
            try {
                Invoke-GitCommand -WorkingDirectory $workspace -Arguments @("init") | Out-Null
                Set-Content -Path (Join-Path -Path $workspace -ChildPath ".gitignore") `
                    -Value (Get-ComponentGitIgnoreContent -ComponentType "Deployment") -Encoding utf8

                New-Item -Path "$workspace\accounts\account_a" -ItemType Directory -Force | Out-Null
                New-Item -Path "$workspace\layers\waf" -ItemType Directory -Force | Out-Null
                Set-Content -Path "$workspace\accounts\account_a\waf.tfvars" -Value "x = 1"
                Set-Content -Path "$workspace\layers\waf\defaults.auto.tfvars" -Value "y = 2"
                Set-Content -Path "$workspace\layers\waf\terraform.tfstate" -Value "state"
                Set-Content -Path "$workspace\layers\waf\local.auto.tfvars" -Value "secret = 1"

                $accountVars = Invoke-GitCommand -WorkingDirectory $workspace -Arguments @("check-ignore", "accounts/account_a/waf.tfvars")
                $layerDefaults = Invoke-GitCommand -WorkingDirectory $workspace -Arguments @("check-ignore", "layers/waf/defaults.auto.tfvars")
                $state = Invoke-GitCommand -WorkingDirectory $workspace -Arguments @("check-ignore", "layers/waf/terraform.tfstate")
                $localOverride = Invoke-GitCommand -WorkingDirectory $workspace -Arguments @("check-ignore", "layers/waf/local.auto.tfvars")

                # 'git check-ignore' exits 1 when a path is NOT ignored.
                $accountVars.ExitCode | Should -Be 1
                $layerDefaults.ExitCode | Should -Be 1
                $state.ExitCode | Should -Be 0
                $localOverride.ExitCode | Should -Be 0
            }
            finally {
                if (Test-Path -Path $workspace) { Remove-Item -Path $workspace -Recurse -Force }
            }
        }
    }
}

Describe "Module CI Scaffold" {
    BeforeAll {
        $script:moduleScaffold = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath "templates\module"
    }

    Context "Shipped template" {
        It "Should carry the CI workflow, the secret scan, the tag script and the scanner config" {
            Test-Path -Path (Join-Path $script:moduleScaffold ".github\workflows\ci.yml") | Should -Be $true
            Test-Path -Path (Join-Path $script:moduleScaffold ".github\workflows\secret-scanning.yml") | Should -Be $true
            Test-Path -Path (Join-Path $script:moduleScaffold ".github\scripts\next-version.sh") | Should -Be $true
            Test-Path -Path (Join-Path $script:moduleScaffold ".betterleaks.toml") | Should -Be $true
        }

        It "Should gate the release tag on every check" {
            $ci = Get-Content -Path (Join-Path $script:moduleScaffold ".github\workflows\ci.yml") -Raw
            $ci | Should -Match "needs: \[fmt, validate, offline-plan, secret-scan\]"
        }
    }

    Context "Copy-ComponentScaffold" {
        It "Should overlay the scaffold onto a staged module" {
            $dest = New-TestWorkspace
            try {
                Set-Content -Path (Join-Path $dest "main.tf") -Value "resource test {}"
                $result = Copy-ComponentScaffold -ScaffoldDirectory $script:moduleScaffold -DestinationDirectory $dest

                $result.FileCount | Should -Be 4
                Test-Path -Path (Join-Path $dest ".github\workflows\ci.yml") | Should -Be $true
                Test-Path -Path (Join-Path $dest "main.tf") | Should -Be $true
            }
            finally {
                if (Test-Path -Path $dest) { Remove-Item -Path $dest -Recurse -Force }
            }
        }

        It "Should leave a file the module already ships untouched" {
            $dest = New-TestWorkspace
            try {
                New-Item -Path (Join-Path $dest ".github\workflows") -ItemType Directory -Force | Out-Null
                Set-Content -Path (Join-Path $dest ".github\workflows\ci.yml") -Value "name: module-own"

                $result = Copy-ComponentScaffold -ScaffoldDirectory $script:moduleScaffold -DestinationDirectory $dest

                (Get-Content -Path (Join-Path $dest ".github\workflows\ci.yml") -Raw).Trim() | Should -Be "name: module-own"
                $result.KeptFromSource | Should -Contain ".github\workflows\ci.yml"
                $result.FileCount | Should -Be 3
            }
            finally {
                if (Test-Path -Path $dest) { Remove-Item -Path $dest -Recurse -Force }
            }
        }

        It "Should reject a missing scaffold directory" {
            { Copy-ComponentScaffold -ScaffoldDirectory "Z:\does-not-exist" -DestinationDirectory ([System.IO.Path]::GetTempPath()) } |
            Should -Throw
        }
    }
}

Describe "Agent Context Files" {
    BeforeAll {
        $script:agentTemplates = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath "templates\agents"
    }

    Context "Shipped templates" {
        It "Should carry AGENTS.md and CLAUDE.md for the <Type> template" -ForEach @(
            @{ Type = "management" }
            @{ Type = "deployment" }
            @{ Type = "module" }
        ) {
            Test-Path -Path (Join-Path $script:agentTemplates "$Type\AGENTS.md") | Should -Be $true
            Test-Path -Path (Join-Path $script:agentTemplates "$Type\CLAUDE.md") | Should -Be $true
        }

        It "Should give the deployment repository different guidance to the modules" {
            $deployment = Get-Content -Path (Join-Path $script:agentTemplates "deployment\AGENTS.md") -Raw
            $module = Get-Content -Path (Join-Path $script:agentTemplates "module\AGENTS.md") -Raw
            $deployment | Should -Not -Be $module
        }
    }

    Context "Overlay onto a staged release" {
        It "Should add both agent files alongside the source" {
            $dest = New-TestWorkspace
            try {
                Set-Content -Path (Join-Path $dest "main.tf") -Value "resource test {}"
                $result = Copy-ComponentScaffold -ScaffoldDirectory (Join-Path $script:agentTemplates "module") -DestinationDirectory $dest

                $result.FileCount | Should -Be 2
                Test-Path -Path (Join-Path $dest "AGENTS.md") | Should -Be $true
                Test-Path -Path (Join-Path $dest "CLAUDE.md") | Should -Be $true
            }
            finally {
                if (Test-Path -Path $dest) { Remove-Item -Path $dest -Recurse -Force }
            }
        }

        It "Should keep an AGENTS.md the component already ships" {
            $dest = New-TestWorkspace
            try {
                Set-Content -Path (Join-Path $dest "AGENTS.md") -Value "component-own"
                $result = Copy-ComponentScaffold -ScaffoldDirectory (Join-Path $script:agentTemplates "deployment") -DestinationDirectory $dest

                (Get-Content -Path (Join-Path $dest "AGENTS.md") -Raw).Trim() | Should -Be "component-own"
                $result.KeptFromSource | Should -Contain "AGENTS.md"
                $result.Files | Should -Contain "CLAUDE.md"
            }
            finally {
                if (Test-Path -Path $dest) { Remove-Item -Path $dest -Recurse -Force }
            }
        }
    }
}

Describe "Publishing Mechanics" {
    Context "Publish-LocalRepository against a local bare remote" {
        BeforeEach {
            $script:testRoot = New-TestWorkspace
            $script:bareRemote = Join-Path -Path $script:testRoot -ChildPath "remote.git"
            $script:staging = Join-Path -Path $script:testRoot -ChildPath "staging"
            $script:sourceTree = Join-Path -Path $script:testRoot -ChildPath "source"

            Invoke-GitCommand -WorkingDirectory $script:testRoot -Arguments @("init", "--bare", "-b", "main", $script:bareRemote) | Out-Null

            New-Item -Path $script:sourceTree -ItemType Directory -Force | Out-Null
            Set-Content -Path (Join-Path -Path $script:sourceTree -ChildPath "main.tf") -Value "resource test {}"
            New-Item -Path (Join-Path -Path $script:sourceTree -ChildPath "examples") -ItemType Directory -Force | Out-Null
            Set-Content -Path (Join-Path -Path $script:sourceTree -ChildPath "examples\demo.tfvars") -Value "a = 1"
        }

        AfterEach {
            if (Test-Path -Path $script:testRoot) { Remove-Item -Path $script:testRoot -Recurse -Force }
        }

        It "Should report an empty remote, publish, and then synchronise idempotently" {
            $first = Initialize-StagingRepository -StagingPath $script:staging -RemoteUrl $script:bareRemote -AuthenticatedUrl $script:bareRemote -DefaultBranch "main"
            $first.RemoteIsEmpty | Should -Be $true
            $first.HistoryFetched | Should -Be $false

            Copy-SourceDataAsIs -SourceDirectory $script:sourceTree -DestinationDirectory $script:staging -ComponentType "Module" | Out-Null

            $publish = Publish-LocalRepository -StagingPath $script:staging -RemoteUrl $script:bareRemote -AuthenticatedPushUrl $script:bareRemote -DefaultBranch "main" -CommitMessage "Initial release"
            $publish.Committed | Should -Be $true
            $publish.Forced | Should -Be $false

            # Files staged with --force reach the remote even though the published .gitignore
            # carries a blanket '*.tfvars' deny.
            $lsTree = Invoke-GitCommand -WorkingDirectory $script:bareRemote -Arguments @("ls-tree", "-r", "--name-only", "main")
            $lsTree.Output | Should -Match "main.tf"
            $lsTree.Output | Should -Match "examples/demo.tfvars"

            # Second run over unchanged source must not create a commit.
            Remove-Item -Path $script:staging -Recurse -Force
            $second = Initialize-StagingRepository -StagingPath $script:staging -RemoteUrl $script:bareRemote -AuthenticatedUrl $script:bareRemote -DefaultBranch "main"
            $second.RemoteIsEmpty | Should -Be $false
            $second.HistoryFetched | Should -Be $true

            Copy-SourceDataAsIs -SourceDirectory $script:sourceTree -DestinationDirectory $script:staging -ComponentType "Module" | Out-Null
            $republish = Publish-LocalRepository -StagingPath $script:staging -RemoteUrl $script:bareRemote -AuthenticatedPushUrl $script:bareRemote -DefaultBranch "main" -CommitMessage "Update release"
            $republish.Committed | Should -Be $false

            $revCount = Invoke-GitCommand -WorkingDirectory $script:bareRemote -Arguments @("rev-list", "--count", "main")
            $revCount.Output | Should -Be "1"
        }

        It "Should propagate deletions made at source into the published repository" {
            Initialize-StagingRepository -StagingPath $script:staging -RemoteUrl $script:bareRemote -AuthenticatedUrl $script:bareRemote -DefaultBranch "main" | Out-Null
            Copy-SourceDataAsIs -SourceDirectory $script:sourceTree -DestinationDirectory $script:staging -ComponentType "Module" | Out-Null
            Publish-LocalRepository -StagingPath $script:staging -RemoteUrl $script:bareRemote -AuthenticatedPushUrl $script:bareRemote -DefaultBranch "main" -CommitMessage "Initial release" | Out-Null

            Remove-Item -Path (Join-Path -Path $script:sourceTree -ChildPath "examples") -Recurse -Force
            Remove-Item -Path $script:staging -Recurse -Force

            Initialize-StagingRepository -StagingPath $script:staging -RemoteUrl $script:bareRemote -AuthenticatedUrl $script:bareRemote -DefaultBranch "main" | Out-Null
            Copy-SourceDataAsIs -SourceDirectory $script:sourceTree -DestinationDirectory $script:staging -ComponentType "Module" | Out-Null
            $publish = Publish-LocalRepository -StagingPath $script:staging -RemoteUrl $script:bareRemote -AuthenticatedPushUrl $script:bareRemote -DefaultBranch "main" -CommitMessage "Update release"

            $publish.Committed | Should -Be $true
            $lsTree = Invoke-GitCommand -WorkingDirectory $script:bareRemote -Arguments @("ls-tree", "-r", "--name-only", "main")
            $lsTree.Output | Should -Not -Match "examples/demo.tfvars"
        }

        It "Should not write the authentication token into the staging Git configuration" {
            Initialize-StagingRepository -StagingPath $script:staging -RemoteUrl "https://github.com/example/repo.git" -AuthenticatedUrl $script:bareRemote -DefaultBranch "main" | Out-Null

            $gitConfig = Get-Content -Path (Join-Path -Path $script:staging -ChildPath ".git\config") -Raw
            $gitConfig | Should -Not -Match "x-access-token"
            $gitConfig | Should -Match "https://github.com/example/repo.git"
        }

        It "Should build the Git remote URL for each transport" {
            Get-GitRemoteUrl -Transport "https" -Owner "acme" -RepoName "r" -Token "tok" | Should -Be "https://x-access-token:tok@github.com/acme/r.git"
            Get-GitRemoteUrl -Transport "https" -Owner "acme" -RepoName "r" -Token "" | Should -Be "https://github.com/acme/r.git"
            Get-GitRemoteUrl -Transport "ssh" -Owner "acme" -RepoName "r" -Token "tok" | Should -Be "git@github.com:acme/r.git"
        }

        It "Should pass the SSH command to Git processes only while it is set" {
            $keyDir = New-TestWorkspace
            try {
                $key = Join-Path $keyDir "id test"
                Set-Content -Path $key -Value "not a real key"
                $expectedPath = (Resolve-Path $key).ProviderPath -replace '\\', '/'

                Get-GitSshCommand -KeyPath $key | Should -Be "ssh -o BatchMode=yes -o IdentitiesOnly=yes -i `"$expectedPath`""
                Get-GitSshCommand | Should -Be "ssh -o BatchMode=yes"

                # A shell alias echoes what Git sees in its environment.
                $show = @("-c", 'alias.showssh=!echo "[$GIT_SSH_COMMAND]"', "showssh")
                Set-GitSshCommand -KeyPath $key
                (Invoke-GitCommand -WorkingDirectory $keyDir -Arguments $show).Output | Should -Be "[ssh -o BatchMode=yes -o IdentitiesOnly=yes -i `"$expectedPath`"]"

                Set-GitSshCommand -Clear
                (Invoke-GitCommand -WorkingDirectory $keyDir -Arguments $show).Output | Should -Be "[$env:GIT_SSH_COMMAND]"
                $env:GIT_SSH_COMMAND | Should -BeNullOrEmpty -Because "the caller's environment is never modified"
            }
            finally {
                Set-GitSshCommand -Clear
                Remove-Item -Path $keyDir -Recurse -Force
            }
        }

        It "Should read the login from GitHub's SSH greeting, and nothing from a failure" {
            ConvertFrom-GitHubSshGreeting -Text "Hi HarrySheltonFocus! You've successfully authenticated, but GitHub does not provide shell access." |
                Should -Be "HarrySheltonFocus"
            ConvertFrom-GitHubSshGreeting -Text "Hi acme/deploy-repo! You've successfully authenticated, but GitHub does not provide shell access." |
                Should -Be "acme"
            ConvertFrom-GitHubSshGreeting -Text "git@github.com: Permission denied (publickey)." | Should -BeNullOrEmpty
            ConvertFrom-GitHubSshGreeting -Text "" | Should -BeNullOrEmpty
        }

        It "Should redact credentials embedded in Git output" {
            Protect-GitOutput -Text "remote: rejected https://x-access-token:ghp_secretvalue@github.com/o/r.git" |
            Should -Be "remote: rejected https://***@github.com/o/r.git"
        }
    }

    Context "Sync-UpstreamSource" {
        It "Should clone a source repository at the requested ref and report its commit" {
            $testRoot = New-TestWorkspace
            try {
                $origin = Join-Path -Path $testRoot -ChildPath "origin"
                New-Item -Path $origin -ItemType Directory -Force | Out-Null
                Invoke-GitCommand -WorkingDirectory $origin -Arguments @("init", "-b", "main") | Out-Null
                Invoke-GitCommand -WorkingDirectory $origin -Arguments @("config", "user.email", "test@localhost") | Out-Null
                Invoke-GitCommand -WorkingDirectory $origin -Arguments @("config", "user.name", "Test") | Out-Null
                Set-Content -Path (Join-Path -Path $origin -ChildPath "README.md") -Value "upstream"
                Invoke-GitCommand -WorkingDirectory $origin -Arguments @("add", "-A") | Out-Null
                Invoke-GitCommand -WorkingDirectory $origin -Arguments @("commit", "-m", "Upstream commit") | Out-Null

                $destination = Join-Path -Path $testRoot -ChildPath "_upstream"
                $info = Sync-UpstreamSource -RepositoryUrl $origin -DestinationPath $destination -Ref "main"

                $info.CommitSubject | Should -Be "Upstream commit"
                $info.CommitSha | Should -Match "^[0-9a-f]{40}$"
                Test-Path -Path (Join-Path -Path $destination -ChildPath "README.md") | Should -Be $true
            }
            finally {
                if (Test-Path -Path $testRoot) { Remove-Item -Path $testRoot -Recurse -Force }
            }
        }
    }
}

Describe "Re-run Policy" {
    Context "Get-ComponentReleaseAction" {
        It "Should create a component whose repository does not exist" {
            (Get-ComponentReleaseAction -ComponentType "Deployment" -RepoExists $false -RemoteHasCommits $false).Action | Should -Be "Create"
            (Get-ComponentReleaseAction -ComponentType "Module" -RepoExists $false -RemoteHasCommits $false).Action | Should -Be "Create"
        }

        It "Should complete the initial release when the repository exists but carries no commits" {
            # Creation succeeded but the first push failed; a retry must still seed it.
            (Get-ComponentReleaseAction -ComponentType "Deployment" -RepoExists $true -RemoteHasCommits $false).Action | Should -Be "Create"
        }

        It "Should always re-synchronise module repositories" {
            $action = Get-ComponentReleaseAction -ComponentType "Module" -RepoExists $true -RemoteHasCommits $true
            $action.Action | Should -Be "Update"
        }

        It "Should skip an already-seeded deployment repository so operator edits survive" {
            $action = Get-ComponentReleaseAction -ComponentType "Deployment" -RepoExists $true -RemoteHasCommits $true
            $action.Action | Should -Be "Skip"
            $action.Reason | Should -Match "ForceDeploymentUpdate"
        }

        It "Should re-release a seeded deployment repository when explicitly forced" {
            (Get-ComponentReleaseAction -ComponentType "Deployment" -RepoExists $true -RemoteHasCommits $true -ForceDeploymentUpdate $true).Action |
                Should -Be "Update"
        }

        It "Should re-release a seeded deployment repository when the seed-once policy is disabled" {
            (Get-ComponentReleaseAction -ComponentType "Deployment" -RepoExists $true -RemoteHasCommits $true -SeedDeploymentOnce $false).Action |
                Should -Be "Update"
        }

        It "Should apply the seed-once policy to the management repository" {
            $action = Get-ComponentReleaseAction -ComponentType "Management" -RepoExists $true -RemoteHasCommits $true
            $action.Action | Should -Be "Skip"
            $action.Reason | Should -Match "^Management repository"
            (Get-ComponentReleaseAction -ComponentType "Management" -RepoExists $true -RemoteHasCommits $true -ForceDeploymentUpdate $true).Action |
                Should -Be "Update"
            (Get-ComponentReleaseAction -ComponentType "Management" -RepoExists $false -RemoteHasCommits $false).Action |
                Should -Be "Create"
        }
    }

    Context "Mirror semantics for module repositories" {
        It "Should revert edits and remove files added directly to a published module repository" {
            $testRoot = New-TestWorkspace
            try {
                $remote = Join-Path -Path $testRoot -ChildPath "remote.git"
                $source = Join-Path -Path $testRoot -ChildPath "source"
                $staging = Join-Path -Path $testRoot -ChildPath "staging"
                $consumer = Join-Path -Path $testRoot -ChildPath "consumer"

                Invoke-GitCommand -WorkingDirectory $testRoot -Arguments @("init", "--bare", "-b", "main", $remote) | Out-Null
                New-Item -Path $source -ItemType Directory -Force | Out-Null
                Set-Content -Path (Join-Path -Path $source -ChildPath "main.tf") -Value 'variable "a" {}'

                Initialize-StagingRepository -StagingPath $staging -RemoteUrl $remote -AuthenticatedUrl $remote -DefaultBranch "main" | Out-Null
                Copy-SourceDataAsIs -SourceDirectory $source -DestinationDirectory $staging -ComponentType "Module" | Out-Null
                Publish-LocalRepository -StagingPath $staging -RemoteUrl $remote -AuthenticatedPushUrl $remote -DefaultBranch "main" -CommitMessage "Initial release" | Out-Null

                # A consumer edits the published repository directly and adds a file of their own.
                Invoke-GitCommand -WorkingDirectory $testRoot -Arguments @("clone", $remote, $consumer) | Out-Null
                Invoke-GitCommand -WorkingDirectory $consumer -Arguments @("config", "user.email", "ops@localhost") | Out-Null
                Invoke-GitCommand -WorkingDirectory $consumer -Arguments @("config", "user.name", "Ops") | Out-Null
                Set-Content -Path (Join-Path -Path $consumer -ChildPath "main.tf") -Value 'variable "edited_locally" {}'
                Set-Content -Path (Join-Path -Path $consumer -ChildPath "extra.tf") -Value 'output "extra" {}'
                Invoke-GitCommand -WorkingDirectory $consumer -Arguments @("add", "-A") | Out-Null
                Invoke-GitCommand -WorkingDirectory $consumer -Arguments @("commit", "-m", "Local customisation") | Out-Null
                Invoke-GitCommand -WorkingDirectory $consumer -Arguments @("push", "origin", "main") | Out-Null

                # Re-release from unchanged source.
                Remove-Item -Path $staging -Recurse -Force
                Initialize-StagingRepository -StagingPath $staging -RemoteUrl $remote -AuthenticatedUrl $remote -DefaultBranch "main" | Out-Null
                Copy-SourceDataAsIs -SourceDirectory $source -DestinationDirectory $staging -ComponentType "Module" | Out-Null
                $publish = Publish-LocalRepository -StagingPath $staging -RemoteUrl $remote -AuthenticatedPushUrl $remote -DefaultBranch "main" -CommitMessage "Update release"

                $publish.Committed | Should -Be $true

                # Source content wins: the edit is reverted and the consumer's extra file is removed.
                (Invoke-GitCommand -WorkingDirectory $remote -Arguments @("show", "main:main.tf")).Output | Should -Be 'variable "a" {}'
                (Invoke-GitCommand -WorkingDirectory $remote -Arguments @("ls-tree", "-r", "--name-only", "main")).Output | Should -Not -Match "extra.tf"

                # The consumer's commit remains in history, so the change is recoverable.
                (Invoke-GitCommand -WorkingDirectory $remote -Arguments @("log", "--oneline", "main")).Output | Should -Match "Local customisation"
            }
            finally {
                if (Test-Path -Path $testRoot) { Remove-Item -Path $testRoot -Recurse -Force }
            }
        }
    }
}

Describe "Module Source Rewriting" {
    Context "Get-UpstreamModuleName" {
        It "Should recognise the upstream source form <Source>" -ForEach @(
            @{ Source = "../../../modules/zone_base"; Expected = "zone_base" }
            @{ Source = "../../modules/waf/"; Expected = "waf" }
            @{ Source = "git::https://github.com/Your-Org/cloudflare-platform-modules//dns_records"; Expected = "dns_records" }
            @{ Source = "git::https://github.com/Your-Org/cloudflare-platform-modules//cache_rules?ref=v1.0.0"; Expected = "cache_rules" }
            @{ Source = "git::https://github.com/acme/cloudflare-platform-modules.git//gateway?ref=v2.1.0"; Expected = "gateway" }
            @{ Source = "git::https://github.com/yourorg/CloudflareLandingZone//modules/zerotrust?ref=v1.0.0"; Expected = "zerotrust" }
        ) {
            Get-UpstreamModuleName -Source $Source | Should -Be $Expected
        }

        It "Should leave <Source> alone" -ForEach @(
            @{ Source = "./modules/schema" }
            @{ Source = "./modules/zone_base" }
            @{ Source = "cloudflare/cloudflare" }
            @{ Source = "terraform-aws-modules/vpc/aws" }
            @{ Source = "git::https://github.com/acme/terraform-cloudflare-lz-zone-base.git?ref=v1.0.0" }
            @{ Source = "git::https://github.com/third-party/some-modules//waf" }
        ) {
            Get-UpstreamModuleName -Source $Source | Should -BeNullOrEmpty
        }
    }

    Context "Set-OrchestrationModuleSource on a management repository" {
        BeforeEach {
            $script:fixture = New-FixtureMonorepo
            $script:staged = New-TestWorkspace
            Copy-SourceDataAsIs -SourceDirectory $script:fixture -DestinationDirectory $script:staged -ComponentType "Management" -ExcludeTopLevel @("modules") | Out-Null
            $script:repoNames = @{}
            foreach ($m in @("_TEMPLATE", "zone_base", "dns_records", "cache_rules", "zone_rules")) {
                $script:repoNames[$m] = Expand-RepoNameTemplate -Template "terraform-cloudflare-lz-{module}" -Prefix "cflz" -ModuleName $m
            }
        }

        AfterEach {
            Remove-Item -Path $script:fixture, $script:staged -Recurse -Force
        }

        It "Should repoint every upstream source at its module repository and pin the ref" {
            $result = Set-OrchestrationModuleSource -StagingDirectory $script:staged -ComponentType "Management" `
                -ModuleRepoNames $script:repoNames -Owner "acme" -ModuleSourceRef "v1.2.3"

            @($result.Rewrites).Count | Should -Be 4
            $result.LayerCount | Should -Be 3
            $result.UnknownModules | Should -Be @("retired_module")

            $zones = Get-Content -Path (Join-Path $script:staged "deployment\layers\zones\zones.tf") -Raw
            $zones | Should -Match ([regex]::Escape('  source   = "git::https://github.com/acme/terraform-cloudflare-lz-zone-base.git?ref=v1.2.3"'))
            # The commented example above the block is documentation and is left as written.
            $zones | Should -Match ([regex]::Escape('#   source = "git::https://github.com/yourorg/CloudflareLandingZone//modules/zone_base?ref=v1.0.0"'))
            $zones | Should -Not -Match "`r`n"

            $rules = Get-Content -Path (Join-Path $script:staged "deployment\layers\rules\rules.tf") -Raw
            $rules | Should -Match ([regex]::Escape('"git::https://github.com/acme/terraform-cloudflare-lz-cache-rules.git?ref=v1.2.3"'))
            $rules | Should -Match ([regex]::Escape('"git::https://github.com/acme/terraform-cloudflare-lz-zone-rules.git?ref=v1.2.3"'))

            (Get-Content -Path (Join-Path $script:staged "deployment\layers\dns\dns.tf") -Raw) |
                Should -Match ([regex]::Escape('"git::https://github.com/acme/terraform-cloudflare-lz-dns-records.git?ref=v1.2.3"'))

            # Provider sources and unknown modules are untouched.
            (Get-Content -Path (Join-Path $script:staged "deployment\layers\zones\terraform.tf") -Raw) | Should -Match ([regex]::Escape('source  = "cloudflare/cloudflare"'))
            (Get-Content -Path (Join-Path $script:staged "deployment\layers\legacy\legacy.tf") -Raw) | Should -Match ([regex]::Escape('"../../../modules/retired_module"'))
        }

        It "Should leave a layer's own child modules alone, even when one shares a published module's name" {
            $result = Set-OrchestrationModuleSource -StagingDirectory $script:staged -ComponentType "Management" `
                -ModuleRepoNames $script:repoNames -Owner "acme" -ModuleSourceRef "v1.2.3"

            @($result.Rewrites | Where-Object { $_.File -match 'layers.access.' }) | Should -BeNullOrEmpty
            # Neither child is reported as an unknown upstream module either.
            $result.UnknownModules | Should -Be @("retired_module")

            (Get-Content -Path (Join-Path $script:staged "deployment\layers\access\access.tf") -Raw) |
                Should -Match ([regex]::Escape('source = "./modules/zone_base"'))
            (Get-Content -Path (Join-Path $script:staged "deployment\layers\access\modules\zone_base\main.tf") -Raw) |
                Should -Match ([regex]::Escape('source = "../modules/zone_rules"'))
        }

        It "Should report only references that climb out of the layers tree" {
            $refs = @(Find-LayerModuleReference -LayersDirectory (Join-Path $script:staged "deployment\layers") -KnownModules @($script:repoNames.Keys))
            @($refs | Where-Object { $_.File -match 'layers.access.' }) | Should -BeNullOrEmpty
            @($refs | Where-Object { $_.ModuleName -eq "zone_base" }).Count | Should -Be 1
        }

        It "Should grant modules-auth exactly the module repositories the layers source" {
            $result = Set-OrchestrationModuleSource -StagingDirectory $script:staged -ComponentType "Management" `
                -ModuleRepoNames $script:repoNames -Owner "acme" -ModuleSourceRef "v1.0.0"

            $result.ModulesAuth.Updated | Should -Be $true
            $action = Get-Content -Path (Join-Path $script:staged ".github\actions\modules-auth\action.yml") -Raw
            $action | Should -Match "(?m)^    default: terraform-cloudflare-lz-cache-rules,terraform-cloudflare-lz-dns-records,terraform-cloudflare-lz-zone-base,terraform-cloudflare-lz-zone-rules$"
            $action | Should -Not -Match "cloudflare-platform-modules"
            $action | Should -Not -Match "terraform-cloudflare-lz-template"
        }

        It "Should be idempotent over an already-rewritten tree" {
            Set-OrchestrationModuleSource -StagingDirectory $script:staged -ComponentType "Management" `
                -ModuleRepoNames $script:repoNames -Owner "acme" -ModuleSourceRef "v1.0.0" | Out-Null
            $second = Set-OrchestrationModuleSource -StagingDirectory $script:staged -ComponentType "Management" `
                -ModuleRepoNames $script:repoNames -Owner "acme" -ModuleSourceRef "v9.9.9"

            @($second.Rewrites).Count | Should -Be 0
            (Get-Content -Path (Join-Path $script:staged "deployment\layers\dns\dns.tf") -Raw) | Should -Match "\?ref=v1\.0\.0"
        }

        It "Should pin to each repository's latest tag, or v1.0.0 where there is none yet" {
            $resolver = {
                param($repo)
                switch ($repo) {
                    "terraform-cloudflare-lz-zone-base" { [PSCustomObject]@{ Reachable = $true; Tag = "v1.4.2" } }
                    "terraform-cloudflare-lz-dns-records" { [PSCustomObject]@{ Reachable = $true; Tag = $null } }
                    default { [PSCustomObject]@{ Reachable = $false; Tag = $null } }
                }
            }

            $result = Set-OrchestrationModuleSource -StagingDirectory $script:staged -ComponentType "Management" `
                -ModuleRepoNames $script:repoNames -Owner "acme" -ModuleSourceRef "latest" -ResolveLatestTag $resolver

            $pins = @{}
            foreach ($p in $result.Pins) { $pins[$p.Module] = $p }
            $pins["zone_base"].Ref | Should -Be "v1.4.2"
            $pins["zone_base"].State | Should -Be "latest tag"
            $pins["dns_records"].Ref | Should -Be "v1.0.0"
            $pins["dns_records"].State | Should -Be "awaiting first CI tag"
            $pins["cache_rules"].State | Should -Be "repository not found"
        }

        It "Should repoint a flat deployment repository's layers without touching modules-auth" {
            $flat = New-TestWorkspace
            try {
                Copy-SourceDataAsIs -SourceDirectory (Join-Path $script:fixture "deployment") -DestinationDirectory $flat -ComponentType "Deployment" | Out-Null
                $result = Set-OrchestrationModuleSource -StagingDirectory $flat -ComponentType "Deployment" `
                    -ModuleRepoNames $script:repoNames -Owner "acme" -ModuleSourceRef "v1.0.0"

                @($result.Rewrites).Count | Should -Be 4
                $result.ModulesAuth | Should -BeNullOrEmpty
                (Get-Content -Path (Join-Path $flat "layers\zones\zones.tf") -Raw) | Should -Match "terraform-cloudflare-lz-zone-base\.git\?ref=v1\.0\.0"
            }
            finally {
                Remove-Item -Path $flat -Recurse -Force
            }
        }
    }

    Context "Get-LatestSemVerTag" {
        It "Should return the highest strict vX.Y.Z tag, ignoring anything else" {
            $root = New-TestWorkspace
            try {
                $remote = New-BareRemoteWithTags -Root $root -Name "mod" -Tags @("v1.2.0", "v1.10.0", "v1.9.3", "v2-rc", "release-3", "v0.9.0")
                $info = Get-LatestSemVerTag -WorkingDirectory $root -AuthenticatedUrl $remote
                $info.Reachable | Should -Be $true
                $info.Tag | Should -Be "v1.10.0"
            }
            finally {
                Remove-Item -Path $root -Recurse -Force
            }
        }

        It "Should report a reachable repository with no tags, and an unreachable one" {
            $root = New-TestWorkspace
            try {
                $empty = New-BareRemoteWithTags -Root $root -Name "empty"
                $none = Get-LatestSemVerTag -WorkingDirectory $root -AuthenticatedUrl $empty
                $none.Reachable | Should -Be $true
                $none.Tag | Should -BeNullOrEmpty

                $missing = Get-LatestSemVerTag -WorkingDirectory $root -AuthenticatedUrl (Join-Path $root "does-not-exist.git")
                $missing.Reachable | Should -Be $false
            }
            finally {
                Remove-Item -Path $root -Recurse -Force
            }
        }
    }

    Context "Management repository published to a local bare remote" {
        It "Should publish pipelines, deployment/ and repointed sources, and no modules/" {
            $fixture = New-FixtureMonorepo
            $root = New-TestWorkspace
            try {
                $remote = Join-Path $root "cflz-management.git"
                $staging = Join-Path $root "staging"
                Invoke-GitCommand -WorkingDirectory $root -Arguments @("init", "--bare", "-b", "main", $remote) | Out-Null

                Initialize-StagingRepository -StagingPath $staging -RemoteUrl $remote -AuthenticatedUrl $remote -DefaultBranch "main" | Out-Null
                Copy-SourceDataAsIs -SourceDirectory $fixture -DestinationDirectory $staging -ComponentType "Management" -ExcludeTopLevel @("modules") | Out-Null
                $names = @{ zone_base = "terraform-cloudflare-lz-zone-base"; dns_records = "terraform-cloudflare-lz-dns-records"; cache_rules = "terraform-cloudflare-lz-cache-rules"; zone_rules = "terraform-cloudflare-lz-zone-rules" }
                Set-OrchestrationModuleSource -StagingDirectory $staging -ComponentType "Management" -ModuleRepoNames $names -Owner "acme" -ModuleSourceRef "v1.0.0" | Out-Null
                $agents = Copy-ComponentScaffold -ScaffoldDirectory (Join-Path (Split-Path $PSScriptRoot -Parent) "templates\agents\management") -DestinationDirectory $staging
                Publish-LocalRepository -StagingPath $staging -RemoteUrl $remote -AuthenticatedPushUrl $remote -DefaultBranch "main" -CommitMessage "Initial release" | Out-Null

                # Upstream ships its own AGENTS.md / CLAUDE.md at the root; those win.
                $agents.KeptFromSource | Should -Contain "AGENTS.md"
                (Invoke-GitCommand -WorkingDirectory $remote -Arguments @("show", "main:AGENTS.md")).Output | Should -Be "upstream agent guidance"

                $tree = (Invoke-GitCommand -WorkingDirectory $remote -Arguments @("ls-tree", "-r", "--name-only", "main")).Output -split "`r?`n"
                $tree | Should -Contain ".github/workflows/ci.yml"
                $tree | Should -Contain "deployment/layers/zones/zones.tf"
                $tree | Should -Contain "deployment/accounts/account_a/zones.tfvars"
                @($tree | Where-Object { $_ -like "modules/*" }) | Should -BeNullOrEmpty

                (Invoke-GitCommand -WorkingDirectory $remote -Arguments @("show", "main:deployment/layers/dns/dns.tf")).Output |
                    Should -Match "terraform-cloudflare-lz-dns-records\.git\?ref=v1\.0\.0"
            }
            finally {
                Remove-Item -Path $fixture, $root -Recurse -Force
            }
        }
    }
}

Describe "Organisation Targeting" {
    Context "Get-NewRepositoryPayload" {
        It "Should send the explicit visibility field for organisation repositories" {
            $payload = Get-NewRepositoryPayload -RepoName "cflz-deployment" -OwnerType "Organization" -Visibility "internal"
            $payload.visibility | Should -Be "internal"
            $payload.private | Should -Be $true
            $payload.auto_init | Should -Be $false
        }

        It "Should mark private and public organisation repositories correctly" {
            (Get-NewRepositoryPayload -RepoName "r" -OwnerType "Organization" -Visibility "private").visibility | Should -Be "private"
            (Get-NewRepositoryPayload -RepoName "r" -OwnerType "Organization" -Visibility "private").private | Should -Be $true

            $public = Get-NewRepositoryPayload -RepoName "r" -OwnerType "Organization" -Visibility "public"
            $public.visibility | Should -Be "public"
            $public.private | Should -Be $false
        }

        It "Should omit the visibility field for user repositories" {
            $payload = Get-NewRepositoryPayload -RepoName "r" -OwnerType "User" -Visibility "private"
            $payload.ContainsKey("visibility") | Should -Be $false
            $payload.private | Should -Be $true
        }

        It "Should reject internal visibility on a user account rather than silently creating a private repository" {
            { Get-NewRepositoryPayload -RepoName "r" -OwnerType "User" -Visibility "internal" } |
                Should -Throw -ExpectedMessage "*only available for organisation repositories*"
        }
    }
}

Describe "Release Plan Generation (Dry Run)" {
    BeforeAll {
        $script:planFixture = New-FixtureMonorepo
        # Keep dry runs offline: with no token there is no GitHub API call to resolve the owner.
        # The script re-imports its modules, so a Pester mock would not survive; hiding the gh
        # CLI from PATH does.
        $script:savedEnv = @{ GITHUB_TOKEN = $env:GITHUB_TOKEN; GH_TOKEN = $env:GH_TOKEN; PATH = $env:PATH }
        $env:GITHUB_TOKEN = $null
        $env:GH_TOKEN = $null
        $sep = [System.IO.Path]::PathSeparator
        $env:PATH = (@($env:PATH -split $sep | Where-Object {
                    $_ -and -not (Test-Path -Path (Join-Path $_ "gh.exe")) -and -not (Test-Path -Path (Join-Path $_ "gh"))
                }) -join $sep)

        function Invoke-DryRun {
            param([hashtable]$Arguments = @{})
            & $script:ScriptPath -TargetOwner "test-org" -WhatIf -SourceRoot $script:planFixture @Arguments 6>$null
        }
    }

    AfterAll {
        $env:GITHUB_TOKEN = $script:savedEnv.GITHUB_TOKEN
        $env:GH_TOKEN = $script:savedEnv.GH_TOKEN
        $env:PATH = $script:savedEnv.PATH
        Remove-Item -Path $script:planFixture -Recurse -Force
    }

    Context "Invoke-CloudflareLandingZoneRelease -WhatIf" {
        It "Should plan every module, then the management repository last" {
            $plan = @(Invoke-DryRun)

            $plan.Count | Should -Be 6
            $plan[-1].ComponentType | Should -Be "Management"
            $plan[-1].ComponentName | Should -Be "management"
            $plan[-1].RepoName | Should -Be "cflz-management"
            $plan[-1].RemoteUrl | Should -Be "https://github.com/test-org/cflz-management.git"
            $plan[-1].SourcePath | Should -Be $script:planFixture
            @($plan | Where-Object { $_.ComponentType -eq "Deployment" }) | Should -BeNullOrEmpty

            ($plan | Where-Object { $_.ComponentName -eq "zone_base" }).RepoName | Should -Be "terraform-cloudflare-lz-zone-base"
            ($plan | Where-Object { $_.ComponentName -eq "_TEMPLATE" }).RepoName | Should -Be "terraform-cloudflare-lz-template"
        }

        It "Should plan a flat deployment repository when the layout is Flat" {
            $plan = @(Invoke-DryRun @{ DeploymentLayout = "Flat" })

            $plan.Count | Should -Be 6
            $plan[-1].ComponentType | Should -Be "Deployment"
            $plan[-1].RepoName | Should -Be "cflz-deployment"
            $plan[-1].SourcePath | Should -Be (Join-Path $script:planFixture "deployment")
        }

        It "Should honour module selection and exclusion switches" {
            $modulesOnly = @(Invoke-DryRun @{ OnlyModules = $true; ExcludeModules = "_TEMPLATE" })
            $modulesOnly.Count | Should -Be 4
            @($modulesOnly | Where-Object { $_.ComponentType -ne "Module" }) | Should -BeNullOrEmpty
            @($modulesOnly | Where-Object { $_.ComponentName -eq "_TEMPLATE" }) | Should -BeNullOrEmpty

            $managementOnly = @(Invoke-DryRun @{ OnlyDeployment = $true })
            $managementOnly.Count | Should -Be 1
            $managementOnly[0].ComponentType | Should -Be "Management"

            $selected = @(Invoke-DryRun @{ OnlyModules = $true; Modules = @("zone_base", "dns_records") })
            $selected.Count | Should -Be 2
        }

        It "Should accept -OnlyManagement and -ForceManagementUpdate as aliases" {
            $plan = @(& $script:ScriptPath -TargetOwner "test-org" -WhatIf -SourceRoot $script:planFixture -OnlyManagement -ForceManagementUpdate 6>$null)
            $plan.Count | Should -Be 1
            $plan[0].ComponentType | Should -Be "Management"
        }

        It "Should apply a custom prefix and name templates to the plan" {
            (Invoke-DryRun @{ Prefix = "acme"; Modules = "zone_base"; OnlyModules = $true }).RepoName | Should -Be "terraform-cloudflare-lz-zone-base"
            (Invoke-DryRun @{ Prefix = "acme"; ModuleRepoPattern = "{prefix}-tf-{module}"; Modules = "zone_base"; OnlyModules = $true }).RepoName | Should -Be "acme-tf-zone-base"
            (Invoke-DryRun @{ Prefix = "acme"; ManagementRepoName = "{prefix}-landing-zone"; OnlyDeployment = $true }).RepoName | Should -Be "acme-landing-zone"
            (Invoke-DryRun @{ Prefix = "acme"; DeploymentLayout = "Flat"; DeploymentRepoName = "{prefix}-lz-deploy"; OnlyDeployment = $true }).RepoName | Should -Be "acme-lz-deploy"
        }

        It "Should reject an SSH key path that does not exist" {
            { & $script:ScriptPath -TargetOwner "test-org" -WhatIf -SourceRoot $script:planFixture -GitTransport ssh -SshKeyPath "Z:\no\such\key" 6>$null } |
                Should -Throw -ExpectedMessage "*SSH key not found*"
        }

        It "Should reject an unknown layout from a configuration file" {
            $cfg = Join-Path ([System.IO.Path]::GetTempPath()) "cflz-test-layout-$([guid]::NewGuid()).json"
            try {
                Set-Content -Path $cfg -Value '{ "DeploymentLayout": "Sideways" }'
                { & $script:ScriptPath -TargetOwner "test-org" -WhatIf -SourceRoot $script:planFixture -ConfigFile $cfg 6>$null } |
                    Should -Throw -ExpectedMessage "*DeploymentLayout must be*"
            }
            finally {
                Remove-Item -Path $cfg -Force -ErrorAction SilentlyContinue
            }
        }

        It "Should plan the real upstream checkout with one repository per module plus management" -Skip:$script:NoSourceMonorepo {
            $plan = @(& $script:ScriptPath -TargetOwner "test-org" -WhatIf -SourceRoot $script:SourceMonorepo 6>$null)
            $moduleCount = @(Get-ChildItem -Path (Join-Path $script:SourceMonorepo "modules") -Directory | Where-Object { $_.Name -notlike ".*" }).Count

            $plan.Count | Should -Be ($moduleCount + 1)
            @($plan | Where-Object { $_.ComponentType -eq "Module" }).Count | Should -Be $moduleCount
            $plan[-1].RepoName | Should -Be "cflz-management"
        }
    }
}
