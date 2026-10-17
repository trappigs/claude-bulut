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
$envFile  = Join-Path $Root '.env'
# MIROFISH_LAUNCHER_ONLY=1 ise yalnızca başlatıcı/kısayollar güncellenir (bağımlılık, depo ve .env'e dokunulmaz).
$LauncherOnly = ($env:MIROFISH_LAUNCHER_ONLY -eq '1')
Remove-Item Env:\MIROFISH_LAUNCHER_ONLY -ErrorAction SilentlyContinue
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
  if ($LauncherOnly) {
    if (-not (Test-Path (Join-Path $Root 'backend\.venv'))) {
      throw "Mevcut bir MiroFish kurulumu bulunamadı ($Root). Tam kurulum komutunu çalıştırın."
    }
    Write-Host 'Yalnızca başlatıcı güncelleniyor; depo, bağımlılıklar ve .env korunuyor.' -ForegroundColor Yellow
  } else {
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
  if (-not (Test-Path $envFile)) {
    Copy-Item (Join-Path $Root '.env.example') $envFile
    Write-Host "[OK] $envFile oluşturuldu." -ForegroundColor Green
  } else { Write-Host '[OK] .env zaten var, dokunulmadı.' -ForegroundColor Green }
  }  # tam kurulum sonu

  Step 'Başlatıcı ve kısayollar'
  $launcherText = @'
# MiroFish başlatıcı (v2) - kurulum betiği tarafından üretilir. Elle düzenlemeyin.
# Varsayılan portlar: frontend 3001, backend 5001. Doluysa boş port bulunur.
# Yalnızca MiroFish klasöründen başlayan süreçleri durdurur; başka uygulamalara (ör. 3000 portundaki servis) dokunmaz.
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$env:PYTHONUTF8 = '1'
$Root      = Join-Path $env:USERPROFILE 'MiroFish'
$Base      = Join-Path $env:USERPROFILE 'MiroFish-Launcher'
$LogDir    = Join-Path $Base 'logs'
$StateFile = Join-Path $Base 'calisan.json'
$PreferredFrontend = 3001
$PreferredBackend  = 5001
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
Get-ChildItem $LogDir -File -ErrorAction SilentlyContinue |
  Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) } | Remove-Item -Force -ErrorAction SilentlyContinue
try { Start-Transcript -Path (Join-Path $LogDir "baslat-$Stamp.log") | Out-Null } catch {}

# Port bir uygulama tarafından dinleniyor mu? (tüm adresler: 127.0.0.1, ::1, 0.0.0.0)
function Test-Listening([int]$Port) {
  try { return [bool](Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop) }
  catch { return $false }
}

function Test-PortFree([int]$Port) {
  if (Test-Listening $Port) { return $false }
  try {
    $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Any, $Port)
    $l.Start(); $l.Stop(); return $true
  } catch { return $false }
}

function Find-FreePort([int]$Start, [int[]]$Skip = @()) {
  for ($p = $Start; $p -lt ($Start + 100); $p++) {
    if ($Skip -contains $p) { continue }
    if (Test-PortFree $p) { return $p }
  }
  throw "$Start ile $($Start + 99) arasında boş port bulunamadı."
}

# Sunucu bağlantı kabul ediyor mu?
function Test-Connect([int]$Port) {
  foreach ($addr in '127.0.0.1', '::1') {
    try {
      $c = New-Object Net.Sockets.TcpClient
      $iar = $c.BeginConnect($addr, $Port, $null, $null)
      $ok = $iar.AsyncWaitHandle.WaitOne(400) -and $c.Connected
      $c.Close()
      if ($ok) { return $true }
    } catch {}
  }
  return $false
}

# Bu süreç MiroFish klasöründen mi başlatılmış? (yol "…\MiroFish\" içeriyor mu)
function Test-Mine([int]$ProcId) {
  $cim = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcId" -ErrorAction SilentlyContinue
  if (-not $cim) { return $false }
  $needle = $Root.TrimEnd('\') + '\'
  foreach ($s in @($cim.CommandLine, $cim.ExecutablePath)) {
    if ($s -and ($s.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0)) { return $true }
  }
  return $false
}

function Get-MineOnPort([int]$Port) {
  $pids = @()
  try { $pids = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop | Select-Object -ExpandProperty OwningProcess -Unique) } catch {}
  @($pids | Where-Object { Test-Mine $_ })
}

# Yalnızca verilen portlardaki MiroFish süreçlerini durdurur.
function Stop-Mine([int[]]$Ports) {
  foreach ($port in $Ports) {
    foreach ($procId in @(Get-MineOnPort $port)) { & taskkill.exe /PID $procId /T /F 2>&1 | Out-Null }
  }
}

$own = @(); $fport = 0; $bport = 0
try {
  if (-not (Test-Path (Join-Path $Root 'backend\.venv'))) {
    throw "Kurulum bulunamadı. Önce kurulum komutunu çalıştırın (bkz. MiroFish-Launcher\README.txt)."
  }
  $envFile = Join-Path $Root '.env'
  if ((-not (Test-Path $envFile)) -or ((Get-Content $envFile -Raw) -match 'your_api_key_here|your_zep_api_key_here')) {
    Write-Warning "LLM_API_KEY / ZEP_API_KEY henüz girilmemiş. Arayüz açılır ama simülasyon çalışmaz. 'MiroFish Ayarlar (.env)' kısayoluyla düzenleyin."
  }

  # MiroFish zaten çalışıyorsa (önceki başlatmadan) yalnızca tarayıcıyı aç.
  $st = $null
  if (Test-Path $StateFile) { try { $st = Get-Content $StateFile -Raw | ConvertFrom-Json } catch {} }
  if ($st) {
    if ((@(Get-MineOnPort ([int]$st.frontendPort)).Count -gt 0) -and (@(Get-MineOnPort ([int]$st.backendPort)).Count -gt 0)) {
      $url = "http://localhost:$($st.frontendPort)"
      Write-Host "MiroFish zaten çalışıyor; tarayıcı açılıyor: $url" -ForegroundColor Green
      Start-Process $url
      $ans = Read-Host 'Durdurmak için "d" yazıp Enter, çıkmak için sadece Enter'
      if ($ans -eq 'd') { Stop-Mine @([int]$st.frontendPort, [int]$st.backendPort); Remove-Item $StateFile -Force -ErrorAction SilentlyContinue; Write-Host 'Durduruldu.' }
      return
    }
    Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
  }

  # Boş port seç. Dolu portlardaki uygulamalara dokunulmaz, sadece atlanır.
  $bport = Find-FreePort $PreferredBackend
  $fport = Find-FreePort $PreferredFrontend @($bport)
  if ($bport -ne $PreferredBackend)  { Write-Warning "Backend için $PreferredBackend dolu; $bport kullanılacak." }
  if ($fport -ne $PreferredFrontend) { Write-Warning "Frontend için $PreferredFrontend dolu; $fport kullanılacak." }

  # Backend portu FLASK_PORT ile, frontend'in API adresi VITE_API_BASE_URL ile ayarlanır (kaynak koda dokunulmaz).
  $env:FLASK_PORT         = "$bport"
  $env:VITE_API_BASE_URL  = "http://localhost:$bport"

  Write-Host "MiroFish başlatılıyor... (frontend: $fport, backend: $bport)" -ForegroundColor Cyan
  $b = Start-Process cmd.exe -ArgumentList '/c', 'npm run backend' -WorkingDirectory $Root -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $LogDir "backend-$Stamp.out.log") -RedirectStandardError (Join-Path $LogDir "backend-$Stamp.err.log")
  $f = Start-Process cmd.exe -ArgumentList '/c', "npx --no-install vite --host --no-open --port $fport --strictPort" -WorkingDirectory (Join-Path $Root 'frontend') -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $LogDir "frontend-$Stamp.out.log") -RedirectStandardError (Join-Path $LogDir "frontend-$Stamp.err.log")
  $own = @($b, $f)
  @{ frontendPort = $fport; backendPort = $bport; started = (Get-Date -Format 's') } | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8

  $deadline = (Get-Date).AddSeconds(120)
  while (-not ((Test-Connect $bport) -and (Test-Connect $fport))) {
    if ($b.HasExited) { throw "Backend kapandı. Ayrıntı: $LogDir\backend-$Stamp.err.log" }
    if ($f.HasExited) { throw "Frontend kapandı. Ayrıntı: $LogDir\frontend-$Stamp.err.log" }
    if ((Get-Date) -gt $deadline) { throw "120 sn içinde açılmadı. Kayıtlar: $LogDir" }
    Start-Sleep -Milliseconds 700
  }
  Start-Process "http://localhost:$fport"
  Write-Host ''
  Write-Host "MiroFish çalışıyor:  http://localhost:$fport   (API: http://localhost:$bport)" -ForegroundColor Green
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
  if ($own.Count -gt 0) {
    Stop-Mine @($fport, $bport)
    Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
  }
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
  $lnk.Description      = 'MiroFish servislerini başlatır ve arayüzü tarayıcıda açar (varsayılan http://localhost:3001)'
  $lnk.Save()

  $lnk2 = $ws.CreateShortcut((Join-Path $desktop 'MiroFish Ayarlar (.env).lnk'))
  $lnk2.TargetPath = Join-Path $env:SystemRoot 'System32\notepad.exe'
  $lnk2.Arguments  = "`"$envFile`""
  $lnk2.Save()
  Write-Host "[OK] Masaüstüne kısayollar eklendi." -ForegroundColor Green

  Step 'Tamamlandı'
  Write-Host ($(if ($LauncherOnly) { 'Başlatıcı güncellendi.' } else { 'Kurulum bitti.' }) + ' Sıradaki adımlar:') -ForegroundColor Green
  Write-Host "  1) .env dosyasına LLM_API_KEY ve ZEP_API_KEY girin (Masaüstü: 'MiroFish Ayarlar (.env)')."
  Write-Host "  2) Masaüstündeki 'MiroFish Başlat' kısayoluna çift tıklayın."
  Write-Host "Kayıtlar: $LogDir"
  if ((-not $LauncherOnly) -and ((Get-Content $envFile -Raw) -match 'your_api_key_here|your_zep_api_key_here')) { Start-Process notepad.exe -ArgumentList "`"$envFile`"" }
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
