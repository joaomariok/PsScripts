@{
    RootModule = 'Common.psm1'
    ModuleVersion = '1.0.0'
    GUID = '0e4b9f4d-6e1e-4bc8-aaba-737539342ed5'
    Author = 'joaomariok'
    FunctionsToExport = @(
        # Guards.psm1
        'Confirm-Action',
        'Test-Elevated',
        'Test-ExternalCommand',

        # DiffTools.psm1
        'Compare-Diff',
        'Compare-CharDiff',

        # Write.psm1
        'Write-EmptyLine',
        'Write-Text',
        'Write-Success',
        'Write-Title',
        'Write-MainTitle',
        'Show-PathEntries',

        # Tree.psm1
        'Show-Tree',
        'Show-TreeFromList',

        # FileTools.psm1
        'Find-DuplicateFile',

        # ImageSimilarity.psm1
        'Find-SimilarImage'

        # ExternalTools.psm1's Get-FilesViaEverything and Get-EnumeratedFiles are intentionally
        # not listed here -- they're exported from their own module for reuse by
        # FileTools.psm1/ImageSimilarity.psm1, but aren't part of Common's public surface.
    )
    CmdletsToExport = '*'
    VariablesToExport = '*'
    AliasesToExport = '*'
}
