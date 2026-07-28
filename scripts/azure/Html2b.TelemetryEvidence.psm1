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
            duration = [Convert]::ToString(
                $row[6],
                [System.Globalization.CultureInfo]::InvariantCulture)
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

function Test-PositiveDependencyDuration {
    param(
        [AllowNull()]
        [object] $Duration
    )

    $durationText = [Convert]::ToString(
        $Duration,
        [System.Globalization.CultureInfo]::InvariantCulture)
    [double] $durationMilliseconds = 0
    if ([double]::TryParse(
            $durationText,
            [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref] $durationMilliseconds)) {
        return (
            [double]::IsFinite($durationMilliseconds) -and
            $durationMilliseconds -gt 0
        )
    }

    [TimeSpan] $durationTimeSpan = [TimeSpan]::Zero
    return (
        [TimeSpan]::TryParse(
            $durationText,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref] $durationTimeSpan) -and
        $durationTimeSpan -gt [TimeSpan]::Zero
    )
}

function Test-RenderDependencyEvidenceRecord {
    param(
        [Parameter(Mandatory)]
        [object] $Record,

        [Parameter(Mandatory)]
        [string] $RenderHostName
    )

    $hasPositiveDuration = Test-PositiveDependencyDuration `
        -Duration $Record.duration
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

function Resolve-FunctionAuthorizationTelemetryEvidence {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $NoKeyRecords,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $KeyedRecords,

        [Parameter(Mandatory)]
        [DateTimeOffset] $NoKeyStartTime,

        [Parameter(Mandatory)]
        [DateTimeOffset] $NoKeyEndTime,

        [Parameter(Mandatory)]
        [DateTimeOffset] $KeyedStartTime,

        [Parameter(Mandatory)]
        [DateTimeOffset] $KeyedEndTime,

        [Parameter(Mandatory)]
        [string] $RenderHostName
    )

    if ($NoKeyRecords.Count -ne 0) {
        throw 'No-key Function validation produced a Render dependency.'
    }

    $qualifyingKeyedRecords = @(
        $KeyedRecords |
            Where-Object {
                Test-RenderDependencyEvidenceRecord `
                    -Record $_ `
                    -RenderHostName $RenderHostName
            }
    )
    $readinessDependencyCount = @(
        $qualifyingKeyedRecords |
            Where-Object {
                [string]::Equals(
                    [string] $_.name,
                    'GET /health/ready',
                    [StringComparison]::OrdinalIgnoreCase)
            }
    ).Count
    $renderDependencyCount = @(
        $qualifyingKeyedRecords |
            Where-Object {
                [string]::Equals(
                    [string] $_.name,
                    'POST /internal/renders',
                    [StringComparison]::OrdinalIgnoreCase)
            }
    ).Count

    if ($readinessDependencyCount -eq 0 -or
        $renderDependencyCount -eq 0) {
        return [ordered]@{
            status = 'not-observed'
            classification = 'evidence-gap'
            reason =
                'The keyed telemetry window did not contain both an exact ' +
                'successful readiness dependency and an exact successful ' +
                'render dependency.'
            risk =
                'Application Insights cannot prove both keyed readiness and ' +
                'keyed rendering through the Function-to-Render boundary.'
            recovery =
                'Verify the deployed Function dependency collector, allow ' +
                'for telemetry ingestion, and rerun this bounded query.'
            noKey = [ordered]@{
                status = 'passed'
                queryStartUtc = $NoKeyStartTime.ToString('o')
                queryEndUtc = $NoKeyEndTime.ToString('o')
                recordCount = 0
            }
            keyed = [ordered]@{
                status = 'not-observed'
                queryStartUtc = $KeyedStartTime.ToString('o')
                queryEndUtc = $KeyedEndTime.ToString('o')
                recordCount = $KeyedRecords.Count
                records = @($KeyedRecords)
            }
        }
    }

    return [ordered]@{
        status = 'available'
        recordCount = $KeyedRecords.Count
        records = @($KeyedRecords)
        noKey = [ordered]@{
            status = 'passed'
            queryStartUtc = $NoKeyStartTime.ToString('o')
            queryEndUtc = $NoKeyEndTime.ToString('o')
            recordCount = 0
        }
        keyed = [ordered]@{
            status = 'available'
            queryStartUtc = $KeyedStartTime.ToString('o')
            queryEndUtc = $KeyedEndTime.ToString('o')
            recordCount = $KeyedRecords.Count
            records = @($KeyedRecords)
            readinessDependencyCount = $readinessDependencyCount
            renderDependencyCount = $renderDependencyCount
        }
    }
}

function Get-FunctionAuthorizationTelemetryEvidence {
    param(
        [Parameter(Mandatory)]
        [string] $Subscription,

        [Parameter(Mandatory)]
        [string] $GroupName,

        [Parameter(Mandatory)]
        [string] $ApplicationName,

        [Parameter(Mandatory)]
        [DateTimeOffset] $NoKeyStartTime,

        [Parameter(Mandatory)]
        [DateTimeOffset] $NoKeyEndTime,

        [Parameter(Mandatory)]
        [DateTimeOffset] $KeyedStartTime,

        [Parameter(Mandatory)]
        [DateTimeOffset] $KeyedEndTime,

        [Parameter(Mandatory)]
        [string] $RenderHostName,

        [TimeSpan] $Timeout = [TimeSpan]::FromMinutes(5)
    )

    if ($NoKeyStartTime -gt $NoKeyEndTime -or
        $KeyedStartTime -gt $KeyedEndTime -or
        $NoKeyEndTime -ge $KeyedStartTime) {
        throw 'Function authorization telemetry windows are invalid.'
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $pollIntervalMilliseconds = [Math]::Min(
        10000.0,
        [Math]::Max(1.0, $Timeout.TotalMilliseconds / 4.0))
    $noKeyRecords = @()
    $noKeyQueryFailure = $null
    $keyedRecords = @()
    $qualifyingKeyedRecords = @()
    $keyedQueryFailure = $null
    $hasReadinessDependency = $false
    $hasRenderDependency = $false
    while ($true) {
        try {
            $noKeyRecords = @(
                Get-SanitizedDependencyTelemetry `
                    -Subscription $Subscription `
                    -GroupName $GroupName `
                    -ApplicationName $ApplicationName `
                    -StartTime $NoKeyStartTime `
                    -EndTime $NoKeyEndTime `
                    -RenderHostName $RenderHostName
            )
            $noKeyQueryFailure = $null
        }
        catch {
            $noKeyQueryFailure = $_.Exception.Message
        }
        if ($noKeyRecords.Count -ne 0) {
            throw 'No-key Function validation produced a Render dependency.'
        }

        try {
            $keyedRecords = @(
                Get-SanitizedDependencyTelemetry `
                    -Subscription $Subscription `
                    -GroupName $GroupName `
                    -ApplicationName $ApplicationName `
                    -StartTime $KeyedStartTime `
                    -EndTime $KeyedEndTime `
                    -RenderHostName $RenderHostName
            )
            $keyedQueryFailure = $null
            $qualifyingKeyedRecords = @(
                $keyedRecords |
                    Where-Object {
                        Test-RenderDependencyEvidenceRecord `
                            -Record $_ `
                            -RenderHostName $RenderHostName
                    }
            )
            $hasReadinessDependency = @(
                $qualifyingKeyedRecords |
                    Where-Object {
                        [string]::Equals(
                            [string] $_.name,
                            'GET /health/ready',
                            [StringComparison]::OrdinalIgnoreCase)
                    }
            ).Count -gt 0
            $hasRenderDependency = @(
                $qualifyingKeyedRecords |
                    Where-Object {
                        [string]::Equals(
                            [string] $_.name,
                            'POST /internal/renders',
                            [StringComparison]::OrdinalIgnoreCase)
                    }
            ).Count -gt 0
        }
        catch {
            $keyedQueryFailure = $_.Exception.Message
        }

        $remainingMilliseconds =
            $Timeout.TotalMilliseconds - $stopwatch.Elapsed.TotalMilliseconds
        if ($remainingMilliseconds -le 0) {
            break
        }

        $sleepMilliseconds = [int] [Math]::Ceiling(
            [Math]::Min(
                $pollIntervalMilliseconds,
                $remainingMilliseconds))
        Start-Sleep -Milliseconds $sleepMilliseconds
    }

    if ($null -ne $noKeyQueryFailure) {
        return [ordered]@{
            status = 'not-observed'
            classification = 'evidence-gap'
            reason =
                'The sanitized no-key dependency query failed: ' +
                $noKeyQueryFailure
            risk =
                'Telemetry cannot independently prove that rejected no-key ' +
                'requests created no Render dependency.'
            recovery =
                'Restore the bounded telemetry query and rerun the complete ' +
                'Function authorization matrix.'
            noKey = [ordered]@{
                status = 'not-observed'
                queryStartUtc = $NoKeyStartTime.ToString('o')
                queryEndUtc = $NoKeyEndTime.ToString('o')
            }
            keyed = [ordered]@{
                status = if ($hasReadinessDependency -and
                    $hasRenderDependency) {
                    'available'
                }
                else {
                    'not-observed'
                }
                queryStartUtc = $KeyedStartTime.ToString('o')
                queryEndUtc = $KeyedEndTime.ToString('o')
                recordCount = $keyedRecords.Count
                records = @($keyedRecords)
            }
        }
    }

    if ($null -ne $keyedQueryFailure) {
        return [ordered]@{
            status = 'not-observed'
            classification = 'evidence-gap'
            reason =
                'The sanitized keyed dependency query failed: ' +
                $keyedQueryFailure
            risk =
                'Application Insights cannot prove both keyed readiness and ' +
                'keyed rendering through the Function-to-Render boundary.'
            recovery =
                'Verify the deployed Function dependency collector, allow ' +
                'for telemetry ingestion, and rerun this bounded query.'
            noKey = [ordered]@{
                status = 'passed'
                queryStartUtc = $NoKeyStartTime.ToString('o')
                queryEndUtc = $NoKeyEndTime.ToString('o')
                recordCount = 0
            }
            keyed = [ordered]@{
                status = 'not-observed'
                queryStartUtc = $KeyedStartTime.ToString('o')
                queryEndUtc = $KeyedEndTime.ToString('o')
                recordCount = $keyedRecords.Count
                records = @($keyedRecords)
            }
        }
    }

    return Resolve-FunctionAuthorizationTelemetryEvidence `
        -NoKeyRecords @($noKeyRecords) `
        -KeyedRecords @($keyedRecords) `
        -NoKeyStartTime $NoKeyStartTime `
        -NoKeyEndTime $NoKeyEndTime `
        -KeyedStartTime $KeyedStartTime `
        -KeyedEndTime $KeyedEndTime `
        -RenderHostName $RenderHostName
}


Export-ModuleMember -Function @(
    'Get-DependencyTelemetryEvidence',
    'Get-FunctionAuthorizationTelemetryEvidence'
)
