# `vs` entry point for shells that have not imported the module: Scoop's shims (vs.ps1, vs.cmd
# and the bash `vs`) run this file with the arguments after `vs`. Opening Visual Studio needs no
# cd, so this does everything the function does - from PowerShell it runs in-process and leaves
# the module imported; only Tab completion before that first call needs `vs install profile`.
# The exit code is 1 when nothing was found, opened or changed as asked, so cmd, bash and
# scripts can tell.
$module = Import-Module (Join-Path $PSScriptRoot 'PSVsCommand.psd1') -PassThru
vs @args
exit (& $module { $script:VsExitCode })
