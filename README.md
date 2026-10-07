# home-assistant

Assistant personnel **100 % local** sur macOS :

- **mbsync + mail2md** : copie des boîtes mail en local puis conversion en Markdown (voir [`mbsync/readme.md`](mbsync/readme.md)).
- **OpenClaw** : agent qui reçoit tes messages texte et vocaux sur Telegram, les transcrit et alimente un **vault Obsidian**.

```
Téléphone ──Telegram──► OpenClaw (LaunchAgent)
                          │  vocal ──► scripts/transcribe.sh ──► whisper.cpp (Metal)
                          │              └─ précharge le LLM en parallèle
                          ▼
                       Ollama (LaunchAgent, 127.0.0.1:11434)
                          │
                          ▼
                    Vault Obsidian (data/vault) ◄── Syncthing ──► téléphone

IMAP ──► mbsync (Docker) ──► Maildir ──► mail2md (Docker) ──► Markdown
```

Le LLM et Whisper tournent **nativement** (pas dans Docker) : Docker Desktop n'a pas accès au GPU Metal.

## Installation

### Prérequis

- macOS sur Apple Silicon.
- [Homebrew](https://brew.sh). Le script ne l'installe pas lui-même :
  ```bash
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  ```
- Environ 22 Go d'espace disque pour les modèles (≈ 19 Go pour le LLM par défaut, 1,6 Go pour Whisper).

### Lancer l'installation

```bash
make install            # ou ./scripts/install.sh
```

Le script est **idempotent** : relancé, il ne refait que ce qui manque. Voici ce qu'il fait, dans l'ordre :

1. Il vérifie qu'on est sous macOS avec une puce Apple Silicon et que Homebrew est présent.
2. Il installe le [`Brewfile`](Brewfile) : `ollama`, `whisper.cpp`, `ffmpeg`, `jq`, `shellcheck`, `syncthing`, Docker Desktop et Obsidian. Les applications déjà présentes dans `/Applications` sont ignorées.
3. Il installe Node 24.16 ou plus via Homebrew, seulement si aucun Node assez récent n'est présent (un Node de nvm convient).
4. Il crée la LaunchAgent `com.escarrie.ollama` à partir de [`launchd/`](launchd/), avec les réglages mémoire décrits plus bas. Elle remplace `brew services`, qui ne permet pas de passer ces variables.
5. Il télécharge les modèles : le LLM et le modèle d'embeddings de la mémoire (`qwen3-embedding:0.6b`) avec `ollama pull`, puis `ggml-large-v3-turbo.bin` dans `data/models/whisper/`, dont le checksum SHA-256 est vérifié.
6. Il crée le vault (`00-Inbox/`, `Notes/`, `Journal/`, `Attachments/audio/`), y copie les consignes de l'agent ([`openclaw/workspace/AGENTS.md`](openclaw/workspace/AGENTS.md)) et masque `media/` dans Obsidian.
7. Il installe OpenClaw (`npm install -g openclaw`), génère `~/.openclaw/openclaw.json` depuis [`openclaw/openclaw.json.example`](openclaw/openclaw.json.example) et crée le lien `~/.openclaw/.env` → `openclaw/.env`. Il installe enfin la gateway en LaunchAgent, si Telegram est configuré.
8. Il installe le nettoyage horaire des fichiers reçus (voir [Suppression des fichiers reçus](#suppression-des-fichiers-reçus)).
9. Il prépare l'accès MCP en lecture seule au vault : image `mcp/filesystem`, et entrée `obsidian-vault` dans Claude Desktop s'il est installé (voir [Accès MCP](#accès-mcp)).

| Option | Rôle |
|---|---|
| `--skip-models` | Ne télécharge pas les modèles (`make install-no-models`) |
| `--model <nom>` | Modèle Ollama (défaut : `OLLAMA_MODEL` de `openclaw/.env`, sinon `qwen3:30b-a3b`) |
| `--vault <chemin>` | Emplacement du vault (défaut : `data/vault`, ignoré par git) |
| `--update-openclaw-config` | Régénère `~/.openclaw/openclaw.json` et `AGENTS.md` depuis le dépôt, puis redémarre la gateway (`make openclaw-update-config`) |

Par défaut, les fichiers existants (`~/.openclaw/openclaw.json`, `AGENTS.md` dans le vault) ne sont **pas écrasés**. Après avoir modifié `openclaw/openclaw.json.example` ou `openclaw/workspace/AGENTS.md`, lance `make openclaw-update-config` :

- les anciennes versions sont sauvegardées en `.bak-<date>` ;
- les clés gérées par OpenClaw lui-même (token de la gateway, plugins, skills) sont conservées ;
- la config générée est validée (`openclaw config validate`) avant de remplacer la config active ; la gateway la recharge seule, puis l'index de la mémoire est reconstruit.

### Configurer Telegram

1. Dans Telegram, ouvre une conversation avec **@BotFather**, envoie `/newbot`, puis copie le token.
2. Récupère ton **ID utilisateur numérique**, par exemple avec @userinfobot. C'est un nombre, pas ton @pseudo.
3. Remplis `openclaw/.env` (le fichier est créé depuis [`openclaw/.env.example`](openclaw/.env.example)) :
   ```bash
   TELEGRAM_BOT_TOKEN=123456789:ABC...
   TELEGRAM_ALLOWED_USER_ID=123456789
   OLLAMA_MODEL=qwen3:30b-a3b
   ```
4. Relance `make install`, qui installe alors la gateway, puis vérifie avec `openclaw doctor`.
5. Envoie un message au bot : une note doit apparaître dans `data/vault/00-Inbox/`.

### Vault et téléphone

Dans Obsidian, choisis « Ouvrir un dossier comme coffre » et sélectionne `data/vault`. Pour l'avoir sur ton téléphone sans passer par le cloud, partage ce dossier avec **Syncthing** : `brew services start syncthing`, puis ouvre l'interface sur http://127.0.0.1:8384.

### Désinstaller

```bash
make uninstall          # ou ./scripts/uninstall.sh
```

Chaque service est confirmé un par un (`[y/N]`, non par défaut). `./scripts/uninstall.sh --yes` accepte tout sans demander.

Ce que fait la désinstallation, avec une question par élément :
- **services** : la gateway OpenClaw, la LaunchAgent Ollama, le nettoyage automatique des fichiers reçus, les conteneurs `docker compose` du projet et les conteneurs MCP encore ouverts ;
- **Claude Desktop** : elle retire l'entrée `obsidian-vault`, avec une sauvegarde de sa config ;
- **commandes** : la commande `openclaw` (npm) et chaque paquet Homebrew du [`Brewfile`](Brewfile) encore installé (`ollama`, `whisper.cpp`, `ffmpeg`, `jq`, `shellcheck`, `syncthing`, `node`, ainsi que Docker Desktop et Obsidian s'ils ont été installés par Homebrew). Un paquet dont un autre dépend est signalé, pas supprimé.

**Les données ne sont jamais supprimées** : modèles Ollama (`~/.ollama`, conservé même après `brew uninstall ollama`), modèle Whisper (`data/models`), vault, mails, config et mémoire OpenClaw (`~/.openclaw`). Un `make install` réinstalle les commandes et les services sans retélécharger les modèles.

## Où sont les données

| Quoi | Où |
|---|---|
| Notes | `data/vault/00-Inbox/` (captures), `Notes/`, `Journal/` |
| Mémoire de l'IA (Markdown, source de vérité) | `data/vault/USER.md` (ce qu'elle sait de toi), `MEMORY.md` (faits durables), `memory/AAAA-MM-JJ.md` (notes du jour), `IDENTITY.md` / `SOUL.md` (sa personnalité) |
| Consignes de l'agent | `data/vault/AGENTS.md` (copie de [`openclaw/workspace/AGENTS.md`](openclaw/workspace/AGENTS.md)) |
| Fichiers reçus (vocaux, images, documents) | `~/.openclaw/media/inbound/` + une copie dans `data/vault/media/inbound/` (masquée dans Obsidian). **Supprimés après 24 h**, voir ci-dessous |
| Index de recherche + historique des conversations | `~/.openclaw/agents/main/agent/openclaw-agent.sqlite` (interne à OpenClaw) |

### Suppression des fichiers reçus

Une fois un vocal transcrit et traité, l'audio n'est plus utile : la transcription est conservée dans la note (section `Original`) et dans l'historique d'OpenClaw. Tous les fichiers reçus (vocaux, images, documents) sont donc **supprimés 24 h après leur réception**, dans les deux emplacements :

- par OpenClaw lui-même (`attachments.ttlHours: 24` dans la config) ;
- par [`scripts/cleanup-inbound.sh`](scripts/cleanup-inbound.sh), lancé toutes les heures par la LaunchAgent `com.escarrie.inbound-cleanup`. Il couvre aussi les copies placées dans le vault.

```bash
make cleanup-inbound-dry   # liste ce qui serait supprimé
make cleanup-inbound       # supprime maintenant ce qui a plus de 24 h
INBOUND_RETENTION_HOURS=1 ./scripts/cleanup-inbound.sh   # autre délai, ponctuellement
```

Pour changer le délai de façon permanente, modifie `INBOUND_RETENTION_HOURS` dans [`launchd/com.escarrie.inbound-cleanup.plist.tmpl`](launchd/com.escarrie.inbound-cleanup.plist.tmpl) et `attachments.ttlHours` dans `openclaw/openclaw.json.example`, puis lance `make install`.

La mémoire est faite de fichiers Markdown du vault : tu peux la lire et la corriger dans Obsidian. La recherche (`memory_search`) indexe ces fichiers ainsi que `Notes/`, `00-Inbox/` et `Journal/`, avec des embeddings calculés localement par Ollama.

## Accès MCP

Le serveur `obsidian-vault` ([`scripts/mcp-vault.sh`](scripts/mcp-vault.sh)) donne à un client MCP l'accès au vault, notes et mémoire comprises, **en lecture seule**. C'est le serveur filesystem officiel, lancé dans Docker avec le vault monté en `ro` et sans réseau : une tentative d'écriture échoue toujours. Seul OpenClaw écrit dans le vault. Docker Desktop doit être démarré.

| Client | Configuration |
|---|---|
| Claude Code | Automatique dans ce dépôt via [`.mcp.json`](.mcp.json) : accepte le serveur au premier lancement, puis vérifie avec `/mcp` |
| Claude Desktop | Ajouté par `make install` dans `claude_desktop_config.json`, puis redémarre l'application |
| Autre client (stdio) | Commande : chemin absolu de `scripts/mcp-vault.sh`, sans argument |

Exemple pour un autre client :

```json
{ "mcpServers": { "obsidian-vault": { "command": "/chemin/vers/home-assistant/scripts/mcp-vault.sh" } } }
```

Pour lire les **conversations** Telegram (et non les notes), OpenClaw fournit son propre serveur MCP : `openclaw mcp serve`.

## Mémoire et performances

Le LLM n'occupe **pas** la RAM en permanence :

| Réglage | Valeur | Effet |
|---|---|---|
| `OLLAMA_KEEP_ALIVE` | `5m` | Le modèle est déchargé 5 min après le dernier message : 0 Go au repos |
| `OLLAMA_MAX_LOADED_MODELS` | `2` | Le LLM et le petit modèle d'embeddings (≈ 0,6 Go), jamais plus |
| `OLLAMA_NUM_PARALLEL` | `2` | Deux requêtes traitées en parallèle sur le modèle chargé |
| `OLLAMA_FLASH_ATTENTION` + `OLLAMA_KV_CACHE_TYPE=q8_0` | | Le cache du contexte prend environ deux fois moins de mémoire |
| `num_ctx` (openclaw.json) | `32768` | Plafonne la taille du contexte (≈ 1,5 Go de cache) |
| `tools.media.concurrency` | `2` | Deux vocaux transcrits en parallèle |

- **Préchargement** : `scripts/transcribe.sh` lance le chargement du LLM en arrière-plan **pendant** que Whisper transcrit. Le modèle est donc prêt quand le texte arrive.
- **Rafales** : le délai de `keep_alive` repart de zéro à chaque requête. Plusieurs messages d'affilée ne coûtent donc qu'un seul chargement.
- **Pic mémoire attendu** : environ 20 à 25 Go avec `qwen3:30b-a3b` (modèle MoE ≈ 19 Go en Q4, plus le contexte), seulement pendant le traitement.

**Changer de modèle** : modifie `OLLAMA_MODEL` dans `openclaw/.env` et le modèle dans `~/.openclaw/openclaw.json`, puis lance `ollama pull <modèle>` et `make restart-openclaw`.

## Services

| Service | Démarrage | Statut / logs |
|---|---|---|
| Ollama | Automatique (LaunchAgent `com.escarrie.ollama`) | `make status`, `make logs-ollama` |
| OpenClaw | Automatique (LaunchAgent installée par `openclaw gateway install`) | `make status`, `make logs-openclaw` |
| Nettoyage des fichiers reçus | Toutes les heures (LaunchAgent `com.escarrie.inbound-cleanup`) | `~/Library/Logs/inbound-cleanup.log` |
| mbsync / mail2md | `make start-mail` (docker compose) | `make logs-mail` |

```bash
# Tout le projet (Ollama → OpenClaw → mail)
make start
make stop
make restart

# Un seul service : ollama, openclaw ou mail
make start-ollama
make stop-openclaw
make restart-mail

# Recharger OpenClaw après une modification de ~/.openclaw/openclaw.json
make restart-openclaw

# Tester la transcription seule
make transcribe-test FILE=vocal.ogg
```

## Sécurité

- **Liste blanche** : `dmPolicy: "allowlist"` avec ton seul ID Telegram. Les groupes sont bloqués.
- **Outils restreints** : profil `coding`, avec `toolSearch: false` (les outils sont exposés directement au modèle local), sans `group:runtime` (pas de shell), `group:web`, `group:ui`, `group:nodes` ni `group:automation`. L'agent lit et écrit des fichiers, mais ne peut rien exécuter et n'a pas accès au web.
- **Contenu non fiable** : les mails et les messages transférés peuvent contenir des injections de prompt. Les consignes de l'agent ([`AGENTS.md`](openclaw/workspace/AGENTS.md)) les traitent comme des données, et l'agent n'a aucun outil d'envoi.
- **Telegram n'est pas chiffré de bout en bout** : le traitement est local, mais les messages transitent par les serveurs de Telegram. Pour une confidentialité complète, il faudra passer à Signal (prévu plus tard).
- Ollama n'écoute que sur `127.0.0.1`. Les secrets restent dans `openclaw/.env` (droits 600, ignoré par git).
