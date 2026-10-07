# Dépendances macOS du projet : `brew bundle --file=Brewfile` (idempotent).
# Node (>= 24.16, requis par OpenClaw) est géré à part par scripts/install.sh,
# pour ne pas doublonner un Node déjà installé via nvm.

# IA locale
brew "ollama"        # LLM local (servi par la LaunchAgent du projet, pas brew services)
brew "whisper.cpp"   # transcription, binaire `whisper-cli` (Metal)
brew "ffmpeg"        # conversion des vocaux Telegram (ogg/opus → wav 16 kHz)

# Outillage
brew "jq"
brew "shellcheck"

# Synchronisation du vault Mac ↔ téléphone, sans cloud
brew "syncthing"

# Applications
cask "docker-desktop"  # mbsync + mail2md (docker compose)
cask "obsidian"
