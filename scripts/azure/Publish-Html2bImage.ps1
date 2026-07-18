[CmdletBinding()]
param(
    [ValidatePattern('^[a-z0-9]{5,50}$')]
    [string] $RegistryName = 'crhtml2bdev',

    [ValidatePattern('^[a-z0-9]+(?:[._/-][a-z0-9]+)*$')]
    [string] $RepositoryName = 'html2b-render',

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $SourceCommit,

    [switch] $Push,

    [string] $PreviewManifestPath = '',

    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string] $ApplicationDeploymentClientId = '',

    [string] $OrasPath = 'oras',

    [string] $OutputDirectory = 'build/deployment/004'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepositoryRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
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

function Invoke-DockerBuildx {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments
    )

    return Invoke-Docker -Arguments (@('buildx') + $Arguments)
}

function Invoke-AzureCli {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments
    )

    $output = & az @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $commandLabel = (@($Arguments | Select-Object -First 3) -join ' ')
        throw "Azure CLI command '$commandLabel' failed with exit code $exitCode. Output was suppressed."
    }

    return ($output | Out-String).Trim()
}

function Invoke-Oras {
    param(
        [Parameter(Mandatory)]
        [string] $Executable,

        [Parameter(Mandatory)]
        [string[]] $Arguments,

        [switch] $AllowNotFound
    )

    $output = & $Executable @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String).Trim()
    if ($exitCode -ne 0) {
        if ($AllowNotFound -and
            $text -match '(?i)(manifest_unknown|name_unknown|not found|status code 404)') {
            return $null
        }

        $commandLabel = (@($Arguments | Select-Object -First 2) -join ' ')
        throw "ORAS command '$commandLabel' failed with exit code $exitCode. Output was suppressed."
    }

    return $text
}

function Assert-OrasVersion {
    param(
        [Parameter(Mandatory)]
        [string] $Executable
    )

    if (-not (Get-Command $Executable -ErrorAction SilentlyContinue)) {
        throw 'ORAS v1.3.3 is required for Render publication.'
    }

    $version = Invoke-Oras -Executable $Executable -Arguments @('version')
    if ($version -notmatch '(?m)^Version:\s*1\.3\.3\s*$') {
        throw 'Render publication requires exactly ORAS v1.3.3.'
    }
}

function Assert-AcrLoginContext {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $ExpectedApplicationClientId
    )

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI is required for Render publication.'
    }
    if ($ExpectedApplicationClientId -notmatch '^[0-9a-fA-F-]{36}$') {
        throw 'ApplicationDeploymentClientId is required for Render publication.'
    }

    $account = Invoke-AzureCli -Arguments @(
        'account', 'show',
        '--query', '{state:state,userType:user.type,userName:user.name}',
        '--output', 'json',
        '--only-show-errors'
    ) | ConvertFrom-Json
    if ($account.state -ne 'Enabled' -or
        $account.userType -ne 'servicePrincipal' -or
        ([string] $account.userName).ToLowerInvariant() -ne
        $ExpectedApplicationClientId.ToLowerInvariant()) {
        throw 'Render publication requires the exact application deployment identity.'
    }

    $identity = Invoke-AzureCli -Arguments @(
        'identity', 'show',
        '--resource-group', 'rg-html2b-dev',
        '--name', 'id-html2b-application-deploy-dev',
        '--query', '{clientId:clientId,principalId:principalId}',
        '--output', 'json',
        '--only-show-errors'
    ) | ConvertFrom-Json
    if ([string] $identity.clientId -notmatch '^[0-9a-fA-F-]{36}$' -or
        ([string] $identity.clientId).ToLowerInvariant() -ne
        $ExpectedApplicationClientId.ToLowerInvariant() -or
        [string] $identity.principalId -notmatch '^[0-9a-fA-F-]{36}$') {
        throw 'ApplicationDeploymentClientId does not match the Bicep-owned identity.'
    }

    $registry = Invoke-AzureCli -Arguments @(
        'acr', 'show',
        '--name', 'crhtml2bdev',
        '--query', '{name:name,loginServer:loginServer,adminUserEnabled:adminUserEnabled,roleAssignmentMode:roleAssignmentMode}',
        '--output', 'json',
        '--only-show-errors'
    ) | ConvertFrom-Json
    if ($registry.name -ne 'crhtml2bdev' -or
        $registry.loginServer -ne 'crhtml2bdev.azurecr.io' -or
        [bool] $registry.adminUserEnabled -or
        $registry.roleAssignmentMode -ne 'AbacRepositoryPermissions') {
        throw 'ACR login context does not match the exact secretless ABAC registry.'
    }
}

function Get-ExistingCommitTagDigest {
    param(
        [Parameter(Mandatory)]
        [string] $Executable,

        [Parameter(Mandatory)]
        [string] $CommitTag
    )

    $digest = Invoke-Oras `
        -Executable $Executable `
        -Arguments @('resolve', $CommitTag) `
        -AllowNotFound
    if ([string]::IsNullOrWhiteSpace($digest)) {
        return ''
    }
    if ($digest -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'Existing Render commit tag resolved to an invalid digest.'
    }

    return $digest
}

function Assert-CommitTagIsImmutable {
    param(
        [AllowEmptyString()]
        [string] $ExistingDigest,

        [Parameter(Mandatory)]
        [string] $PreviewDigest
    )

    if ($PreviewDigest -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'Preview Render digest is invalid.'
    }
    if ([string]::IsNullOrWhiteSpace($ExistingDigest)) {
        return $false
    }
    if ($ExistingDigest -cne $PreviewDigest) {
        throw 'The existing full-SHA Render tag points to a conflicting digest.'
    }

    return $true
}

function Push-RenderOciLayout {
    param(
        [Parameter(Mandatory)]
        [string] $Executable,

        [Parameter(Mandatory)]
        [string] $OciLayoutPath,

        [Parameter(Mandatory)]
        [string] $SourceCommit,

        [Parameter(Mandatory)]
        [string] $CommitTag
    )

    if (-not (Test-Path -LiteralPath (Join-Path $OciLayoutPath 'index.json') -PathType Leaf)) {
        throw 'The retained OCI layout is missing index.json.'
    }

    $null = Invoke-Oras -Executable $Executable -Arguments @(
        'cp',
        '--from-oci-layout',
        "${OciLayoutPath}:$SourceCommit",
        $CommitTag
    )
}

function Resolve-PushedImageDigest {
    param(
        [Parameter(Mandatory)]
        [string] $Executable,

        [Parameter(Mandatory)]
        [string] $CommitTag,

        [Parameter(Mandatory)]
        [string] $ExpectedDigest
    )

    $digest = Invoke-Oras -Executable $Executable -Arguments @('resolve', $CommitTag)
    if ($digest -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'Published Render commit tag resolved to an invalid digest.'
    }
    if ($digest -cne $ExpectedDigest) {
        throw 'Published Render digest differs from the retained preview digest.'
    }

    return $digest
}

function Get-SourceCommit {
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot
    )

    $commit = (& git -C $RepositoryRoot rev-parse HEAD 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $commit -cnotmatch '^[0-9a-f]{40}$') {
        throw 'Could not resolve a full lowercase Git commit SHA.'
    }

    return $commit
}

function Assert-CleanRenderSource {
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [Parameter(Mandatory)]
        [string] $ExpectedCommit
    )

    if ((Get-SourceCommit -RepositoryRoot $RepositoryRoot) -cne $ExpectedCommit) {
        throw 'SourceCommit must equal the checked-out full HEAD commit.'
    }

    $renderInputs = @(
        '.dockerignore',
        'src/api/Html2b.Domain',
        'src/api/Html2b.Application',
        'src/api/Html2b.Contracts',
        'src/api/Html2b.Render'
    )
    $status = (& git -C $RepositoryRoot status --porcelain --untracked-files=all -- @renderInputs 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not compare Render inputs with SourceCommit.'
    }

    if (-not [string]::IsNullOrWhiteSpace($status)) {
        throw 'Render build inputs must be committed in SourceCommit.'
    }
}

function Resolve-RenderOutputDirectory {
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [Parameter(Mandatory)]
        [string] $RequestedPath,

        [Parameter(Mandatory)]
        [string] $SourceCommit
    )

    $basePath = if ([System.IO.Path]::IsPathRooted($RequestedPath)) {
        [System.IO.Path]::GetFullPath($RequestedPath)
    }
    else {
        [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot $RequestedPath))
    }

    $buildRoot = [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'build'))
    if (-not $basePath.StartsWith("$buildRoot$([System.IO.Path]::DirectorySeparatorChar)", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'OutputDirectory must remain beneath the repository build directory.'
    }

    $renderPath = Join-Path (Join-Path $basePath $SourceCommit) 'render'
    $null = New-Item -ItemType Directory -Force -Path $renderPath
    return $renderPath
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
    $client.Timeout = [TimeSpan]::FromSeconds(5)
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
                # The bounded readiness loop handles startup races.
            }
            catch [System.Threading.Tasks.TaskCanceledException] {
                # The bounded readiness loop handles individual request timeouts.
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
    param([byte[]] $Bytes, [int] $Offset)
    return ([int] $Bytes[$Offset] -shl 8) -bor [int] $Bytes[$Offset + 1]
}

function Get-BigEndianUInt32 {
    param([byte[]] $Bytes, [int] $Offset)
    return ([int64] $Bytes[$Offset] -shl 24) -bor
        ([int64] $Bytes[$Offset + 1] -shl 16) -bor
        ([int64] $Bytes[$Offset + 2] -shl 8) -bor
        [int64] $Bytes[$Offset + 3]
}

function Assert-RenderOutputContract {
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

    if ($ContentType -ne $expectedContentType -or $FileName.Trim('"') -ne $expectedFileName) {
        throw "$Format output headers do not match the Render contract."
    }

    if ($Format -eq 'png') {
        $signature = [byte[]] @(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)
        for ($index = 0; $index -lt $signature.Length; $index++) {
            if ($Bytes[$index] -ne $signature[$index]) {
                throw 'PNG signature validation failed.'
            }
        }

        if ((Get-BigEndianUInt32 -Bytes $Bytes -Offset 16) -ne 1280 -or
            (Get-BigEndianUInt32 -Bytes $Bytes -Offset 20) -ne 720) {
            throw 'PNG dimensions are not 1280x720.'
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
            throw 'JPEG dimensions are not 1280x720.'
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
            throw 'PDF page box is not 960x540 points.'
        }
    }
}

function Invoke-LocalRenderValidation {
    param(
        [Parameter(Mandatory)]
        [string] $Image,

        [Parameter(Mandatory)]
        [string] $SourceCommit
    )

    $port = Get-AvailableTcpPort
    $containerName = "html2b-render-$($SourceCommit.Substring(0, 12))-$([guid]::NewGuid().ToString('N').Substring(0, 8))"

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
            foreach ($health in @(
                    @{ Path = 'health/live'; Status = 'live' },
                    @{ Path = 'health/ready'; Status = 'ready' })) {
                $response = $client.GetAsync("http://127.0.0.1:$port/$($health.Path)").GetAwaiter().GetResult()
                try {
                    if ([int] $response.StatusCode -ne 200) {
                        throw "$($health.Path) returned HTTP $([int] $response.StatusCode)."
                    }
                    $payload = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
                    if ($payload.status -ne $health.Status) {
                        throw "$($health.Path) returned unexpected readiness state."
                    }
                }
                finally {
                    $response.Dispose()
                }
            }

            foreach ($format in @('png', 'jpeg', 'pdf')) {
                $content = [System.Net.Http.StringContent]::new(
                    (@{ format = $format } | ConvertTo-Json -Compress),
                    [System.Text.Encoding]::UTF8,
                    'application/json')
                try {
                    $response = $client.PostAsync(
                        "http://127.0.0.1:$port/internal/renders",
                        $content).GetAwaiter().GetResult()
                    try {
                        if ([int] $response.StatusCode -ne 200) {
                            throw "$format render returned HTTP $([int] $response.StatusCode)."
                        }

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
                        Assert-RenderOutputContract `
                            -Format $format `
                            -Bytes ($response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()) `
                            -ContentType $response.Content.Headers.ContentType.MediaType `
                            -FileName $fileName
                    }
                    finally {
                        $response.Dispose()
                    }
                }
                finally {
                    $content.Dispose()
                }
            }
        }
        finally {
            $client.Dispose()
        }

        if ((Invoke-Docker -Arguments @('inspect', '--format', '{{.Config.User}}', $containerName)) -ne 'pwuser') {
            throw 'Render container is not configured to run as pwuser.'
        }
        if ((Invoke-Docker -Arguments @('exec', $containerName, 'id', '-u')) -eq '0') {
            throw 'Render container process is running as root.'
        }
        if ((Invoke-Docker -Arguments @('exec', $containerName, 'cat', '/proc/1/comm')) -ne 'tini') {
            throw 'Render container does not run tini as PID 1.'
        }

        $shutdown = [System.Diagnostics.Stopwatch]::StartNew()
        $null = Invoke-Docker -Arguments @('stop', '--time', '30', $containerName)
        $shutdown.Stop()
        if ($shutdown.Elapsed -gt [TimeSpan]::FromSeconds(35)) {
            throw 'Render container graceful stop exceeded 35 seconds.'
        }
    }
    finally {
        $containerId = Invoke-Docker -AllowFailure -Arguments @(
            'container', 'inspect', '--format', '{{.Id}}', $containerName)
        if (-not [string]::IsNullOrWhiteSpace($containerId)) {
            $null = Invoke-Docker -Arguments @('rm', '--force', $containerName)
        }
    }
}

function Build-RenderOciLayout {
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [Parameter(Mandatory)]
        [string] $ImageReference,

        [Parameter(Mandatory)]
        [string] $OciLayoutPath
    )

    $dockerfile = Join-Path $RepositoryRoot 'src/api/Html2b.Render/Dockerfile'
    $commonArguments = @(
        '--file', $dockerfile,
        '--platform', 'linux/amd64',
        '--provenance=false',
        '--sbom=false',
        '--build-arg', 'BUILD_CONFIGURATION=Release',
        $RepositoryRoot
    )

    $null = Invoke-DockerBuildx -Arguments (@(
        'build',
        '--load',
        '--tag', $ImageReference
    ) + $commonArguments)

    if (Test-Path -LiteralPath $OciLayoutPath) {
        $resolvedLayoutPath = [System.IO.Path]::GetFullPath($OciLayoutPath)
        if (-not $resolvedLayoutPath.Contains(
                "$([System.IO.Path]::DirectorySeparatorChar)build$([System.IO.Path]::DirectorySeparatorChar)",
                [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'Refusing to replace an OCI layout outside build.'
        }
        Remove-Item -LiteralPath $resolvedLayoutPath -Recurse -Force
    }

    $null = Invoke-DockerBuildx -Arguments (@(
        'build',
        '--tag', $ImageReference,
        '--output', "type=oci,dest=$OciLayoutPath,tar=false"
    ) + $commonArguments)
}

function Get-Sha256 {
    param([Parameter(Mandatory)][string] $Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-OciManifestDigest {
    param(
        [Parameter(Mandatory)]
        [string] $OciLayoutPath
    )

    $indexPath = Join-Path $OciLayoutPath 'index.json'
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) {
        throw 'OCI layout is missing index.json.'
    }

    $index = Get-Content -Raw -LiteralPath $indexPath | ConvertFrom-Json -Depth 20
    $descriptors = @($index.manifests)
    if ($descriptors.Count -ne 1) {
        throw "OCI layout must contain exactly one manifest descriptor; found $($descriptors.Count)."
    }

    $digest = [string] $descriptors[0].digest
    if ($digest -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'OCI layout returned an invalid manifest digest.'
    }

    $manifestPath = Join-Path $OciLayoutPath "blobs/sha256/$($digest.Substring(7))"
    if ((Get-Sha256 -Path $manifestPath) -cne $digest.Substring(7)) {
        throw 'OCI manifest digest does not match its retained bytes.'
    }

    return $digest
}

function Assert-LocalAndOciImagesMatch {
    param(
        [Parameter(Mandatory)]
        [string] $ImageReference,

        [Parameter(Mandatory)]
        [string] $OciLayoutPath,

        [Parameter(Mandatory)]
        [string] $ManifestDigest
    )

    $localImage = Invoke-Docker -Arguments @(
        'image', 'inspect',
        '--format', '{{json .}}',
        $ImageReference
    ) | ConvertFrom-Json -Depth 30

    $manifestPath = Join-Path $OciLayoutPath "blobs/sha256/$($ManifestDigest.Substring(7))"
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json -Depth 20
    $configDigest = [string] $manifest.config.digest
    if ($configDigest -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'OCI manifest contains an invalid configuration digest.'
    }

    $configPath = Join-Path $OciLayoutPath "blobs/sha256/$($configDigest.Substring(7))"
    if ((Get-Sha256 -Path $configPath) -cne $configDigest.Substring(7)) {
        throw 'OCI configuration digest does not match its retained bytes.'
    }
    $config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json -Depth 30

    if ([string] $localImage.Architecture -cne [string] $config.architecture -or
        [string] $localImage.Os -cne [string] $config.os -or
        [string] $localImage.Created -cne [string] $config.created) {
        throw 'Runnable and OCI builds produced different platform or creation metadata.'
    }

    $configurationFields = @(
        'User',
        'ExposedPorts',
        'Env',
        'Entrypoint',
        'WorkingDir',
        'Labels',
        'Healthcheck'
    )
    foreach ($field in $configurationFields) {
        $localValue = $localImage.Config.$field | ConvertTo-Json -Depth 20 -Compress
        $ociValue = $config.config.$field | ConvertTo-Json -Depth 20 -Compress
        if ($localValue -cne $ociValue) {
            throw "Runnable and OCI build configuration differs for $field."
        }
    }

    $localLayers = @($localImage.RootFS.Layers)
    $ociLayers = @($config.rootfs.diff_ids)
    if ($localLayers.Count -ne $ociLayers.Count) {
        throw 'Runnable and OCI builds produced a different layer count.'
    }
    for ($index = 0; $index -lt $localLayers.Count; $index++) {
        if ([string] $localLayers[$index] -cne [string] $ociLayers[$index]) {
            throw "Runnable and OCI build layer identity differs at index $index."
        }
    }

    return [pscustomobject]@{
        ConfigDigest = $configDigest
        LayerCount = $localLayers.Count
    }
}

function New-RenderImageMetadata {
    param(
        [Parameter(Mandatory)]
        [string] $SourceCommit,

        [Parameter(Mandatory)]
        [string] $ImageReference,

        [Parameter(Mandatory)]
        [string] $ManifestDigest,

        [Parameter(Mandatory)]
        [string] $OciLayoutPath,

        [Parameter(Mandatory)]
        [string] $ConfigDigest,

        [Parameter(Mandatory)]
        [int] $LayerCount
    )

    return [ordered]@{
        schema = 'Html2bRenderImageMetadataV1'
        sourceCommit = $SourceCommit
        commitTag = $ImageReference
        manifestDigest = $ManifestDigest
        immutableImage = "$($ImageReference.Substring(0, $ImageReference.LastIndexOf(':')))@$ManifestDigest"
        platform = 'linux/amd64'
        ociLayoutPath = $OciLayoutPath
        configDigest = $ConfigDigest
        layerCount = $LayerCount
        provenanceAttestationIncluded = $false
        sbomAttestationIncluded = $false
        createdAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
    }
}

function Read-RetainedRenderMetadata {
    param(
        [Parameter(Mandatory)]
        [string] $MetadataPath,

        [Parameter(Mandatory)]
        [string] $OciLayoutPath,

        [Parameter(Mandatory)]
        [string] $SourceCommit,

        [Parameter(Mandatory)]
        [string] $CommitTag
    )

    if (-not (Test-Path -LiteralPath $MetadataPath -PathType Leaf)) {
        throw 'Push requires retained Render metadata from the build step.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $OciLayoutPath 'index.json') -PathType Leaf)) {
        throw 'Push requires the retained OCI layout from the build step.'
    }

    $metadata = Get-Content -Raw -LiteralPath $MetadataPath |
        ConvertFrom-Json -Depth 20
    if ($metadata.schema -ne 'Html2bRenderImageMetadataV1' -or
        [string] $metadata.sourceCommit -cne $SourceCommit -or
        [string] $metadata.commitTag -cne $CommitTag -or
        [string] $metadata.platform -cne 'linux/amd64' -or
        [bool] $metadata.provenanceAttestationIncluded -or
        [bool] $metadata.sbomAttestationIncluded) {
        throw 'Retained Render metadata does not match the selected build.'
    }
    if ([System.IO.Path]::GetFullPath([string] $metadata.ociLayoutPath) -cne
        [System.IO.Path]::GetFullPath($OciLayoutPath)) {
        throw 'Retained Render metadata points to a different OCI layout.'
    }

    $layoutDigest = Get-OciManifestDigest -OciLayoutPath $OciLayoutPath
    $layoutIndex = Get-Content -Raw -LiteralPath (Join-Path $OciLayoutPath 'index.json') |
        ConvertFrom-Json -Depth 20
    if ([string] $layoutIndex.manifests[0].annotations.'org.opencontainers.image.ref.name' -cne
        $SourceCommit) {
        throw 'Retained OCI layout reference is not the selected full source SHA.'
    }
    if ([string] $metadata.manifestDigest -cne $layoutDigest -or
        [string] $metadata.immutableImage -cne
        "crhtml2bdev.azurecr.io/html2b-render@$layoutDigest") {
        throw 'Retained Render metadata does not match the OCI layout bytes.'
    }

    return $metadata
}

function Read-RenderPreviewManifest {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $SourceCommit,

        [Parameter(Mandatory)]
        [pscustomobject] $Metadata
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'Push requires the sanitized preview manifest.'
    }

    $manifestTestPath = Join-Path $PSScriptRoot 'Test-AzureDevManifest.ps1'
    $null = & $manifestTestPath `
        -ManifestPath $Path `
        -ExpectedSourceCommit $SourceCommit `
        -ExpectedMode Preview
    $manifest = Get-Content -Raw -LiteralPath $Path |
        ConvertFrom-Json -Depth 30

    if ([string] $manifest.artifacts.renderCommitTag -cne
        [string] $Metadata.commitTag -or
        [string] $manifest.artifacts.renderDigest -cne
        [string] $Metadata.manifestDigest -or
        [string] $manifest.artifacts.renderImage -cne
        [string] $Metadata.immutableImage) {
        throw 'Retained Render build does not match the sanitized preview manifest.'
    }

    return $manifest
}

if ($RegistryName -ne 'crhtml2bdev' -or $RepositoryName -ne 'html2b-render') {
    throw 'This feature is limited to crhtml2bdev.azurecr.io/html2b-render.'
}

$repositoryRoot = Resolve-RepositoryRoot
Assert-CleanRenderSource -RepositoryRoot $repositoryRoot -ExpectedCommit $SourceCommit

$renderOutputDirectory = Resolve-RenderOutputDirectory `
    -RepositoryRoot $repositoryRoot `
    -RequestedPath $OutputDirectory `
    -SourceCommit $SourceCommit
$ociLayoutPath = Join-Path $renderOutputDirectory 'oci'
$imageReference = "${RegistryName}.azurecr.io/${RepositoryName}:$SourceCommit"
$metadataPath = Join-Path $renderOutputDirectory 'render-image.json'

if ($Push) {
    $metadata = Read-RetainedRenderMetadata `
        -MetadataPath $metadataPath `
        -OciLayoutPath $ociLayoutPath `
        -SourceCommit $SourceCommit `
        -CommitTag $imageReference
    $previewManifest = Read-RenderPreviewManifest `
        -Path $PreviewManifestPath `
        -SourceCommit $SourceCommit `
        -Metadata $metadata

    Assert-OrasVersion -Executable $OrasPath
    Assert-AcrLoginContext `
        -ExpectedApplicationClientId $ApplicationDeploymentClientId
    $null = Invoke-AzureCli -Arguments @(
        'acr', 'login',
        '--name', $RegistryName,
        '--only-show-errors',
        '--output', 'none'
    )

    $existingDigest = Get-ExistingCommitTagDigest `
        -Executable $OrasPath `
        -CommitTag $imageReference
    $reused = Assert-CommitTagIsImmutable `
        -ExistingDigest $existingDigest `
        -PreviewDigest ([string] $previewManifest.artifacts.renderDigest)
    if (-not $reused) {
        Push-RenderOciLayout `
            -Executable $OrasPath `
            -OciLayoutPath $ociLayoutPath `
            -SourceCommit $SourceCommit `
            -CommitTag $imageReference
    }

    $publishedDigest = Resolve-PushedImageDigest `
        -Executable $OrasPath `
        -CommitTag $imageReference `
        -ExpectedDigest ([string] $previewManifest.artifacts.renderDigest)
    Write-Output "renderImage=${RegistryName}.azurecr.io/$RepositoryName@$publishedDigest"
    Write-Output "renderImageTag=$imageReference"
    Write-Output "renderManifestDigest=$publishedDigest"
    Write-Output "renderPublication=$(if ($reused) { 'reused' } else { 'pushed' })"
}
else {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw 'Docker is required.'
    }
    $null = Invoke-Docker -Arguments @('info', '--format', '{{.ServerVersion}}')
    $null = Invoke-DockerBuildx -Arguments @('version')

    Build-RenderOciLayout `
        -RepositoryRoot $repositoryRoot `
        -ImageReference $imageReference `
        -OciLayoutPath $ociLayoutPath
    Invoke-LocalRenderValidation -Image $imageReference -SourceCommit $SourceCommit

    $manifestDigest = Get-OciManifestDigest -OciLayoutPath $ociLayoutPath
    $imageIdentity = Assert-LocalAndOciImagesMatch `
        -ImageReference $imageReference `
        -OciLayoutPath $ociLayoutPath `
        -ManifestDigest $manifestDigest
    $metadata = New-RenderImageMetadata `
        -SourceCommit $SourceCommit `
        -ImageReference $imageReference `
        -ManifestDigest $manifestDigest `
        -OciLayoutPath $ociLayoutPath `
        -ConfigDigest $imageIdentity.ConfigDigest `
        -LayerCount $imageIdentity.LayerCount
    [System.IO.File]::WriteAllText(
        $metadataPath,
        ($metadata | ConvertTo-Json -Depth 10),
        [System.Text.UTF8Encoding]::new($false))

    Write-Output "renderImageTag=$imageReference"
    Write-Output "renderManifestDigest=$manifestDigest"
    Write-Output "renderImage=$($metadata.immutableImage)"
    Write-Output "renderOciLayoutPath=$ociLayoutPath"
    Write-Output "renderMetadataPath=$metadataPath"
}
