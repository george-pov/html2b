[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [switch] $Push,

    [string] $RegistryName = 'crhtml2bdev',

    [string] $RepositoryName = 'html2b-api'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module `
    (Join-Path $PSScriptRoot 'Html2b.OutputContracts.psm1') `
    -Force

function Resolve-RepositoryRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Invoke-AzureCli {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments,

        [switch] $AllowFailure
    )

    $output = & az @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String).Trim()

    if ($exitCode -ne 0) {
        if ($AllowFailure) {
            return $null
        }

        throw "Azure CLI failed with exit code $exitCode.`n$text"
    }

    return $text
}

function Invoke-Docker {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments,

        [switch] $AllowFailure
    )

    $output = & docker @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String).Trim()

    if ($exitCode -ne 0) {
        if ($AllowFailure) {
            return $null
        }

        throw "Docker failed with exit code $exitCode.`n$text"
    }

    return $text
}

function Get-SourceCommit {
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot
    )

    $commit = (& git -C $RepositoryRoot rev-parse HEAD 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $commit -cnotmatch '^[0-9a-f]{40}$') {
        throw 'Could not resolve a full lowercase Git commit SHA.'
    }

    return $commit
}

function Assert-CleanImageSource {
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot
    )

    $changedInputs = (& git -C $RepositoryRoot diff --name-only HEAD -- src/api 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not compare image inputs with HEAD.'
    }

    if (-not [string]::IsNullOrWhiteSpace($changedInputs)) {
        throw "Image publication requires tracked src/api inputs to match HEAD. Changed inputs:`n$changedInputs"
    }
}

function Get-AvailableTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new(
        [System.Net.IPAddress]::Loopback,
        0)
    try {
        $listener.Start()
        return ([System.Net.IPEndPoint] $listener.LocalEndpoint).Port
    }
    finally {
        $listener.Stop()
    }
}

function Wait-HttpReady {
    param(
        [Parameter(Mandatory)]
        [uri] $Uri,

        [TimeSpan] $Timeout = [TimeSpan]::FromSeconds(90)
    )

    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromSeconds(10)
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        while ($stopwatch.Elapsed -lt $Timeout) {
            try {
                $response = $client.GetAsync($Uri).GetAwaiter().GetResult()
                try {
                    if ([int] $response.StatusCode -eq 200) {
                        return
                    }
                }
                finally {
                    $response.Dispose()
                }
            }
            catch [System.Net.Http.HttpRequestException] {
                # The container may not be listening yet.
            }
            catch [System.Threading.Tasks.TaskCanceledException] {
                # Keep polling within the bounded outer timeout.
            }

            Start-Sleep -Seconds 2
        }
    }
    finally {
        $client.Dispose()
    }

    throw "Timed out waiting for $Uri."
}

function Invoke-LocalContainerValidation {
    param(
        [Parameter(Mandatory)]
        [string] $Image,

        [Parameter(Mandatory)]
        [string] $RepositoryRoot
    )

    $port = Get-AvailableTcpPort
    $containerName = 'html2b-validation-{0}-{1}' -f (
        (Get-SourceCommit -RepositoryRoot $RepositoryRoot).Substring(0, 12)),
        ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $validationDirectory = Join-Path $RepositoryRoot 'build\validation\002\p01\image-local'
    $null = [System.IO.Directory]::CreateDirectory($validationDirectory)

    try {
        $null = Invoke-Docker -Arguments @(
            'run', '--detach',
            '--name', $containerName,
            '--publish', "127.0.0.1:${port}:8080",
            '--stop-timeout', '30',
            $Image
        )
        Wait-HttpReady -Uri "http://127.0.0.1:$port/health/ready"
        $client = [System.Net.Http.HttpClient]::new()
        $client.Timeout = [TimeSpan]::FromSeconds(60)
        try {
            foreach ($healthPath in @('health/live', 'health/ready')) {
                $response = $client.GetAsync("http://127.0.0.1:$port/$healthPath").GetAwaiter().GetResult()
                try {
                    if ([int] $response.StatusCode -ne 200) {
                        throw "$healthPath returned HTTP $([int] $response.StatusCode)."
                    }
                }
                finally {
                    $response.Dispose()
                }
            }

            foreach ($format in @('png', 'jpeg', 'pdf')) {
                $response = $client.PostAsync(
                    "http://127.0.0.1:$port/api/renders/$format",
                    [System.Net.Http.HttpContent] $null).GetAwaiter().GetResult()
                try {
                    if ([int] $response.StatusCode -ne 200) {
                        throw "$format render returned HTTP $([int] $response.StatusCode)."
                    }

                    $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
                    $fileName = Get-Html2bResponseFileName `
                        -Disposition $response.Content.Headers.ContentDisposition `
                        -Format $format
                    $null = Assert-Html2bOutputContract `
                        -Format $format `
                        -Bytes $bytes `
                        -ContentType $response.Content.Headers.ContentType.MediaType `
                        -FileName $fileName

                    $extension = if ($format -eq 'jpeg') { 'jpg' } else { $format }
                    [System.IO.File]::WriteAllBytes(
                        (Join-Path $validationDirectory "html2b-poc.$extension"),
                        $bytes)
                }
                finally {
                    $response.Dispose()
                }
            }
        }
        finally {
            $client.Dispose()
        }

        $configuredUser = Invoke-Docker -Arguments @(
            'inspect', '--format', '{{.Config.User}}', $containerName)
        if ($configuredUser -ne 'pwuser') {
            throw "Container runs as '$configuredUser' instead of pwuser."
        }

        $entryPoint = Invoke-Docker -Arguments @(
            'inspect', '--format', '{{.Path}}', $containerName)
        if ($entryPoint -ne '/usr/bin/tini') {
            throw "Container PID 1 entry point is '$entryPoint' instead of /usr/bin/tini."
        }

        $runtimeUserId = Invoke-Docker -Arguments @(
            'exec', $containerName, 'id', '-u')
        if ($runtimeUserId -notmatch '^\d+$' -or [int] $runtimeUserId -eq 0) {
            throw "Container runtime user ID '$runtimeUserId' is not a non-root UID."
        }

        $pidOneProcess = Invoke-Docker -Arguments @(
            'exec', $containerName, 'cat', '/proc/1/comm')
        if ($pidOneProcess -ne 'tini') {
            throw "Container PID 1 process is '$pidOneProcess' instead of tini."
        }

        $shutdown = [System.Diagnostics.Stopwatch]::StartNew()
        $null = Invoke-Docker -Arguments @('stop', '--time', '30', $containerName)
        $shutdown.Stop()
        if ($shutdown.Elapsed -gt [TimeSpan]::FromSeconds(35)) {
            throw "Container shutdown exceeded 35 seconds: $($shutdown.Elapsed)."
        }
    }
    finally {
        $existingContainer = Invoke-Docker -AllowFailure -Arguments @(
            'container', 'inspect', '--format', '{{.Id}}', $containerName)
        if (-not [string]::IsNullOrWhiteSpace($existingContainer)) {
            $null = Invoke-Docker -Arguments @('rm', '--force', $containerName)
        }
    }
}

function Resolve-PushedImageDigest {
    param(
        [Parameter(Mandatory)]
        [string] $Registry,

        [Parameter(Mandatory)]
        [string] $Repository,

        [Parameter(Mandatory)]
        [string] $Tag
    )

    $metadataJson = Invoke-AzureCli -Arguments @(
        'acr', 'manifest', 'show-metadata',
        '--registry', $Registry,
        '--name', "${Repository}:$Tag",
        '--only-show-errors',
        '--output', 'json'
    )
    $metadata = $metadataJson | ConvertFrom-Json
    $digest = [string] $metadata.digest
    if ($digest -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'ACR returned an invalid manifest digest.'
    }

    $observedTags = if ($metadata.PSObject.Properties.Name -contains 'tags') {
        @($metadata.tags)
    }
    else {
        @([string] $metadata.name)
    }
    if ($observedTags -notcontains $Tag) {
        throw "ACR manifest $digest is not tagged with the source commit $Tag."
    }

    return $digest
}

if ($RegistryName -ne 'crhtml2bdev' -or $RepositoryName -ne 'html2b-api') {
    throw 'This feature is limited to crhtml2bdev.azurecr.io/html2b-api.'
}

if ($Push -and
    $PSBoundParameters.ContainsKey('Confirm') -and
    -not [bool] $PSBoundParameters['Confirm']) {
    throw 'Image publication rejects -Confirm:$false. Interactive confirmation is required.'
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'Docker is required.'
}

$repositoryRoot = Resolve-RepositoryRoot
$sourceCommit = Get-SourceCommit -RepositoryRoot $repositoryRoot
Assert-CleanImageSource -RepositoryRoot $repositoryRoot

$null = Invoke-Docker -Arguments @('info', '--format', '{{.ServerVersion}}')
$imageReference = "${RegistryName}.azurecr.io/${RepositoryName}:$sourceCommit"
$dockerfile = Join-Path $repositoryRoot 'src\api\Html2b.WebApi\Dockerfile'
Write-Host "Building and validating $imageReference"
$null = Invoke-Docker -Arguments @(
    'build',
    '--file', $dockerfile,
    '--tag', $imageReference,
    $repositoryRoot
)
Invoke-LocalContainerValidation -Image $imageReference -RepositoryRoot $repositoryRoot

if (-not $Push) {
    Write-Output "imageTag=$imageReference"
    return
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required for image publication.'
}

$accountJson = Invoke-AzureCli -Arguments @(
    'account', 'show',
    '--query', '{name:name,id:id,tenantId:tenantId,state:state}',
    '--output', 'json'
)
$account = $accountJson | ConvertFrom-Json
if ($account.state -ne 'Enabled') {
    throw 'The selected Azure subscription is not enabled.'
}

$registryLoginServer = Invoke-AzureCli -Arguments @(
    'acr', 'show',
    '--name', $RegistryName,
    '--resource-group', 'rg-html2b-dev',
    '--query', 'loginServer',
    '--output', 'tsv'
)
if ($registryLoginServer -ne "${RegistryName}.azurecr.io") {
    throw "Registry login server '$registryLoginServer' does not match the approved target."
}

$existingDigest = Invoke-AzureCli -AllowFailure -Arguments @(
    'acr', 'manifest', 'show-metadata',
        '--registry', $RegistryName,
        '--name', "${RepositoryName}:$sourceCommit",
        '--query', 'digest',
        '--only-show-errors',
        '--output', 'tsv'
    )
if (-not [string]::IsNullOrWhiteSpace($existingDigest)) {
    throw "The immutable commit tag already exists as $existingDigest; refusing to retag it."
}

Write-Host "Registry: $RegistryName ($registryLoginServer)"
Write-Host "Repository: $RepositoryName"
Write-Host "Tag: $sourceCommit"
Write-Host "Subscription: $($account.name) ($($account.id))"
Write-Host 'The pushed ACR artifact is retained and may incur charges.'

if (-not $PSCmdlet.ShouldProcess(
        $imageReference,
        'Authenticate with the current Entra identity and push this retained ACR artifact')) {
    return
}

$null = Invoke-AzureCli -Arguments @('acr', 'login', '--name', $RegistryName)
$null = Invoke-Docker -Arguments @('push', $imageReference)
$digest = Resolve-PushedImageDigest `
    -Registry $RegistryName `
    -Repository $RepositoryName `
    -Tag $sourceCommit

Write-Output "containerImage=${RegistryName}.azurecr.io/${RepositoryName}@$digest"
