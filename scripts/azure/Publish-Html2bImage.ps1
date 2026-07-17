[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [switch] $Push,

    [string] $RegistryName = 'crhtml2bdev',

    [string] $RepositoryName = 'html2b-api'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Get-BigEndianUInt16 {
    param(
        [byte[]] $Bytes,
        [int] $Offset
    )

    return ([int] $Bytes[$Offset] -shl 8) -bor [int] $Bytes[$Offset + 1]
}

function Get-BigEndianUInt32 {
    param(
        [byte[]] $Bytes,
        [int] $Offset
    )

    return ([int64] $Bytes[$Offset] -shl 24) -bor
        ([int64] $Bytes[$Offset + 1] -shl 16) -bor
        ([int64] $Bytes[$Offset + 2] -shl 8) -bor
        [int64] $Bytes[$Offset + 3]
}

function Assert-LocalOutputContract {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('png', 'jpeg', 'pdf')]
        [string] $Format,

        [Parameter(Mandatory)]
        [byte[]] $Bytes,

        [Parameter(Mandatory)]
        [string] $ContentType,

        [Parameter(Mandatory)]
        [string] $FileName
    )

    $expectedContentType = @{
        png = 'image/png'
        jpeg = 'image/jpeg'
        pdf = 'application/pdf'
    }[$Format]
    $expectedFileName = @{
        png = 'html2b-poc.png'
        jpeg = 'html2b-poc.jpg'
        pdf = 'html2b-poc.pdf'
    }[$Format]

    if ($ContentType -ne $expectedContentType) {
        throw "$Format returned content type '$ContentType' instead of '$expectedContentType'."
    }

    if ($FileName.Trim('"') -ne $expectedFileName) {
        throw "$Format returned filename '$FileName' instead of '$expectedFileName'."
    }

    if ($Format -eq 'png') {
        $signature = [byte[]] @(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)
        for ($index = 0; $index -lt $signature.Length; $index++) {
            if ($Bytes[$index] -ne $signature[$index]) {
                throw 'PNG signature validation failed.'
            }
        }

        $width = Get-BigEndianUInt32 -Bytes $Bytes -Offset 16
        $height = Get-BigEndianUInt32 -Bytes $Bytes -Offset 20
        if ($width -ne 1280 -or $height -ne 720) {
            throw "PNG dimensions were ${width}x${height}, expected 1280x720."
        }
    }
    elseif ($Format -eq 'jpeg') {
        if ($Bytes.Length -lt 4 -or
            $Bytes[0] -ne 0xff -or
            $Bytes[1] -ne 0xd8 -or
            $Bytes[-2] -ne 0xff -or
            $Bytes[-1] -ne 0xd9) {
            throw 'JPEG signature validation failed.'
        }

        $offset = 2
        $width = 0
        $height = 0
        $startOfFrameMarkers = @(0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf)
        while ($offset + 8 -lt $Bytes.Length) {
            if ($Bytes[$offset] -ne 0xff) {
                $offset++
                continue
            }

            while ($offset -lt $Bytes.Length -and $Bytes[$offset] -eq 0xff) {
                $offset++
            }

            if ($offset -ge $Bytes.Length) {
                break
            }

            $marker = $Bytes[$offset]
            $offset++
            if ($marker -eq 0xd8 -or $marker -eq 0xd9 -or ($marker -ge 0xd0 -and $marker -le 0xd7)) {
                continue
            }

            $segmentLength = Get-BigEndianUInt16 -Bytes $Bytes -Offset $offset
            if ($startOfFrameMarkers -contains $marker) {
                $height = Get-BigEndianUInt16 -Bytes $Bytes -Offset ($offset + 3)
                $width = Get-BigEndianUInt16 -Bytes $Bytes -Offset ($offset + 5)
                break
            }

            $offset += $segmentLength
        }

        if ($width -ne 1280 -or $height -ne 720) {
            throw "JPEG dimensions were ${width}x${height}, expected 1280x720."
        }
    }
    else {
        $header = [System.Text.Encoding]::ASCII.GetString($Bytes, 0, [Math]::Min(5, $Bytes.Length))
        if ($header -ne '%PDF-') {
            throw 'PDF signature validation failed.'
        }

        $pdfText = [System.Text.Encoding]::ASCII.GetString($Bytes)
        $mediaBoxes = [regex]::Matches(
            $pdfText,
            '/MediaBox\s*\[\s*([-+]?\d*\.?\d+)\s+([-+]?\d*\.?\d+)\s+([-+]?\d*\.?\d+)\s+([-+]?\d*\.?\d+)\s*\]')
        $validMediaBox = $false
        foreach ($mediaBox in $mediaBoxes) {
            $values = 1..4 | ForEach-Object {
                [double]::Parse(
                    $mediaBox.Groups[$_].Value,
                    [System.Globalization.CultureInfo]::InvariantCulture)
            }
            if ([Math]::Abs($values[0]) -lt 0.1 -and
                [Math]::Abs($values[1]) -lt 0.1 -and
                [Math]::Abs($values[2] - 960) -lt 0.1 -and
                [Math]::Abs($values[3] - 540) -lt 0.1) {
                $validMediaBox = $true
                break
            }
        }

        if (-not $validMediaBox) {
            throw 'PDF page box validation failed; expected 960 by 540 points.'
        }
    }
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
                    $disposition = $response.Content.Headers.ContentDisposition
                    if ($null -eq $disposition) {
                        throw "$format render omitted Content-Disposition."
                    }

                    $fileName = if (-not [string]::IsNullOrWhiteSpace($disposition.FileNameStar)) {
                        $disposition.FileNameStar
                    }
                    else {
                        $disposition.FileName
                    }
                    Assert-LocalOutputContract `
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
