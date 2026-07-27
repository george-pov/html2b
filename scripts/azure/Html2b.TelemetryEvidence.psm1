Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module `
    (Join-Path $PSScriptRoot 'Html2b.AzureStateValidation.psm1')

function Get-SanitizedDependencyTelemetry {
    param(
        [Parameter(Mandatory)]
        [string] $Subscription,

        [Parameter(Mandatory)]
        [string] $GroupName,

        [Parameter(Mandatory)]
        [string] $ApplicationName,

        [Parameter(Mandatory)]
        [DateTimeOffset] $StartTime,

        [Parameter(Mandatory)]
        [DateTimeOffset] $EndTime,

        [Parameter(Mandatory)]
        [string] $RenderHostName
    )

    $startText = $StartTime.ToUniversalTime().ToString(
        'yyyy-MM-dd HH:mm:ss.fffffff zzz',
        [System.Globalization.CultureInfo]::InvariantCulture)
    $endText = $EndTime.ToUniversalTime().ToString(
        'yyyy-MM-dd HH:mm:ss.fffffff zzz',
        [System.Globalization.CultureInfo]::InvariantCulture)
    $escapedRenderHostName = $RenderHostName.Replace("'", "''")
    $analyticsQuery = @"
dependencies
| where timestamp >= todatetime('$startText')
| where timestamp <= todatetime('$endText')
| where target contains '$escapedRenderHostName'
    or name contains '$escapedRenderHostName'
    or data contains '$escapedRenderHostName'
| project timestamp, name, type, target, resultCode, success, duration,
    operationId = operation_Id
| order by timestamp asc
"@

    $json = Invoke-AzureCli `
        -Subscription $Subscription `
        -Operation 'query sanitized Function dependency telemetry' `
        -Arguments @(
            'monitor', 'app-insights', 'query',
            '--app', $ApplicationName,
            '--resource-group', $GroupName,
            '--analytics-query', $analyticsQuery,
            '--start-time', $startText,
            '--end-time', $endText,
            '--query', 'tables[0].rows',
            '--output', 'json'
        )
    $rows = ConvertFrom-AzureCliJson `
        -Json $json `
        -Operation 'query sanitized Function dependency telemetry'

    $records = @()
    foreach ($row in @(
            $rows |
                Where-Object { $null -ne $_ })) {
        if (@($row).Count -ne 8) {
            throw 'The sanitized dependency query returned an unexpected schema.'
        }

        $records += [ordered]@{
            timestamp = [string] $row[0]
            name = [string] $row[1]
            type = [string] $row[2]
            target = [string] $row[3]
            resultCode = [string] $row[4]
            success = if ($null -eq $row[5]) {
                $null
            }
            else {
                [bool] $row[5]
            }
            duration = [string] $row[6]
            operationId = [string] $row[7]
        }
    }

    return $records
}

function Get-DependencyTelemetryEvidence {
    param(
        [Parameter(Mandatory)]
        [string] $Subscription,

        [Parameter(Mandatory)]
        [string] $GroupName,

        [Parameter(Mandatory)]
        [string] $ApplicationName,

        [Parameter(Mandatory)]
        [DateTimeOffset] $StartTime,

        [Parameter(Mandatory)]
        [DateTimeOffset] $EndTime,

        [Parameter(Mandatory)]
        [string] $RenderHostName,

        [TimeSpan] $Timeout = [TimeSpan]::FromMinutes(1)
    )

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $records = @()
    $queryFailure = $null
    while ($stopwatch.Elapsed -lt $Timeout) {
        try {
            $records = @(
                Get-SanitizedDependencyTelemetry `
                    -Subscription $Subscription `
                    -GroupName $GroupName `
                    -ApplicationName $ApplicationName `
                    -StartTime $StartTime `
                    -EndTime $EndTime `
                    -RenderHostName $RenderHostName
            )
            $queryFailure = $null
        }
        catch {
            $queryFailure = $_.Exception.Message
            break
        }

        if (@($records | Where-Object success -EQ $true).Count -gt 0) {
            return [ordered]@{
                status = 'available'
                queryStartUtc = $StartTime.ToString('o')
                queryEndUtc = $EndTime.ToString('o')
                recordCount = $records.Count
                records = @($records)
            }
        }

        Start-Sleep -Seconds 10
    }

    $reason = if ($null -ne $queryFailure) {
        "The sanitized dependency query failed: $queryFailure"
    }
    elseif ($records.Count -eq 0) {
        'No Render-target dependency records were available for the validator time window.'
    }
    else {
        'Render-target dependency records were available, but none recorded a successful Function-to-Render call.'
    }

    return [ordered]@{
        status = 'not-observed'
        classification = 'evidence-gap'
        queryStartUtc = $StartTime.ToString('o')
        queryEndUtc = $EndTime.ToString('o')
        recordCount = $records.Count
        records = @($records)
        reason = $reason
        sourceAssessment =
            'The deployed Function package does not establish ' +
            'worker-originated Application Insights dependency collection.'
        risk =
            'Application Insights cannot independently prove the deployed ' +
            'worker dependency path or correlate rejected ingress requests.'
        recovery =
            'Establish worker-originated dependency collection in a separately ' +
            'approved Function package, then rerun this bounded query.'
    }
}


Export-ModuleMember -Function 'Get-DependencyTelemetryEvidence'
