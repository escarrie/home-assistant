#!/usr/bin/env bash
# Arrête et désinstalle les services et les commandes du projet, SANS supprimer les
# données téléchargées.
#
# Supprimé / arrêté :
#   - gateway OpenClaw (LaunchAgent ai.openclaw.gateway)
#   - Ollama (LaunchAgent com.escarrie.ollama)
#   - nettoyage automatique des fichiers reçus (LaunchAgent com.escarrie.inbound-cleanup)
#   - conteneurs docker compose du projet (mbsync, mail2md)
#   - conteneurs MCP obsidian-vault encore ouverts, et l'entrée Claude Desktop
#   - commande openclaw (npm) et paquets Homebrew du Brewfile (ollama, whisper.cpp…)
#
# Conservé : modèles Ollama (~/.ollama), modèle Whisper (data/models), vault, mails,
# config et mémoire OpenClaw (~/.openclaw).
# `make install` remet tout en place sans retélécharger les modèles.
#
# Chaque service est confirmé un par un (y/N, non par défaut).
# Usage : scripts/uninstall.sh [-y|--yes]   (--yes : tout accepter sans demander)
# shellcheck disable=SC2088  # les « ~/... » des messages sont de l'affichage, pas des chemins
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OLLAMA_LABEL="com.escarrie.ollama"
OLLAMA_PLIST="$HOME/Library/LaunchAgents/$OLLAMA_LABEL.plist"
CLEANUP_LABEL="com.escarrie.inbound-cleanup"
CLEANUP_PLIST="$HOME/Library/LaunchAgents/$CLEANUP_LABEL.plist"
CLAUDE_DESKTOP_CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"

c_info=$'\033[32m'; c_warn=$'\033[33m'; c_step=$'\033[36m'; c_ask=$'\033[35m'; c_off=$'\033[0m'
step() { printf '\n%s==> %s%s\n' "$c_step" "$*" "$c_off"; }
ok()   { printf '  %s✓%s %s\n' "$c_info" "$c_off" "$*"; }
warn() { printf '  %s!%s %s\n' "$c_warn" "$c_off" "$*"; }

ASSUME_YES=0
case "${1:-}" in
  -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  -y|--yes) ASSUME_YES=1 ;;
  "") ;;
  *) echo "option inconnue : $1 (voir --help)" >&2; exit 1 ;;
esac

# Demande confirmation (y/N, non par défaut). Lit le terminal même si stdin est redirigé.
confirm() {
  [[ "$ASSUME_YES" == "1" ]] && return 0
  local answer=""
  # /dev/tty peut exister sans terminal associé : on vérifie qu'il est vraiment ouvrable.
  if { : < /dev/tty; } 2>/dev/null; then
    printf '  %s?%s %s [y/N] ' "$c_ask" "$c_off" "$1" > /dev/tty
    read -r answer < /dev/tty || answer=""
  else
    warn "pas de terminal : « $1 » ignoré (utilise --yes pour tout accepter)"
    return 1
  fi
  [[ "$answer" =~ ^[yYoO]$ ]]
}
skipped() { warn "conservé : $*"; }

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
uid="$(id -u)"

# ---------- OpenClaw ----------
step "OpenClaw (gateway)"
if ! command -v openclaw >/dev/null; then
  ok "openclaw absent : rien à faire"
elif ! launchctl print "gui/$uid/ai.openclaw.gateway" >/dev/null 2>&1; then
  ok "gateway non installée"
elif confirm "Arrêter et désinstaller la gateway OpenClaw (bot Telegram) ?"; then
  openclaw gateway stop >/dev/null 2>&1 || true
  openclaw gateway uninstall >/dev/null
  ok "gateway arrêtée et LaunchAgent supprimée"
else
  skipped "gateway OpenClaw"
fi

# ---------- Ollama ----------
step "Ollama (LaunchAgent $OLLAMA_LABEL)"
ollama_loaded=0; ollama_brew=0
launchctl print "gui/$uid/$OLLAMA_LABEL" >/dev/null 2>&1 && ollama_loaded=1
# Un `brew services` Ollama démarré à la main occuperait encore le port.
brew services list 2>/dev/null | awk '$1=="ollama" && $2=="started"' | grep -q . && ollama_brew=1
if [[ "$ollama_loaded" == "0" && "$ollama_brew" == "0" && ! -f "$OLLAMA_PLIST" ]]; then
  ok "Ollama non installé comme service"
elif confirm "Arrêter et désinstaller le service Ollama (les modèles restent sur disque) ?"; then
  # Décharge d'abord les modèles en mémoire.
  if curl -sf --max-time 2 http://127.0.0.1:11434/api/ps >/dev/null; then
    for m in $(curl -s http://127.0.0.1:11434/api/ps | jq -r '.models[].name'); do
      curl -s http://127.0.0.1:11434/api/generate -d "{\"model\":\"$m\",\"keep_alive\":0}" >/dev/null || true
    done
  fi
  [[ "$ollama_loaded" == "1" ]] && launchctl bootout "gui/$uid/$OLLAMA_LABEL" 2>/dev/null || true
  rm -f "$OLLAMA_PLIST"
  [[ "$ollama_brew" == "1" ]] && brew services stop ollama >/dev/null
  ok "Ollama arrêté et LaunchAgent supprimée (modèles conservés dans ~/.ollama)"
else
  skipped "service Ollama"
fi

# ---------- Nettoyage des fichiers reçus ----------
step "Nettoyage automatique des fichiers reçus (LaunchAgent $CLEANUP_LABEL)"
if [[ ! -f "$CLEANUP_PLIST" ]] && ! launchctl print "gui/$uid/$CLEANUP_LABEL" >/dev/null 2>&1; then
  ok "non installé"
elif confirm "Arrêter le nettoyage automatique des fichiers reçus (les fichiers présents restent) ?"; then
  launchctl bootout "gui/$uid/$CLEANUP_LABEL" 2>/dev/null || true
  rm -f "$CLEANUP_PLIST"
  ok "nettoyage automatique arrêté et LaunchAgent supprimée"
else
  skipped "nettoyage automatique"
fi

# ---------- Docker ----------
step "Docker (mbsync, mail2md)"
if ! docker info >/dev/null 2>&1; then
  ok "Docker Desktop arrêté : aucun conteneur à arrêter"
else
  compose=(docker compose --project-directory "$REPO_DIR" -f "$REPO_DIR/docker-compose.yml")
  if [[ -z "$("${compose[@]}" ps -aq 2>/dev/null)" ]]; then
    ok "aucun conteneur du projet"
  elif confirm "Arrêter et supprimer les conteneurs mbsync / mail2md (mails conservés) ?"; then
    # Uniquement les conteneurs de ce projet ; les volumes et data/ ne sont pas touchés.
    "${compose[@]}" down --remove-orphans
    ok "conteneurs docker compose du projet arrêtés et supprimés"
  else
    skipped "conteneurs mbsync / mail2md"
  fi

  step "MCP obsidian-vault (conteneurs ouverts)"
  mcp_ids="$(docker ps -q --filter ancestor=mcp/filesystem)"
  if [[ -z "$mcp_ids" ]]; then
    ok "aucun conteneur MCP en cours"
  elif confirm "Arrêter les conteneurs MCP obsidian-vault en cours (ferme l'accès des clients MCP) ?"; then
    # shellcheck disable=SC2086  # liste d'identifiants
    docker stop $mcp_ids >/dev/null
    ok "conteneurs MCP obsidian-vault arrêtés"
  else
    skipped "conteneurs MCP"
  fi
fi

# ---------- Claude Desktop ----------
step "MCP Claude Desktop"
if [[ ! -f "$CLAUDE_DESKTOP_CONFIG" ]] || ! jq -e '.mcpServers["obsidian-vault"]' "$CLAUDE_DESKTOP_CONFIG" >/dev/null 2>&1; then
  ok "aucune entrée obsidian-vault"
elif confirm "Retirer le serveur obsidian-vault de Claude Desktop (config sauvegardée) ?"; then
  cp -p "$CLAUDE_DESKTOP_CONFIG" "$CLAUDE_DESKTOP_CONFIG.bak-$(date +%Y%m%d-%H%M%S)"
  desktop_cfg="$(jq 'del(.mcpServers["obsidian-vault"])' "$CLAUDE_DESKTOP_CONFIG")"
  echo "$desktop_cfg" > "$CLAUDE_DESKTOP_CONFIG"
  ok "entrée obsidian-vault retirée (redémarre Claude Desktop)"
else
  skipped "entrée Claude Desktop"
fi

# ---------- Commandes et paquets ----------
# En dernier : les étapes précédentes ont besoin d'openclaw, brew et jq.
step "Commande openclaw (npm)"
if ! command -v openclaw >/dev/null; then
  ok "openclaw absent"
elif confirm "Désinstaller la commande openclaw (config et mémoire conservées dans ~/.openclaw) ?"; then
  # npm du même Node que celui qui porte openclaw (nvm ou Homebrew).
  npm_bin="$(dirname "$(command -v openclaw)")/npm"
  [[ -x "$npm_bin" ]] || npm_bin="npm"
  "$npm_bin" uninstall -g openclaw >/dev/null
  ok "openclaw désinstallé"
else
  skipped "commande openclaw"
fi

step "Paquets Homebrew du projet (Brewfile)"
# Les modèles ne sont pas dans les paquets : ~/.ollama et data/models restent.
formulas=()
while IFS= read -r f; do formulas+=("$f"); done \
  < <(sed -nE 's/^brew "([^"]+)".*/\1/p' "$REPO_DIR/Brewfile")
formulas+=("node")   # installé par install.sh seulement si aucun Node récent n'existait
for f in "${formulas[@]}"; do
  brew list --formula "$f" >/dev/null 2>&1 || continue
  note=""
  case "$f" in
    ollama) note=" (modèles conservés dans ~/.ollama)" ;;
    node) note=" (inutile si tu utilises nvm ; d'autres outils peuvent en dépendre)" ;;
    jq|ffmpeg) note=" (d'autres outils peuvent l'utiliser)" ;;
  esac
  if confirm "Désinstaller $f$note ?"; then
    # brew refuse si un autre paquet installé en dépend : on le signale sans s'arrêter.
    if brew uninstall --formula "$f" >/dev/null 2>&1; then
      ok "$f désinstallé"
    else
      warn "$f non désinstallé (dépendance d'un autre paquet ? voir : brew uses --installed $f)"
    fi
  else
    skipped "$f"
  fi
done

casks=()
while IFS= read -r c; do casks+=("$c"); done \
  < <(sed -nE 's/^cask "([^"]+)".*/\1/p' "$REPO_DIR/Brewfile")
for c in "${casks[@]}"; do
  brew list --cask "$c" >/dev/null 2>&1 || continue
  if confirm "Désinstaller l'application $c (installée via Homebrew, peut servir hors de ce projet) ?"; then
    if brew uninstall --cask "$c" >/dev/null 2>&1; then
      ok "$c désinstallé"
    else
      warn "$c non désinstallé (voir : brew uninstall --cask $c)"
    fi
  else
    skipped "$c"
  fi
done

# ---------- Récapitulatif ----------
step "Conservé"
du_h() { [[ -e "$1" ]] && du -sh "$1" 2>/dev/null | awk '{print $1}' || echo "-"; }
printf '  %-28s %s\n' \
  "modèles Ollama"             "$(du_h "$HOME/.ollama/models") ~/.ollama/models" \
  "modèle Whisper"             "$(du_h "$REPO_DIR/data/models") data/models" \
  "vault Obsidian"             "$(du_h "$REPO_DIR/data/vault") data/vault" \
  "mails (Maildir + Markdown)" "$(du_h "$REPO_DIR/data/mbsync") data/mbsync" \
  "config + mémoire OpenClaw"  "$(du_h "$HOME/.openclaw") ~/.openclaw"
echo
echo "Réinstaller : make install (rien ne sera retéléchargé)."
