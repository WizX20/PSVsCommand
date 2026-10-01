@{
    # Information-level rules (comment help, positional parameters) are style advice for
    # published cmdlets; `vs` is a console tool with its own --help.
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # `vs` is an interactive console tool: coloured Write-Host lines ARE its output.
        'PSAvoidUsingWriteHost',
        # The internal Set-/Start-/Update-/New- helpers are driven by `vs`, which carries its own
        # confirmation flow (the open prompt, -Yes, y/N before running Scoop) instead of ShouldProcess.
        'PSUseShouldProcessForStateChangingFunctions',
        'PSUseSingularNouns',
        # Argument-completer script blocks must declare the leading positions of the
        # ($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
        # signature to reach the later ones, so the first two are unused by design.
        'PSReviewUnusedParameter'
    )
}
