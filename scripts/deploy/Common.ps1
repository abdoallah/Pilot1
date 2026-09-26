Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RequiredEnvironmentVariable {
    param([string]$Name)
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) { throw "Missing deployment setting: $Name" }
    return $value
}

function Assert-Release {
    param([string]$Directory, [string]$Sha, [string]$RunId)
    if ($Sha -notmatch '^[a-f0-9]{40}$' -or $RunId -notmatch '^[1-9][0-9]*$') {
        throw 'Invalid release identity.'
    }
    $manifest = Get-Content -LiteralPath (Join-Path $Directory 'release.json') -Raw | ConvertFrom-Json
    if ($manifest.commit -ne $Sha -or [string]$manifest.runId -ne $RunId) {
        throw 'The downloaded artifact does not match the successful CI run.'
    }
}

function Get-DeploymentId {
    $value = Get-RequiredEnvironmentVariable 'DEPLOYMENT_ID'
    if ($value -notmatch '^[1-9][0-9]*-[1-9][0-9]*$') { throw 'Invalid deployment ID.' }
    return $value
}

function Get-DeploymentDirectory {
    param([string]$Path)
    if (-not [IO.Path]::IsPathRooted($Path)) { throw 'Deployment paths must be absolute.' }
    $resolved = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if ($resolved -eq [IO.Path]::GetPathRoot($resolved).TrimEnd([IO.Path]::DirectorySeparatorChar)) {
        throw 'A filesystem root cannot be used as a deployment directory.'
    }
    return $resolved
}

function Wait-Healthy {
    param([string]$Url, [int]$TimeoutSeconds = 90)
    $uri = [uri]$Url
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -notin @('http', 'https')) { throw 'Invalid health URL.' }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try {
            $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 5 -MaximumRedirection 0
            if ([int]$response.StatusCode -eq 200 -and $response.Content.Trim() -eq 'Healthy') { return }
        } catch { }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'The deployed application did not pass its readiness check.'
}

function Test-PathWithin {
    param([string]$Path, [string]$Parent)
    $candidate = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $root = [IO.Path]::GetFullPath($Parent).TrimEnd([IO.Path]::DirectorySeparatorChar)
    return $candidate.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
        $candidate.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
}

function Invoke-DeploymentTransaction {
    param([scriptblock]$Activate, [scriptblock]$Verify, [scriptblock]$Rollback)
    try {
        & $Activate
        & $Verify
    } catch {
        $failure = $_
        try { & $Rollback } catch { Write-Warning "Rollback also failed: $($_.Exception.Message)" }
        throw $failure
    }
}

function Invoke-Docker {
    param([string[]]$Arguments)
    $output = & docker @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Docker operation '$($Arguments[0])' failed with exit code $LASTEXITCODE." }
    return $output
}
