#!/usr/bin/env bash
# Supprime les fichiers reçus par OpenClaw (vocaux, images, documents) une fois
# expirés, dans les deux emplacements où ils sont copiés :
#   - ~/.openclaw/media/inbound/                        (stockage d'OpenClaw)
#   - <vault>/media/inbound/openclaw-staged-*/          (copie dans l'espace de travail)
# Le .gitignore de chaque dossier staged (marqueur de propriété d'OpenClaw) est
# conservé ; le dossier est retiré quand il ne contient plus que lui.
#
# Lancé toutes les heures par la LaunchAgent com.escarrie.inbound-cleanup.
#
# Usage : scripts/cleanup-inbound.sh [--dry-run]
# Variables : INBOUND_RETENTION_HOURS (défaut : 24), VAULT_DIR (défaut : data/vault)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VAULT_DIR="${VAULT_DIR:-$REPO_DIR/data/vault}"
OPENCLAW_INBOUND="$HOME/.openclaw/media/inbound"
RETENTION_HOURS="${INBOUND_RETENTION_HOURS:-24}"

DRY_RUN=0
case "${1:-}" in
  --dry-run) DRY_RUN=1 ;;
  -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) echo "option inconnue : $1 (voir --help)" >&2; exit 1 ;;
esac

[[ "$RETENTION_HOURS" =~ ^[0-9]+$ ]] || { echo "INBOUND_RETENTION_HOURS doit être un entier" >&2; exit 1; }
minutes=$((RETENTION_HOURS * 60))

log() { printf '%s [inbound-cleanup] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"; }

# Liste (séparée par NUL) des fichiers expirés. -P : ne suit aucun lien symbolique.
expired_files() {
  if [[ -d "$OPENCLAW_INBOUND" ]]; then
    find -P "$OPENCLAW_INBOUND" -mindepth 1 -maxdepth 1 -type f -mmin "+$minutes" -print0
  fi
  if [[ -d "$VAULT_DIR/media/inbound" ]]; then
    find -P "$VAULT_DIR/media/inbound" -mindepth 2 -maxdepth 2 -type f \
      -path '*/openclaw-staged-*/*' ! -name '.gitignore' -mmin "+$minutes" -print0
  fi
}

count=0
bytes=0
while IFS= read -r -d '' f; do
  size="$(stat -f %z "$f" 2>/dev/null || echo 0)"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "à supprimer : $f"
  else
    rm -f -- "$f"
  fi
  count=$((count + 1))
  bytes=$((bytes + size))
done < <(expired_files)

# Dossiers staged qui ne contiennent plus que leur .gitignore.
dirs=0
if [[ -d "$VAULT_DIR/media/inbound" ]]; then
  while IFS= read -r -d '' d; do
    if [[ -z "$(find -P "$d" -mindepth 1 ! -name '.gitignore' -print -quit)" ]]; then
      if [[ "$DRY_RUN" == "1" ]]; then
        # En dry-run, les fichiers n'ont pas été supprimés : on signale seulement les dossiers déjà vides.
        echo "dossier à retirer : $d"
      else
        rm -f -- "$d/.gitignore"
        rmdir -- "$d"
      fi
      dirs=$((dirs + 1))
    fi
  done < <(find -P "$VAULT_DIR/media/inbound" -mindepth 1 -maxdepth 1 -type d -name 'openclaw-staged-*' -print0)
fi

mode=""; [[ "$DRY_RUN" == "1" ]] && mode=" (dry-run, rien supprimé)"
log "rétention ${RETENTION_HOURS} h : ${count} fichier(s), $((bytes / 1024)) Ko, ${dirs} dossier(s) staged vide(s)${mode}"
