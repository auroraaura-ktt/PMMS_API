$ErrorActionPreference = 'Stop'

$ProjectRoot = $PSScriptRoot
$FlutterProject = Join-Path $ProjectRoot 'flutter\flutter_application_1'
$FlutterBuild = Join-Path $FlutterProject 'build\web'
$ServerUrl = 'http://127.0.0.1:8080'
$DjangoUrl = 'http://127.0.0.1:8001'

function Test-ListeningPort([int]$Port) {
    return [bool](Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
}

$FlutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
if ($FlutterCommand) {
    $Flutter = $FlutterCommand.Source
} else {
    $FlutterCandidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\flutter\bin\flutter.bat'),
        'D:\flutter_windows_3.47.7-stable\flutter\bin\flutter.bat'
    )
    $Flutter = $FlutterCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $Flutter) {
        throw 'Flutter SDK was not found on PATH or in the usual local install folders. Install Flutter or add its bin folder to PATH.'
    }
}
if (-not (Test-Path (Join-Path $ProjectRoot 'manage.py'))) {
    throw 'manage.py was not found. Keep run_flutter.ps1 in the Django project root.'
}
if (-not (Test-Path (Join-Path $ProjectRoot 'venv\Scripts\python.exe'))) {
    Write-Warning 'No project venv was found; using the Python interpreter available on PATH.'
    $Python = 'python'
} else {
    $Python = Join-Path $ProjectRoot 'venv\Scripts\python.exe'
}

Push-Location $FlutterProject
try {
    Write-Host 'Resolving Flutter packages...'
    & $Flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed.' }

    Write-Host 'Building PMMS for web...'
    & $Flutter build web --no-wasm-dry-run
    if ($LASTEXITCODE -ne 0) { throw 'Flutter web build failed.' }
} finally {
    Pop-Location
}

if (-not (Test-ListeningPort 8001)) {
    Write-Host 'Starting Django on http://127.0.0.1:8001 ...'
    Start-Process -FilePath $Python -ArgumentList @('manage.py', 'runserver', '127.0.0.1:8001', '--noreload') -WorkingDirectory $ProjectRoot -WindowStyle Hidden
} else {
    Write-Host 'Using Django already listening on port 8001.'
}

$ready = $false
for ($attempt = 0; $attempt -lt 30; $attempt++) {
    try {
        Invoke-WebRequest -Uri "$DjangoUrl/api/v1/csrf/" -TimeoutSec 2 -UseBasicParsing | Out-Null
        $ready = $true
        break
    } catch {
        Start-Sleep -Seconds 1
    }
}
if (-not $ready) { throw 'Django did not become ready. Check Python dependencies and the Django server.' }

if (-not (Test-ListeningPort 8080)) {
    Write-Host 'Starting PMMS web server on http://127.0.0.1:8080 ...'
    Start-Process -FilePath $Python -ArgumentList @('flutter_ui/dev_server.py') -WorkingDirectory $ProjectRoot -WindowStyle Hidden
} else {
    Write-Host 'Port 8080 is already in use; using the existing server.'
}

$ready = $false
for ($attempt = 0; $attempt -lt 15; $attempt++) {
    try {
        Invoke-WebRequest -Uri $ServerUrl -TimeoutSec 2 -UseBasicParsing | Out-Null
        $ready = $true
        break
    } catch {
        Start-Sleep -Seconds 1
    }
}
if (-not $ready) { throw 'PMMS web server did not become ready. Check whether port 8080 is available.' }

Start-Process $ServerUrl
Write-Host "PMMS is running at $ServerUrl. Keep this PowerShell window open; press Ctrl+C to stop waiting."
while ($true) { Start-Sleep -Seconds 2 }
