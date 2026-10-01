@{
    RootModule        = 'PSVsCommand.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a6c73fc2-36e2-49bb-86ad-6f863cea5fc9'
    Author            = 'WizX20'
    CompanyName       = 'WizX20'
    Copyright         = '(c) 2026 WizX20. Business Source License 1.1.'
    Description       = 'vs - open the right solution in the right Visual Studio from the command line: finds every .sln/.slnx below the current folder, offers a picker when there are several, and matches each one to an installed Visual Studio (SSRS projects to the install with the Reporting Services extension, and so on).'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport = @('vs')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('visual-studio', 'devenv', 'solution', 'sln', 'windows', 'cli')
            LicenseUri = 'https://github.com/WizX20/PSVsCommand/blob/main/LICENSE'
            ProjectUri = 'https://github.com/WizX20/PSVsCommand'
            ReleaseNotes = 'https://github.com/WizX20/PSVsCommand/blob/main/CHANGELOG.md'
        }
    }
}
