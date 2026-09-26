. "$PSScriptRoot/Common.ps1"

function Assert-Equal($Actual, $Expected) {
    if ($Actual -ne $Expected) { throw "Expected '$Expected', got '$Actual'." }
}

$script:events = ''
Invoke-DeploymentTransaction -Activate { $script:events += 'activate;' } -Verify { $script:events += 'verify;' } -Rollback { $script:events += 'rollback;' }
Assert-Equal $script:events 'activate;verify;'

$basePath = [IO.Path]::GetTempPath()
Assert-Equal (Test-PathWithin -Path (Join-Path $basePath 'releases/keys') -Parent (Join-Path $basePath 'releases')) $true
Assert-Equal (Test-PathWithin -Path (Join-Path $basePath 'releases-old') -Parent (Join-Path $basePath 'releases')) $false

foreach ($failureStage in @('activate', 'verify')) {
    $script:events = ''
    $caught = $false
    try {
        Invoke-DeploymentTransaction -Activate {
            $script:events += 'activate;'
            if ($failureStage -eq 'activate') { throw 'simulated activation failure' }
        } -Verify {
            $script:events += 'verify;'
            throw 'simulated health failure'
        } -Rollback { $script:events += 'rollback;' }
    } catch { $caught = $true }
    Assert-Equal $caught $true
    if ($failureStage -eq 'activate') { Assert-Equal $script:events 'activate;rollback;' }
    else { Assert-Equal $script:events 'activate;verify;rollback;' }
}

# Reject an artifact from a different run, including when its commit matches.
$testDirectory = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testDirectory | Out-Null
$manifestPath = Join-Path $testDirectory 'release.json'
try {
    $sha = 'a' * 40
    @{ commit = $sha; runId = '123' } | ConvertTo-Json | Set-Content -LiteralPath $manifestPath
    Assert-Release -Directory $testDirectory -Sha $sha -RunId '123'
    foreach ($identity in @(@{ Sha = ('b' * 40); RunId = '123' }, @{ Sha = $sha; RunId = '456' })) {
        $caught = $false
        try { Assert-Release -Directory $testDirectory -Sha $identity.Sha -RunId $identity.RunId } catch { $caught = $true }
        Assert-Equal $caught $true
    }
} finally {
    Remove-Item -LiteralPath $manifestPath
    Remove-Item -LiteralPath $testDirectory
}
Write-Output 'Deployment identity and rollback failure tests passed.'
