[CmdletBinding()]
param(
    [string]$PythonBin = 'python',
    [string]$VenvPath = ''
)

$ErrorActionPreference = 'Stop'
$appRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($VenvPath)) {
    $VenvPath = Join-Path $appRoot '.build-venv-windows'
}
$venvPython = Join-Path $VenvPath 'Scripts\python.exe'
$bundleRoot = Join-Path $appRoot 'windows\runner\resources\arxiv_markitdown'
$buildRoot = Join-Path $appRoot 'build\markitdown_pyinstaller_windows'
$flutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
if ($null -eq $flutterCommand) {
    $bundledFlutter = Join-Path $env:USERPROFILE 'develop\flutter\bin\flutter.bat'
    if (-not (Test-Path $bundledFlutter)) {
        throw 'Flutter was not found. Add it to PATH or install it at %USERPROFILE%\develop\flutter.'
    }
    $flutterPath = $bundledFlutter
} else {
    $flutterPath = $flutterCommand.Source
}

& $PythonBin -c 'import sys; raise SystemExit(sys.version_info < (3, 10))'
if ($LASTEXITCODE -ne 0) {
    throw 'Python 3.10 or later is required for Microsoft MarkItDown.'
}

if (-not (Test-Path $venvPython)) {
    & $PythonBin -m venv $VenvPath
}

& $venvPython -m pip install --upgrade pip
& $venvPython -m pip install --upgrade 'markitdown[pdf]>=0.1.0' pyinstaller

Remove-Item -Recurse -Force $buildRoot -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $bundleRoot -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $buildRoot | Out-Null
New-Item -ItemType Directory -Force (Split-Path -Parent $bundleRoot) | Out-Null

& $venvPython -m PyInstaller `
    --clean `
    --noconfirm `
    --onedir `
    --name arxiv_markitdown `
    --collect-all magika `
    --distpath (Join-Path $buildRoot 'dist') `
    --workpath (Join-Path $buildRoot 'work') `
    --specpath $buildRoot `
    (Join-Path $appRoot 'tools\markitdown_converter.py')

Copy-Item -Recurse -Force (Join-Path $buildRoot 'dist\arxiv_markitdown') $bundleRoot

Push-Location $appRoot
try {
    & $flutterPath pub get
    & $flutterPath build windows --release
} finally {
    Pop-Location
}

Write-Host "Release app: $appRoot\build\windows\x64\runner\Release\ArxivReaderAI.exe"
