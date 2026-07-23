@{
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # These are interactive admin tools. Progress and summaries on the host
        # are deliberate; the actual result goes to the pipeline.
        'PSAvoidUsingWriteHost',

        # Flags deliberately aligned continuation lines (multi-line regex
        # concatenation, aligned if/elseif/else) as misindented. Indentation is
        # handled by .editorconfig instead.
        'PSUseConsistentIndentation'
    )

    Rules        = @{
        PSPlaceOpenBrace = @{
            Enable     = $true
            OnSameLine = $true
        }
    }
}
