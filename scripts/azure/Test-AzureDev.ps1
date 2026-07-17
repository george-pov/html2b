[CmdletBinding()]
param(
    [string] $ResourceGroupName = 'rg-html2b-dev',

    [string] $ContainerAppName = 'ca-html2b-dev',

    [Parameter(Mandatory)]
    [string] $ExpectedContainerImage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-AzureCli {
    param(
        [Parameter(Mandatory)]
        [string[]] $Arguments
    )

    $output = & az @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | Out-String).Trim()
    if ($exitCode -ne 0) {
        throw "Azure CLI failed with exit code $exitCode.`n$text"
    }

    return $text
}

function Get-ContainerAppState {
    param(
        [Parameter(Mandatory)]
        [string] $GroupName,

        [Parameter(Mandatory)]
        [string] $AppName
    )

    $json = Invoke-AzureCli -Arguments @(
        'resource', 'show',
        '--resource-group', $GroupName,
        '--resource-type', 'Microsoft.App/containerApps',
        '--name', $AppName,
        '--api-version', '2026-01-01',
        '--output', 'json'
    )
    return $json | ConvertFrom-Json
}

function Wait-ContainerAppReady {
    param(
        [Parameter(Mandatory)]
        [uri] $ReadyUri,

        [TimeSpan] $Timeout = [TimeSpan]::FromMinutes(4)
    )

    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromSeconds(20)
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        while ($stopwatch.Elapsed -lt $Timeout) {
            try {
                $response = $client.GetAsync($ReadyUri).GetAwaiter().GetResult()
                try {
                    if ([int] $response.StatusCode -eq 200) {
                        return $stopwatch.Elapsed
                    }
                }
                finally {
                    $response.Dispose()
                }
            }
            catch [System.Net.Http.HttpRequestException] {
                # Scale-to-zero wake-up can briefly refuse the connection.
            }
            catch [System.Threading.Tasks.TaskCanceledException] {
                # Continue within the bounded cold-start timeout.
            }

            Start-Sleep -Seconds 3
        }
    }
    finally {
        $client.Dispose()
    }

    throw "Timed out waiting for $ReadyUri."
}

function Get-RevisionReplicas {
    param(
        [Parameter(Mandatory)]
        [string] $ContainerAppResourceId,

        [Parameter(Mandatory)]
        [string] $RevisionName
    )

    $json = Invoke-AzureCli -Arguments @(
        'rest', '--method', 'get',
        '--uri', "${ContainerAppResourceId}/revisions/${RevisionName}/replicas?api-version=2026-01-01",
        '--query', 'value[].{name:name,createdTime:properties.createdTime,runningState:properties.runningState}',
        '--output', 'json'
    )
    return @($json | ConvertFrom-Json)
}

function Wait-ContainerAppScaledToZero {
    param(
        [Parameter(Mandatory)]
        [string] $ContainerAppResourceId,

        [Parameter(Mandatory)]
        [string] $RevisionName,

        [TimeSpan] $Timeout = [TimeSpan]::FromMinutes(10)
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed -lt $Timeout) {
        $replicas = @(Get-RevisionReplicas `
                -ContainerAppResourceId $ContainerAppResourceId `
                -RevisionName $RevisionName)
        if ($replicas.Count -eq 0) {
            return $stopwatch.Elapsed
        }

        if ($replicas.Count -gt 1) {
            throw "Replica cap violated while waiting for scale-to-zero; Azure reported $($replicas.Count) replicas."
        }

        Start-Sleep -Seconds 15
    }

    throw "Timed out waiting for revision $RevisionName to scale to zero."
}

function Assert-ContentDisposition {
    param(
        [System.Net.Http.Headers.ContentDispositionHeaderValue] $Disposition,
        [Parameter(Mandatory)]
        [string] $ExpectedFileName
    )

    if ($null -eq $Disposition) {
        throw "Response omitted Content-Disposition for $ExpectedFileName."
    }

    $actualFileName = if (-not [string]::IsNullOrWhiteSpace($Disposition.FileNameStar)) {
        $Disposition.FileNameStar
    }
    else {
        $Disposition.FileName
    }
    if ($actualFileName.Trim('"') -ne $ExpectedFileName) {
        throw "Response filename '$actualFileName' did not match '$ExpectedFileName'."
    }
}

function Assert-FileSignature {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('png', 'jpeg', 'pdf')]
        [string] $Format,

        [Parameter(Mandatory)]
        [byte[]] $Bytes
    )

    if ($Format -eq 'png') {
        $signature = [byte[]] @(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)
        for ($index = 0; $index -lt $signature.Length; $index++) {
            if ($Bytes[$index] -ne $signature[$index]) {
                throw 'PNG signature validation failed.'
            }
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
    }
    else {
        $header = [System.Text.Encoding]::ASCII.GetString(
            $Bytes,
            0,
            [Math]::Min(5, $Bytes.Length))
        if ($header -ne '%PDF-') {
            throw 'PDF signature validation failed.'
        }
    }
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

function Assert-RasterDimensions {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('png', 'jpeg')]
        [string] $Format,

        [Parameter(Mandatory)]
        [byte[]] $Bytes,

        [int] $ExpectedWidth = 1280,
        [int] $ExpectedHeight = 720
    )

    if ($Format -eq 'png') {
        $width = Get-BigEndianUInt32 -Bytes $Bytes -Offset 16
        $height = Get-BigEndianUInt32 -Bytes $Bytes -Offset 20
    }
    else {
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
    }

    if ($width -ne $ExpectedWidth -or $height -ne $ExpectedHeight) {
        throw "$Format dimensions were ${width}x${height}, expected ${ExpectedWidth}x${ExpectedHeight}."
    }
}

function Assert-PdfPageSize {
    param(
        [Parameter(Mandatory)]
        [byte[]] $Bytes,

        [double] $ExpectedWidthPoints = 960,
        [double] $ExpectedHeightPoints = 540
    )

    $pdfText = [System.Text.Encoding]::ASCII.GetString($Bytes)
    $mediaBoxes = [regex]::Matches(
        $pdfText,
        '/MediaBox\s*\[\s*([-+]?\d*\.?\d+)\s+([-+]?\d*\.?\d+)\s+([-+]?\d*\.?\d+)\s+([-+]?\d*\.?\d+)\s*\]')
    foreach ($mediaBox in $mediaBoxes) {
        $values = 1..4 | ForEach-Object {
            [double]::Parse(
                $mediaBox.Groups[$_].Value,
                [System.Globalization.CultureInfo]::InvariantCulture)
        }
        if ([Math]::Abs($values[0]) -lt 0.1 -and
            [Math]::Abs($values[1]) -lt 0.1 -and
            [Math]::Abs($values[2] - $ExpectedWidthPoints) -lt 0.1 -and
            [Math]::Abs($values[3] - $ExpectedHeightPoints) -lt 0.1) {
            return
        }
    }

    throw "PDF page box did not match ${ExpectedWidthPoints}x${ExpectedHeightPoints} points."
}

function Invoke-HttpValidation {
    param(
        [Parameter(Mandatory)]
        [uri] $BaseUri,

        [Parameter(Mandatory)]
        [string] $OutputDirectory
    )

    $null = New-Item -ItemType Directory -Force -Path $OutputDirectory
    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromSeconds(90)

    try {
        foreach ($health in @(
                @{ Path = 'health/live'; Status = 'live' },
                @{ Path = 'health/ready'; Status = 'ready' })) {
            $response = $client.GetAsync("$BaseUri$($health.Path)").GetAwaiter().GetResult()
            try {
                if ([int] $response.StatusCode -ne 200) {
                    throw "$($health.Path) returned HTTP $([int] $response.StatusCode)."
                }

                $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json
                if ($body.status -ne $health.Status) {
                    throw "$($health.Path) returned status '$($body.status)'."
                }
            }
            finally {
                $response.Dispose()
            }
        }

        $contracts = @(
            @{ Format = 'png'; Type = 'image/png'; Name = 'html2b-poc.png'; Extension = 'png' },
            @{ Format = 'jpeg'; Type = 'image/jpeg'; Name = 'html2b-poc.jpg'; Extension = 'jpg' },
            @{ Format = 'pdf'; Type = 'application/pdf'; Name = 'html2b-poc.pdf'; Extension = 'pdf' })
        foreach ($contract in $contracts) {
            $response = $client.PostAsync(
                "$BaseUri/api/renders/$($contract.Format)",
                [System.Net.Http.HttpContent] $null).GetAwaiter().GetResult()
            try {
                if ([int] $response.StatusCode -ne 200) {
                    throw "$($contract.Format) returned HTTP $([int] $response.StatusCode)."
                }

                if ($response.Content.Headers.ContentType.MediaType -ne $contract.Type) {
                    throw "$($contract.Format) returned content type '$($response.Content.Headers.ContentType.MediaType)'."
                }

                Assert-ContentDisposition `
                    -Disposition $response.Content.Headers.ContentDisposition `
                    -ExpectedFileName $contract.Name
                $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
                Assert-FileSignature -Format $contract.Format -Bytes $bytes
                if ($contract.Format -eq 'pdf') {
                    Assert-PdfPageSize -Bytes $bytes
                }
                else {
                    Assert-RasterDimensions -Format $contract.Format -Bytes $bytes
                }

                [System.IO.File]::WriteAllBytes(
                    (Join-Path $OutputDirectory "html2b-poc.$($contract.Extension)"),
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
}

function Assert-ContainerAppConfiguration {
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $State,

        [Parameter(Mandatory)]
        [string] $ExpectedImage,

        [Parameter(Mandatory)]
        [string] $RuntimeIdentityId
    )

    $normalizedLocation = ([string] $State.location -replace '\s', '').ToLowerInvariant()
    if ($normalizedLocation -ne 'westus2') {
        throw "Container App location '$($State.location)' is not westus2."
    }

    foreach ($tag in @{
            Application = 'Html2B'
            Environment = 'dev'
            Region = 'westus2'
            ManagedBy = 'Bicep'
            Repository = 'george-pov/html2b'
            Component = 'Api'
        }.GetEnumerator()) {
        if ($State.tags.($tag.Key) -ne $tag.Value) {
            throw "Container App tag $($tag.Key) is missing or incorrect."
        }
    }

    if ($State.properties.provisioningState -ne 'Succeeded') {
        throw "Container App provisioning state is '$($State.properties.provisioningState)'."
    }

    $assignedIdentities = @($State.identity.userAssignedIdentities.PSObject.Properties.Name)
    if ($assignedIdentities.Count -ne 1 -or $assignedIdentities[0] -ine $RuntimeIdentityId) {
        throw 'Container App does not have exactly the planned runtime identity.'
    }

    $configuration = $State.properties.configuration
    if ($configuration.activeRevisionsMode -ne 'Single') {
        throw "Active revisions mode is '$($configuration.activeRevisionsMode)'."
    }

    if ($configuration.ingress.external -ne $true -or
        $configuration.ingress.allowInsecure -ne $false -or
        [int] $configuration.ingress.targetPort -ne 8080 -or
        $configuration.ingress.transport -ne 'auto') {
        throw 'Ingress does not match the external HTTPS-only port 8080 contract.'
    }

    $registries = @($configuration.registries)
    if ($registries.Count -ne 1 -or
        $registries[0].server -ne 'crhtml2bdev.azurecr.io' -or
        $registries[0].identity -ine $RuntimeIdentityId) {
        throw 'Registry configuration does not use the planned ACR and runtime identity.'
    }

    $identitySettings = @($configuration.identitySettings)
    if ($identitySettings.Count -ne 1 -or
        $identitySettings[0].identity -ine $RuntimeIdentityId -or
        $identitySettings[0].lifecycle -ne 'None') {
        throw 'Runtime identity lifecycle is not restricted to None for the application process.'
    }

    $secretsProperty = $configuration.PSObject.Properties['secrets']
    if ($null -ne $secretsProperty -and
        $null -ne $secretsProperty.Value -and
        @($secretsProperty.Value).Count -ne 0) {
        throw 'Container App unexpectedly contains secrets.'
    }

    $containers = @($State.properties.template.containers)
    if ($containers.Count -ne 1 -or $containers[0].name -ne 'html2b-api') {
        throw 'Container template does not contain exactly html2b-api.'
    }

    $container = $containers[0]
    if ($container.image -cne $ExpectedImage) {
        throw "Deployed image '$($container.image)' does not match '$ExpectedImage'."
    }

    if ([double] $container.resources.cpu -ne 1 -or $container.resources.memory -ne '2Gi') {
        throw 'Container resources do not match 1 vCPU and 2Gi.'
    }

    $environmentProperty = $container.PSObject.Properties['env']
    if ($null -ne $environmentProperty -and
        $null -ne $environmentProperty.Value -and
        @($environmentProperty.Value).Count -ne 0) {
        throw 'Container unexpectedly contains application settings.'
    }

    $expectedProbes = @{
        Startup = @{ Path = '/health/ready'; Initial = 1; Period = 5; Timeout = 5; Failure = 10 }
        Liveness = @{ Path = '/health/live'; Initial = 10; Period = 30; Timeout = 5; Failure = 3 }
        Readiness = @{ Path = '/health/ready'; Initial = 1; Period = 5; Timeout = 5; Failure = 3 }
    }
    $probes = @($container.probes)
    if ($probes.Count -ne 3) {
        throw "Expected three health probes, found $($probes.Count)."
    }

    foreach ($probe in $probes) {
        if (-not $expectedProbes.ContainsKey([string] $probe.type)) {
            throw "Unexpected probe type '$($probe.type)'."
        }

        $expected = $expectedProbes[[string] $probe.type]
        if ($probe.httpGet.path -ne $expected.Path -or
            [int] $probe.httpGet.port -ne 8080 -or
            $probe.httpGet.scheme -ne 'HTTP' -or
            [int] $probe.initialDelaySeconds -ne $expected.Initial -or
            [int] $probe.periodSeconds -ne $expected.Period -or
            [int] $probe.timeoutSeconds -ne $expected.Timeout -or
            [int] $probe.failureThreshold -ne $expected.Failure -or
            [int] $probe.successThreshold -ne 1) {
            throw "$($probe.type) probe does not match the Bicep contract."
        }
    }

    $template = $State.properties.template
    if ([int] $template.terminationGracePeriodSeconds -ne 30) {
        throw 'Termination grace period is not 30 seconds.'
    }

    if ([int] $template.scale.minReplicas -ne 0 -or
        [int] $template.scale.maxReplicas -ne 1) {
        throw 'Scale limits do not match min 0 and max 1.'
    }

    $rules = @($template.scale.rules)
    if ($rules.Count -ne 1 -or
        $rules[0].name -ne 'http-one-render' -or
        [string] $rules[0].http.metadata.concurrentRequests -ne '1') {
        throw 'HTTP concurrency scale rule does not match one active render.'
    }
}

if ($ResourceGroupName -ne 'rg-html2b-dev' -or $ContainerAppName -ne 'ca-html2b-dev') {
    throw 'This validation script is limited to rg-html2b-dev/ca-html2b-dev.'
}

if ($ExpectedContainerImage -cnotmatch '^crhtml2bdev\.azurecr\.io/html2b-api@sha256:[0-9a-f]{64}$') {
    throw 'ExpectedContainerImage must be the approved immutable Html2B digest.'
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is required.'
}

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$outputDirectory = Join-Path $repositoryRoot 'build\validation\002\p01\live'
$null = New-Item -ItemType Directory -Force -Path $outputDirectory
$runtimeIdentityId = Invoke-AzureCli -Arguments @(
    'identity', 'show',
    '--resource-group', $ResourceGroupName,
    '--name', 'id-html2b-api-dev',
    '--query', 'id',
    '--output', 'tsv'
)
$state = Get-ContainerAppState -GroupName $ResourceGroupName -AppName $ContainerAppName
Assert-ContainerAppConfiguration `
    -State $state `
    -ExpectedImage $ExpectedContainerImage `
    -RuntimeIdentityId $runtimeIdentityId

$fqdn = [string] $state.properties.configuration.ingress.fqdn
if ([string]::IsNullOrWhiteSpace($fqdn)) {
    throw 'Container App has no generated ingress FQDN.'
}

$initialReadinessDuration = Wait-ContainerAppReady -ReadyUri "https://$fqdn/health/ready"
Invoke-HttpValidation -BaseUri "https://$fqdn/" -OutputDirectory $outputDirectory

$redirectHandler = [System.Net.Http.HttpClientHandler]::new()
$redirectHandler.AllowAutoRedirect = $false
$redirectClient = [System.Net.Http.HttpClient]::new($redirectHandler)
try {
    $httpResponse = $redirectClient.GetAsync("http://$fqdn/health/live").GetAwaiter().GetResult()
    try {
        if ([int] $httpResponse.StatusCode -notin @(301, 302, 307, 308)) {
            throw "Plain HTTP was not redirected or rejected; status was $([int] $httpResponse.StatusCode)."
        }

        if ($null -eq $httpResponse.Headers.Location -or
            $httpResponse.Headers.Location.Scheme -ne 'https') {
            throw 'Plain HTTP did not redirect to HTTPS.'
        }
    }
    finally {
        $httpResponse.Dispose()
    }
}
finally {
    $redirectClient.Dispose()
    $redirectHandler.Dispose()
}

$state = Get-ContainerAppState -GroupName $ResourceGroupName -AppName $ContainerAppName
if ([string]::IsNullOrWhiteSpace([string] $state.properties.latestRevisionName) -or
    $state.properties.latestRevisionName -ne $state.properties.latestReadyRevisionName) {
    throw 'The latest Container App revision is not the latest ready revision.'
}

$inventory = Invoke-AzureCli -Arguments @(
    'resource', 'list',
    '--resource-group', $ResourceGroupName,
    '--query', '[].{name:name,type:type,location:location,tags:tags}',
    '--output', 'json'
)
$inventoryObjects = @($inventory | ConvertFrom-Json)
$expectedInventory = @{
    'microsoft.containerregistry/registries' = 'crhtml2bdev'
    'microsoft.operationalinsights/workspaces' = 'log-html2b-dev'
    'microsoft.managedidentity/userassignedidentities' = 'id-html2b-api-dev'
    'microsoft.app/managedenvironments' = 'cae-html2b-dev'
    'microsoft.app/containerapps' = 'ca-html2b-dev'
}
if ($inventoryObjects.Count -ne $expectedInventory.Count) {
    throw "Resource inventory contains $($inventoryObjects.Count) resources; expected $($expectedInventory.Count)."
}

foreach ($resource in $inventoryObjects) {
    $resourceType = ([string] $resource.type).ToLowerInvariant()
    if (-not $expectedInventory.ContainsKey($resourceType) -or
        $expectedInventory[$resourceType] -ne [string] $resource.name) {
        throw "Unexpected resource found: $($resource.type)/$($resource.name)."
    }
}
[System.IO.File]::WriteAllText(
    (Join-Path $outputDirectory 'resource-inventory.json'),
    $inventory)

$revisions = Invoke-AzureCli -Arguments @(
    'rest', '--method', 'get',
    '--uri', "$($state.id)/revisions?api-version=2026-01-01",
    '--query', 'value[].{name:name,active:properties.active,healthState:properties.healthState,provisioningState:properties.provisioningState,createdTime:properties.createdTime}',
    '--output', 'json'
)
$revisionObjects = @($revisions | ConvertFrom-Json)
$latestRevision = @($revisionObjects | Where-Object {
        $_.name -eq $state.properties.latestRevisionName
    })
if ($latestRevision.Count -ne 1 -or
    $latestRevision[0].active -ne $true -or
    $latestRevision[0].healthState -ne 'Healthy' -or
    $latestRevision[0].provisioningState -notin @('Provisioned', 'Succeeded')) {
    throw 'The latest revision is not active, healthy, and provisioned.'
}
[System.IO.File]::WriteAllText(
    (Join-Path $outputDirectory 'revisions.json'),
    $revisions)

$replicas = @(Get-RevisionReplicas `
        -ContainerAppResourceId $state.id `
        -RevisionName $state.properties.latestRevisionName)
if ($replicas.Count -gt 1) {
    throw "Replica cap violated; Azure reported $($replicas.Count) replicas."
}
[System.IO.File]::WriteAllText(
    (Join-Path $outputDirectory 'replicas.json'),
    ($replicas | ConvertTo-Json -Depth 5 -AsArray))

$registryId = Invoke-AzureCli -Arguments @(
    'acr', 'show',
    '--resource-group', $ResourceGroupName,
    '--name', 'crhtml2bdev',
    '--query', 'id',
    '--output', 'tsv'
)
$roleAssignmentsJson = Invoke-AzureCli -Arguments @(
    'role', 'assignment', 'list',
    '--scope', $registryId,
    '--query', '[].{principalId:principalId,roleDefinitionId:roleDefinitionId,scope:scope,condition:condition,conditionVersion:conditionVersion}',
    '--output', 'json'
)
$roleAssignments = @($roleAssignmentsJson | ConvertFrom-Json | Where-Object {
        $_.scope -ieq $registryId
    })
if ($roleAssignments.Count -ne 2) {
    throw "Expected two direct ACR repository role assignments, found $($roleAssignments.Count)."
}

$operatorPrincipalId = Invoke-AzureCli -Arguments @(
    'ad', 'signed-in-user', 'show',
    '--query', 'id',
    '--output', 'tsv'
)
$runtimePrincipalId = Invoke-AzureCli -Arguments @(
    'identity', 'show',
    '--resource-group', $ResourceGroupName,
    '--name', 'id-html2b-api-dev',
    '--query', 'principalId',
    '--output', 'tsv'
)
$writerAssignment = @($roleAssignments | Where-Object {
        $_.roleDefinitionId -like '*/2a1e307c-b015-4ebd-883e-5b7698a07328'
    })
$readerAssignment = @($roleAssignments | Where-Object {
        $_.roleDefinitionId -like '*/b93aa761-3e63-49ed-ac28-beffa264f7ac'
    })
if ($writerAssignment.Count -ne 1 -or
    $writerAssignment[0].principalId -ine $operatorPrincipalId -or
    $writerAssignment[0].conditionVersion -ne '2.0' -or
    $writerAssignment[0].condition -notlike "*StringEqualsIgnoreCase 'html2b-api'*" -or
    $writerAssignment[0].condition -notlike "*content/write*" -or
    $writerAssignment[0].condition -notlike "*metadata/write*") {
    throw 'Operator ACR repository-writer assignment is missing or overbroad.'
}

if ($readerAssignment.Count -ne 1 -or
    $readerAssignment[0].principalId -ine $runtimePrincipalId -or
    $readerAssignment[0].conditionVersion -ne '2.0' -or
    $readerAssignment[0].condition -notlike "*StringEqualsIgnoreCase 'html2b-api'*") {
    throw 'Runtime ACR repository-reader assignment is missing or overbroad.'
}

[System.IO.File]::WriteAllText(
    (Join-Path $outputDirectory 'repository-role-assignments.json'),
    $roleAssignmentsJson)

$scaleToZeroDuration = Wait-ContainerAppScaledToZero `
    -ContainerAppResourceId $state.id `
    -RevisionName $state.properties.latestRevisionName
[System.IO.File]::WriteAllText(
    (Join-Path $outputDirectory 'scale-to-zero.txt'),
    "scaleToZeroSeconds=$([Math]::Round($scaleToZeroDuration.TotalSeconds, 1))")

$coldWakeDuration = Wait-ContainerAppReady -ReadyUri "https://$fqdn/health/ready"
Invoke-HttpValidation -BaseUri "https://$fqdn/" -OutputDirectory $outputDirectory
$replicas = @(Get-RevisionReplicas `
        -ContainerAppResourceId $state.id `
        -RevisionName $state.properties.latestRevisionName)
if ($replicas.Count -gt 1) {
    throw "Replica cap violated after cold wake-up; Azure reported $($replicas.Count) replicas."
}
[System.IO.File]::WriteAllText(
    (Join-Path $outputDirectory 'replicas.json'),
    ($replicas | ConvertTo-Json -Depth 5 -AsArray))

$workspaceCustomerId = Invoke-AzureCli -Arguments @(
    'monitor', 'log-analytics', 'workspace', 'show',
    '--resource-group', $ResourceGroupName,
    '--workspace-name', 'log-html2b-dev',
    '--query', 'customerId',
    '--output', 'tsv'
)
$logQuery = "union isfuzzy=true ContainerAppConsoleLogs_CL, ContainerAppSystemLogs_CL | where ContainerAppName_s == '$ContainerAppName' | project TimeGenerated, RevisionName_s, ReplicaName_s, Log_s | order by TimeGenerated desc | take 100"
$logs = Invoke-AzureCli -Arguments @(
    'monitor', 'log-analytics', 'query',
    '--workspace', $workspaceCustomerId,
    '--analytics-query', $logQuery,
    '--timespan', 'PT1H',
    '--output', 'json'
)
[System.IO.File]::WriteAllText(
    (Join-Path $outputDirectory 'sanitized-logs.json'),
    $logs)

Write-Host "FQDN: $fqdn"
Write-Host "Active revision: $($state.properties.latestRevisionName)"
Write-Host "Deployed image: $ExpectedContainerImage"
Write-Host "Initial readiness: $([Math]::Round($initialReadinessDuration.TotalSeconds, 1)) seconds"
Write-Host "Scale-to-zero: $([Math]::Round($scaleToZeroDuration.TotalSeconds, 1)) seconds"
Write-Host "Cold-wake readiness: $([Math]::Round($coldWakeDuration.TotalSeconds, 1)) seconds"
Write-Host "Replica count after validation: $($replicas.Count)"
Write-Host 'Live Azure validation passed.'
