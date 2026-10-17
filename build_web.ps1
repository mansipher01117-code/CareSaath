<#
    Builds the Flutter web app for a Vercel static upload.

    The API URL is compiled in (frontend/lib/api.dart reads it through
    String.fromEnvironment), so a build is tied to one backend.

        .\build_web.ps1 https://caresaath-api.vercel.app

    Output: frontend/build/web — upload that folder to Vercel, or point a
    Vercel project at it. vercel.json travels with it so deep links
    (/today, /ask, ...) are served index.html instead of a 404.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Base URL of the deployed backend, e.g. https://caresaath-api.vercel.app")]
    [string]$ApiUrl
)

$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
$frontend = Join-Path $root "frontend"
$out = Join-Path $frontend "build\web"

Write-Host "Building Flutter web against $ApiUrl" -ForegroundColor Cyan

Push-Location $frontend
try {
    flutter build web --release --dart-define=API_URL=$ApiUrl
    if ($LASTEXITCODE -ne 0) { throw "flutter build web failed with exit code $LASTEXITCODE" }
}
finally {
    Pop-Location
}

Copy-Item (Join-Path $frontend "vercel.json") -Destination $out -Force

Write-Host "Done: $out" -ForegroundColor Green
