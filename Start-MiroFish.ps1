<#
 MiroFish tek komutla kurulum + başlatma (Windows 11, Docker'sız).
 Kullanım:  powershell -ExecutionPolicy Bypass -File .\Start-MiroFish.ps1
 API anahtarları betiğe yazılmaz; .env dosyasına siz girersiniz.
#>
$ErrorActionPreference = 'Stop'
$Root = Join-Path $HOME 'MiroFish'

function Need($cmd, $wingetId) {
  if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
    Write-Host "$cmd eksik, winget ile kuruluyor ($wingetId)..."
    winget install --id $wingetId -e --accept-source-agreements --accept-package-agreements
    $env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
      throw "$cmd kuruldu ama bu pencerede bulunamadı. PowerShell'i kapatıp yeniden açın ve betiği tekrar çalıştırın."
    }
  }
}

Need git    'Git.Git'
Need node   'OpenJS.NodeJS.LTS'
Need uv     'astral-sh.uv'   # uv, projenin istediği Python 3.11/3.12'yi kendisi indirir; sistem Python'una dokunmaz

if (-not (Test-Path $Root)) { git clone https://github.com/666ghj/MiroFish.git $Root }
Set-Location $Root

if (-not (Test-Path .env)) {
  Copy-Item .env.example .env
  Write-Host "`n.env oluşturuldu. LLM_API_KEY ve ZEP_API_KEY değerlerini girin:" -ForegroundColor Yellow
  notepad .env | Out-Null
}
$envText = Get-Content .env -Raw
if ($envText -match 'your_api_key_here' -or $envText -match 'your_zep_api_key_here') {
  throw ".env içinde LLM_API_KEY / ZEP_API_KEY hâlâ örnek değerde. Doldurup betiği tekrar çalıştırın."
}

if (-not (Test-Path node_modules) -or -not (Test-Path frontend\node_modules) -or -not (Test-Path backend\.venv)) {
  npm run setup:all
}

Start-Process 'http://localhost:3000'
npm run dev
