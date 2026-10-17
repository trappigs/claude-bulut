# MiroFish: yalnızca başlatıcıyı günceller (depo, bağımlılıklar ve .env'e dokunmaz).
# Kullanım (PowerShell):  irm "https://raw.githubusercontent.com/trappigs/claude-bulut/main/Update-Launcher.ps1?t=$(Get-Random)" | iex
$env:MIROFISH_LAUNCHER_ONLY = '1'
iex (irm ("https://raw.githubusercontent.com/trappigs/claude-bulut/main/Start-MiroFish.ps1?t=" + (Get-Random)))
