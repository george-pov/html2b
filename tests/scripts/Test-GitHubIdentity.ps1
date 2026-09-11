[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$scriptPath = Join-Path `
    $repositoryRoot `
    'scripts\azure\Set-GitHubIdentity.ps1'
$pwshPath = (Get-Command pwsh -CommandType Application |
    Select-Object -First 1).Source
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$tempRoot = [IO.Path]::GetFullPath((Join-Path `
    $tempBase `
    "html2b-id-test-$([guid]::NewGuid().ToString('N'))"))
$clientId = '11111111-2222-4333-8444-555555555555'
$subscriptionId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
$repository = 'example/html2b'
$environmentName = 'dev'

function Assert-Condition {
    param(
        [Parameter(Mandatory)]
        [bool] $Condition,

        [Parameter(Mandatory)]
        [string] $Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function New-FakeCommands {
    param(
        [Parameter(Mandatory)]
        [string] $BinDir,

        [Parameter(Mandatory)]
        [string] $Case
    )

    if ($Case -cne 'missing_az') {
        @'
$line = 'az ' + ($args -join ' ')
Add-Content -LiteralPath $env:FAKE_LOG -Value $line

if ($env:FAKE_CASE -ceq 'native_fail' -and
    $args[0] -ceq 'account') {
    exit 19
}
if ($args[0] -ceq 'account') {
    $state = if ($env:FAKE_CASE -ceq 'azure_disabled') {
        'Disabled'
    }
    else {
        'Enabled'
    }
    $id = if ($env:FAKE_CASE -ceq 'azure_mismatch') {
        'bbbbbbbb-cccc-4ddd-8eee-ffffffffffff'
    }
    else {
        $env:FAKE_SUBSCRIPTION
    }
    @{ id = $id; state = $state } | ConvertTo-Json -Compress
    exit 0
}
if ($args[0] -ceq 'identity') {
    if ($env:FAKE_CASE -ceq 'missing_identity') {
        @() | ConvertTo-Json -Compress
    }
    elseif ($env:FAKE_CASE -ceq 'duplicate_identity') {
        @(
            @{ name = 'id-html2b-dev'; clientId = $env:FAKE_CLIENT_ID }
            @{ name = 'id-html2b-dev'; clientId = $env:FAKE_CLIENT_ID }
        ) | ConvertTo-Json -Compress
    }
    else {
        $id = if ($env:FAKE_CASE -ceq 'bad_client_id') {
            'not-a-guid'
        }
        else {
            $env:FAKE_CLIENT_ID
        }
        @(@{ name = 'id-html2b-dev'; clientId = $id }) |
            ConvertTo-Json -Compress
    }
    exit 0
}
exit 29
'@ | Set-Content -LiteralPath (Join-Path $BinDir 'az.ps1')
    }

    if ($Case -cne 'missing_gh') {
        @'
$line = 'gh ' + ($args -join ' ')
Add-Content -LiteralPath $env:FAKE_LOG -Value $line

if ($args[0] -ceq 'repo') {
    if ($env:FAKE_CASE -ceq 'repo_mismatch') {
        'other/html2b'
    }
    else {
        $env:FAKE_REPOSITORY
    }
    exit 0
}
if ($args[0] -ceq 'api') {
    if ($env:FAKE_CASE -ceq 'missing_env') {
        exit 7
    }
    $env:FAKE_ENVIRONMENT
    exit 0
}
if ($args[0] -ceq 'variable' -and $args[1] -ceq 'set') {
    if ($env:FAKE_CASE -ceq 'write_fail') {
        exit 9
    }
    exit 0
}
if ($args[0] -ceq 'variable' -and $args[1] -ceq 'get') {
    if ($env:FAKE_CASE -ceq 'read_mismatch') {
        '99999999-8888-4777-8666-555555555555'
    }
    else {
        $env:FAKE_CLIENT_ID
    }
    exit 0
}
exit 39
'@ | Set-Content -LiteralPath (Join-Path $BinDir 'gh.ps1')
    }
}

function Invoke-TestCase {
    param(
        [Parameter(Mandatory)]
        [string] $Case
    )

    $caseDir = Join-Path $tempRoot $Case
    $binDir = Join-Path $caseDir 'bin'
    $logPath = Join-Path $caseDir 'calls.log'
    $null = New-Item -ItemType Directory -Path $binDir -Force
    $null = New-Item -ItemType File -Path $logPath -Force
    New-FakeCommands -BinDir $binDir -Case $Case

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pwshPath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @(
            '-NoLogo', '-NoProfile', '-File', $scriptPath,
            '-SubscriptionId', $subscriptionId,
            '-ResourceGroupName', 'rg-html2b-dev',
            '-DeploymentIdentityName', 'id-html2b-dev',
            '-Repository', $repository,
            '-EnvironmentName', $environmentName)) {
        $null = $startInfo.ArgumentList.Add($argument)
    }
    $startInfo.Environment['PATH'] = $binDir
    $startInfo.Environment['FAKE_CASE'] = $Case
    $startInfo.Environment['FAKE_LOG'] = $logPath
    $startInfo.Environment['FAKE_CLIENT_ID'] = $clientId
    $startInfo.Environment['FAKE_SUBSCRIPTION'] = $subscriptionId
    $startInfo.Environment['FAKE_REPOSITORY'] = $repository
    $startInfo.Environment['FAKE_ENVIRONMENT'] = $environmentName

    $process = [Diagnostics.Process]::Start($startInfo)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $calls = @(Get-Content -LiteralPath $logPath)

    return [pscustomobject] @{
        ExitCode = $process.ExitCode
        Output = "$stdout$stderr"
        Calls = $calls
        Writes = @($calls | Where-Object {
                $_ -like 'gh variable set AZURE_INFRA_CLIENT_ID *'
            })
    }
}

try {
    Assert-Condition `
        -Condition $tempRoot.StartsWith(
            $tempBase, [StringComparison]::OrdinalIgnoreCase) `
        -Message 'Test temporary directory escaped the system temporary path.'
    $null = New-Item -ItemType Directory -Path $tempRoot

    $preflightCases = @(
        'missing_az'
        'missing_gh'
        'azure_disabled'
        'azure_mismatch'
        'repo_mismatch'
        'missing_env'
        'missing_identity'
        'duplicate_identity'
        'bad_client_id'
        'native_fail'
    )
    foreach ($case in $preflightCases) {
        $result = Invoke-TestCase -Case $case
        Assert-Condition `
            -Condition ($result.ExitCode -ne 0) `
            -Message "Case '$case' unexpectedly succeeded."
        Assert-Condition `
            -Condition ($result.Writes.Count -eq 0) `
            -Message "Case '$case' wrote the GitHub variable before preflight passed."
    }

    $writeFail = Invoke-TestCase -Case 'write_fail'
    Assert-Condition `
        -Condition ($writeFail.ExitCode -ne 0 -and
            $writeFail.Writes.Count -eq 1) `
        -Message 'Failed GitHub writes must stop after the one intended write.'

    $readMismatch = Invoke-TestCase -Case 'read_mismatch'
    Assert-Condition `
        -Condition ($readMismatch.ExitCode -ne 0 -and
            $readMismatch.Writes.Count -eq 1 -and
            $readMismatch.Output.Contains('readback did not match')) `
        -Message 'Mismatched GitHub readback was not detected.'

    $success = Invoke-TestCase -Case 'success'
    $expectedWrite = "gh variable set AZURE_INFRA_CLIENT_ID --repo $repository " +
        "--env $environmentName --body $clientId"
    Assert-Condition `
        -Condition ($success.ExitCode -eq 0 -and
            $success.Writes.Count -eq 1 -and
            $success.Writes[0] -ceq $expectedWrite) `
        -Message 'Success did not perform the one exact Environment variable write.'
    Assert-Condition `
        -Condition (@($success.Calls | Where-Object {
                    $_ -like 'gh variable get AZURE_INFRA_CLIENT_ID *'
                }).Count -eq 1) `
        -Message 'Success did not verify the Environment variable readback.'

    Write-Host 'GitHub identity link contracts passed.'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        $resolvedRoot = [IO.Path]::GetFullPath($tempRoot)
        if (-not $resolvedRoot.StartsWith(
                $tempBase, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Refusing to remove a temporary directory outside the temp path.'
        }
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
