# Redefine a senha do usuario "postgres" (PostgreSQL 18 local).
# EXECUTE COMO ADMINISTRADOR:
#   powershell -ExecutionPolicy Bypass -File .\reset-pg-password.ps1 -NewPassword "minhasenha"
#
# Faz backup do pg_hba.conf, libera acesso 'trust' temporariamente, troca a senha,
# restaura o arquivo original e reinicia o servico.

param(
  [Parameter(Mandatory = $true)]
  [string]$NewPassword
)

$ErrorActionPreference = "Stop"

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw "Abra o PowerShell como Administrador e rode novamente."
}

$pgbin = "C:\Program Files\PostgreSQL\18\bin"
$hba   = "C:\Program Files\PostgreSQL\18\data\pg_hba.conf"
$svc   = "postgresql-x64-18"

Copy-Item $hba "$hba.bak" -Force
try {
  (Get-Content $hba) -replace 'scram-sha-256', 'trust' -replace '\bmd5\b', 'trust' |
    Set-Content $hba -Encoding ascii
  Restart-Service $svc

  $safe = $NewPassword.Replace("'", "''")
  & "$pgbin\psql.exe" -U postgres -h localhost -c "ALTER USER postgres PASSWORD '$safe';"
  if ($LASTEXITCODE -ne 0) { throw "psql falhou ao alterar a senha." }
}
finally {
  Copy-Item "$hba.bak" $hba -Force
  Restart-Service $svc
}

Write-Host "OK - senha do postgres redefinida e pg_hba.conf restaurado."
