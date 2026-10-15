# Arranca el servidor MCP. Uso: .\scripts\start.ps1   (lee el token de .mcp-token o lo genera)
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
$tokFile = Join-Path $root ".mcp-token"
if (-not $env:MCP_TOKEN) {
  if (-not (Test-Path $tokFile)) {
    $bytes = New-Object byte[] 32; [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    ([Convert]::ToBase64String($bytes) -replace '[+/=]','') | Set-Content -NoNewline $tokFile
    Write-Host "Token nuevo generado en $tokFile"
  }
  $env:MCP_TOKEN = (Get-Content $tokFile -Raw).Trim()
}
if (-not $env:MCP_PORT) { $env:MCP_PORT = "3333" }
if (-not (Test-Path "dist\index.js")) { npm run build }
node dist/index.js
