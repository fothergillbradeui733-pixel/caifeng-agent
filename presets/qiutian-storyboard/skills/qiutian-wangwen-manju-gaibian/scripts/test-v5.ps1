# Compatibility shim. V6 is the only maintained test suite.
& (Join-Path $PSScriptRoot 'test-v6.ps1') @args
exit $LASTEXITCODE
