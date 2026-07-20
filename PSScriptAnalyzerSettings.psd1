@{
    Severity = @('Error', 'Warning')

    # Plugin functions are private implementation details rather than a public
    # PowerShell command surface. Plural nouns are retained where the function
    # intentionally returns or operates on a collection.
    #
    # Winix owns confirmation at the protocol-v2 plan/apply boundary. Adding a
    # second ShouldProcess contract to private helpers would create a competing
    # execution path and would incorrectly flag pure New-* operation builders.
    ExcludeRules = @(
        'PSUseShouldProcessForStateChangingFunctions'
        'PSUseSingularNouns'
    )
}
