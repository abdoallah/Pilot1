. "$PSScriptRoot/Common.ps1"
Import-Module WebAdministration

$artifact = Join-Path $PSScriptRoot '../../artifacts/deploy/iis'
$sha = Get-RequiredEnvironmentVariable 'RELEASE_SHA'
Assert-Release -Directory $artifact -Sha $sha -RunId (Get-RequiredEnvironmentVariable 'CI_RUN_ID')
$deploymentId = Get-DeploymentId
$siteName = Get-RequiredEnvironmentVariable 'IIS_SITE_NAME'
$pool = Get-RequiredEnvironmentVariable 'IIS_APP_POOL'
$releaseRoot = Get-DeploymentDirectory (Get-RequiredEnvironmentVariable 'IIS_RELEASES_PATH')
$keysPath = Get-DeploymentDirectory (Get-RequiredEnvironmentVariable 'DATA_PROTECTION_KEYS_PATH')
$healthUrl = Get-RequiredEnvironmentVariable 'HEALTH_URL'
$connection = Get-RequiredEnvironmentVariable 'APP_CONNECTION_STRING'
$applyMigrations = $env:APPLY_DATABASE_MIGRATIONS -eq 'true'
if ($applyMigrations) { $migrationConnection = Get-RequiredEnvironmentVariable 'MIGRATION_CONNECTION_STRING' }
if ($siteName -match '[\\/:*?\[\]]' -or $pool -match '[\\/:*?\[\]]') { throw 'Invalid IIS site or app pool name.' }
$site = Get-Website -Name $siteName
if (-not $site -or $site.ApplicationPool -ne $pool) { throw 'The configured site and application pool do not match.' }
if (@(Get-Website | Where-Object { $_.ApplicationPool -eq $pool }).Count -ne 1) { throw 'Use a dedicated application pool for this site.' }
$previousPath = [Environment]::ExpandEnvironmentVariables($site.PhysicalPath)
if (Test-PathWithin -Path $releaseRoot -Parent $previousPath) { throw 'Release storage must be outside the current website.' }
if (Test-PathWithin -Path $keysPath -Parent $releaseRoot) { throw 'Data Protection keys must be outside release storage.' }
if (Test-PathWithin -Path $keysPath -Parent $previousPath) { throw 'Data Protection keys must be outside the current website.' }
if ($env:GITHUB_WORKSPACE) {
    if ((Test-PathWithin -Path $releaseRoot -Parent $env:GITHUB_WORKSPACE) -or
        (Test-PathWithin -Path $keysPath -Parent $env:GITHUB_WORKSPACE)) {
        throw 'Release storage and Data Protection keys must be outside the runner workspace.'
    }
}
$wasRunning = (Get-WebAppPoolState -Name $pool).Value -eq 'Started'
$releasePath = Join-Path $releaseRoot "$sha-$deploymentId"
if (Test-Path -LiteralPath $releasePath) { throw 'Release directory already exists; use a new deployment attempt.' }
New-Item -ItemType Directory -Path $releasePath -Force | Out-Null
New-Item -ItemType Directory -Path $keysPath -Force | Out-Null
Copy-Item -Path (Join-Path $artifact 'site/*') -Destination $releasePath -Recurse -Force

# Keep production settings in this release's IIS configuration, never in the CI artifact.
$webConfigPath = Join-Path $releasePath 'web.config'
[xml]$webConfig = Get-Content -LiteralPath $webConfigPath -Raw
$aspNetCore = $webConfig.SelectSingleNode('//system.webServer/aspNetCore')
if (-not $aspNetCore) { throw 'The IIS release is missing ASP.NET Core hosting configuration.' }
$variables = $aspNetCore.SelectSingleNode('environmentVariables')
if (-not $variables) {
    $variables = $webConfig.CreateElement('environmentVariables')
    $aspNetCore.AppendChild($variables) | Out-Null
}
$settings = @{
    ASPNETCORE_ENVIRONMENT = 'Production'
    DOTNET_ENVIRONMENT = 'Production'
    ConnectionStrings__CoPilotDb = $connection
    DataProtection__KeysPath = $keysPath
}
foreach ($setting in $settings.GetEnumerator()) {
    $node = $variables.SelectSingleNode("environmentVariable[@name='$($setting.Key)']")
    if (-not $node) {
        $node = $webConfig.CreateElement('environmentVariable')
        $node.SetAttribute('name', $setting.Key)
        $variables.AppendChild($node) | Out-Null
    }
    $node.SetAttribute('value', $setting.Value)
}
$webConfig.Save($webConfigPath)

if ($applyMigrations) {
    $oldConnection = $env:ConnectionStrings__CoPilotDb
    try {
        $env:ConnectionStrings__CoPilotDb = $migrationConnection
        & (Join-Path $artifact 'efbundle.exe')
        if ($LASTEXITCODE -ne 0) { throw 'Database migration failed; the current IIS release is unchanged.' }
    } finally { $env:ConnectionStrings__CoPilotDb = $oldConnection }
} else { Write-Output 'Database migrations are disabled until the existing database has been baselined.' }

function Stop-DeploymentPool {
    if ((Get-WebAppPoolState -Name $pool).Value -ne 'Stopped') { Stop-WebAppPool -Name $pool }
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while ((Get-WebAppPoolState -Name $pool).Value -ne 'Stopped') {
        if ([DateTime]::UtcNow -ge $deadline) { throw 'IIS app pool did not stop within 30 seconds.' }
        Start-Sleep -Seconds 1
    }
}

$script:switched = $false
Invoke-DeploymentTransaction -Activate {
    Stop-DeploymentPool
    Set-ItemProperty -LiteralPath "IIS:\Sites\$siteName" -Name physicalPath -Value $releasePath
    $script:switched = $true
    Start-WebAppPool -Name $pool
} -Verify {
    Wait-Healthy -Url $healthUrl
} -Rollback {
    if ($script:switched) {
        Stop-DeploymentPool
        Set-ItemProperty -LiteralPath "IIS:\Sites\$siteName" -Name physicalPath -Value $previousPath
    }
    if ($wasRunning -and (Get-WebAppPoolState -Name $pool).Value -ne 'Started') { Start-WebAppPool -Name $pool }
    if ($wasRunning) { Wait-Healthy -Url $healthUrl }
}
Write-Output "Deployed $sha. Previous IIS release retained at $previousPath."
