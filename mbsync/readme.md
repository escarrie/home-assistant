# mailsync

Conteneur générique qui copie **une** mailbox IMAP en local au format Maildir, avec `mbsync` (isync). L'image ne connaît aucune mailbox : tout passe par des variables d'environnement et un volume monté sur `/data`. Pour synchroniser plusieurs mailbox, on lance plusieurs conteneurs avec des paramètres différents.

La synchro est **à sens unique (serveur → local)**. Le serveur n'est jamais modifié : pas de suppression, pas de déplacement, pas de création de dossier.

## Démarrage rapide

```bash
cp env/perso.env.example env/perso.env   # puis remplir
cp env/pro.env.example env/pro.env
# adapter PUID/PGID dans ../docker-compose.yml (id -u / id -g)
cd ..                                    # le compose est à la racine du dépôt
docker compose up -d --build
docker compose logs -f
```

Résultat sur l'hôte (dans `data/mbsync/`, ignoré par git) :

```
data/mbsync/mail/
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
| `IMAP_AUTH_MECHS` | `PLAIN LOGIN` (`XOAUTH2` en oauth2) | Mécanismes d'authentification autorisés |
| `IMAP_AUTH` | `password` | `password` ou `oauth2` (Microsoft 365, mécanisme XOAUTH2) |
| `OAUTH2_CLIENT_ID` | | ID de l'application Entra ID, utilisé seulement par `authorize` |
| `OAUTH2_TENANT` | `organizations` | Tenant Microsoft (domaine ou ID), utilisé seulement par `authorize` |
| `OAUTH2_TOKEN_FILE` | `/oauth/<MAILBOX_NAME>.json` | Fichier du refresh token, doit rester inscriptible |
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

Commandes à lancer depuis la racine du dépôt (là où se trouve `docker-compose.yml`).

```bash
docker compose run --rm -e DRY_RUN=true mail-perso      # voir la config générée
docker compose run --rm -e SYNC_INTERVAL=0 -e VERBOSE=true mail-perso   # une passe verbeuse
cat data/mbsync/mail/perso/.mailsync-status.json
```

## Limites

- **OAuth2 : Microsoft 365 uniquement**. Gmail passe par un mot de passe d'application.
- **Une mailbox par conteneur**, par choix : isolation des identifiants, logs et healthchecks séparés.

## Conversion en Markdown (mail2md)

Le service `mail2md` (image séparée, dossier `mail2md/`) convertit chaque mail en un fichier Markdown : front matter YAML (sujet, from, to, cc, date, message_id, flags, pièces jointes…) puis le corps HTML converti en Markdown (ou le texte brut s'il n'y a pas de HTML).

- **Déclenchement** : passe complète au démarrage, puis à chaque mise à jour de `data/mbsync/mail/<mailbox>/.mailsync-last-success` (écrit par mbsync après une synchro réussie). Vérification toutes les `POLL_INTERVAL` secondes.
- **Pas de double conversion** : `data/mbsync/markdown/<mailbox>/.mail2md-index.json` mémorise les mails déjà convertis (clé = nom Maildir sans les flags). Supprimer un `.md` le fait régénérer ; `FORCE=true` régénère tout.
- **Sortie** : `data/mbsync/markdown/<mailbox>/<dossier>/<date>_<sujet>_<hash>.md`. `data/mbsync/mail` est monté en lecture seule.

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

Monte `data/mbsync/mail` en **lecture seule** côté agent. Le contenu des mails est non fiable (injection de prompt possible) : l'agent qui les lit ne doit pas avoir de shell ni d'envoi de mail.

# Process google
1. https://myaccount.google.com/apppasswords, connecté avec contact@escarrie.eu (pas un autre compte Google ouvert dans le navigateur).
2. Donne-lui un nom (par exemple mbsync) puis clique sur Créer.
3. Copie le code de 16 lettres qui s'affiche dans une fenêtre jaune. Il n'est montré qu'une seule fois.
4. Mets-le dans env/.env.perso, sans espaces :

# Process Microsoft 365 (OAuth2)
Microsoft 365 n'accepte plus de mot de passe en IMAP, même un mot de passe d'application. `IMAP_AUTH=oauth2` utilise un refresh token obtenu une seule fois, puis `oauth2-token` (PassCmd de mbsync) le renouvelle tout seul.

1. https://entra.microsoft.com → Applications → Inscriptions d'applications → Nouvelle inscription. Nom `mbsync`, comptes de cet annuaire uniquement, pas d'URI de redirection.
2. Copie l'ID d'application (client) dans `OAUTH2_CLIENT_ID`, et le domaine (ou l'ID de l'annuaire) dans `OAUTH2_TENANT`.
3. Authentification → Paramètres avancés → « Autoriser les flux de clients publics » : Oui.
4. Autorisations d'API → Ajouter → API utilisées par mon organisation → `Office 365 Exchange Online` → Autorisations déléguées → `IMAP.AccessAsUser.All`. Accorder le consentement administrateur si demandé.
5. Vérifie que l'IMAP est actif sur la boîte (centre d'admin Microsoft 365 → Utilisateurs → Courrier → Gérer les applications de messagerie).
6. Connexion initiale, depuis la racine du dépôt :
   ```bash
   docker compose build mail-zenproject
   docker compose run --rm mail-zenproject authorize
   ```
   Ouvre l'URL affichée, entre le code, connecte-toi (2FA comprise). Le jeton est écrit dans `data/mbsync/oauth/<MAILBOX_NAME>.json`.
7. `docker compose up -d mail-zenproject`.

Le refresh token expire après 90 jours sans utilisation ; tant que la synchro tourne, il est renouvelé. S'il est révoqué (changement de mot de passe, politique d'accès conditionnel), relance l'étape 6.
