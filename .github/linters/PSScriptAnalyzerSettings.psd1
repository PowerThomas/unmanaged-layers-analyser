@{
    ExcludeRules = @(
        # This is an interactive, colourized CLI script; Write-Host is used deliberately for prompts and diff output.
        'PSAvoidUsingWriteHost'

        # Existing internal helper names use plural nouns and are currently published as a script, not a module.
        # A v2 module conversion can cleanly separate public commands from private helpers.
        'PSUseSingularNouns'
    )
}