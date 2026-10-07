#!/usr/bin/env bash
# Installe les dépendances locales du projet sur macOS (Apple Silicon) :
# Homebrew bundle, Ollama (LaunchAgent), modèles LLM + Whisper, OpenClaw, vault Obsidian.
# Idempotent : relancer le script ne refait que ce qui manque.
# shellcheck disable=SC2088  # les « ~/... » des messages sont de l'affichage, pas des chemins
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_DIR/openclaw/.env"

OLLAMA_LABEL="com.escarrie.ollama"
OLLAMA_URL="http://127.0.0.1:11434"
OLLAMA_KEEP_ALIVE="5m"
OLLAMA_NUM_PARALLEL="2"
LOG_DIR="$HOME/Library/Logs"

WHISPER_DIR="$REPO_DIR/data/models/whisper"
WHISPER_FILE="ggml-large-v3-turbo.bin"
WHISPER_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$WHISPER_FILE"
WHISPER_SHA256="1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"

NODE_MIN="24.16"
OPENCLAW_DIR="$HOME/.openclaw"
EMBED_MODEL="qwen3-embedding:0.6b"   # embeddings de la mémoire OpenClaw (memory_search)
CLAUDE_DESKTOP_CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"

SKIP_MODELS=0
UPDATE_OPENCLAW_CONFIG=0
MODEL=""
VAULT_DIR="$REPO_DIR/data/vault"

# ---------- Affichage ----------
c_info=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_step=$'\033[36m'; c_off=$'\033[0m'
step() { printf '\n%s==> %s%s\n' "$c_step" "$*" "$c_off"; }
ok()   { printf '  %s✓%s %s\n' "$c_info" "$c_off" "$*"; }
warn() { printf '  %s!%s %s\n' "$c_warn" "$c_off" "$*"; }
die()  { printf '%s✗ %s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }

usage() {
  cat <<EOF
Usage : scripts/install.sh [options]

  --skip-models       N'installe pas les modèles (LLM Ollama + Whisper)
  --model <nom>       Modèle Ollama (défaut : OLLAMA_MODEL de openclaw/.env, sinon qwen3:30b-a3b)
  --vault <chemin>    Dossier du vault Obsidian (défaut : data/vault)
  --update-openclaw-config
                      Régénère ~/.openclaw/openclaw.json et AGENTS.md depuis le dépôt
                      (sauvegardes .bak-<date>), puis redémarre la gateway
  -h, --help          Affiche cette aide
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-models) SKIP_MODELS=1 ;;
    --model) MODEL="${2:?--model attend un nom}"; shift ;;
    --vault) VAULT_DIR="${2:?--vault attend un chemin}"; shift ;;
    --update-openclaw-config) UPDATE_OPENCLAW_CONFIG=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "option inconnue : $1" ;;
  esac
  shift
done

# Lit une variable dans openclaw/.env sans sourcer le fichier.
env_value() {
  [[ -f "$ENV_FILE" ]] || return 0
  grep -E "^$1=" "$ENV_FILE" | tail -n1 | cut -d= -f2- | sed -E 's/^["'\'']|["'\'']$//g'
}

# Copie $1 en $1.bak-<date> s'il existe.
backup() { [[ -e "$1" ]] && cp -p "$1" "$1.bak-$(date +%Y%m%d-%H%M%S)"; return 0; }

# Installe (ou met à jour) une LaunchAgent depuis un modèle du dossier launchd/.
# Usage : install_launch_agent <label> <modèle> [-e 's|__X__|valeur|' ...]
install_launch_agent() {
  local label="$1" template="$2"; shift 2
  local plist="$HOME/Library/LaunchAgents/$label.plist" rendered
  mkdir -p "$(dirname "$plist")" "$LOG_DIR"
  rendered="$(mktemp)"
  sed "$@" "$template" > "$rendered"
  plutil -lint "$rendered" >/dev/null || { rm -f "$rendered"; die "plist $label invalide."; }

  if [[ -f "$plist" ]] && cmp -s "$rendered" "$plist" \
     && launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
    ok "LaunchAgent $label déjà installée et à jour"
  else
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    # bootout est asynchrone : bootstrap échoue (« Input/output error ») tant que
    # l'ancien service n'est pas complètement retiré.
    for _ in $(seq 1 20); do
      launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1 || break
      sleep 0.5
    done
    cp "$rendered" "$plist"
    launchctl bootstrap "gui/$(id -u)" "$plist"
    # RunAtLoad ne suffit pas : launchd peut laisser le premier lancement « en attente ».
    launchctl kickstart "gui/$(id -u)/$label" 2>/dev/null || true
    ok "LaunchAgent $label installée et lancée"
  fi
  rm -f "$rendered"
}

# Vrai si la version $1 >= $2 (format x.y[.z]).
version_ge() { [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]; }

MODEL="${MODEL:-$(env_value OLLAMA_MODEL)}"
MODEL="${MODEL:-qwen3:30b-a3b}"

# ---------- 1. Prérequis ----------
step "Prérequis"
[[ "$(uname -s)" == "Darwin" ]] || die "macOS uniquement."
[[ "$(uname -m)" == "arm64" ]] || die "Apple Silicon requis (Metal pour Ollama et whisper.cpp)."
ok "macOS $(sw_vers -productVersion) sur Apple Silicon"

if ! command -v brew >/dev/null; then
  die "Homebrew absent. Installe-le puis relance ce script :
  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
fi
ok "Homebrew $(brew --version | head -n1 | awk '{print $2}')"

# ---------- 2. Paquets Homebrew ----------
step "Paquets Homebrew (Brewfile)"
# Applications déjà installées hors Homebrew : brew bundle échouerait en voulant les écraser.
cask_skip=()
[[ -d /Applications/Docker.app ]]   && cask_skip+=("docker-desktop")
[[ -d /Applications/Obsidian.app ]] && cask_skip+=("obsidian")
if [[ ${#cask_skip[@]} -gt 0 ]]; then
  warn "déjà présentes, ignorées : ${cask_skip[*]}"
fi
HOMEBREW_BUNDLE_CASK_SKIP="${cask_skip[*]:-}" brew bundle --file="$REPO_DIR/Brewfile"
ok "Brewfile appliqué"

# Node : requis par OpenClaw. On garde celui de nvm s'il est assez récent.
if command -v node >/dev/null && version_ge "$(node -v | tr -d v)" "$NODE_MIN"; then
  ok "Node $(node -v) ($(command -v node))"
else
  warn "Node >= $NODE_MIN absent, installation via Homebrew"
  brew install node
  ok "Node $(node -v)"
fi

# ---------- 3. Ollama (LaunchAgent) ----------
step "Ollama (LaunchAgent $OLLAMA_LABEL)"
OLLAMA_BIN="$(command -v ollama)" || die "ollama introuvable après brew bundle."

# Un `brew services` Ollama occuperait le même port.
if brew services list 2>/dev/null | awk '$1=="ollama" && $2=="started"' | grep -q .; then
  warn "service Homebrew ollama actif : arrêt (remplacé par la LaunchAgent du projet)"
  brew services stop ollama
fi

install_launch_agent "$OLLAMA_LABEL" "$REPO_DIR/launchd/$OLLAMA_LABEL.plist.tmpl" \
  -e "s|__OLLAMA_BIN__|$OLLAMA_BIN|" \
  -e "s|__OLLAMA_KEEP_ALIVE__|$OLLAMA_KEEP_ALIVE|" \
  -e "s|__OLLAMA_NUM_PARALLEL__|$OLLAMA_NUM_PARALLEL|" \
  -e "s|__LOG_DIR__|$LOG_DIR|"
ok "réglages : keep_alive=$OLLAMA_KEEP_ALIVE, num_parallel=$OLLAMA_NUM_PARALLEL"

# RunAtLoad ne suffit pas : launchd peut laisser le lancement « en attente » (runs = 0).
if ! launchctl print "gui/$(id -u)/$OLLAMA_LABEL" 2>/dev/null | grep -q 'state = running'; then
  launchctl kickstart "gui/$(id -u)/$OLLAMA_LABEL"
  ok "démarrée (kickstart)"
fi

for _ in $(seq 1 30); do
  curl -sf "$OLLAMA_URL/api/version" >/dev/null && break
  sleep 0.5
done
curl -sf "$OLLAMA_URL/api/version" >/dev/null || die "Ollama ne répond pas sur $OLLAMA_URL (voir $LOG_DIR/ollama.log)."
ok "Ollama $(curl -s "$OLLAMA_URL/api/version" | jq -r .version) répond sur $OLLAMA_URL"

# ---------- 4. Modèles ----------
step "Modèles"
if [[ "$SKIP_MODELS" == "1" ]]; then
  warn "ignorés (--skip-models)"
else
  # `ollama pull` ne retélécharge que les couches manquantes.
  ollama pull "$MODEL"
  ok "LLM $MODEL"
  ollama pull "$EMBED_MODEL"
  ok "embeddings $EMBED_MODEL"

  mkdir -p "$WHISPER_DIR"
  target="$WHISPER_DIR/$WHISPER_FILE"
  if [[ -f "$target" ]] && [[ "$(shasum -a 256 "$target" | awk '{print $1}')" == "$WHISPER_SHA256" ]]; then
    ok "Whisper $WHISPER_FILE déjà présent"
  else
    # -C - : reprend un téléchargement interrompu.
    curl -L --fail --progress-bar -C - -o "$target.part" "$WHISPER_URL"
    [[ "$(shasum -a 256 "$target.part" | awk '{print $1}')" == "$WHISPER_SHA256" ]] \
      || { rm -f "$target.part"; die "checksum Whisper invalide, fichier supprimé : relance le script."; }
    mv "$target.part" "$target"
    ok "Whisper $WHISPER_FILE téléchargé et vérifié"
  fi
fi

# ---------- 5. Vault Obsidian ----------
step "Vault Obsidian"
mkdir -p "$VAULT_DIR"/{00-Inbox,Notes,Journal,Attachments/audio}
VAULT_DIR="$(cd "$VAULT_DIR" && pwd)"
if [[ ! -f "$VAULT_DIR/AGENTS.md" ]]; then
  cp "$REPO_DIR/openclaw/workspace/AGENTS.md" "$VAULT_DIR/AGENTS.md"
  ok "consignes de l'agent copiées dans AGENTS.md"
elif cmp -s "$REPO_DIR/openclaw/workspace/AGENTS.md" "$VAULT_DIR/AGENTS.md"; then
  ok "AGENTS.md à jour"
elif [[ "$UPDATE_OPENCLAW_CONFIG" == "1" ]]; then
  backup "$VAULT_DIR/AGENTS.md"
  cp "$REPO_DIR/openclaw/workspace/AGENTS.md" "$VAULT_DIR/AGENTS.md"
  ok "AGENTS.md mis à jour (ancienne version sauvegardée)"
else
  warn "AGENTS.md diffère du dépôt (non écrasé, voir --update-openclaw-config)"
fi

# Masque dans Obsidian les fichiers reçus par OpenClaw (audios, pièces jointes).
app_json="$VAULT_DIR/.obsidian/app.json"
mkdir -p "$VAULT_DIR/.obsidian"
[[ -s "$app_json" ]] || echo '{}' > "$app_json"
if jq -e '(.userIgnoreFilters // []) | index("media/")' "$app_json" >/dev/null; then
  ok "Obsidian : media/ déjà masqué"
else
  app_cfg="$(jq '.userIgnoreFilters = ((.userIgnoreFilters // []) + ["media/"])' "$app_json")"
  echo "$app_cfg" > "$app_json"
  ok "Obsidian : dossier media/ masqué (recharge Obsidian si le vault est ouvert)"
fi
ok "$VAULT_DIR"

# ---------- 5b. Nettoyage des fichiers reçus ----------
step "Nettoyage des fichiers reçus (24 h)"
install_launch_agent "com.escarrie.inbound-cleanup" "$REPO_DIR/launchd/com.escarrie.inbound-cleanup.plist.tmpl" \
  -e "s|__REPO_DIR__|$REPO_DIR|" \
  -e "s|__VAULT_DIR__|$VAULT_DIR|" \
  -e "s|__LOG_DIR__|$LOG_DIR|"
ok "balayage toutes les heures (log : $LOG_DIR/inbound-cleanup.log)"

# ---------- 6. OpenClaw ----------
step "OpenClaw"
if command -v openclaw >/dev/null; then
  ok "OpenClaw $(openclaw --version 2>/dev/null | head -n1) déjà installé"
else
  npm install -g openclaw@latest --allow-scripts=openclaw
  ok "OpenClaw $(openclaw --version 2>/dev/null | head -n1) installé"
fi

if [[ ! -f "$ENV_FILE" ]]; then
  cp "$REPO_DIR/openclaw/.env.example" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  warn "openclaw/.env créé depuis l'exemple : à remplir (token BotFather + ID Telegram)"
fi

mkdir -p "$OPENCLAW_DIR"
chmod 700 "$OPENCLAW_DIR"
if [[ -L "$OPENCLAW_DIR/.env" && "$(readlink "$OPENCLAW_DIR/.env")" == "$ENV_FILE" ]]; then
  ok "~/.openclaw/.env -> openclaw/.env"
elif [[ -e "$OPENCLAW_DIR/.env" ]]; then
  warn "~/.openclaw/.env existe déjà et n'est pas un lien vers openclaw/.env : laissé tel quel"
else
  ln -s "$ENV_FILE" "$OPENCLAW_DIR/.env"
  ok "lien ~/.openclaw/.env -> openclaw/.env"
fi

# Génère la config depuis l'exemple. Les clés gérées par OpenClaw lui-même (token de la
# gateway, plugins, skills, métadonnées) sont reprises de la config existante.
render_openclaw_config() {
  local rendered_cfg template_json
  rendered_cfg="$(mktemp)"
  sed -e "s|__REPO_DIR__|$REPO_DIR|g" \
      -e "s|__VAULT_DIR__|$VAULT_DIR|g" \
      -e "s|__OLLAMA_MODEL__|$MODEL|g" \
      -e "s|__EMBED_MODEL__|$EMBED_MODEL|g" \
      "$REPO_DIR/openclaw/openclaw.json.example" > "$rendered_cfg"
  template_json="$(npx -y json5 "$rendered_cfg")" || die "openclaw.json.example invalide (JSON5)."
  rm -f "$rendered_cfg"
  if [[ -f "$OPENCLAW_DIR/openclaw.json" ]]; then
    local current_json
    current_json="$(npx -y json5 "$OPENCLAW_DIR/openclaw.json")" || die "~/.openclaw/openclaw.json illisible."
    jq -n --argjson t "$template_json" --argjson c "$current_json" \
      '$t + ($c | with_entries(select(.key | IN("gateway", "plugins", "skills", "meta", "wizard"))))'
  else
    echo "$template_json"
  fi
}

config_changed=0
if [[ ! -f "$OPENCLAW_DIR/openclaw.json" ]]; then
  render_openclaw_config > "$OPENCLAW_DIR/openclaw.json"
  chmod 600 "$OPENCLAW_DIR/openclaw.json"
  config_changed=1
  ok "~/.openclaw/openclaw.json créé"
elif [[ "$UPDATE_OPENCLAW_CONFIG" == "1" ]]; then
  new_cfg="$(render_openclaw_config)"
  # Valide le rendu avec le schéma d'OpenClaw avant de toucher à la config active.
  candidate="$(mktemp)"
  echo "$new_cfg" > "$candidate"
  OPENCLAW_CONFIG_PATH="$candidate" openclaw config validate >/dev/null \
    || { rm -f "$candidate"; die "config générée refusée par openclaw config validate."; }
  rm -f "$candidate"
  if [[ "$(jq -S . <<<"$new_cfg")" == "$(npx -y json5 "$OPENCLAW_DIR/openclaw.json" | jq -S .)" ]]; then
    ok "~/.openclaw/openclaw.json déjà à jour"
  else
    backup "$OPENCLAW_DIR/openclaw.json"
    echo "$new_cfg" > "$OPENCLAW_DIR/openclaw.json"
    chmod 600 "$OPENCLAW_DIR/openclaw.json"
    config_changed=1
    ok "~/.openclaw/openclaw.json mis à jour (ancienne version sauvegardée)"
  fi
else
  ok "~/.openclaw/openclaw.json déjà présent (non écrasé, voir --update-openclaw-config)"
fi

token="$(env_value TELEGRAM_BOT_TOKEN)"
user_id="$(env_value TELEGRAM_ALLOWED_USER_ID)"
example_token="$(grep -E '^TELEGRAM_BOT_TOKEN=' "$REPO_DIR/openclaw/.env.example" | cut -d= -f2-)"
telegram_ok=0
if [[ -z "$token" || "$token" == "$example_token" || ! "$user_id" =~ ^[0-9]+$ ]]; then
  warn "Telegram non configuré : remplis openclaw/.env (token + ID numérique) puis relance make install"
else
  telegram_ok=1
  if ! launchctl list 2>/dev/null | grep -q 'ai.openclaw.gateway'; then
    openclaw gateway install
    ok "gateway installée (LaunchAgent)"
  fi
  # Une gateway active recharge seule sa config quand le fichier change (et redémarre si
  # besoin). `openclaw doctor --fix` ne doit pas tourner pendant ce temps : il exige une
  # gateway arrêtée.
  gateway_running() { openclaw gateway status 2>/dev/null | grep -q 'Runtime: running'; }
  if [[ "$config_changed" == "1" ]]; then
    sleep 5   # laisse la gateway détecter la nouvelle config et redémarrer
    for _ in $(seq 1 30); do gateway_running && break; sleep 1; done
  fi
  gateway_running || openclaw gateway start
  if [[ "$config_changed" == "1" ]]; then
    # Le modèle d'embeddings a pu changer : l'index vectoriel doit être reconstruit.
    if openclaw memory status --index --agent main >/dev/null; then
      ok "index de la mémoire reconstruit"
    else
      warn "index mémoire non reconstruit : openclaw memory status --index --agent main"
    fi
  fi
  ok "gateway active (après un changement de config : openclaw gateway restart)"
fi

# ---------- 7. MCP (lecture seule du vault) ----------
step "MCP (vault en lecture seule)"
if docker info >/dev/null 2>&1; then
  docker pull -q mcp/filesystem >/dev/null && ok "image mcp/filesystem"
else
  warn "Docker Desktop arrêté : image mcp/filesystem non téléchargée (elle le sera au premier lancement)"
fi
ok "Claude Code : .mcp.json (serveur obsidian-vault)"

if [[ -f "$CLAUDE_DESKTOP_CONFIG" ]]; then
  if jq -e '.mcpServers["obsidian-vault"]' "$CLAUDE_DESKTOP_CONFIG" >/dev/null 2>&1; then
    ok "Claude Desktop : obsidian-vault déjà déclaré"
  else
    backup "$CLAUDE_DESKTOP_CONFIG"
    desktop_cfg="$(jq --arg cmd "$REPO_DIR/scripts/mcp-vault.sh" \
      '.mcpServers = (.mcpServers // {}) + {"obsidian-vault": {"command": $cmd, "args": []}}' \
      "$CLAUDE_DESKTOP_CONFIG")" || die "config Claude Desktop illisible."
    echo "$desktop_cfg" > "$CLAUDE_DESKTOP_CONFIG"
    ok "Claude Desktop : obsidian-vault ajouté (redémarre Claude Desktop)"
  fi
else
  warn "Claude Desktop non détecté : voir le README pour l'ajouter à la main"
fi

# ---------- 8. Récapitulatif ----------
step "Récapitulatif"
printf '  %-12s %s\n' \
  "ollama"     "$(ollama --version 2>/dev/null | awk '{print $NF}')" \
  "whisper"    "$(brew list --versions whisper.cpp | awk '{print $2}')" \
  "ffmpeg"     "$(brew list --versions ffmpeg | awk '{print $2}')" \
  "node"       "$(node -v)" \
  "openclaw"   "$(openclaw --version 2>/dev/null | head -n1)" \
  "modèle"     "$MODEL" \
  "vault"      "$VAULT_DIR"

echo
echo "Prochaines étapes :"
if [[ "$telegram_ok" == "0" ]]; then
  echo "  - Telegram : crée un bot avec @BotFather (/newbot), récupère ton ID numérique"
  echo "    (@userinfobot), remplis openclaw/.env puis relance make install."
else
  echo "  - Vérifie : make services-status, puis envoie un texte et un vocal au bot."
fi
echo "  - Ouvre le vault dans Obsidian : $VAULT_DIR"
