#!/usr/bin/env python3
"""mail2md : convertit en Markdown les mails Maildir écrits par mailsync (mbsync).

Une passe est déclenchée au démarrage, puis à chaque mise à jour de
<MAIL_DIR>/<mailbox>/.mailsync-last-success (écrit par mbsync après une synchro réussie).
Seuls les mails pas encore convertis sont traités (index par mailbox).
"""
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

TRIGGER_FILE = ".mailsync-last-success"
INDEX_FILE = ".mail2md-index.json"
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
    yaml_front = yaml.safe_dump(front, allow_unicode=True, sort_keys=False, width=1000)
    return date, subject, f"---\n{yaml_front}---\n\n# {subject}\n\n{body_markdown(msg)}\n"


def write_atomic(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(content, encoding="utf-8")
    os.replace(tmp, path)


# ---------- Passe de conversion ----------
def load_index(out_root):
    try:
        return json.loads((out_root / INDEX_FILE).read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as e:
        log.warning("Index illisible (%s), reconstruction complète", e)
        return {}


def convert_mailbox(mailbox_dir):
    mailbox = mailbox_dir.name
    out_root = OUTPUT_DIR / mailbox
    index = {} if FORCE else load_index(out_root)
    converted = errors = 0
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
                date, subject, content = render(msg, mailbox, rel_folder, path)
                stamp = date.astimezone().strftime("%Y-%m-%d_%H%M") if date else "0000-00-00_0000"
                digest = hashlib.sha1(key.encode()).hexdigest()[:8]
                out = out_folder / f"{stamp}_{slugify(subject)}_{digest}.md"
                write_atomic(out, content)
                index[key] = str(out.relative_to(out_root))
                converted += 1
            except FileNotFoundError:
                pass  # renommé par mbsync entre-temps : sera vu à la prochaine passe
            except Exception as e:
                errors += 1
                log.error("[%s] %s : %s", mailbox, path.name, e)

    if converted or not (out_root / INDEX_FILE).exists():
        write_atomic(out_root / INDEX_FILE, json.dumps(index, ensure_ascii=False, indent=0, sort_keys=True))
    log.info("[%s] %d mail(s) converti(s), %d erreur(s), %d au total (%.1fs)",
             mailbox, converted, errors, len(index), time.monotonic() - start)


def trigger_mtime(mailbox_dir):
    try:
        return (mailbox_dir / TRIGGER_FILE).stat().st_mtime
    except FileNotFoundError:
        return None


def main():
    logging.basicConfig(level=logging.INFO, stream=sys.stdout,
                        format="%(asctime)s [mail2md] %(message)s", datefmt="%Y-%m-%dT%H:%M:%S%z")
    signal.signal(signal.SIGTERM, on_stop)
    signal.signal(signal.SIGINT, on_stop)
    log.info("Démarrage : %s -> %s (vérification toutes les %ss)", MAIL_DIR, OUTPUT_DIR, POLL_INTERVAL)

    seen = {}  # mailbox -> mtime du fichier signal lors de la dernière passe
    first = True
    while not stopping:
        for mailbox_dir in list_mailboxes():
            mtime = trigger_mtime(mailbox_dir)
            if first or mtime != seen.get(mailbox_dir.name):
                seen[mailbox_dir.name] = mtime
                convert_mailbox(mailbox_dir)
            if stopping:
                break
        first = False
        for _ in range(POLL_INTERVAL):
            if stopping:
                break
            time.sleep(1)


if __name__ == "__main__":
    main()
