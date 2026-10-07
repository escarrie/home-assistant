#!/usr/bin/env bash
# Serveur MCP (stdio) donnant accès au vault Obsidian EN LECTURE SEULE.
# Serveur filesystem officiel dans Docker : le vault est monté en `ro`, donc toute
# tentative d'écriture échoue côté système, quel que soit le client MCP.
#
# Utilisé par .mcp.json (Claude Code) et par Claude Desktop ; tout client MCP stdio
# peut le lancer avec son chemin absolu.
#
# Variables : VAULT_DIR (défaut : data/vault), MCP_FS_IMAGE (défaut : mcp/filesystem).
# Rien ne doit être écrit sur stdout hors du protocole MCP : les erreurs vont sur stderr.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VAULT_DIR="${VAULT_DIR:-$REPO_DIR/data/vault}"
MCP_FS_IMAGE="${MCP_FS_IMAGE:-mcp/filesystem}"

# PATH minimal quand le client MCP lance le script hors d'un shell.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

die() { echo "mcp-vault: $*" >&2; exit 1; }

[[ -d "$VAULT_DIR" ]] || die "vault introuvable : $VAULT_DIR"
VAULT_DIR="$(cd "$VAULT_DIR" && pwd)"
command -v docker >/dev/null || die "docker absent"
docker info >/dev/null 2>&1 || die "Docker Desktop n'est pas démarré"

exec docker run -i --rm --network none \
  --mount "type=bind,src=$VAULT_DIR,dst=/projects/vault,ro" \
  "$MCP_FS_IMAGE" /projects
