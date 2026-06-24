BeforeAll {
    $scriptPath = Join-Path $PSScriptRoot '..' 'Get-UnmanagedLayers.ps1'
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$parseErrors)

    if ($parseErrors) {
        throw "Unable to parse ${scriptPath}: $($parseErrors | ForEach-Object { $_.Message } | Join-String '; ')"
    }

    $functionDefinition = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-YesNoPrompt'
        }, $true)

    if (-not $functionDefinition) {
        throw 'Test-YesNoPrompt function was not found.'
    }

    . ([scriptblock]::Create($functionDefinition[0].Extent.Text))
}

Describe 'Test-YesNoPrompt' {
    It 'accepts standard affirmative values case-insensitively' {
        foreach ($value in @('y', 'Y', 'yes', 'YES')) {
            Test-YesNoPrompt -Value $value | Should -BeTrue
        }
    }

    It 'accepts locale-specific and compatibility values' {
        foreach ($value in @('j', 'J', '1')) {
            Test-YesNoPrompt -Value $value | Should -BeTrue
        }
    }

    It 'rejects negative, invalid, and empty values' {
        foreach ($value in @('n', 'no', 'invalid', '', '   ', $null)) {
            Test-YesNoPrompt -Value $value | Should -BeFalse
        }
    }
}
