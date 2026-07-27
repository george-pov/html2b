Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:MaximumResponseBytes = 16 * 1024 * 1024
$script:ExpectedWidth = 1280
$script:ExpectedHeight = 720
$script:ExpectedPdfWidthPoints = 960
$script:ExpectedPdfHeightPoints = 540

function Get-BigEndianUInt16 {
    param(
        [Parameter(Mandatory)]
        [byte[]] $Bytes,

        [Parameter(Mandatory)]
        [int] $Offset
    )

    return ([int] $Bytes[$Offset] -shl 8) -bor
        [int] $Bytes[$Offset + 1]
}

function Get-BigEndianUInt32 {
    param(
        [Parameter(Mandatory)]
        [byte[]] $Bytes,

        [Parameter(Mandatory)]
        [int] $Offset
    )

    return ([int64] $Bytes[$Offset] -shl 24) -bor
        ([int64] $Bytes[$Offset + 1] -shl 16) -bor
        ([int64] $Bytes[$Offset + 2] -shl 8) -bor
        [int64] $Bytes[$Offset + 3]
}

function Assert-FileSignature {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('png', 'jpeg', 'pdf')]
        [string] $Format,

        [Parameter(Mandatory)]
        [byte[]] $Bytes
    )

    if ($Bytes.Length -eq 0) {
        throw "$Format response was empty."
    }

    switch ($Format) {
        'png' {
            if ($Bytes.Length -lt 24) {
                throw 'PNG response was too short.'
            }

            $signature = [byte[]] @(
                0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)
            for ($index = 0; $index -lt $signature.Length; $index++) {
                if ($Bytes[$index] -ne $signature[$index]) {
                    throw 'PNG signature validation failed.'
                }
            }
        }
        'jpeg' {
            if ($Bytes.Length -lt 4 -or
                $Bytes[0] -ne 0xff -or
                $Bytes[1] -ne 0xd8 -or
                $Bytes[-2] -ne 0xff -or
                $Bytes[-1] -ne 0xd9) {
                throw 'JPEG signature validation failed.'
            }
        }
        'pdf' {
            if ($Bytes.Length -lt 5 -or
                [System.Text.Encoding]::ASCII.GetString($Bytes, 0, 5) -ne
                    '%PDF-') {
                throw 'PDF signature validation failed.'
            }
        }
    }
}

function Assert-RasterDimensions {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('png', 'jpeg')]
        [string] $Format,

        [Parameter(Mandatory)]
        [byte[]] $Bytes
    )

    if ($Format -eq 'png') {
        $width = Get-BigEndianUInt32 -Bytes $Bytes -Offset 16
        $height = Get-BigEndianUInt32 -Bytes $Bytes -Offset 20
    }
    else {
        $offset = 2
        $width = 0
        $height = 0
        $startOfFrameMarkers = @(
            0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7,
            0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf)
        while ($offset + 8 -lt $Bytes.Length) {
            if ($Bytes[$offset] -ne 0xff) {
                $offset++
                continue
            }
            while ($offset -lt $Bytes.Length -and
                $Bytes[$offset] -eq 0xff) {
                $offset++
            }
            if ($offset -ge $Bytes.Length) {
                break
            }

            $marker = $Bytes[$offset]
            $offset++
            if ($marker -eq 0xd8 -or
                $marker -eq 0xd9 -or
                ($marker -ge 0xd0 -and $marker -le 0xd7)) {
                continue
            }
            if ($offset + 1 -ge $Bytes.Length) {
                break
            }

            $segmentLength = Get-BigEndianUInt16 `
                -Bytes $Bytes `
                -Offset $offset
            if ($startOfFrameMarkers -contains $marker) {
                if ($offset + 6 -ge $Bytes.Length) {
                    break
                }
                $height = Get-BigEndianUInt16 `
                    -Bytes $Bytes `
                    -Offset ($offset + 3)
                $width = Get-BigEndianUInt16 `
                    -Bytes $Bytes `
                    -Offset ($offset + 5)
                break
            }
            if ($segmentLength -lt 2) {
                break
            }

            $offset += $segmentLength
        }
    }

    if ($width -ne $script:ExpectedWidth -or
        $height -ne $script:ExpectedHeight) {
        throw "$Format dimensions were ${width}x${height}, expected 1280x720."
    }

    return [ordered]@{
        width = $width
        height = $height
    }
}

function Assert-PdfPageSize {
    param(
        [Parameter(Mandatory)]
        [byte[]] $Bytes
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
            [Math]::Abs(
                $values[2] - $script:ExpectedPdfWidthPoints) -lt 0.1 -and
            [Math]::Abs(
                $values[3] - $script:ExpectedPdfHeightPoints) -lt 0.1) {
            return [ordered]@{
                widthPoints = $script:ExpectedPdfWidthPoints
                heightPoints = $script:ExpectedPdfHeightPoints
            }
        }
    }

    throw 'PDF page box did not match 960x540 points.'
}

function Get-Html2bResponseFileName {
    param(
        [AllowNull()]
        [System.Net.Http.Headers.ContentDispositionHeaderValue] $Disposition,

        [Parameter(Mandatory)]
        [string] $Format
    )

    if ($null -eq $Disposition) {
        throw "$Format response omitted Content-Disposition."
    }

    $fileName = if (
        -not [string]::IsNullOrWhiteSpace($Disposition.FileNameStar)) {
        $Disposition.FileNameStar
    }
    else {
        $Disposition.FileName
    }
    if ([string]::IsNullOrWhiteSpace($fileName)) {
        throw "$Format response contained an empty Content-Disposition filename."
    }

    return $fileName.Trim('"')
}

function Assert-Html2bOutputContract {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('png', 'jpeg', 'pdf')]
        [string] $Format,

        [Parameter(Mandatory)]
        [byte[]] $Bytes,

        [AllowNull()]
        [string] $ContentType,

        [AllowNull()]
        [string] $FileName
    )

    $contracts = @{
        png = @{
            ContentType = 'image/png'
            FileName = 'html2b-poc.png'
        }
        jpeg = @{
            ContentType = 'image/jpeg'
            FileName = 'html2b-poc.jpg'
        }
        pdf = @{
            ContentType = 'application/pdf'
            FileName = 'html2b-poc.pdf'
        }
    }
    $contract = $contracts[$Format]

    if ($ContentType -cne $contract.ContentType) {
        throw "$Format returned an unexpected content type."
    }
    if ([string]::IsNullOrWhiteSpace($FileName) -or
        $FileName.Trim('"') -cne $contract.FileName) {
        throw "$Format returned an unexpected filename."
    }
    if ($Bytes.Length -gt $script:MaximumResponseBytes) {
        throw "$Format exceeded the 16 MiB response limit."
    }

    Assert-FileSignature -Format $Format -Bytes $Bytes
    $dimensions = if ($Format -eq 'pdf') {
        Assert-PdfPageSize -Bytes $Bytes
    }
    else {
        Assert-RasterDimensions -Format $Format -Bytes $Bytes
    }

    return [ordered]@{
        contentType = [string] $contract.ContentType
        fileName = [string] $contract.FileName
        byteCount = $Bytes.Length
        signatureValidated = $true
        dimensions = $dimensions
    }
}

Export-ModuleMember -Function @(
    'Assert-Html2bOutputContract',
    'Get-Html2bResponseFileName'
)
