Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module `
    (Join-Path $PSScriptRoot 'Html2b.AzureStateValidation.psm1')

function New-SanitizedDependencyAnalyticsQuery {
    param(
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

    return @(
        'dependencies',
        "| where timestamp >= todatetime('$startText')",
        "| where timestamp <= todatetime('$endText')",
        "| where target contains '$escapedRenderHostName'",
        "or name contains '$escapedRenderHostName'",
        "or data contains '$escapedRenderHostName'",
        '| project timestamp, name, type, target, resultCode, success, duration,',
        'operationId = operation_Id',
        '| order by timestamp asc'
    ) -join ' '
}

function ConvertFrom-SanitizedDependencyQueryResponse {
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Response
    )

    $expectedColumns = @(
        'timestamp',
        'name',
        'type',
        'target',
        'resultCode',
        'success',
        'duration',
        'operationId'
    )
    $tables = @($Response.tables)
    if ($tables.Count -ne 1) {
        throw 'The sanitized dependency query returned an unexpected table count.'
    }

    $table = $tables[0]
    $columns = @($table.columns)
    if ($columns.Count -ne $expectedColumns.Count) {
        throw 'The sanitized dependency query returned an unexpected schema.'
    }
    for ($index = 0; $index -lt $expectedColumns.Count; $index++) {
        if ([string] $columns[$index].name -cne $expectedColumns[$index]) {
            throw 'The sanitized dependency query returned an unexpected schema.'
        }
    }

    $records = @()
    foreach ($rowValue in @($table.rows)) {
        $row = @($rowValue)
        if ($row.Count -ne $expectedColumns.Count) {
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
    $analyticsQuery = New-SanitizedDependencyAnalyticsQuery `
        -StartTime $StartTime `
        -EndTime $EndTime `
        -RenderHostName $RenderHostName

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
            '--output', 'json'
        )
    $response = ConvertFrom-AzureCliJson `
        -Json $json `
        -Operation 'query sanitized Function dependency telemetry'

    return ConvertFrom-SanitizedDependencyQueryResponse -Response $response
}

function Test-RenderDependencyEvidenceRecord {
    param(
        [Parameter(Mandatory)]
        [object] $Record,

        [Parameter(Mandatory)]
        [string] $RenderHostName
    )

    [TimeSpan] $duration = [TimeSpan]::Zero
    $hasPositiveDuration = [TimeSpan]::TryParse(
        [string] $Record.duration,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [ref] $duration) -and $duration -gt [TimeSpan]::Zero
    $hasExpectedName =
        [string]::Equals(
            [string] $Record.name,
            'POST /internal/renders',
            [StringComparison]::OrdinalIgnoreCase) -or
        [string]::Equals(
            [string] $Record.name,
            'GET /health/ready',
            [StringComparison]::OrdinalIgnoreCase)

    return (
        [string]::Equals(
            [string] $Record.target,
            $RenderHostName,
            [StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals(
            [string] $Record.type,
            'Http',
            [StringComparison]::OrdinalIgnoreCase) -and
        [string] $Record.resultCode -ceq '200' -and
        $Record.success -eq $true -and
        -not [string]::IsNullOrWhiteSpace([string] $Record.operationId) -and
        $hasPositiveDuration -and
        $hasExpectedName
    )
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

        [TimeSpan] $Timeout = [TimeSpan]::FromMinutes(5)
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

        $qualifyingRecords = @(
            $records |
                Where-Object {
                    Test-RenderDependencyEvidenceRecord `
                        -Record $_ `
                        -RenderHostName $RenderHostName
                }
        )
        if ($qualifyingRecords.Count -gt 0) {
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
        'Render-related dependency records were available, but none proved an exact successful and correlated Function-to-Render call.'
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
            'No exact successful and correlated Render-target worker ' +
            'dependency was observed within the bounded telemetry polling window.'
        risk =
            'Application Insights cannot correlate a successful Function ' +
            'invocation with its outbound Render dependency for the validation window.'
        recovery =
            'Verify that the deployed Function package includes worker ' +
            'dependency collection, allow for telemetry ingestion, and rerun ' +
            'this bounded query.'
    }
}


Export-ModuleMember -Function 'Get-DependencyTelemetryEvidence'
