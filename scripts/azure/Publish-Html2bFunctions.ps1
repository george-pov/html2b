[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $SourceCommit,

    [ValidateSet('Release')]
    [string] $Configuration = 'Release',

    [string] $OutputDirectory = 'build/deployment/004'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepositoryRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
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

function Assert-CleanFunctionSource {
    param(
        [Parameter(Mandatory)]
        [string] $RepositoryRoot,

        [Parameter(Mandatory)]
        [string] $ExpectedCommit
    )

    if ((Get-SourceCommit -RepositoryRoot $RepositoryRoot) -cne $ExpectedCommit) {
        throw 'SourceCommit must equal the checked-out full HEAD commit.'
    }

    $functionInputs = @(
        'src/api/Html2b.Domain',
        'src/api/Html2b.Application',
        'src/api/Html2b.Contracts',
        'src/api/Html2b.Infrastructure',
        'src/api/Html2b.AzureFunctions'
    )
    $status = (& git -C $RepositoryRoot status --porcelain --untracked-files=all -- @functionInputs 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not compare Functions inputs with SourceCommit.'
    }

    if (-not [string]::IsNullOrWhiteSpace($status)) {
        throw 'Functions package inputs must be committed in SourceCommit.'
    }
}

function Resolve-FunctionsOutputDirectory {
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

    $functionsPath = Join-Path (Join-Path $basePath $SourceCommit) 'functions'
    $null = New-Item -ItemType Directory -Force -Path $functionsPath
    return $functionsPath
}

function Remove-GeneratedPath {
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $FunctionsOutputDirectory
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $resolvedRoot = [System.IO.Path]::GetFullPath($FunctionsOutputDirectory)
    if (-not $resolvedPath.StartsWith(
            "$resolvedRoot$([System.IO.Path]::DirectorySeparatorChar)",
            [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to remove a generated path outside the Functions output directory.'
    }

    Remove-Item -LiteralPath $resolvedPath -Recurse -Force
}

function Invoke-DotNetPublish {
    param(
        [Parameter(Mandatory)]
        [string] $ProjectPath,

        [Parameter(Mandatory)]
        [string] $PublishDirectory,

        [Parameter(Mandatory)]
        [string] $Configuration
    )

    $output = & dotnet publish $ProjectPath `
        --configuration $Configuration `
        --runtime linux-x64 `
        --self-contained false `
        --output $PublishDirectory `
        -p:PublishReadyToRun=true `
        -p:Deterministic=true `
        -p:ContinuousIntegrationBuild=true `
        --nologo 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed.`n$(($output | Out-String).Trim())"
    }
}

function Assert-FunctionPackageLayout {
    param(
        [Parameter(Mandatory)]
        [string] $PublishDirectory
    )

    foreach ($requiredFile in @(
            'host.json',
            'Html2b.AzureFunctions',
            'Html2b.AzureFunctions.dll',
            'functions.metadata',
            'worker.config.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $PublishDirectory $requiredFile) -PathType Leaf)) {
            throw "Functions publish output is missing root file '$requiredFile'."
        }
    }

    $forbiddenFiles = @(Get-ChildItem -LiteralPath $PublishDirectory -File -Recurse | Where-Object {
            $_.Name -like 'local.settings*.json' -or
            $_.Extension -in @('.cs', '.csproj', '.sln', '.slnx', '.user')
        })
    if ($forbiddenFiles.Count -gt 0) {
        throw "Functions publish output contains forbidden source or local settings file '$($forbiddenFiles[0].Name)'."
    }

    $nestedPublishDirectories = @(Get-ChildItem -LiteralPath $PublishDirectory -Directory -Recurse | Where-Object {
            $_.Name -in @('publish', 'bin', 'obj')
        })
    if ($nestedPublishDirectories.Count -gt 0) {
        throw 'Functions publish output contains a nested build/publish directory.'
    }

    $executable = Get-Item -LiteralPath (Join-Path $PublishDirectory 'Html2b.AzureFunctions')
    if ($executable.Length -eq 0) {
        throw 'Functions worker executable is empty.'
    }
}

function New-DeterministicZip {
    param(
        [Parameter(Mandatory)]
        [string] $SourceDirectory,

        [Parameter(Mandatory)]
        [string] $DestinationPath
    )

    Add-Type -AssemblyName System.IO.Compression
    if (Test-Path -LiteralPath $DestinationPath) {
        Remove-Item -LiteralPath $DestinationPath -Force
    }

    $destinationStream = [System.IO.File]::Open(
        $DestinationPath,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None)
    try {
        $archive = [System.IO.Compression.ZipArchive]::new(
            $destinationStream,
            [System.IO.Compression.ZipArchiveMode]::Create,
            $false,
            [System.Text.Encoding]::UTF8)
        try {
            $files = @(Get-ChildItem -LiteralPath $SourceDirectory -File -Recurse | Sort-Object {
                    [System.IO.Path]::GetRelativePath($SourceDirectory, $_.FullName).Replace('\', '/')
                })
            foreach ($file in $files) {
                $entryName = [System.IO.Path]::GetRelativePath(
                    $SourceDirectory,
                    $file.FullName).Replace('\', '/')
                if ($entryName.StartsWith('/') -or $entryName.Contains('../')) {
                    throw "Unsafe Functions package entry '$entryName'."
                }

                $entry = $archive.CreateEntry(
                    $entryName,
                    [System.IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = [DateTimeOffset]::new(
                    2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
                $entryStream = $entry.Open()
                $sourceStream = [System.IO.File]::OpenRead($file.FullName)
                try {
                    $sourceStream.CopyTo($entryStream)
                }
                finally {
                    $sourceStream.Dispose()
                    $entryStream.Dispose()
                }
            }
        }
        finally {
            $archive.Dispose()
        }
    }
    finally {
        $destinationStream.Dispose()
    }
}

function Get-Sha256 {
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw '.NET SDK is required.'
}

$repositoryRoot = Resolve-RepositoryRoot
Assert-CleanFunctionSource -RepositoryRoot $repositoryRoot -ExpectedCommit $SourceCommit
$functionsOutputDirectory = Resolve-FunctionsOutputDirectory `
    -RepositoryRoot $repositoryRoot `
    -RequestedPath $OutputDirectory `
    -SourceCommit $SourceCommit
$publishDirectory = Join-Path $functionsOutputDirectory 'publish'
$packagePath = Join-Path $functionsOutputDirectory 'released-package.zip'
$metadataPath = Join-Path $functionsOutputDirectory 'function-package.json'

Remove-GeneratedPath -Path $publishDirectory -FunctionsOutputDirectory $functionsOutputDirectory
if (Test-Path -LiteralPath $packagePath) {
    Remove-Item -LiteralPath $packagePath -Force
}
if (Test-Path -LiteralPath $metadataPath) {
    Remove-Item -LiteralPath $metadataPath -Force
}

Invoke-DotNetPublish `
    -ProjectPath (Join-Path $repositoryRoot 'src/api/Html2b.AzureFunctions/Html2b.AzureFunctions.csproj') `
    -PublishDirectory $publishDirectory `
    -Configuration $Configuration
Assert-FunctionPackageLayout -PublishDirectory $publishDirectory
New-DeterministicZip -SourceDirectory $publishDirectory -DestinationPath $packagePath

$packageSha256 = Get-Sha256 -Path $packagePath
$metadata = [ordered]@{
    schema = 'Html2bFunctionPackageMetadataV1'
    sourceCommit = $SourceCommit
    configuration = $Configuration
    runtimeIdentifier = 'linux-x64'
    readyToRun = $true
    packageFileName = [System.IO.Path]::GetFileName($packagePath)
    packageSha256 = $packageSha256
    createdAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
}
[System.IO.File]::WriteAllText(
    $metadataPath,
    ($metadata | ConvertTo-Json -Depth 5),
    [System.Text.UTF8Encoding]::new($false))

Write-Output "functionPackagePath=$packagePath"
Write-Output "functionPackageSha256=$packageSha256"
Write-Output "functionPackageMetadataPath=$metadataPath"
