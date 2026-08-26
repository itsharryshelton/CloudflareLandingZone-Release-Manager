<#
.SYNOPSIS
    Test suite for Cloudflare Landing Zone Release Manager.
.DESCRIPTION
    Validates module discovery, configuration parsing, file copy mechanics,
    repository naming, publishing behaviour, and dry-run execution plans.
#>

BeforeAll {
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    $srcDir = Join-Path -Path $repoRoot -ChildPath "src"

    Import-Module (Join-Path -Path $srcDir -ChildPath "UiHelper.psm1") -Force
    Import-Module (Join-Path -Path $srcDir -ChildPath "ConfigManager.psm1") -Force
    Import-Module (Join-Path -Path $srcDir -ChildPath "GitHubApi.psm1") -Force
    Import-Module (Join-Path -Path $srcDir -ChildPath "RepoPublisher.psm1") -Force

    $script:SourceMonorepo = "D:\Git\CloudflareLandingZone\CloudflareLandingZone"

    function New-TestWorkspace {
        $path = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "cflz-test-$([System.Guid]::NewGuid())"
        New-Item -Path $path -ItemType Directory -Force | Out-Null
        return $path
    }
}

Describe "Configuration Manager" {
    Context "Default Configuration" {
        It "Should generate default configuration with expected values" {
            $config = Get-ReleaseDefaultConfig
            $config.Prefix | Should -Be "cflz"
            $config.DeploymentRepoName | Should -Be "{prefix}-deployment"
            $config.ModuleRepoPattern | Should -Be "terraform-cloudflare-lz-{module}"
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
        It "Should resolve the default deployment and module templates" {
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
    Context "Real Source Directory Discovery" {
        It "Should discover deployment directory and all 14 modules" {
            $discovery = Get-SourceDiscovery -SourceRoot $script:SourceMonorepo
            $discovery.HasDeployment | Should -Be $true
            $discovery.Modules.Count | Should -Be 14

            $moduleNames = $discovery.Modules | ForEach-Object { $_.ModuleName }
            $moduleNames | Should -Contain "waf"
            $moduleNames | Should -Contain "gateway"
            $moduleNames | Should -Contain "zerotrust"
            $moduleNames | Should -Contain "r2_bucket"
            $moduleNames | Should -Contain "zone_base"
            $moduleNames | Should -Contain "zone_rules"
            $moduleNames | Should -Contain "_TEMPLATE"
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
                Test-Path -Path "$tempDest\.terraform.lock.hcl" | Should -Be $true
                Test-Path -Path "$tempDest\subdir\helper.tf" | Should -Be $true
                Test-Path -Path "$tempDest\.gitignore" | Should -Be $true

                # Ephemeral and ignored files must NOT be copied
                Test-Path -Path "$tempDest\.terraform" | Should -Be $false
                Test-Path -Path "$tempDest\.git" | Should -Be $false
                Test-Path -Path "$tempDest\terraform.tfstate" | Should -Be $false

                $result.FileCount | Should -Be 3
                $result.Files | Should -Contain "main.tf"
            }
            finally {
                if (Test-Path -Path $tempSource) { Remove-Item -Path $tempSource -Recurse -Force }
                if (Test-Path -Path $tempDest) { Remove-Item -Path $tempDest -Recurse -Force }
            }
        }

        It "Should copy the full deployment tree including account variable files" {
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

    Context "Published .gitignore path correctness" {
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

Describe "Release Plan Generation (Dry Run)" {
    Context "Invoke-CloudflareLandingZoneRelease -WhatIf" {
        It "Should generate execution plan with 15 total repositories (1 deployment + 14 modules)" {
            $scriptPath = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath "Invoke-CloudflareLandingZoneRelease.ps1"
            $plan = & $scriptPath -TargetOwner "test-org" -WhatIf -SourceRoot $script:SourceMonorepo

            $plan | Should -Not -BeNullOrEmpty
            $plan.Count | Should -Be 15

            $deploymentItem = $plan | Where-Object { $_.ComponentType -eq "Deployment" }
            $deploymentItem | Should -Not -BeNullOrEmpty
            $deploymentItem.RepoName | Should -Be "cflz-deployment"
            $deploymentItem.RemoteUrl | Should -Be "https://github.com/test-org/cflz-deployment.git"

            $wafModuleItem = $plan | Where-Object { $_.ComponentName -eq "waf" }
            $wafModuleItem | Should -Not -BeNullOrEmpty
            $wafModuleItem.RepoName | Should -Be "terraform-cloudflare-lz-waf"
            $wafModuleItem.RemoteUrl | Should -Be "https://github.com/test-org/terraform-cloudflare-lz-waf.git"

            $governanceItem = $plan | Where-Object { $_.ComponentName -eq "account_governance" }
            $governanceItem.RepoName | Should -Be "terraform-cloudflare-lz-account-governance"

            $templateItem = $plan | Where-Object { $_.ComponentName -eq "_TEMPLATE" }
            $templateItem.RepoName | Should -Be "terraform-cloudflare-lz-template"
        }

        It "Should honour module selection and exclusion switches" {
            $scriptPath = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath "Invoke-CloudflareLandingZoneRelease.ps1"

            $modulesOnly = & $scriptPath -TargetOwner "test-org" -WhatIf -SourceRoot $script:SourceMonorepo -OnlyModules -ExcludeModules "_TEMPLATE"
            $modulesOnly.Count | Should -Be 13
            ($modulesOnly | Where-Object { $_.ComponentType -eq "Deployment" }) | Should -BeNullOrEmpty
            ($modulesOnly | Where-Object { $_.ComponentName -eq "_TEMPLATE" }) | Should -BeNullOrEmpty

            $deploymentOnly = & $scriptPath -TargetOwner "test-org" -WhatIf -SourceRoot $script:SourceMonorepo -OnlyDeployment
            $deploymentOnly.Count | Should -Be 1
            $deploymentOnly.ComponentType | Should -Be "Deployment"

            $singleModule = & $scriptPath -TargetOwner "test-org" -WhatIf -SourceRoot $script:SourceMonorepo -OnlyModules -Modules "waf", "gateway"
            $singleModule.Count | Should -Be 2
        }

        It "Should apply a custom prefix and module pattern to the plan" {
            $scriptPath = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath "Invoke-CloudflareLandingZoneRelease.ps1"

            $plan = & $scriptPath -TargetOwner "test-org" -WhatIf -SourceRoot $script:SourceMonorepo `
                -Prefix "cflz" -Modules "waf" -OnlyModules

            $plan.RepoName | Should -Be "terraform-cloudflare-lz-waf"

            $custom = & $scriptPath -TargetOwner "test-org" -WhatIf -SourceRoot $script:SourceMonorepo `
                -Prefix "cflzs" -DeploymentRepoName "{prefix}-landing-zone" -ModuleRepoPattern "{prefix}-tf-{module}" -OnlyDeployment

            $custom.RepoName | Should -Be "cflz-landing-zone"
        }
    }
}
