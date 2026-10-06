# mailsync

Conteneur générique qui copie **une** mailbox IMAP en local au format Maildir, avec `mbsync` (isync). L'image ne connaît aucune mailbox : tout passe par des variables d'environnement et un volume monté sur `/data`. Pour synchroniser plusieurs mailbox, on lance plusieurs conteneurs avec des paramètres différents.

La synchro est **à sens unique (serveur → local)**. Le serveur n'est jamais modifié : pas de suppression, pas de déplacement, pas de création de dossier.

## Démarrage rapide

```bash
cp env/perso.env.example env/perso.env   # puis remplir
cp env/pro.env.example env/pro.env
# adapter PUID/PGID dans docker-compose.yml (id -u / id -g)
docker compose up -d --build
docker compose logs -f
```

Résultat sur l'hôte :

```
mail/
├── perso/
│   ├── INBOX/{cur,new,tmp}
│   ├── [Gmail]/Sent Mail/...
│   ├── .mailsync-status.json
│   └── .mailsync-last-success
└── pro/
    └── ...
```

## Sans compose

```bash
docker build -t mailsync .
docker run -d --name mail-perso --restart unless-stopped \
  --env-file env/perso.env -e PUID=$(id -u) -e PGID=$(id -g) \
  -v "$PWD/mail:/data" --tmpfs /tmp mailsync
```

Avec `docker run --env-file`, n'entoure pas les valeurs de guillemets : ils seraient conservés tels quels.

## Paramètres

| Variable | Défaut | Rôle |
|---|---|---|
| `MAILBOX_NAME` | requis | Nom du sous-dossier dans `/data` (`[A-Za-z0-9._-]`) |
| `IMAP_HOST` | requis | Serveur IMAP |
| `IMAP_PORT` | `993` | Port |
| `IMAP_TLS` | `imaps` | `imaps`, `starttls` ou `none` |
| `IMAP_USER` | requis | Identifiant |
| `IMAP_PASSWORD` | | Mot de passe (ou mot de passe d'application) |
| `IMAP_PASSWORD_FILE` | | Chemin d'un fichier secret, prioritaire sur `IMAP_PASSWORD` |
| `IMAP_AUTH_MECHS` | auto | Forcer un mécanisme : `LOGIN`, `PLAIN`… |
| `SYNC_PATTERNS` | `*` | Dossiers à synchroniser, syntaxe `Patterns` de mbsync |
| `SYNC_INTERVAL` | `300` | Secondes entre deux passes. `0` = une passe puis sortie |
| `SYNC_TIMEOUT` | `3600` | Durée max d'une passe. `0` = illimité |
| `SYNC_MAX_SIZE` | | Ignore les mails plus gros (`500k`, `20m`) |
| `SYNC_BATCH_SIZE` | `5000` | Nouveaux mails max par dossier et par passe. `0` = illimité |
| `SYNC_BATCH_DELAY` | `30` | Secondes avant le lot suivant quand il reste des mails à récupérer |
| `LOCAL_EXPUNGE` | `false` | `true` = supprime aussi en local ce qui a été supprimé sur le serveur |
| `PUID` / `PGID` | `1000` | Propriétaire des fichiers écrits |
| `VERBOSE` | `false` | Logs détaillés de mbsync |
| `DRY_RUN` | `false` | Affiche la config générée et s'arrête |
| `HEALTH_MAX_AGE` | `3 × intervalle + 300` | Âge max de la dernière synchro réussie avant `unhealthy` |

`SYNC_PATTERNS` : les motifs sont évalués dans l'ordre, le dernier qui correspond l'emporte. `!` exclut. Exemple Gmail : `* ![Gmail]* "[Gmail]/Sent Mail"`.

## Comportement

- **Premier lancement** : la synchro initiale d'une grosse boîte peut prendre des heures. Augmente `SYNC_TIMEOUT` (ou mets `0`) pour cette première passe. L'état est stocké dans chaque dossier Maildir, donc les passes suivantes sont incrémentales et reprennent après un redémarrage.
- **Synchro par lots** : chaque passe récupère au plus `SYNC_BATCH_SIZE` nouveaux mails par dossier, en commençant par les plus récents (option `MaxMessages` de mbsync, fixée au nombre de mails déjà présents en local + la taille du lot). Si un dossier a atteint cette limite, le lot suivant part après `SYNC_BATCH_DELAY` secondes au lieu d'attendre `SYNC_INTERVAL`. Les passes restent courtes : un arrêt ou un timeout coûte au plus un lot. Couper mbsync en plein téléchargement provoque `Warning: lost track of N pulled message(s)`.
- **Échecs répétés** : l'attente double à chaque échec (plafonnée à 1 h) pour éviter que le serveur te bloque après trop de logins ratés.
- **Statut** : `.mailsync-status.json` donne la dernière passe, le code de sortie, la dernière réussite et le nombre d'échecs consécutifs. Pratique pour que le brief du matin signale une boîte qui ne synchronise plus.
- **Healthcheck Docker** : healthy si une passe est en cours (et pas bloquée) ou si la dernière réussite est récente.
- **Secrets** : la config mbsync et le mot de passe sont écrits dans `/tmp` (tmpfs dans le compose), jamais sur le volume. mbsync tourne en utilisateur `PUID:PGID`, pas en root.

## Debug

```bash
docker compose run --rm -e DRY_RUN=true mail-perso      # voir la config générée
docker compose run --rm -e SYNC_INTERVAL=0 -e VERBOSE=true mail-perso   # une passe verbeuse
cat mail/perso/.mailsync-status.json
```

## Limites

- **OAuth2 non géré** (XOAUTH2). Gmail fonctionne avec un mot de passe d'application. Microsoft 365 / Outlook.com a désactivé l'authentification basique en IMAP, il faudrait ajouter un plugin SASL XOAUTH2 et un renouvellement de token.
- **Une mailbox par conteneur**, par choix : isolation des identifiants, logs et healthchecks séparés.

## Conversion en Markdown (mail2md)

Le service `mail2md` (image séparée, dossier `mail2md/`) convertit chaque mail en un fichier Markdown : front matter YAML (sujet, from, to, cc, date, message_id, flags, pièces jointes…) puis le corps HTML converti en Markdown (ou le texte brut s'il n'y a pas de HTML).

- **Déclenchement** : passe complète au démarrage, puis à chaque mise à jour de `mail/<mailbox>/.mailsync-last-success` (écrit par mbsync après une synchro réussie). Vérification toutes les `POLL_INTERVAL` secondes.
- **Pas de double conversion** : `markdown/<mailbox>/.mail2md-index.json` mémorise les mails déjà convertis (clé = nom Maildir sans les flags). Supprimer un `.md` le fait régénérer ; `FORCE=true` régénère tout.
- **Sortie** : `markdown/<mailbox>/<dossier>/<date>_<sujet>_<hash>.md`. `./mail` est monté en lecture seule.

| Variable | Défaut | Rôle |
|---|---|---|
| `MAIL_DIR` | `/data/mail` | Racine des Maildir |
| `OUTPUT_DIR` | `/data/markdown` | Racine des fichiers Markdown |
| `POLL_INTERVAL` | `15` | Secondes entre deux vérifications du fichier signal |
| `MAILBOXES` | toutes | Liste de mailbox à traiter, séparées par des espaces |
| `FORCE` | `false` | Ignore l'index et reconvertit tout |

```bash
docker compose up -d --build mail2md
docker compose logs -f mail2md
```

## Utilisation avec OpenClaw

Monte `./mail` en **lecture seule** côté agent. Le contenu des mails est non fiable (injection de prompt possible) : l'agent qui les lit ne doit pas avoir de shell ni d'envoi de mail.

# Process google
1. https://myaccount.google.com/apppasswords, connecté avec contact@escarrie.eu (pas un autre compte Google ouvert dans le navigateur).
2. Donne-lui un nom (par exemple mbsync) puis clique sur Créer.
3. Copie le code de 16 lettres qui s'affiche dans une fenêtre jaune. Il n'est montré qu'une seule fois.
4. Mets-le dans env/.env.perso, sans espaces :