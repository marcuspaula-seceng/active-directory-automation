BeforeAll {
    Import-Module "$PSScriptRoot/../lib/IdentityHelpers.psm1" -Force
}

Describe 'ConvertTo-SafeSamAccountName' {
    It 'builds first-initial plus last-name in lowercase' {
        ConvertTo-SafeSamAccountName -FirstName 'Jane' -LastName 'Smith' | Should -Be 'jsmith'
    }

    It 'removes punctuation and spaces' {
        ConvertTo-SafeSamAccountName -FirstName 'Ana' -LastName "D'Ávila Silva" | Should -Be 'adavsilva'
    }

    It 'respects the 20-character SAMAccountName limit' {
        (ConvertTo-SafeSamAccountName -FirstName 'Alexandra' -LastName 'VeryLongSurnameForTesting').Length | Should -BeLessOrEqual 20
    }

    It 'rejects whitespace-only names' {
        { ConvertTo-SafeSamAccountName -FirstName ' ' -LastName 'Smith' } | Should -Throw
    }
}

Describe 'Get-RedactedIdentifier' {
    It 'redacts identifiers while preserving minimal correlation context' {
        Get-RedactedIdentifier -Value 'abcdef1234' | Should -Be 'ab***34'
    }
}
