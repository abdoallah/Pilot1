. "$PSScriptRoot/Common.ps1"

$artifact = Join-Path $PSScriptRoot '../../artifacts/deploy/docker'
$sha = Get-RequiredEnvironmentVariable 'RELEASE_SHA'
Assert-Release -Directory $artifact -Sha $sha -RunId (Get-RequiredEnvironmentVariable 'CI_RUN_ID')
$deploymentId = Get-DeploymentId
$connection = Get-RequiredEnvironmentVariable 'APP_CONNECTION_STRING'
$port = Get-RequiredEnvironmentVariable 'DOCKER_PORT'
if ($port -notmatch '^[0-9]+$' -or [int]$port -lt 1 -or [int]$port -gt 65535) { throw 'Invalid DOCKER_PORT.' }
$applyMigrations = $env:APPLY_DATABASE_MIGRATIONS -eq 'true'
if ($applyMigrations) { $migrationConnection = Get-RequiredEnvironmentVariable 'MIGRATION_CONNECTION_STRING' }

$name = 'copilot-web'
$network = 'databases_default'
$image = "${name}:$sha"
$candidate = "$name-candidate-$deploymentId"
$previous = "$name-previous-$deploymentId"
$keysVolume = 'copilot-data-protection'
if ((Invoke-Docker -Arguments @('info', '--format', '{{.OSType}}')) -ne 'linux') { throw 'A Linux Docker daemon is required.' }
Invoke-Docker -Arguments @('network', 'inspect', $network) | Out-Null
Invoke-Docker -Arguments @('load', '--input', (Join-Path $artifact 'image.tar')) | Out-Null
$revision = Invoke-Docker -Arguments @('image', 'inspect', $image, '--format', '{{index .Config.Labels "org.opencontainers.image.revision"}}')
if ($revision -ne $sha) { throw 'Docker image revision does not match the CI release.' }
Invoke-Docker -Arguments @('volume', 'create', $keysVolume) | Out-Null

$oldConnection = $env:ConnectionStrings__CoPilotDb
$env:ConnectionStrings__CoPilotDb = $connection
$candidateCreated = $false
$script:newCreated = $false
$script:oldRenamed = $false
$script:oldStopped = $false
$oldExists = @(Invoke-Docker -Arguments @('ps', '-aq', '--filter', "name=^${name}$")).Count -gt 0
$oldRunning = $false
if ($oldExists) { $oldRunning = (Invoke-Docker -Arguments @('inspect', $name, '--format', '{{.State.Running}}')) -eq 'true' }
$baseArguments = @('--network', $network, '--env', 'ConnectionStrings__CoPilotDb',
    '--env', 'ASPNETCORE_ENVIRONMENT=Production', '--env', 'DOTNET_ENVIRONMENT=Production',
    '--env', 'OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4317', '--env', 'OTEL_SERVICE_NAME=copilot-web',
    '--mount', "type=volume,source=$keysVolume,target=/var/lib/copilot/keys")

try {
    if ($applyMigrations) {
        $env:ConnectionStrings__CoPilotDb = $migrationConnection
        Invoke-Docker -Arguments @('run', '--rm', '--network', $network, '--env', 'ConnectionStrings__CoPilotDb',
            '--entrypoint', '/app/efbundle', $image) | Out-Null
        $env:ConnectionStrings__CoPilotDb = $connection
    } else { Write-Output 'Database migrations are disabled until the existing database has been baselined.' }

    # Validate the new image on a private ephemeral port while the current app still serves traffic.
    Invoke-Docker -Arguments (@('create', '--name', $candidate, '-p', '127.0.0.1::8080') + $baseArguments + @($image)) | Out-Null
    $candidateCreated = $true
    Invoke-Docker -Arguments @('start', $candidate) | Out-Null
    $binding = Invoke-Docker -Arguments @('port', $candidate, '8080/tcp')
    Wait-Healthy -Url "http://$binding/health"

    Invoke-DeploymentTransaction -Activate {
        if ($oldExists) {
            if ($oldRunning) {
                Invoke-Docker -Arguments @('stop', '--time', '30', $name) | Out-Null
                $script:oldStopped = $true
            }
            Invoke-Docker -Arguments @('rename', $name, $previous) | Out-Null
            $script:oldRenamed = $true
        }
        # Use create/start separately so rollback also handles startup failures.
        Invoke-Docker -Arguments (@('create', '--name', $name, '--restart', 'unless-stopped', '-p', "${port}:8080") + $baseArguments + @($image)) | Out-Null
        $script:newCreated = $true
        Invoke-Docker -Arguments @('start', $name) | Out-Null
    } -Verify {
        Wait-Healthy -Url "http://localhost:$port/health"
    } -Rollback {
        if ($script:newCreated) { Invoke-Docker -Arguments @('rm', '-f', $name) | Out-Null }
        if ($script:oldRenamed) { Invoke-Docker -Arguments @('rename', $previous, $name) | Out-Null }
        if ($script:oldStopped) {
            Invoke-Docker -Arguments @('start', $name) | Out-Null
            Wait-Healthy -Url "http://localhost:$port/health"
        }
    }
    Write-Output "Deployed $sha. Previous container retained as $previous when present."
} finally {
    $env:ConnectionStrings__CoPilotDb = $oldConnection
    if ($candidateCreated) { Invoke-Docker -Arguments @('rm', '-f', $candidate) | Out-Null }
}
