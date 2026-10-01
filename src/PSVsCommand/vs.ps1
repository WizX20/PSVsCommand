# `vs` entry point for shells that have not imported the module: Scoop's shims (vs.ps1, vs.cmd
# and the bash `vs`) run this file with the arguments after `vs`. Opening Visual Studio needs no
# cd, so this does everything the function does - from PowerShell it runs in-process and leaves
# the module imported; only Tab completion before that first call needs `vs install profile`.
Import-Module (Join-Path $PSScriptRoot 'PSVsCommand.psd1')
vs @args
