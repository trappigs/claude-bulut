<#
  MiroFish LLM uyumluluk yamasını mevcut Windows kurulumuna uygular.
  - Yalnızca backend\app\utils\openai_chat_compat.py ve backend\app\api\graph.py (+ testler) değişir.
  - .env, bağımlılıklar, Hermes ve diğer dosyalar korunur. Ağ isteği yalnızca yamayı indirir.
  - Uygulamadan önce değişecek dosyalar %USERPROFILE%\MiroFish-Launcher\yedek\<tarih> altına yedeklenir.
  Geri alma:  cd $HOME\MiroFish; git apply -R --ignore-whitespace $env:TEMP\mirofish-llm-compat.patch
#>
$ErrorActionPreference = 'Stop'
$Root  = Join-Path $env:USERPROFILE 'MiroFish'
$Base  = Join-Path $env:USERPROFILE 'MiroFish-Launcher'
$Patch = Join-Path $env:TEMP 'mirofish-llm-compat.patch'
$Url   = 'https://raw.githubusercontent.com/trappigs/claude-bulut/main/patches/mirofish-llm-compat.patch?t=' + (Get-Random)

function Git-Ok([string[]]$GitArgs) {
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { & git @GitArgs 2>&1 | Out-Null; return ($LASTEXITCODE -eq 0) } finally { $ErrorActionPreference = $prev }
}

try {
  if (-not (Test-Path (Join-Path $Root '.git'))) { throw "MiroFish kurulumu bulunamadı: $Root" }
  Invoke-WebRequest -Uri $Url -OutFile $Patch -UseBasicParsing
  Set-Location $Root

  if (Git-Ok @('apply', '-R', '--check', '--ignore-whitespace', $Patch)) {
    Write-Host 'Yama zaten uygulanmış; yapılacak bir şey yok.' -ForegroundColor Green; return
  }
  if (-not (Git-Ok @('apply', '--check', '--ignore-whitespace', $Patch))) {
    throw "Yama bu MiroFish sürümüne uymuyor (dosyalar yerel olarak değişmiş ya da farklı sürüm). Hiçbir şey değiştirilmedi. 'git log -1 --oneline' çıktısını bana gönderin."
  }

  $backup = Join-Path $Base ('yedek\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
  New-Item -ItemType Directory -Force -Path $backup | Out-Null
  foreach ($f in 'backend\app\utils\openai_chat_compat.py', 'backend\app\api\graph.py', 'backend\tests\test_ontology_api_errors.py') {
    Copy-Item (Join-Path $Root $f) (Join-Path $backup ($f -replace '[\\/]', '_'))
  }

  & git apply --ignore-whitespace $Patch
  if ($LASTEXITCODE -ne 0) { throw 'git apply başarısız oldu.' }
  Write-Host "Yama uygulandı. Yedek: $backup" -ForegroundColor Green
  Write-Host 'MiroFish çalışıyorsa başlatıcı penceresinde Enter ile durdurun, sonra "MiroFish Başlat" kısayoluyla yeniden başlatın.' -ForegroundColor Yellow
}
catch {
  Write-Host "`nHATA: $($_.Exception.Message)" -ForegroundColor Red
}
