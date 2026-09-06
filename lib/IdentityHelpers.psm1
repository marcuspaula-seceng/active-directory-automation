Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-SafeSamAccountName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$FirstName,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$LastName,
        [Parameter()][ValidateRange(3,20)][int]$MaxLength = 20
    )

    $first = $FirstName.Trim()
    $last  = $LastName.Trim()

    if (-not $first -or -not $last) {
        throw 'FirstName and LastName must contain non-whitespace characters.'
    }

    $raw = "$($first[0])$last".Normalize([Text.NormalizationForm]::FormD)
    $ascii = -join ($raw.ToCharArray() | Where-Object {
        [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne [Globalization.UnicodeCategory]::NonSpacingMark
    })

    $safe = ($ascii -replace '[^a-zA-Z0-9]', '').ToLowerInvariant()
    if (-not $safe) {
        throw 'Unable to generate a valid SAMAccountName from the supplied name.'
    }

    if ($safe.Length -gt $MaxLength) {
        $safe = $safe.Substring(0, $MaxLength)
    }

    return $safe
}

function Get-RedactedIdentifier {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNull()][string]$Value
    )

    if ($Value.Length -le 4) {
        return ('*' * $Value.Length)
    }

    return "$($Value.Substring(0,2))***$($Value.Substring($Value.Length - 2))"
}

Export-ModuleMember -Function ConvertTo-SafeSamAccountName, Get-RedactedIdentifier
