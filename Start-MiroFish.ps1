<#
  MiroFish - Windows 11 otomatik kurulum betiği (Docker'sız, yerel kurulum).

  Tek komutla kurulum (normal PowerShell penceresinde):
    powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/trappigs/claude-bulut/main/Start-MiroFish.ps1 | iex"

  Ne yapar:
    1. Git, Node.js ve uv'yi denetler; eksikse winget ile kurar (Python'u uv yönetir).
    2. MiroFish'i  %USERPROFILE%\MiroFish  klasörüne klonlar (varsa yeniden indirmez).
    3. Frontend + backend bağımlılıklarını kurar (tamamlandıysa atlar).
    4. .env dosyasını .env.example'dan oluşturur (varsa dokunmaz).
    5. Masaüstüne "MiroFish Başlat" ve "MiroFish Ayarlar (.env)" kısayollarını koyar.
    6. Kayıtlar:  %USERPROFILE%\MiroFish-Launcher\logs

  API anahtarları bu betikte yoktur; .env dosyasına siz yazarsınız.
#>

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$RepoUrl  = 'https://github.com/666ghj/MiroFish.git'
$Root     = Join-Path $env:USERPROFILE 'MiroFish'
$Base     = Join-Path $env:USERPROFILE 'MiroFish-Launcher'
$LogDir   = Join-Path $Base 'logs'
$Launcher = Join-Path $Base 'MiroFish-Baslat.ps1'
$Marker   = Join-Path $Base 'kurulum-tamam.txt'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$InstallLog = Join-Path $LogDir ("kurulum-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$ErrorLog   = Join-Path $LogDir 'hatalar.log'
try { Start-Transcript -Path $InstallLog | Out-Null } catch {}

function Step($msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

function Update-SessionPath {
  $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $u = [Environment]::GetEnvironmentVariable('Path', 'User')
  $env:Path = (@($m, $u) | Where-Object { $_ }) -join ';'
  foreach ($extra in @(
      "$env:ProgramFiles\Git\cmd",
      "$env:ProgramFiles\nodejs",
      "$env:USERPROFILE\.local\bin",
      "$env:LOCALAPPDATA\Microsoft\WinGet\Links")) {
    if ((Test-Path $extra) -and ($env:Path -notlike "*$extra*")) { $env:Path += ";$extra" }
  }
}

function Has($cmd) { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

# Yerel komut çalıştırır; çıkış kodu 0 değilse hata fırlatır.
function Run([string]$Exe, [string[]]$Arguments) {
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { & $Exe @Arguments; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
  if ($code -ne 0) { throw "'$Exe $($Arguments -join ' ')' başarısız oldu (çıkış kodu $code)." }
}

function Ensure-Tool([string]$Cmd, [string]$WingetId, [string]$Label) {
  if (Has $Cmd) { Write-Host "[OK] $Label bulundu." -ForegroundColor Green; return }
  if (-not (Has 'winget')) {
    throw "$Label eksik ve winget bulunamadı. Microsoft Store'dan 'Uygulama Yükleyicisi' (App Installer) paketini güncelleyin ya da $Label aracını elle kurun."
  }
  Write-Host "[..] $Label kuruluyor (winget: $WingetId). Yönetici izni penceresi çıkabilir." -ForegroundColor Yellow
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { & winget install --id $WingetId -e --silent --accept-source-agreements --accept-package-agreements } finally { $ErrorActionPreference = $prev }
  Update-SessionPath
  if (-not (Has $Cmd)) {
    throw "$Label kuruldu ama bu pencerede bulunamadı. PowerShell'i kapatıp yeniden açın ve aynı komutu tekrar çalıştırın (kurulu olanlar atlanır)."
  }
  Write-Host "[OK] $Label kuruldu." -ForegroundColor Green
}

$failed = $false
try {
  Step 'Gereksinimler'
  Update-SessionPath
  Ensure-Tool 'git'  'Git.Git'            'Git'
  Ensure-Tool 'node' 'OpenJS.NodeJS.LTS'  'Node.js'
  Ensure-Tool 'uv'   'astral-sh.uv'       'uv'

  # Node sürümü: Vite 7, Node 20.19+ veya 22.12+ ister. Mevcut Node'u sessizce yükseltmiyoruz.
  $nv = [version](((& node -v) -replace '^v', '').Trim())
  $nodeOk = ($nv.Major -ge 23) -or ($nv.Major -eq 22 -and $nv.Minor -ge 12) -or ($nv.Major -eq 20 -and $nv.Minor -ge 19)
  if (-not $nodeOk) {
    throw "Node.js $nv çok eski (20.19+ veya 22.12+ gerekir). Diğer projelerinizi etkilememek için otomatik yükseltmedim. Güncellemek için: winget upgrade OpenJS.NodeJS.LTS"
  }
  Write-Host "[OK] Node.js $nv uygun."

  # Python: backend 3.11-3.12 ister. Sistem Python'una dokunmayız; uv kendi 3.12'sini indirir.
  $sysPy = $null
  try { if (Has 'python') { $sysPy = (& python --version 2>&1 | Out-String).Trim() } } catch {}
  if ($sysPy -match '^Python \d') { Write-Host "[i] Sistem Python'u: $sysPy (kullanılmayacak; uv uygun sürümü kendisi yönetir)" }
  else { Write-Host "[i] Kullanılabilir sistem Python'u yok; uv uygun sürümü (3.11-3.12) kendisi indirecek." }

  Step 'MiroFish deposu'
  if (Test-Path (Join-Path $Root '.git')) {
    Write-Host "[OK] Depo zaten var: $Root (yeniden indirilmedi)." -ForegroundColor Green
  } elseif (Test-Path $Root) {
    throw "$Root var ama bir git deposu değil. Taşıyın ya da silin, sonra tekrar çalıştırın."
  } else {
    Run 'git' @('clone', $RepoUrl, $Root)
  }

  Step 'Bağımlılıklar (frontend + backend)'
  $needSetup = (-not (Test-Path $Marker)) -or
               (-not (Test-Path (Join-Path $Root 'node_modules'))) -or
               (-not (Test-Path (Join-Path $Root 'frontend\node_modules'))) -or
               (-not (Test-Path (Join-Path $Root 'backend\.venv\Scripts\python.exe')))
  if ($needSetup) {
    Write-Host 'İlk kurulum: Python paketleri (PyTorch dahil) birkaç GB olabilir, 10-60 dk sürebilir.' -ForegroundColor Yellow
    Push-Location $Root
    try {
      Run 'npm.cmd' @('run', 'setup')
      Run 'npm.cmd' @('run', 'setup:backend')
    } finally { Pop-Location }
    Set-Content -Path $Marker -Value ("tamam: {0}" -f (Get-Date -Format 's')) -Encoding UTF8
  } else {
    Write-Host '[OK] Bağımlılıklar zaten kurulu, atlandı.' -ForegroundColor Green
  }

  Step '.env yapılandırması'
  $envFile = Join-Path $Root '.env'
  if (-not (Test-Path $envFile)) {
    Copy-Item (Join-Path $Root '.env.example') $envFile
    Write-Host "[OK] $envFile oluşturuldu." -ForegroundColor Green
  } else { Write-Host '[OK] .env zaten var, dokunulmadı.' -ForegroundColor Green }

  Step 'Başlatıcı ve kısayollar'
  $launcherText = @'
# MiroFish başlatıcı - kurulum betiği tarafından üretilir. Elle düzenlemeyin.
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$env:PYTHONUTF8 = '1'
$Root   = Join-Path $env:USERPROFILE 'MiroFish'
$Base   = Join-Path $env:USERPROFILE 'MiroFish-Launcher'
$LogDir = Join-Path $Base 'logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$Stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
Get-ChildItem $LogDir -File -ErrorAction SilentlyContinue |
  Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) } | Remove-Item -Force -ErrorAction SilentlyContinue
try { Start-Transcript -Path (Join-Path $LogDir "baslat-$Stamp.log") | Out-Null } catch {}

function Test-Port([int]$Port) {
  try {
    $c = New-Object Net.Sockets.TcpClient
    $iar = $c.BeginConnect('127.0.0.1', $Port, $null, $null)
    $ok = $iar.AsyncWaitHandle.WaitOne(500) -and $c.Connected
    $c.Close(); return $ok
  } catch { return $false }
}

# Portu dinleyen süreç(ler) MiroFish'e mi ait? (Başka projeleri yanlışlıkla kapatmamak için.)
function Get-PortOwners([int]$Port) {
  $pids = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique)
  foreach ($p in $pids) {
    $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$p" -ErrorAction SilentlyContinue
    [pscustomobject]@{ Pid = $p; Mine = [bool]($cim -and (($cim.CommandLine -like "*$Root*") -or ($cim.ExecutablePath -like "$Root*"))) }
  }
}

function Stop-MiroFish {
  foreach ($port in 3000, 5001) {
    foreach ($o in @(Get-PortOwners $port)) {
      if ($o.Mine) { & taskkill.exe /PID $o.Pid /T /F 2>&1 | Out-Null }
    }
  }
}

$own = @()
try {
  if (-not (Test-Path (Join-Path $Root 'backend\.venv'))) {
    throw "Kurulum bulunamadı. Önce kurulum komutunu çalıştırın (bkz. MiroFish-Launcher\README.txt)."
  }
  $envFile = Join-Path $Root '.env'
  if ((-not (Test-Path $envFile)) -or ((Get-Content $envFile -Raw) -match 'your_api_key_here|your_zep_api_key_here')) {
    Write-Warning "LLM_API_KEY / ZEP_API_KEY henüz girilmemiş. Arayüz açılır ama simülasyon çalışmaz. 'MiroFish Ayarlar (.env)' kısayoluyla düzenleyin."
  }

  # Port çakışması: MiroFish zaten çalışıyorsa sadece tarayıcıyı aç; başka uygulamaysa dur.
  $busy = @(); foreach ($port in 3000, 5001) { foreach ($o in @(Get-PortOwners $port)) { $busy += $o } }
  if ($busy.Count -gt 0) {
    if (@($busy | Where-Object { -not $_.Mine }).Count -gt 0) {
      throw "3000 veya 5001 portu başka bir uygulama tarafından kullanılıyor. O uygulamayı kapatıp tekrar deneyin."
    }
    Write-Host 'MiroFish zaten çalışıyor; tarayıcı açılıyor.' -ForegroundColor Green
    Start-Process 'http://localhost:3000'
    $ans = Read-Host 'Durdurmak için "d" yazıp Enter, çıkmak için sadece Enter'
    if ($ans -eq 'd') { Stop-MiroFish; Write-Host 'Durduruldu.' }
    return
  }

  Write-Host 'MiroFish başlatılıyor...' -ForegroundColor Cyan
  $b = Start-Process cmd.exe -ArgumentList '/c', 'npm run backend' -WorkingDirectory $Root -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $LogDir "backend-$Stamp.out.log") -RedirectStandardError (Join-Path $LogDir "backend-$Stamp.err.log")
  $f = Start-Process cmd.exe -ArgumentList '/c', 'npx --no-install vite --host --no-open' -WorkingDirectory (Join-Path $Root 'frontend') -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $LogDir "frontend-$Stamp.out.log") -RedirectStandardError (Join-Path $LogDir "frontend-$Stamp.err.log")
  $own = @($b, $f)

  $deadline = (Get-Date).AddSeconds(120)
  while (-not ((Test-Port 5001) -and (Test-Port 3000))) {
    if ($b.HasExited) { throw "Backend kapandı. Ayrıntı: $LogDir\backend-$Stamp.err.log" }
    if ($f.HasExited) { throw "Frontend kapandı. Ayrıntı: $LogDir\frontend-$Stamp.err.log" }
    if ((Get-Date) -gt $deadline) { throw "120 sn içinde açılmadı. Kayıtlar: $LogDir" }
    Start-Sleep -Milliseconds 700
  }
  Start-Process 'http://localhost:3000'
  Write-Host ''
  Write-Host 'MiroFish çalışıyor:  http://localhost:3000   (API: http://localhost:5001)' -ForegroundColor Green
  Write-Host "Kayıtlar: $LogDir"
  Write-Host 'Kapatmak için bu pencerede Enter tuşuna basın (pencereyi X ile kapatırsanız servisler arkada kalır; kısayola yeniden tıklayıp "d" yazarak durdurabilirsiniz).'
  [void](Read-Host)
}
catch {
  $msg = "{0}  {1}" -f (Get-Date -Format 's'), $_.Exception.Message
  Add-Content -Path (Join-Path $LogDir 'hatalar.log') -Value $msg
  Write-Host "`nHATA: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "Kayıtlar: $LogDir" -ForegroundColor Red
  [void](Read-Host 'Kapatmak için Enter')
}
finally {
  foreach ($p in $own) { if ($p -and -not $p.HasExited) { & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null } }
  if ($own.Count -gt 0) { Stop-MiroFish }
  try { Stop-Transcript | Out-Null } catch {}
}
'@
  [IO.File]::WriteAllText($Launcher, $launcherText, (New-Object Text.UTF8Encoding $true))
  [IO.File]::WriteAllText((Join-Path $Base 'README.txt'),
    "MiroFish kurulumu: $Root`r`nAnahtarlar: $Root\.env  (LLM_API_KEY, ZEP_API_KEY)`r`nKayitlar: $LogDir`r`nYeniden kurulum/onarim icin kurulum komutunu tekrar calistirin; kurulu olanlar atlanir.`r`n",
    (New-Object Text.UTF8Encoding $true))

  $desktop = [Environment]::GetFolderPath('Desktop')
  $ws = New-Object -ComObject WScript.Shell
  $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

  $lnk = $ws.CreateShortcut((Join-Path $desktop ('MiroFish Ba' + [char]0x15F + 'lat.lnk')))
  $lnk.TargetPath       = $psExe
  $lnk.Arguments        = "-NoProfile -ExecutionPolicy Bypass -File `"$Launcher`""
  $lnk.WorkingDirectory = $Root
  $lnk.IconLocation     = "$psExe,0"
  $lnk.Description      = 'MiroFish servislerini başlatır ve http://localhost:3000 adresini açar'
  $lnk.Save()

  $lnk2 = $ws.CreateShortcut((Join-Path $desktop 'MiroFish Ayarlar (.env).lnk'))
  $lnk2.TargetPath = Join-Path $env:SystemRoot 'System32\notepad.exe'
  $lnk2.Arguments  = "`"$envFile`""
  $lnk2.Save()
  Write-Host "[OK] Masaüstüne kısayollar eklendi." -ForegroundColor Green

  Step 'Tamamlandı'
  Write-Host 'Kurulum bitti. Sıradaki adımlar:' -ForegroundColor Green
  Write-Host "  1) .env dosyasına LLM_API_KEY ve ZEP_API_KEY girin (Masaüstü: 'MiroFish Ayarlar (.env)')."
  Write-Host "  2) Masaüstündeki 'MiroFish Başlat' kısayoluna çift tıklayın."
  Write-Host "Kayıtlar: $LogDir"
  if ((Get-Content $envFile -Raw) -match 'your_api_key_here|your_zep_api_key_here') { Start-Process notepad.exe -ArgumentList "`"$envFile`"" }
}
catch {
  $failed = $true
  $msg = "{0}  {1}" -f (Get-Date -Format 's'), $_.Exception.Message
  try { Add-Content -Path $ErrorLog -Value $msg } catch {}
  Write-Host "`nHATA: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host "Ayrıntılı kayıt: $InstallLog" -ForegroundColor Red
  Write-Host 'Sorunu giderip aynı komutu tekrar çalıştırın; tamamlanan adımlar atlanır.' -ForegroundColor Yellow
}
finally {
  try { Stop-Transcript | Out-Null } catch {}
}
