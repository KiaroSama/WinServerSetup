<#
    PSScriptAnalyzer configuration for WinServerSetup.

    CI runs at Error AND Warning severity. Only the rules below are suppressed, each for a
    specific, documented architectural reason. Every other rule stays enabled - in particular
    PSAvoidUsingEmptyCatchBlock, PSAvoidAssignmentToAutomaticVariable, PSReviewUnusedParameter
    and PSAvoidOverwritingBuiltInCmdlets, which catch real defects in this codebase.

    Do not add a rule here to silence a finding. Fix the finding, or suppress it narrowly at the
    single site with [Diagnostics.CodeAnalysis.SuppressMessageAttribute] plus a justification.
#>
@{
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # The setup is a single orchestrated run whose steps are dot-sourced from scripts\.
        # Shared run state ($Global:Config, $Global:RunStats, $Global:ProjectRoot, the colour
        # table) is deliberately global so those scripts observe one consistent context.
        # Threading it through every call signature would be a large refactor with no
        # correctness benefit.
        'PSAvoidGlobalVars',

        # This is a provisioning tool: essentially every function changes machine state by
        # design. Confirmation is handled by the menu, the -NoPause/-Full contract and the
        # explicit prompts in the security section, not by per-function -WhatIf/-Confirm.
        'PSUseShouldProcessForStateChangingFunctions',

        # Established public command names that act on collections read better as plurals
        # (Install-WingetPackages, Remove-AppxPackages, ...). Renaming them would break the
        # menu routing, the scheduled-task action lines and the documented recovery commands.
        'PSUseSingularNouns',

        # A few long-standing names use verbs outside the approved list. They are part of the
        # documented interface for the same reason as above.
        'PSUseApprovedVerbs',

        # The console UI *is* the product here: the banner, menu, coloured status column and
        # progress output are all intentional host writes, not accidental debug output.
        'PSAvoidUsingWriteHost'
    )
}
