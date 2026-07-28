Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

Import-Module `
    (Join-Path $PSScriptRoot 'Html2b.OutputContracts.psm1')

$script:MaximumResponseBytes = 16 * 1024 * 1024

function New-ValidationHttpClient {
    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(95)
    return $client
}

function ConvertFrom-HealthBody {
    param(
        [Parameter(Mandatory)]
        [string] $Body,

        [Parameter(Mandatory)]
        [string] $Path
    )

    try {
        $result = $Body | ConvertFrom-Json
    }
    catch {
        throw "$Path did not return valid health JSON."
    }

    return [string] $result.status
}

function Wait-EndpointStatus {
    param(
        [Parameter(Mandatory)]
        [uri] $Uri,

        [Parameter(Mandatory)]
        [string] $ExpectedBodyStatus,

        [TimeSpan] $Timeout = [TimeSpan]::FromMinutes(4)
    )

    $client = New-ValidationHttpClient
    $client.Timeout = [TimeSpan]::FromSeconds(20)
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastStatus = $null

    try {
        while ($stopwatch.Elapsed -lt $Timeout) {
            try {
                $response = $client.GetAsync($Uri).GetAwaiter().GetResult()
                try {
                    $lastStatus = [int] $response.StatusCode
                    if ($lastStatus -eq 200) {
                        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                        $status = ConvertFrom-HealthBody `
                            -Body $body `
                            -Path $Uri.AbsolutePath
                        if ($status -eq $ExpectedBodyStatus) {
                            return [ordered]@{
                                path = $Uri.AbsolutePath
                                httpStatus = $lastStatus
                                bodyStatus = $status
                                elapsedMilliseconds =
                                    [Math]::Round(
                                        $stopwatch.Elapsed.TotalMilliseconds,
                                        1)
                            }
                        }
                    }
                }
                finally {
                    $response.Dispose()
                }
            }
            catch [System.Net.Http.HttpRequestException] {
                $lastStatus = $null
            }
            catch [System.Threading.Tasks.TaskCanceledException] {
                $lastStatus = $null
            }

            Start-Sleep -Seconds 3
        }
    }
    finally {
        $client.Dispose()
    }

    throw "Timed out waiting for $($Uri.AbsolutePath); last status was $lastStatus."
}

function Invoke-HealthContract {
    param(
        [Parameter(Mandatory)]
        [System.Net.Http.HttpClient] $Client,

        [Parameter(Mandatory)]
        [uri] $Uri,

        [Parameter(Mandatory)]
        [string] $ExpectedBodyStatus,

        [Parameter(Mandatory)]
        [string] $Phase,

        [Parameter(Mandatory)]
        [string] $HostLabel,

        [switch] $ReturnFailure
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $response = $Client.GetAsync($Uri).GetAwaiter().GetResult()
    try {
        $httpStatus = [int] $response.StatusCode
        $elapsedMilliseconds =
            [Math]::Round($stopwatch.Elapsed.TotalMilliseconds, 1)
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $bodyStatus = $null
        try {
            $bodyStatus = ConvertFrom-HealthBody `
                -Body $body `
                -Path $Uri.AbsolutePath
        }
        catch {
            if (-not $ReturnFailure) {
                throw
            }
        }

        $result = [ordered]@{
            host = $HostLabel
            phase = $Phase
            method = 'GET'
            path = $Uri.AbsolutePath
            httpStatus = $httpStatus
            bodyStatus = $bodyStatus
            elapsedMilliseconds = $elapsedMilliseconds
        }

        if ($httpStatus -ne 200 -or
            $bodyStatus -ne $ExpectedBodyStatus) {
            if ($ReturnFailure) {
                return $result
            }

            throw "$HostLabel $Phase $($Uri.AbsolutePath) returned HTTP $httpStatus with health status '$bodyStatus' after $elapsedMilliseconds ms."
        }

        return $result
    }
    finally {
        $response.Dispose()
    }
}

function Invoke-RenderContract {
    param(
        [Parameter(Mandatory)]
        [System.Net.Http.HttpClient] $Client,

        [Parameter(Mandatory)]
        [uri] $Uri,

        [Parameter(Mandatory)]
        [ValidateSet('png', 'jpeg', 'pdf')]
        [string] $Format,

        [Parameter(Mandatory)]
        [string] $Phase,

        [Parameter(Mandatory)]
        [string] $HostLabel,

        [switch] $DirectRender
    )

    [System.Net.Http.HttpContent] $content = $null
    if ($DirectRender) {
        $payload = @{ format = $Format } | ConvertTo-Json -Compress
        $content = [System.Net.Http.StringContent]::new(
            $payload,
            [System.Text.Encoding]::UTF8,
            'application/json')
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $response = $Client.PostAsync($Uri, $content).GetAwaiter().GetResult()
        try {
            $httpStatus = [int] $response.StatusCode
            if ($httpStatus -ne 200) {
                throw "$HostLabel $Phase $Format returned HTTP $httpStatus."
            }

            $fileName = Get-Html2bResponseFileName `
                -Disposition $response.Content.Headers.ContentDisposition `
                -Format $Format
            $null = $response.Content.LoadIntoBufferAsync(
                $script:MaximumResponseBytes).GetAwaiter().GetResult()
            $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            $contentType = $response.Content.Headers.ContentType
            $mediaType = if ($null -eq $contentType) {
                $null
            }
            else {
                [string] $contentType.MediaType
            }
            $outputContract = Assert-Html2bOutputContract `
                -Format $Format `
                -Bytes $bytes `
                -ContentType $mediaType `
                -FileName $fileName

            return [ordered]@{
                host = $HostLabel
                phase = $Phase
                method = 'POST'
                path = $Uri.AbsolutePath
                format = $Format
                httpStatus = $httpStatus
                contentType = $outputContract.contentType
                fileName = $outputContract.fileName
                byteCount = $outputContract.byteCount
                signatureValidated = $outputContract.signatureValidated
                dimensions = $outputContract.dimensions
                elapsedMilliseconds =
                    [Math]::Round($stopwatch.Elapsed.TotalMilliseconds, 1)
            }
        }
        finally {
            $response.Dispose()
        }
    }
    finally {
        if ($null -ne $content) {
            $content.Dispose()
        }
    }
}

function Invoke-FunctionContractValidation {
    param(
        [Parameter(Mandatory)]
        [System.Net.Http.HttpClient] $Client,

        [Parameter(Mandatory)]
        [uri] $BaseUri,

        [string] $Phase = 'warm'
    )

    $results = @()
    $results += Invoke-HealthContract `
        -Client $Client `
        -Uri ([uri]::new($BaseUri, 'health/live')) `
        -ExpectedBodyStatus 'live' `
        -Phase $Phase `
        -HostLabel 'Function'
    $results += Invoke-HealthContract `
        -Client $Client `
        -Uri ([uri]::new($BaseUri, 'health/ready')) `
        -ExpectedBodyStatus 'ready' `
        -Phase $Phase `
        -HostLabel 'Function'
    foreach ($format in @('png', 'jpeg', 'pdf')) {
        $results += Invoke-RenderContract `
            -Client $Client `
            -Uri ([uri]::new($BaseUri, "api/renders/$format")) `
            -Format $format `
            -Phase $Phase `
            -HostLabel 'Function'
    }

    return $results
}

function Invoke-ExpectedRenderAuthorizationStatus {
    param(
        [Parameter(Mandatory)]
        [System.Net.Http.HttpClient] $Client,

        [Parameter(Mandatory)]
        [uri] $Uri,

        [Parameter(Mandatory)]
        [ValidateSet('GET', 'POST')]
        [string] $Method,

        [Parameter(Mandatory)]
        [string] $Scenario,

        [Parameter(Mandatory)]
        [ValidateSet(401, 403)]
        [int] $ExpectedStatus,

        [AllowNull()]
        [string] $BearerToken,

        [switch] $UseBearerToken
    )

    if ($UseBearerToken -and
        [string]::IsNullOrWhiteSpace($BearerToken)) {
        throw "The $Scenario validation did not receive a bearer token."
    }

    $httpMethod = [System.Net.Http.HttpMethod]::new($Method)
    $request = [System.Net.Http.HttpRequestMessage]::new($httpMethod, $Uri)
    [System.Net.Http.HttpResponseMessage] $response = $null
    try {
        if ($Method -eq 'POST') {
            $request.Content = [System.Net.Http.StringContent]::new(
                '{"format":"png"}',
                [System.Text.Encoding]::UTF8,
                'application/json')
        }
        if ($UseBearerToken) {
            $request.Headers.Authorization =
                [System.Net.Http.Headers.AuthenticationHeaderValue]::new(
                    'Bearer',
                    $BearerToken)
        }

        $response = $Client.SendAsync($request).GetAwaiter().GetResult()
        $httpStatus = [int] $response.StatusCode
        if ($httpStatus -ne $ExpectedStatus) {
            throw "Render $Scenario returned HTTP $httpStatus instead of $ExpectedStatus."
        }

        return [ordered]@{
            host = 'Render'
            phase = 'protected-p02'
            method = $Method
            path = $Uri.AbsolutePath
            scenario = $Scenario
            expectedHttpStatus = $ExpectedStatus
            httpStatus = $httpStatus
            status = 'passed'
        }
    }
    finally {
        if ($null -ne $response) {
            $response.Dispose()
        }
        $request.Headers.Authorization = $null
        $BearerToken = $null
        $request.Dispose()
    }
}

function Get-RenderAuthorizationTestCases {
    return @(
        [ordered]@{
            method = 'GET'
            path = 'health/live'
            scenario = 'anonymous'
            expectedStatus = 401
            bearerTokenKind = 'none'
        },
        [ordered]@{
            method = 'GET'
            path = 'health/ready'
            scenario = 'anonymous'
            expectedStatus = 401
            bearerTokenKind = 'none'
        },
        [ordered]@{
            method = 'POST'
            path = 'internal/renders'
            scenario = 'anonymous'
            expectedStatus = 401
            bearerTokenKind = 'none'
        },
        [ordered]@{
            method = 'POST'
            path = 'internal/renders'
            scenario = 'malformed-token'
            expectedStatus = 401
            bearerTokenKind = 'malformed'
        },
        [ordered]@{
            method = 'POST'
            path = 'internal/renders'
            scenario = 'valid-token-wrong-audience'
            expectedStatus = 401
            bearerTokenKind = 'wrong-audience'
        }
    )
}

function Invoke-RenderAuthorizationMatrix {
    param(
        [Parameter(Mandatory)]
        [System.Net.Http.HttpClient] $Client,

        [Parameter(Mandatory)]
        [uri] $BaseUri,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string] $WrongAudienceToken,

        [AllowNull()]
        [System.Security.SecureString] $WrongPrincipalToken,

        [Parameter(Mandatory)]
        [string] $AllowedPrincipalId
    )

    $results = @()
    $cases = @(Get-RenderAuthorizationTestCases)
    $bearerToken = $null
    $parameters = $null
    try {
        foreach ($case in $cases) {
            $bearerToken = switch ($case.bearerTokenKind) {
                'none' { $null }
                'malformed' { 'not-a-valid-jwt' }
                'wrong-audience' { $WrongAudienceToken }
                default {
                    throw "Unknown bearer-token kind '$($case.bearerTokenKind)'."
                }
            }
            $parameters = @{
                Client = $Client
                Uri = [uri]::new($BaseUri, $case.path)
                Method = $case.method
                Scenario = $case.scenario
                ExpectedStatus = $case.expectedStatus
            }
            if ($null -ne $bearerToken) {
                $parameters.BearerToken = $bearerToken
                $parameters.UseBearerToken = $true
            }

            $results += Invoke-ExpectedRenderAuthorizationStatus @parameters
            if ($parameters.ContainsKey('BearerToken')) {
                $parameters.BearerToken = $null
                $null = $parameters.Remove('BearerToken')
            }
            $bearerToken = $null
        }
    }
    finally {
        if ($null -ne $parameters -and
            $parameters.ContainsKey('BearerToken')) {
            $parameters.BearerToken = $null
            $null = $parameters.Remove('BearerToken')
        }
        $parameters = $null
        $bearerToken = $null
        Remove-Variable -Name WrongAudienceToken -Force
    }

    if ($null -eq $WrongPrincipalToken) {
        $results += [ordered]@{
            host = 'Render'
            phase = 'protected-p02'
            method = 'POST'
            path = '/internal/renders'
            scenario = 'valid-token-wrong-principal'
            expectedHttpStatus = 403
            httpStatus = $null
            status = 'skipped'
            reason =
                'No separately approved Render-audience token from a safe ' +
                'second principal was supplied.'
            risk =
                'The live 403 branch was not exercised, so principal denial ' +
                'is proven by exact policy readback rather than a second token.'
            policyEvidence = [ordered]@{
                allowedPrincipalCount = 1
                allowedPrincipalIds = @($AllowedPrincipalId)
            }
        }

        return $results
    }

    $plainTextToken = $null
    try {
        $plainTextToken =
            [System.Net.NetworkCredential]::new(
                '',
                $WrongPrincipalToken).Password
        if ([string]::IsNullOrWhiteSpace($plainTextToken)) {
            throw 'The approved wrong-principal token was empty.'
        }

        $results += Invoke-ExpectedRenderAuthorizationStatus `
            -Client $Client `
            -Uri ([uri]::new($BaseUri, 'internal/renders')) `
            -Method 'POST' `
            -Scenario 'valid-token-wrong-principal' `
            -ExpectedStatus 403 `
            -BearerToken $plainTextToken `
            -UseBearerToken
    }
    finally {
        $plainTextToken = $null
    }

    return $results
}
function Get-WrongAudienceAccessToken {
    param(
        [Parameter(Mandatory)]
        [string] $Subscription
    )

    $tokenOutput = $null
    $accessToken = $null
    try {
        try {
            $tokenOutput = & az account get-access-token `
                --subscription $Subscription `
                --resource 'https://management.azure.com/' `
                --query accessToken `
                --output tsv `
                --only-show-errors 2>$null
        }
        catch {
            throw 'Unable to acquire the wrong-audience ARM access token.'
        }

        if ($LASTEXITCODE -ne 0) {
            throw 'Unable to acquire the wrong-audience ARM access token.'
        }

        $accessToken = ($tokenOutput | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($accessToken)) {
            throw 'The wrong-audience ARM access token was empty.'
        }

        return $accessToken
    }
    finally {
        $accessToken = $null
        $tokenOutput = $null
    }
}


Export-ModuleMember -Function @(
    'Get-RenderAuthorizationTestCases',
    'Get-WrongAudienceAccessToken',
    'Invoke-FunctionContractValidation',
    'Invoke-HealthContract',
    'Invoke-RenderAuthorizationMatrix',
    'Invoke-RenderContract',
    'New-ValidationHttpClient',
    'Wait-EndpointStatus'
)
