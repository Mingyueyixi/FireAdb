$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $root 'native\fire_usb\fire_usb.c'
$outDir = Join-Path $root 'vendor\windows\x64'
$out = Join-Path $outDir 'fire_usb.dll'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

function Invoke-Cl {
  param([string]$Vcvars)
  cmd /c "`"$Vcvars`" && cl /nologo /O2 /LD /DFIRE_USB_BUILD `"$src`" /Fe:`"$out`" /Fo:`"$outDir\fire_usb.obj`""
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  Write-Host "built $out"
  exit 0
}

$cl = Get-Command cl -ErrorAction SilentlyContinue
if ($cl) {
  & cl /nologo /O2 /LD /DFIRE_USB_BUILD $src /Fe:$out /Fo:"$outDir\fire_usb.obj"
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  Write-Host "built $out"
  exit 0
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (Test-Path $vswhere) {
  $install = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
  if ($install) {
    $vcvars = Join-Path $install 'VC\Auxiliary\Build\vcvars64.bat'
    if (Test-Path $vcvars) { Invoke-Cl -Vcvars $vcvars }
  }
}

Write-Error 'cl.exe not found. Open x64 Native Tools or install VS C++ tools.'
exit 1
