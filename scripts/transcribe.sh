#!/usr/bin/env bash
# Transcrit un fichier audio en texte (stdout) avec whisper.cpp, en local.
# Appelé par OpenClaw (tools.media.models, type "cli") pour chaque vocal Telegram.
#
# Pendant la transcription, le LLM est préchargé en arrière-plan dans Ollama :
# le chargement du modèle se fait en même temps que Whisper, pas après.
#
# Usage : scripts/transcribe.sh <fichier-audio>
#
# Variables (optionnelles, aussi lues dans openclaw/.env) :
#   OLLAMA_MODEL       modèle à précharger (défaut : qwen3:30b-a3b)
#   OLLAMA_URL         défaut : http://127.0.0.1:11434
#   OLLAMA_PRELOAD     0 pour désactiver le préchargement
#   WHISPER_MODEL      chemin du modèle ggml (défaut : data/models/whisper/ggml-large-v3-turbo.bin)
#   WHISPER_LANG       langue (défaut : fr, "auto" pour détecter)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_DIR/openclaw/.env"

# Lit une variable dans openclaw/.env sans sourcer le fichier (il contient le token Telegram).
env_value() {
  [[ -f "$ENV_FILE" ]] || return 0
  grep -E "^$1=" "$ENV_FILE" | tail -n1 | cut -d= -f2- | sed -E 's/^["'\'']|["'\'']$//g'
}

OLLAMA_MODEL="${OLLAMA_MODEL:-$(env_value OLLAMA_MODEL)}"
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen3:30b-a3b}"
OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"
OLLAMA_PRELOAD="${OLLAMA_PRELOAD:-1}"
WHISPER_MODEL="${WHISPER_MODEL:-$REPO_DIR/data/models/whisper/ggml-large-v3-turbo.bin}"
WHISPER_LANG="${WHISPER_LANG:-fr}"

# PATH minimal quand le script est lancé par launchd (OpenClaw).
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

die() { echo "transcribe: $*" >&2; exit 1; }

[[ $# -eq 1 ]] || die "usage : $0 <fichier-audio>"
INPUT="$1"
[[ -f "$INPUT" ]] || die "fichier introuvable : $INPUT"
[[ -f "$WHISPER_MODEL" ]] || die "modèle Whisper absent : $WHISPER_MODEL (lancer make install)"
command -v whisper-cli >/dev/null || die "whisper-cli absent (brew install whisper.cpp)"
command -v ffmpeg >/dev/null || die "ffmpeg absent (brew install ffmpeg)"

# 1. Préchargement du LLM en arrière-plan (requête sans prompt = chargement seul).
if [[ "$OLLAMA_PRELOAD" != "0" ]]; then
  curl -s --max-time 120 "$OLLAMA_URL/api/generate" \
    -d "{\"model\":\"$OLLAMA_MODEL\"}" >/dev/null 2>&1 &
  disown || true
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# 2. Conversion en WAV 16 kHz mono, le format attendu par whisper.cpp.
ffmpeg -nostdin -loglevel error -y -i "$INPUT" -ar 16000 -ac 1 -c:a pcm_s16le "$TMP_DIR/audio.wav" \
  || die "conversion ffmpeg impossible"

# 3. Transcription sur les cœurs performance (Metal est utilisé automatiquement).
THREADS="$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || sysctl -n hw.physicalcpu)"
whisper-cli -m "$WHISPER_MODEL" -l "$WHISPER_LANG" -t "$THREADS" -nt -np -f "$TMP_DIR/audio.wav" \
  | sed -E 's/^[[:space:]]+//; /^$/d'
