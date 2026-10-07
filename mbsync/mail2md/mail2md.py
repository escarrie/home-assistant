#!/usr/bin/env python3
"""mail2md : convertit en Markdown les mails Maildir écrits par mailsync (mbsync).

Une passe est déclenchée au démarrage, puis à chaque mise à jour de
<MAIL_DIR>/<mailbox>/.mailsync-last-success (écrit par mbsync après une synchro réussie).
Seuls les mails pas encore convertis sont traités (index par mailbox).

Si OPENCLAW_HOOK_URL est défini, chaque nouveau mail des dossiers PUSH_FOLDERS est aussi envoyé
à OpenClaw (webhook /hooks/agent), un par un. Les mails déjà présents à la mise en service ne
sont pas envoyés : `mail2md.py sync` (make sync-mails) les rattrape à la demande, avec un suivi
de progression sur Telegram.
"""
import calendar
import email
import email.policy
import email.utils
import hashlib
import json
import logging
import os
import re
import signal
import sys
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

import yaml
from bs4 import BeautifulSoup
from markdownify import markdownify

MAIL_DIR = Path(os.environ.get("MAIL_DIR", "/data/mail"))
OUTPUT_DIR = Path(os.environ.get("OUTPUT_DIR", "/data/markdown"))
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL", "15"))
MAILBOXES = os.environ.get("MAILBOXES", "").split()
FORCE = os.environ.get("FORCE", "false").lower() in ("1", "true", "yes", "on")

# Envoi à OpenClaw
HOOK_URL = os.environ.get("OPENCLAW_HOOK_URL", "").rstrip("/")
HOOK_TOKEN = os.environ.get("OPENCLAW_HOOKS_TOKEN", "")
HOOK_TIMEOUT = 600  # waitForCompletion : la réponse arrive quand l'agent a fini (chargement à froid compris)
PUSH_FOLDERS = os.environ.get("PUSH_FOLDERS", "INBOX").split()
PUSH_MAX_CHARS = int(os.environ.get("PUSH_MAX_CHARS", "20000"))
TELEGRAM_BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
TELEGRAM_USER_ID = os.environ.get("TELEGRAM_ALLOWED_USER_ID", "")

TRIGGER_FILE = ".mailsync-last-success"
INDEX_FILE = ".mail2md-index.json"
PUSH_FILE = ".mail2md-push.json"   # {"since": ISO, "pending": [...]} : envoi des nouveaux mails
SYNC_FILE = ".mail2md-sync.json"   # clés des anciens mails déjà envoyés par `sync`
MAILDIR_FLAGS = {"S": "seen", "R": "replied", "F": "flagged", "T": "trashed", "D": "draft", "P": "passed"}

log = logging.getLogger("mail2md")
stopping = False


def on_stop(*_):
    global stopping
    log.info("Arrêt demandé")
    stopping = True


# ---------- Maildir ----------
def list_mailboxes():
    if not MAIL_DIR.is_dir():
        return []
    boxes = [p for p in MAIL_DIR.iterdir() if p.is_dir() and not p.name.startswith(".")]
    if MAILBOXES:
        boxes = [p for p in boxes if p.name in MAILBOXES]
    return sorted(boxes)


def list_folders(mailbox):
    """Dossiers Maildir (ceux qui contiennent cur/), sous-dossiers compris."""
    for root, dirs, _ in os.walk(mailbox):
        dirs[:] = sorted(d for d in dirs if not d.startswith(".") and d not in ("cur", "new", "tmp"))
        if os.path.isdir(os.path.join(root, "cur")):
            yield Path(root)


def list_messages(folder):
    for sub in ("cur", "new"):  # jamais tmp/ : mails en cours d'écriture
        d = folder / sub
        if d.is_dir():
            for f in sorted(d.iterdir()):
                if f.is_file() and not f.name.startswith("."):
                    yield f


def maildir_key(path):
    """Nom stable : mbsync renomme le fichier quand les flags changent (partie après ':2,')."""
    return path.name.split(":", 1)[0]


def maildir_flags(path):
    _, _, info = path.name.partition(":2,")
    return [MAILDIR_FLAGS[c] for c in info if c in MAILDIR_FLAGS]


# ---------- Parsing ----------
def header_str(msg, name):
    value = msg.get(name)
    if value is None:
        return None
    return " ".join(str(value).split()) or None


def address_list(msg, name):
    values = msg.get_all(name) or []
    return [
        email.utils.formataddr((n, a)) if n else a
        for n, a in email.utils.getaddresses([str(v) for v in values])
        if a or n
    ]


def parse_date(msg):
    raw = msg.get("Date")
    if raw:
        try:
            dt = email.utils.parsedate_to_datetime(str(raw))
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt
        except (TypeError, ValueError):
            pass
    return None


def attachments(msg):
    result = []
    for part in msg.iter_attachments():
        try:
            size = len(part.get_payload(decode=True) or b"")
        except Exception:
            size = None
        result.append({
            "name": part.get_filename() or "(sans nom)",
            "type": part.get_content_type(),
            "size": size,
        })
    return result


def part_text(part):
    try:
        return part.get_content()
    except (LookupError, UnicodeDecodeError):  # charset inconnu ou mal déclaré
        payload = part.get_payload(decode=True) or b""
        return payload.decode("utf-8", errors="replace")


def html_to_markdown(html):
    soup = BeautifulSoup(html, "html.parser")
    # Sur du HTML mal formé, une balise peut en contenir d'autres de la liste : une fois le parent
    # détruit, ses descendants restent dans la liste avec attrs à None, on les saute.
    for tag in soup(["script", "style", "head", "title", "meta", "link", "noscript"]):
        if tag.attrs is not None:
            tag.decompose()
    for img in soup.find_all("img"):
        if img.attrs is None:
            continue
        w, h = img.get("width", ""), img.get("height", "")
        if str(w).strip() in ("0", "1") or str(h).strip() in ("0", "1") or str(img.get("src", "")).startswith("cid:"):
            # Pixels de tracking et images inline non extraites. unwrap() et non decompose() :
            # le parseur peut avoir rangé du contenu (liens, texte) à l'intérieur de l'<img>.
            img.unwrap()
    # Les mails utilisent des tableaux pour la mise en page : sans <th>, on les aplatit en paragraphes.
    for table in soup.find_all("table"):
        if table.find("th") is None:
            for tag in table.find_all(["thead", "tbody", "tfoot", "tr", "td"]):
                tag.name = "p"
            table.name = "p"
    md = markdownify(str(soup), heading_style="ATX", bullets="-", escape_misc=False)
    return clean_text(md)


def clean_text(text):
    lines = [line.rstrip().replace(" ", " ") for line in text.splitlines()]
    text = "\n".join(lines)
    text = re.sub(r"\n[ \t]*(\n[ \t]*){2,}", "\n\n", text)
    return text.strip()


def body_markdown(msg):
    part = msg.get_body(preferencelist=("html", "plain"))
    if part is None:
        return ""
    text = part_text(part)
    if part.get_content_type() == "text/html":
        return html_to_markdown(text)
    return clean_text(text)


# ---------- Rendu ----------
def slugify(text, max_len=60):
    text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode()
    text = re.sub(r"[^A-Za-z0-9]+", "-", text).strip("-").lower()
    return text[:max_len].rstrip("-") or "sans-sujet"


def folder_slug(rel):
    return re.sub(r"[^A-Za-z0-9._-]+", "_", str(rel)).strip("_") or "root"


def render(msg, mailbox, rel_folder, path):
    subject = header_str(msg, "Subject") or "(sans sujet)"
    date = parse_date(msg)
    front = {
        "subject": subject,
        "from": (address_list(msg, "From") or [None])[0],
        "to": address_list(msg, "To"),
        "cc": address_list(msg, "Cc"),
        "reply_to": address_list(msg, "Reply-To"),
        "date": date.isoformat() if date else None,
        "message_id": header_str(msg, "Message-ID"),
        "in_reply_to": header_str(msg, "In-Reply-To"),
        "references": (header_str(msg, "References") or "").split(),
        "list_unsubscribe": header_str(msg, "List-Unsubscribe"),
        "mailbox": mailbox,
        "folder": str(rel_folder),
        "flags": maildir_flags(path),
        "attachments": attachments(msg),
        "source": str(path.relative_to(MAIL_DIR / mailbox)),
    }
    return date, front, body_markdown(msg)


def to_markdown(front, body):
    yaml_front = yaml.safe_dump(front, allow_unicode=True, sort_keys=False, width=1000)
    return f"---\n{yaml_front}---\n\n# {front['subject']}\n\n{body}\n"


def read_markdown(path):
    """Inverse de to_markdown : (frontmatter, corps)."""
    _, yaml_front, rest = path.read_text(encoding="utf-8").split("---\n", 2)
    front = yaml.safe_load(yaml_front)
    rest = rest.lstrip("\n")
    heading = f"# {front.get('subject')}"
    if rest.startswith(heading):
        rest = rest[len(heading):]
    return front, rest.strip()


def write_atomic(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(content, encoding="utf-8")
    os.replace(tmp, path)


def load_json(path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return default
    except (OSError, ValueError) as e:
        log.warning("%s illisible (%s), ignoré", path, e)
        return default


def write_json(path, data):
    write_atomic(path, json.dumps(data, ensure_ascii=False, indent=0, sort_keys=True))


def parse_iso(value):
    """Date ISO (ou AAAA-MM-JJ) -> datetime avec fuseau ; sans fuseau = heure locale."""
    if not value:
        return None
    dt = datetime.fromisoformat(str(value))
    return dt if dt.tzinfo else dt.astimezone()


# ---------- Envoi à OpenClaw ----------
class HookRetry(Exception):
    """OpenClaw injoignable, occupé ou mal configuré : réessayer plus tard."""


class HookRejected(Exception):
    """Requête refusée pour ce mail précis (payload invalide ou trop gros)."""


hook_down = False  # pour ne journaliser qu'une fois la perte / le retour de la gateway


def build_message(front, body):
    """Message envoyé à l'agent. L'en-tête « [Mail entrant] » est la marque de catégorie (AGENTS.md)."""
    if len(body) > PUSH_MAX_CHARS:
        body = body[:PUSH_MAX_CHARS].rstrip() + "\n\n[… tronqué]"
    lines = [
        "[Mail entrant]",
        f"Boîte : {front.get('mailbox')} / {front.get('folder')}",
        f"De : {front.get('from') or '(inconnu)'}",
    ]
    if front.get("to"):
        lines.append(f"À : {', '.join(front['to'])}")
    lines += [
        f"Objet : {front.get('subject')}",
        f"Date : {front.get('date') or '(inconnue)'}",
    ]
    if front.get("attachments"):
        lines.append("Pièces jointes : " + ", ".join(a["name"] for a in front["attachments"]))
    return "\n".join(lines) + "\n\n" + (body or "(corps vide)")


def hook_key(mailbox, key):
    return "mail2md-" + hashlib.sha1(f"{mailbox}/{key}".encode()).hexdigest()


def post_hook(message, idempotency_key, deliver):
    """Envoie un tour d'agent et attend sa fin. deliver=True : réponse éventuelle sur Telegram."""
    payload = {"message": message, "name": "mail", "waitForCompletion": True, "timeoutSeconds": 300}
    if deliver and TELEGRAM_USER_ID:
        payload.update(channel="telegram", to=TELEGRAM_USER_ID)
    else:
        payload["deliver"] = False
    req = urllib.request.Request(
        f"{HOOK_URL}/agent",
        data=json.dumps(payload).encode(),
        method="POST",
        headers={
            "Authorization": f"Bearer {HOOK_TOKEN}",
            "Content-Type": "application/json",
            "Idempotency-Key": idempotency_key,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=HOOK_TIMEOUT) as resp:
            return json.loads(resp.read() or b"{}")
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", errors="replace")[:300]
        if e.code in (400, 413):
            raise HookRejected(f"HTTP {e.code} {detail}") from None
        raise HookRetry(f"HTTP {e.code} {detail}") from None
    except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
        raise HookRetry(str(getattr(e, "reason", e))) from None


def load_push_state(out_root):
    """À la première activation, `since` = maintenant : le stock existant n'est pas envoyé."""
    state = load_json(out_root / PUSH_FILE, None)
    if state is None:
        state = {"since": datetime.now(timezone.utc).isoformat(), "pending": []}
        write_json(out_root / PUSH_FILE, state)
        log.info("[%s] envoi à OpenClaw activé : seuls les mails datés après %s seront envoyés",
                 out_root.name, state["since"])
    return state


def push_pending(mailbox):
    """Envoie les nouveaux mails en attente, dans l'ordre ; s'arrête si OpenClaw est indisponible."""
    global hook_down
    path = OUTPUT_DIR / mailbox / PUSH_FILE
    state = load_json(path, None)
    while state and state.get("pending") and not stopping:
        item = state["pending"][0]
        try:
            data = post_hook(item["message"], hook_key(mailbox, item["key"]), deliver=True)
            log.info("[%s] envoyé à OpenClaw : %s (run %s, %s)", mailbox, item["subject"],
                     data.get("runId"), (data.get("completion") or {}).get("status"))
        except HookRetry as e:
            if not hook_down:
                log.warning("[%s] OpenClaw indisponible (%s) : %d mail(s) en attente, nouvel essai au prochain tour",
                            mailbox, e, len(state["pending"]))
            hook_down = True
            return
        except HookRejected as e:
            log.error("[%s] mail refusé par OpenClaw, abandonné : %s (%s)", mailbox, item["subject"], e)
        if hook_down:
            log.info("OpenClaw de nouveau joignable")
            hook_down = False
        state["pending"].pop(0)
        write_json(path, state)


# ---------- Passe de conversion ----------
def load_index(out_root):
    index = load_json(out_root / INDEX_FILE, {})
    return index if isinstance(index, dict) else {}


def convert_mailbox(mailbox_dir):
    mailbox = mailbox_dir.name
    out_root = OUTPUT_DIR / mailbox
    index = {} if FORCE else load_index(out_root)
    push = load_push_state(out_root) if HOOK_URL else None
    push_since = parse_iso(push["since"]) if push else None
    pending_keys = {item["key"] for item in push["pending"]} if push else set()
    converted = errors = queued = 0
    start = time.monotonic()

    for folder in list_folders(mailbox_dir):
        rel_folder = folder.relative_to(mailbox_dir)
        out_folder = out_root / folder_slug(rel_folder)
        for path in list_messages(folder):
            if stopping:
                break
            key = f"{rel_folder}/{maildir_key(path)}"
            known = index.get(key)
            if known and (out_root / known).is_file():
                continue
            try:
                with open(path, "rb") as f:
                    msg = email.message_from_binary_file(f, policy=email.policy.default)
                date, front, body = render(msg, mailbox, rel_folder, path)
                stamp = date.astimezone().strftime("%Y-%m-%d_%H%M") if date else "0000-00-00_0000"
                digest = hashlib.sha1(key.encode()).hexdigest()[:8]
                out = out_folder / f"{stamp}_{slugify(front['subject'])}_{digest}.md"
                write_atomic(out, to_markdown(front, body))
                index[key] = str(out.relative_to(out_root))
                converted += 1
                # Date >= since : garde-fou si l'index est perdu ou avec FORCE (pas de renvoi du stock).
                if (push is not None and str(rel_folder) in PUSH_FOLDERS and date and date >= push_since
                        and key not in pending_keys):
                    push["pending"].append({"key": key, "subject": front["subject"],
                                            "message": build_message(front, body)})
                    pending_keys.add(key)
                    queued += 1
            except FileNotFoundError:
                pass  # renommé par mbsync entre-temps : sera vu à la prochaine passe
            except Exception as e:
                errors += 1
                log.error("[%s] %s : %s", mailbox, path.name, e)

    # File d'envoi écrite avant l'index : un arrêt entre les deux ne perd aucun mail à envoyer.
    if queued:
        write_json(out_root / PUSH_FILE, push)
    if converted or not (out_root / INDEX_FILE).exists():
        write_json(out_root / INDEX_FILE, index)
    log.info("[%s] %d mail(s) converti(s), %d erreur(s), %d au total, %d à envoyer à OpenClaw (%.1fs)",
             mailbox, converted, errors, len(index), queued, time.monotonic() - start)


def trigger_mtime(mailbox_dir):
    try:
        return (mailbox_dir / TRIGGER_FILE).stat().st_mtime
    except FileNotFoundError:
        return None


# ---------- Rattrapage du stock (make sync-mails) ----------
def telegram(text):
    """Message de suivi envoyé directement par l'API Bot (sans passer par le LLM)."""
    log.info("%s", text)
    if not (TELEGRAM_BOT_TOKEN and TELEGRAM_USER_ID):
        return
    data = urllib.parse.urlencode({"chat_id": TELEGRAM_USER_ID, "text": text}).encode()
    try:
        urllib.request.urlopen(f"https://api.telegram.org/bot{TELEGRAM_BOT_TOKEN}/sendMessage",
                               data=data, timeout=15).close()
    except (urllib.error.URLError, TimeoutError, ConnectionError) as e:
        log.warning("Telegram injoignable : %s", getattr(e, "reason", e))


def fmt_count(n):
    return f"{n:,}".replace(",", " ")


def fmt_duration(seconds):
    seconds = int(seconds)
    if seconds < 60:
        return f"{seconds} s"
    if seconds < 3600:
        return f"{seconds // 60} min"
    return f"{seconds // 3600} h {seconds % 3600 // 60:02d}"


def months_ago(n):
    """Maintenant moins n mois calendaires (31 mars - 1 mois = dernier jour de février)."""
    now = datetime.now().astimezone()
    year, month = divmod(now.year * 12 + now.month - 1 - n, 12)
    day = min(now.day, calendar.monthrange(year, month + 1)[1])
    return now.replace(year=year, month=month + 1, day=day)


def sync_queue(mailboxes, folders, since_min):
    """Anciens mails à envoyer, du plus récent au plus ancien : antérieurs au `since` de l'envoi
    live et pas encore synchronisés. Les mails sans date passent en dernier."""
    queue = []
    for mailbox in mailboxes:
        out_root = OUTPUT_DIR / mailbox
        push = load_json(out_root / PUSH_FILE, None)
        live_since = parse_iso(push["since"]) if push else None
        done = set(load_json(out_root / SYNC_FILE, []))
        for key, rel in load_index(out_root).items():
            if key.rsplit("/", 1)[0] not in folders or key in done:
                continue
            try:
                front, _ = read_markdown(out_root / rel)
                date = parse_iso(front.get("date"))
            except (OSError, ValueError, yaml.YAMLError) as e:
                log.warning("[%s] %s illisible, ignoré : %s", mailbox, rel, e)
                continue
            if live_since and date and date >= live_since:
                continue  # déjà pris en charge par l'envoi des nouveaux mails
            if since_min and (date is None or date < since_min):
                continue
            queue.append((date or datetime.min.replace(tzinfo=timezone.utc), mailbox, key, out_root / rel))
    queue.sort(key=lambda item: item[0], reverse=True)
    return queue


def run_sync():
    if not (HOOK_URL and HOOK_TOKEN):
        log.error("OPENCLAW_HOOK_URL et OPENCLAW_HOOKS_TOKEN sont requis (voir make install)")
        return 1
    folders = os.environ.get("SYNC_FOLDERS", "").split() or PUSH_FOLDERS
    only = os.environ.get("SYNC_MAILBOX", "").split()
    limit = int(os.environ.get("SYNC_LIMIT") or 0)
    every = max(1, int(os.environ.get("SYNC_NOTIFY_EVERY") or 25))
    try:
        since_min = parse_iso(os.environ.get("SYNC_SINCE", "").strip())
    except ValueError:
        log.error("SINCE invalide (attendu : AAAA-MM-JJ)")
        return 1
    months = os.environ.get("SYNC_MONTHS", "").strip()
    if months:
        if not months.isdigit() or int(months) <= 0:
            log.error("MONTHS invalide (attendu : un nombre de mois > 0)")
            return 1
        # Avec SINCE et MONTHS, la borne la plus récente l'emporte.
        since_min = max(filter(None, (since_min, months_ago(int(months)))))

    known = sorted(p.name for p in OUTPUT_DIR.iterdir() if p.is_dir() and not p.name.startswith("."))
    unknown = [m for m in only if m not in known]
    if unknown:
        log.error("Boîte(s) inconnue(s) : %s (disponibles : %s)", ", ".join(unknown), ", ".join(known))
        return 1
    mailboxes = only or known

    queue = sync_queue(mailboxes, folders, since_min)
    if limit:
        queue = queue[:limit]
    total = len(queue)
    if not total:
        telegram("✅ Aucun mail à synchroniser")
        return 0

    names = ", ".join(sorted({mailbox for _, mailbox, _, _ in queue}))
    period = f", depuis le {since_min:%d/%m/%Y}" if since_min else ""
    telegram(f"📬 Synchro des mails : {fmt_count(total)} mail(s) à traiter{period} ({names}), "
             "du plus récent au plus ancien")
    done = {m: load_json(OUTPUT_DIR / m / SYNC_FILE, []) for m in mailboxes}
    processed = errors = 0
    start = time.monotonic()

    for _, mailbox, key, md in queue:
        if stopping:
            break
        try:
            front, body = read_markdown(md)
            # deliver=False : un vieux mail crée sa fiche, sans alerte « important » sur Telegram.
            post_hook(build_message(front, body), hook_key(mailbox, key), deliver=False)
            done[mailbox].append(key)
            write_json(OUTPUT_DIR / mailbox / SYNC_FILE, done[mailbox])
        except HookRetry as e:
            telegram(f"⚠️ OpenClaw indisponible ({e}) : synchro arrêtée à {fmt_count(processed)}/{fmt_count(total)}. "
                     "Relance make sync-mails pour reprendre.")
            return 1
        except (HookRejected, OSError, ValueError, yaml.YAMLError) as e:
            errors += 1
            log.error("[%s] %s : %s", mailbox, md.name, e)
        processed += 1
        log.info("[%s] %d/%d : %s", mailbox, processed, total, md.name)
        if processed % every == 0 and processed < total:
            remaining = (time.monotonic() - start) / processed * (total - processed)
            telegram(f"⏳ {fmt_count(processed)}/{fmt_count(total)} traités — {errors} erreur(s) — "
                     f"~{fmt_duration(remaining)} restantes")

    elapsed = fmt_duration(time.monotonic() - start)
    if processed < total:
        telegram(f"⏸️ Synchro interrompue à {fmt_count(processed)}/{fmt_count(total)} "
                 "(relance make sync-mails pour reprendre)")
        return 130
    telegram(f"✅ Queue terminée : {fmt_count(processed)} traités, {errors} erreur(s) en {elapsed}")
    return 0


def main():
    logging.basicConfig(level=logging.INFO, stream=sys.stdout,
                        format="%(asctime)s [mail2md] %(message)s", datefmt="%Y-%m-%dT%H:%M:%S%z")
    signal.signal(signal.SIGTERM, on_stop)
    signal.signal(signal.SIGINT, on_stop)
    if sys.argv[1:] == ["sync"]:
        sys.exit(run_sync())

    global HOOK_URL
    if HOOK_URL and not HOOK_TOKEN:
        log.warning("OPENCLAW_HOOKS_TOKEN absent : envoi à OpenClaw désactivé (voir make install)")
        HOOK_URL = ""
    log.info("Démarrage : %s -> %s (vérification toutes les %ss)", MAIL_DIR, OUTPUT_DIR, POLL_INTERVAL)
    if HOOK_URL:
        log.info("Envoi des nouveaux mails (%s) à OpenClaw : %s", ", ".join(PUSH_FOLDERS), HOOK_URL)

    seen = {}  # mailbox -> mtime du fichier signal lors de la dernière passe
    first = True
    while not stopping:
        for mailbox_dir in list_mailboxes():
            mtime = trigger_mtime(mailbox_dir)
            if first or mtime != seen.get(mailbox_dir.name):
                seen[mailbox_dir.name] = mtime
                convert_mailbox(mailbox_dir)
            if HOOK_URL:
                push_pending(mailbox_dir.name)  # à chaque tour : rattrape une gateway revenue
            if stopping:
                break
        first = False
        for _ in range(POLL_INTERVAL):
            if stopping:
                break
            time.sleep(1)


if __name__ == "__main__":
    main()
