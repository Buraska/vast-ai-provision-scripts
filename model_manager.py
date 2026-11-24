#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Model Manager - local web UI for ComfyUI / Vast.ai provision scripts.

Parses the model download entries in every *.sh provision script next to this
file (Civitai: download_civitai_primary / civitai download --version|--model /
bare; HuggingFace: download_hf_file blocks, hf download, download_hf, wget of
huggingface.co resolve URLs) and serves a single-page UI on localhost to:

- browse every model/loras/VAE/text encoder entry with source badges, target
  dirs, descriptions, sizes and links (commented-out entries show as "off"),
- check pinned Civitai versions against the API (latest / new / missing /
  unknown badges; HF entries are not versioned),
- add models by pasting a Civitai (any mirror domain) or HuggingFace URL,
- delete, disable/enable and retarget (edit target dir) entries in place,
- commit and push the current script with one click (Save to git),
- run from any folder: the managed scripts folder is read from
  model_manager_settings.json (same config as the PowerShell version) or set
  in the UI via the Folder button.

Files are always written as UTF-8 without BOM with LF line endings (bash
safe). Before the first mutation of a script in a server session a one-shot
sidecar backup <name>.sh.bak is written. The HTTP listener binds to localhost
only, embeds a per-session token into the page (X-Auth header required) and
rejects cross-origin requests.

Stdlib only - no third-party packages. Python 3.8+.

Usage:
    python model_manager.py [--port 8766] [--scripts-dir PATH] [--no-browser]
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import webbrowser
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from secrets import token_hex

APP_DIR = os.path.dirname(os.path.abspath(__file__))
SETTINGS_FILE = os.path.join(APP_DIR, 'model_manager_settings.json')
CIVITAI_API = 'https://civitai.com/api/v1'
DEFAULT_PORT = 8766
PORT_ATTEMPTS = 20
LOG_TAIL_LINES = 150

# ---------------------------------------------------------------------------
# Parser - regex table (one pattern per call form)
# ---------------------------------------------------------------------------
RE_CIV_PRIMARY = re.compile(r'^download_civitai_primary\s+(\d+)\s+([^\s#]+)(?:\s*\|\|[^#]*)?(?:\s+#\s*(.+?))?\s*$')
RE_CIV_FLAG = re.compile(r'^civitai\s+download\s+--version\s+(\d+)\s+--out-dir\s+([^\s#]+)(?:\s*\|\|[^#]*)?(?:\s+#\s*(.+?))?\s*$')
RE_CIV_MODEL = re.compile(r'^civitai\s+download\s+--model\s+(\d+)\s+--out-dir\s+([^\s#]+)(?:\s*\|\|[^#]*)?(?:\s+#\s*(.+?))?\s*$')
RE_CIV_BARE = re.compile(r'^civitai\s+download\s+(\d+)\s+--out-dir\s+([^\s#]+)(?:\s*\|\|[^#]*)?(?:\s+#\s*(.+?))?\s*$')
RE_HF_DOWNLOAD_A = re.compile(r'^hf\s+download\s+(?:hf://)?([\w.-]+/[\w.-]+)(?:/([^\s#]+?))?\s+--local-dir\s+([^\s#]+)(?:\s*\|\|[^#]*)?(?:\s+#\s*(.+?))?\s*$')
RE_HF_DOWNLOAD_B = re.compile(r'^hf\s+download\s+([\w.-]+/[\w.-]+)\s+([^/\s"\'$]+)\s+--local-dir\s+([^\s#]+)(?:\s*\|\|[^#]*)?(?:\s+#\s*(.+?))?\s*$')
RE_DOWNLOAD_HF = re.compile(r'^download_hf\s+(?:hf://)?([\w.-]+/[\w.-]+)(?:/([^\s#]+?))?\s+([^\s#]+)(?:\s*\|\|[^#]*)?(?:\s+#\s*(.+?))?\s*$')
RE_WGET = re.compile(r'^wget\s+-P\s+([^\s#]+)\s+(https://huggingface\.co/[^\s#]+)(?:\s*\|\|[^#]*)?(?:\s+#\s*(.+?))?\s*$')
RE_HF_FILE_ARGS = re.compile(r'^download_hf_file\s+([^\s"\'$]+)\s+([^\s"\'$]+)\s+([^\s"\'$]+)(?:\s*\|\|[^#]*)?(?:\s+#\s*(.+?))?\s*$')
RE_CUSTOM_NODE = re.compile(r'^install_custom_node\s+(https://github\.com/[^\s#]+?)(?:\.git)?(?:\s+([^\s#]+?))?(?:\s*\|\|[^#]*)?(?:\s+#\s*(.+?))?\s*$')
RE_GH_URL = re.compile(r'github\.com/([\w.-]+)/([\w.-]+?)(?:\.git)?/?$')
RE_HF_FILE_TRIGGER = re.compile(r'^download_hf_file[\s\\]')

# Standalone-comment guards: reject lines that belong to a commented-out
# backslash-continued block or are commented-out model calls themselves.
RE_ADJ_MODEL_CALL = re.compile(r'^(download_hf_file|download_civitai_primary|download_hf)\b')
RE_ADJ_CLI = re.compile(r'^(civitai|hf|wget)\s')

# Target-dir token location, per call form (single-line entries).
RE_DIR_TOKEN = {
    'primary': re.compile(r'^(download_civitai_primary\s+\d+\s+)([^\s#]+)'),
    'download_hf': re.compile(r'^(download_hf\s+(?:hf://)?\S+\s+)([^\s#]+)'),
    'download_hf_file': re.compile(r'^(download_hf_file\s+\S+\s+\S+\s+)([^\s#]+)'),
    'wget': re.compile(r'^(\s*wget\s+-P\s+)([^\s#]+)'),
    'hf_download': re.compile(r'^(.*?--local-dir\s+)([^\s#]+)'),
}
RE_DIR_TOKEN_DEFAULT = re.compile(r'^(.*?--out-dir\s+)([^\s#]+)')  # flag/bare/model

# URL forms accepted by the Add flow.
RE_CIV_URL = re.compile(r'civitai\.[a-z]{2,}/models/(\d+)(?:/[^\s?/]*)?(?:[/?].*?modelVersionId=(\d+))?')
RE_HF_URL_HTTPS = re.compile(r'^https?://(?:www\.)?huggingface\.co/([\w.-]+)/([\w.-]+)(?:/(?:blob|resolve)/[^/\s]+/(.+))?/?$')
RE_HF_URL_SCHEME = re.compile(r'^hf://([\w.-]+)/([\w.-]+)(?:/(.+))?$')
RE_HF_URL_INNER = re.compile(r'^https://huggingface\.co/([^/\s]+)/([^/\s]+)/resolve/([^/\s]+)/(.+)$')

RE_COMMENT_PREFIX = re.compile(r'^(\s*#+\s?)')      # full '# ' prefix, for capture
RE_COMMENT_STRIP = re.compile(r'^(\s*)#+\s?')       # leading whitespace only, for uncomment


def split_script_lines(text):
    """Splits keeping a trailing empty element, so '\\n'.join round-trips a
    final newline exactly."""
    return re.split(r'\r?\n', text)


def read_script_text(path):
    with open(path, 'r', encoding='utf-8-sig', newline='') as fh:
        return fh.read()


def write_script_text(path, lines):
    with open(path, 'w', encoding='utf-8', newline='') as fh:
        fh.write('\n'.join(lines))


def strip_comment(text):
    """Removes all leading '#' markers (used so commented entries parse)."""
    return text.lstrip('#').strip()


def adjacent_comment(lines, line_no):
    """Text of the standalone comment line directly above a (1-based) line,
    used as the entry description. Rejects comment lines that are actually
    parts of a commented-out backslash-continued block (they end with a
    continuation marker, or the line above them does) and commented-out model
    call lines themselves."""
    if line_no < 2:
        return ''
    prev = lines[line_no - 2].strip()
    if not prev.startswith('#'):
        return ''
    t = strip_comment(prev)
    if not t or t.endswith('\\'):
        return ''
    if line_no >= 3:
        above = lines[line_no - 3].strip()
        if above.startswith('#') and strip_comment(above).endswith('\\'):
            return ''
    if RE_ADJ_MODEL_CALL.match(t) or RE_ADJ_CLI.match(t):
        return ''
    return t


def make_entry(line_no, block_end, active, source, kind, call_form, ids, directory,
               description, url, repo=None, path=None, filename=None, name=''):
    entry = {
        'lineStart': line_no,
        'lineEnd': block_end,
        'active': active,
        'source': source,
        'kind': kind,
        'callForm': call_form,
        'ids': ids,
        'dir': directory,
        'description': description,
        'url': url,
        'name': name,
        'repo': repo,
        'path': path,
        'filename': filename,
    }
    return entry


def parse_script(path):
    """Pure parser: returns (models, warnings). Nothing is written to disk."""
    models = []
    warnings = []
    text = read_script_text(path)
    lines = split_script_lines(text)
    total = len(lines)
    i = 0
    while i < total:
        trimmed = lines[i].strip()
        i += 1
        if not trimmed:
            continue
        active = True
        work = trimmed
        if work.startswith('#'):
            active = False
            work = strip_comment(work)
            if not work:
                continue
        line_no = i          # 1-based line number of the first line
        block_end = i        # 1-based line number of the last line
        joined = work

        # --- download_hf_file: single-line or backslash-continued block ---
        is_hf_file_call = work == 'download_hf_file' or RE_HF_FILE_TRIGGER.match(work)
        if is_hf_file_call:
            if work.endswith('\\') or work == 'download_hf_file':
                parts = []
                first = work[:-1].strip() if work.endswith('\\') else work
                if first:
                    parts.append(first)
                done = False
                j = i
                while not done and j < total:
                    c = lines[j].strip()
                    j += 1
                    if c.startswith('#'):
                        c = strip_comment(c)
                    if not c:
                        j -= 1
                        break
                    had_cont = c.endswith('\\')
                    if had_cont:
                        c = c[:-1].strip()
                    if c:
                        parts.append(c)
                    if not had_cont:
                        done = True
                block_end = j
                joined = ' '.join(parts)

            m = RE_HF_FILE_ARGS.match(joined)
            if m:
                repo, remote_path, dest = m.group(1), m.group(2), m.group(3)
                inline_desc = m.group(4) or ''
                directory, file_name = dest, ''
                sep = dest.rfind('/')
                if sep >= 0:
                    directory, file_name = dest[:sep], dest[sep + 1:]
                if not inline_desc and active:
                    inline_desc = adjacent_comment(lines, line_no)
                models.append(make_entry(
                    line_no, block_end, active, 'hf', 'hf-file', 'download_hf_file',
                    {}, directory, inline_desc, 'https://huggingface.co/' + repo,
                    repo=repo, path=remote_path, filename=file_name))
            else:
                warnings.append({'line': line_no,
                                 'reason': 'download_hf_file with non-literal arguments '
                                           'ignored (shell variables/quotes)'})
            i = block_end
            continue

        # --- Civitai forms ---
        m = RE_CIV_PRIMARY.match(work)
        if m:
            desc = m.group(3) or ''
            if not desc.strip() and active:
                desc = adjacent_comment(lines, line_no)
            models.append(make_entry(
                line_no, block_end, active, 'civitai', 'civitai-version', 'primary',
                {'versionId': m.group(1)}, m.group(2), desc, None))
            continue
        m = RE_CIV_FLAG.match(work)
        if m:
            desc = m.group(3) or ''
            if not desc.strip() and active:
                desc = adjacent_comment(lines, line_no)
            models.append(make_entry(
                line_no, block_end, active, 'civitai', 'civitai-version', 'flag',
                {'versionId': m.group(1)}, m.group(2), desc, None))
            continue
        m = RE_CIV_MODEL.match(work)
        if m:
            desc = m.group(3) or ''
            if not desc.strip() and active:
                desc = adjacent_comment(lines, line_no)
            models.append(make_entry(
                line_no, block_end, active, 'civitai', 'civitai-model', 'model',
                {'modelId': m.group(1)}, m.group(2), desc, None))
            continue
        m = RE_CIV_BARE.match(work)
        if m:
            desc = m.group(3) or ''
            if not desc.strip() and active:
                desc = adjacent_comment(lines, line_no)
            models.append(make_entry(
                line_no, block_end, active, 'civitai', 'civitai-version', 'bare',
                {'versionId': m.group(1)}, m.group(2), desc, None))
            continue

        # --- hf download: hf://repo/path --local-dir DIR | repo FILE --local-dir DIR ---
        m = RE_HF_DOWNLOAD_A.match(work)
        if m:
            repo, remote_path, directory, desc = m.group(1), m.group(2) or '', m.group(3), m.group(4) or ''
            file_name = remote_path.rsplit('/', 1)[-1] if remote_path else ''
            if not desc.strip() and active:
                desc = adjacent_comment(lines, line_no)
            models.append(make_entry(
                line_no, block_end, active, 'hf', 'hf-file', 'hf_download',
                {}, directory, desc, 'https://huggingface.co/' + repo,
                repo=repo, path=remote_path, filename=file_name))
            continue
        m = RE_HF_DOWNLOAD_B.match(work)
        if m:
            repo, file_name, directory, desc = m.group(1), m.group(2), m.group(3), m.group(4) or ''
            if not desc.strip() and active:
                desc = adjacent_comment(lines, line_no)
            models.append(make_entry(
                line_no, block_end, active, 'hf', 'hf-file', 'hf_download',
                {}, directory, desc, 'https://huggingface.co/' + repo,
                repo=repo, path=file_name, filename=file_name))
            continue

        # --- download_hf helper (uri + local dir) ---
        m = RE_DOWNLOAD_HF.match(work)
        if m:
            repo, remote_path, directory, desc = m.group(1), m.group(2) or '', m.group(3), m.group(4) or ''
            file_name = remote_path.rsplit('/', 1)[-1] if remote_path else ''
            if not desc.strip() and active:
                desc = adjacent_comment(lines, line_no)
            models.append(make_entry(
                line_no, block_end, active, 'hf', 'hf-file', 'download_hf',
                {}, directory, desc, 'https://huggingface.co/' + repo,
                repo=repo, path=remote_path, filename=file_name))
            continue

        # --- wget of a huggingface.co resolve URL ---
        m = RE_WGET.match(work)
        if m:
            directory, url, desc = m.group(1), m.group(2), m.group(3) or ''
            mu = RE_HF_URL_INNER.match(url)
            repo, remote_path, file_name = '', '', ''
            if mu:
                repo = mu.group(1) + '/' + mu.group(2)
                remote_path = mu.group(4)
                file_name = remote_path.rsplit('/', 1)[-1]
            if not desc.strip() and active:
                desc = adjacent_comment(lines, line_no)
            models.append(make_entry(
                line_no, block_end, active, 'hf', 'hf-file', 'wget',
                {}, directory, desc, url,
                repo=repo, path=remote_path, filename=file_name))
            continue

        # --- custom node via install_custom_node helper ---
        m = RE_CUSTOM_NODE.match(work)
        if m:
            url = m.group(1).rstrip('/')
            folder = m.group(2) or url.rsplit('/', 1)[-1]
            desc = (m.group(3) or '').strip()
            if not desc and active:
                desc = adjacent_comment(lines, line_no)
            models.append(make_entry(
                line_no, block_end, active, 'github', 'custom-node', 'install_custom_node',
                {'repo': url}, './custom_nodes', desc, url, name=folder, repo=url))
            continue

        # nothing matched - plain shell line, skipped
    return models, warnings


def dominant_civitai_form(path):
    """Count of download_civitai_primary hits vs civitai download hits;
    ties resolve to the primary helper form."""
    models, _ = parse_script(path)
    primary = flag = bare = 0
    for m in models:
        if m['source'] != 'civitai':
            continue
        form = m['callForm']
        if form == 'primary':
            primary += 1
        elif form == 'bare':
            bare += 1
        else:
            flag += 1
    if primary >= flag + bare:
        return 'primary'
    if flag >= bare:
        return 'flag'
    return 'bare'


# ---------------------------------------------------------------------------
# Application state
# ---------------------------------------------------------------------------
class AppState:
    def __init__(self):
        self.lock = threading.RLock()
        self.scripts_dir = ''
        self.dir_source = 'default'
        self.token = token_hex(16)
        self.log = deque(maxlen=400)
        self.civitai_cache = {}     # '<script>|<lineStart>|<id>' -> enriched fields
        self.ssh_cache = {}         # '<script>|<lineStart>' -> sshStatus
        self.backed_up = set()      # script names already backed up this session


STATE = AppState()


def add_log(message):
    line = '[{0}] {1}'.format(time.strftime('%H:%M:%S'), message)
    STATE.log.append(line)
    try:
        print(line, flush=True)
    except OSError:
        pass


def log_tail_text():
    if not STATE.log:
        return ''
    return '\n'.join(list(STATE.log)[-LOG_TAIL_LINES:])


def load_settings():
    if not os.path.isfile(SETTINGS_FILE):
        return {}
    try:
        with open(SETTINGS_FILE, 'r', encoding='utf-8-sig') as fh:
            return json.load(fh)
    except Exception as exc:
        print('Could not read {0}: {1}'.format(SETTINGS_FILE, exc), flush=True)
        return {}


def save_settings(scripts_dir='', ssh_host='', remote_dir=''):
    data = {}
    if scripts_dir:
        data['scriptsDir'] = scripts_dir
    if ssh_host:
        data['sshHost'] = ssh_host
    if remote_dir:
        data['remoteDir'] = remote_dir
    with open(SETTINGS_FILE, 'w', encoding='utf-8', newline='') as fh:
        json.dump(data, fh, indent=4)


def get_saved_scripts_dir():
    s = load_settings()
    return str(s.get('scriptsDir', '') or '')


def get_saved_ssh_host():
    s = load_settings()
    return str(s.get('sshHost', '') or '')

def get_saved_remote_dir():
    s = load_settings()
    return str(s.get('remoteDir', '') or '/workspace/ComfyUI')


def resolve_scripts_dir(cli_dir):
    """Precedence: --scripts-dir parameter > config file > folder of this file."""
    if cli_dir:
        return os.path.abspath(cli_dir), 'parameter'
    own = APP_DIR
    saved = get_saved_scripts_dir()
    if saved and os.path.isdir(saved):
        return saved, 'config'
    if saved:
        print('model_manager_settings.json points to a missing folder: {0}'.format(saved),
              flush=True)
    return own, 'default'


def backup_script_once(name, path):
    if name in STATE.backed_up:
        return
    shutil.copy2(path, path + '.bak')
    STATE.backed_up.add(name)
    add_log('One-shot backup written: {0}.bak'.format(name))


def list_scripts(directory):
    """Returns (names, dir_error); a permission problem never raises."""
    names = []
    error = ''
    try:
        for entry in sorted(os.listdir(directory)):
            if entry.lower().endswith('.sh') and os.path.isfile(os.path.join(directory, entry)):
                names.append(entry)
    except OSError as exc:
        error = str(exc)
        add_log('Cannot list scripts in {0}: {1}'.format(directory, exc))
    return names, error


def resolve_script_path(name):
    if not name or not name.strip():
        raise ValueError('A script name is required.')
    if '/' in name or '\\' in name or name in ('.', '..'):
        raise ValueError('Invalid script name: {0}'.format(name))
    full = os.path.join(STATE.scripts_dir, name)
    if not os.path.isfile(full):
        raise ValueError('Script not found: {0}'.format(name))
    return full


# ---------------------------------------------------------------------------
# Script mutations
# ---------------------------------------------------------------------------
def remove_entry_lines(path, line_start, line_end):
    lines = split_script_lines(read_script_text(path))
    if line_start < 1 or line_end < line_start or line_end > len(lines):
        raise ValueError('Line range {0}-{1} is outside the file ({2} lines).'.format(
            line_start, line_end, len(lines)))
    backup_script_once(os.path.basename(path), path)
    kept = [l for idx, l in enumerate(lines) if not (line_start - 1 <= idx <= line_end - 1)]
    write_script_text(path, kept)


def safe_echo_text(text):
    """Text destined for a single-quoted bash echo inside an inserted line:
    characters that would break the quoting or the parser's wrapper suffix are
    replaced with spaces."""
    if not text or not text.strip():
        return ''
    cleaned = ''.join(' ' if c in '#|\'"\\`' else c for c in text)
    cleaned = re.sub(r'\s{2,}', ' ', cleaned)
    return cleaned.strip()


def toggle_entry_active(path, line_start, line_end):
    """Comment out / uncomment the exact block of a parsed model entry; every
    line of a multi-line block is toggled. Returns the resulting active state."""
    models, _ = parse_script(path)
    entry = next((m for m in models
                  if m['lineStart'] == line_start and m['lineEnd'] == line_end), None)
    if entry is None:
        raise ValueError('No model entry found at lines {0}-{1} of {2}.'.format(
            line_start, line_end, os.path.basename(path)))
    backup_script_once(os.path.basename(path), path)
    lines = split_script_lines(read_script_text(path))
    was_active = bool(entry['active'])
    for idx in range(line_start - 1, line_end):
        line = lines[idx]
        if was_active:
            if line.strip() and not line.lstrip().startswith('#'):
                lines[idx] = '# ' + line
        else:
            if line.lstrip().startswith('#'):
                lines[idx] = re.sub(RE_COMMENT_STRIP, r'\1', line)
    write_script_text(path, lines)
    models, _ = parse_script(path)
    after = next((m for m in models
                  if m['lineStart'] == line_start and m['lineEnd'] == line_end), None)
    if after:
        return bool(after['active'])
    return not was_active


def set_entry_dir(path, line_start, line_end, new_dir):
    """Rewrites the target dir of a parsed entry in place, preserving the call
    form, comments and indentation. Multi-line download_hf_file blocks get
    their destination line rebuilt as <newdir>/<filename>."""
    if not new_dir or not new_dir.strip() or re.search(r'[\s#\'"$]', new_dir):
        raise ValueError('Target dir must not be empty and may not contain spaces, '
                         '#, quotes or $.')
    models, _ = parse_script(path)
    entry = next((m for m in models
                  if m['lineStart'] == line_start and m['lineEnd'] == line_end), None)
    if entry is None:
        raise ValueError('No model entry found at lines {0}-{1} of {2}.'.format(
            line_start, line_end, os.path.basename(path)))
    backup_script_once(os.path.basename(path), path)
    lines = split_script_lines(read_script_text(path))
    form = entry['callForm']

    if form == 'install_custom_node':
        raise ValueError('Custom nodes always install to ./custom_nodes - '
                         'the target dir cannot be changed.')

    if form == 'download_hf_file' and line_end > line_start:
        # destination line is the last line of the block
        idx = line_end - 1
        line = lines[idx]
        prefix_m = RE_COMMENT_PREFIX.match(line)
        prefix = prefix_m.group(1) if prefix_m else ''
        content = line[len(prefix):]
        # keep the tolerance wrapper and trailing comment across the rewrite
        comment = ''
        cm = re.search(r'\s+(#.*)$', content)
        if cm:
            comment = cm.group(1)
            content = content[:cm.start()].rstrip()
        wrapper = ''
        wm = re.search(r'\s*\|\|.*$', content)
        if wm:
            wrapper = wm.group(0)
            content = content[:wm.start()].rstrip()
        indent = re.match(r'^\s*', content).group(0)
        content = indent + new_dir + '/' + str(entry['filename'])
        if wrapper:
            content += wrapper
        if comment:
            content += ' ' + comment
        lines[idx] = prefix + content
    else:
        idx = line_start - 1
        line = lines[idx]
        prefix_m = RE_COMMENT_PREFIX.match(line)
        prefix = prefix_m.group(1) if prefix_m else ''
        content = line[len(prefix):]
        pattern = RE_DIR_TOKEN.get(form, RE_DIR_TOKEN_DEFAULT)
        m = pattern.match(content)
        if not m:
            raise ValueError('Could not locate the target dir token on line {0}.'.format(line_start))
        content = content[:m.start(2)] + new_dir + content[m.end(2):]
        lines[idx] = prefix + content
    write_script_text(path, lines)


def insert_entry_lines(path, new_lines):
    """Inserts a blank line + the new call block right after the last active
    entry (or at EOF). Returns the 0-based insertion index."""
    backup_script_once(os.path.basename(path), path)
    lines = split_script_lines(read_script_text(path))
    models, _ = parse_script(path)
    last_active = None
    for m in models:
        if m['active']:
            last_active = m
    if last_active:
        pos = int(last_active['lineEnd'])
    elif lines and lines[-1] == '':
        pos = len(lines) - 1
    else:
        pos = len(lines)
    lines[pos:pos] = [''] + list(new_lines)
    write_script_text(path, lines)
    return pos


# ---------------------------------------------------------------------------
# Civitai / HuggingFace API
# ---------------------------------------------------------------------------
def civitai_headers():
    headers = {'User-Agent': 'model-manager/2'}
    token = os.environ.get('CIVITAI_TOKEN')
    if token:
        headers['Authorization'] = 'Bearer ' + token
    return headers


def api_get_json(url, timeout=30, attempts=3):
    """GET JSON with retry+backoff for transient failures; 404 is not retried
    (the resource is really gone) and surfaces as a 404-marked error."""
    last_exc = None
    for attempt in range(1, attempts + 1):
        try:
            req = urllib.request.Request(url, headers=civitai_headers())
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read().decode('utf-8'))
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                raise
            last_exc = exc
        except (urllib.error.URLError, OSError, ValueError) as exc:
            last_exc = exc
        if attempt < attempts:
            time.sleep(0.6 * attempt)
    raise last_exc


def update_civitai_info(models, script_name):
    """Queries the Civitai API for every active civitai entry and fills in
    names, sizes, links and version status. Results are cached per entry so
    re-renders keep the badges without re-fetching."""
    stats = {'latest': 0, 'new': 0, 'unknown': 0, 'missing': 0, 'model': 0}
    for m in models:
        if m['source'] != 'civitai' or not m['active']:
            continue
        try:
            if m['kind'] == 'civitai-version':
                vid = str(m['ids']['versionId'])
                ver = api_get_json(CIVITAI_API + '/model-versions/' + vid)
                model_id = str(ver.get('modelId', ''))
                ver_name = str(ver.get('name', '') or '')
                model_ref = ver.get('model') or {}
                model_name = str(model_ref.get('name', '') or '')
                m['name'] = '{0} - {1}'.format(model_name, ver_name) if model_name else ver_name
                files = ver.get('files') or []
                if files:
                    if files[0].get('sizeKB'):
                        m['fileSizeKB'] = round(float(files[0]['sizeKB']))
                    if files[0].get('name'):
                        m['filename'] = str(files[0]['name'])
                m['modelId'] = model_id
                m['url'] = 'https://civitai.com/models/{0}'.format(model_id)
                time.sleep(0.12)
                model = api_get_json(CIVITAI_API + '/models/' + model_id)
                versions = model.get('modelVersions') or []
                latest = versions[0] if versions else None
                if latest and int(latest['id']) == int(vid):
                    m['versionStatus'] = 'latest'
                    stats['latest'] += 1
                elif latest:
                    m['versionStatus'] = 'new'
                    m['newVersion'] = {
                        'url': 'https://civitai.com/models/{0}?modelVersionId={1}'.format(
                            model_id, latest['id']),
                        'name': str(latest.get('name', '') or ''),
                        'id': str(latest['id']),
                    }
                    stats['new'] += 1
                else:
                    m['versionStatus'] = 'unknown'
                    stats['unknown'] += 1
            elif m['kind'] == 'civitai-model':
                mid = str(m['ids']['modelId'])
                model = api_get_json(CIVITAI_API + '/models/' + mid)
                m['name'] = str(model.get('name', '') or '')
                m['url'] = 'https://civitai.com/models/{0}'.format(mid)
                m['versionStatus'] = '-'
                versions = model.get('modelVersions') or []
                if versions:
                    m['latestVersion'] = str(versions[0].get('name', '') or '')
                stats['model'] += 1
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                m['versionStatus'] = 'missing'
                stats['missing'] += 1
                add_log('Version on line {0} in {1} is gone from Civitai (404).'.format(
                    m['lineStart'], script_name))
            else:
                m['versionStatus'] = 'unknown'
                stats['unknown'] += 1
                add_log('Civitai check failed for line {0} in {1}: {2}'.format(
                    m['lineStart'], script_name, exc))
        except Exception as exc:
            m['versionStatus'] = 'unknown'
            stats['unknown'] += 1
            add_log('Civitai check failed for line {0} in {1}: {2}'.format(
                m['lineStart'], script_name, exc))

        cache_key = '{0}|{1}|{2}{3}'.format(script_name, m['lineStart'],
                                            m['ids'].get('versionId', ''),
                                            m['ids'].get('modelId', ''))
        STATE.civitai_cache[cache_key] = {
            field: m[field] for field in
            ('name', 'fileSizeKB', 'filename', 'modelId', 'url',
             'versionStatus', 'newVersion', 'latestVersion')
            if m.get(field) is not None
        }
    add_log('Version check for {0}: {1} latest, {2} new, {3} unknown, {4} missing, '
            '{5} model info'.format(script_name, stats['latest'], stats['new'],
                                    stats['unknown'], stats['missing'], stats['model']))


def merge_civitai_cache(script_name, models):
    for m in models:
        cache_key = '{0}|{1}|{2}{3}'.format(script_name, m['lineStart'],
                                            m['ids'].get('versionId', ''),
                                            m['ids'].get('modelId', ''))
        cached = STATE.civitai_cache.get(cache_key)
        if cached:
            m.update(cached)


# ---------------------------------------------------------------------------
# URL resolution for the Add flow
# ---------------------------------------------------------------------------
def civitai_url_error():
    return ValueError('Not a Civitai model URL. Expected https://civitai.com/models/<id> '
                      'or ...?modelVersionId=<id>.')


def resolve_civitai_url(url):
    m = RE_CIV_URL.search(url)
    if not m:
        raise civitai_url_error()
    model_id, version_id = m.group(1), m.group(2)
    auto_pinned = False
    if not version_id:
        model = api_get_json(CIVITAI_API + '/models/' + model_id)
        versions = model.get('modelVersions') or []
        if not versions:
            raise ValueError('Civitai model {0} has no versions.'.format(model_id))
        version_id = str(versions[0]['id'])
        auto_pinned = True
    ver = api_get_json(CIVITAI_API + '/model-versions/' + version_id)
    model_ref = ver.get('model') or {}
    model_name = str(model_ref.get('name', '') or '')
    ver_name = str(ver.get('name', '') or '')
    file_name, size_kb = '', None
    files = ver.get('files') or []
    if files:
        chosen = next((f for f in files if f.get('primary')), files[0])
        if chosen.get('name'):
            file_name = str(chosen['name'])
        if chosen.get('sizeKB'):
            size_kb = round(float(chosen['sizeKB']))
    if model_name and ver_name:
        desc = '{0} - {1}'.format(model_name, ver_name)
    else:
        desc = ver_name or model_name
    return {
        'kind': 'civitai', 'modelId': model_id, 'versionId': version_id,
        'modelName': model_name, 'versionName': ver_name, 'fileName': file_name,
        'sizeKB': size_kb, 'description': desc, 'autoPinned': auto_pinned,
        'url': 'https://civitai.com/models/{0}'.format(model_id),
    }


def resolve_hf_url(url):
    clean = re.split(r'[?#]', url)[0].strip()
    m = RE_HF_URL_HTTPS.match(clean) or RE_HF_URL_SCHEME.match(clean)
    if not m:
        raise ValueError('Not a Hugging Face URL. Expected https://huggingface.co/<owner>/<repo>'
                         '[/blob|/resolve/<branch>/<path>] or hf://<owner>/<repo>/<path>.')
    repo = m.group(1) + '/' + m.group(2)
    path = (m.group(3) or '').strip()
    if path:
        path = path.rstrip('/')
        return {'kind': 'hf', 'repo': repo, 'path': path,
                'fileName': os.path.basename(path), 'files': None}
    api = api_get_json('https://huggingface.co/api/models/' + repo)
    files = [str(s['rfilename']) for s in (api.get('siblings') or []) if s.get('rfilename')]
    return {'kind': 'hf', 'repo': repo, 'path': '', 'fileName': '', 'files': files}


def resolve_github_url(url):
    m = RE_GH_URL.search(url)
    if not m:
        raise ValueError('Not a GitHub repository URL. Expected https://github.com/<owner>/<repo>.')
    owner, repo = m.group(1), m.group(2)
    full = 'https://github.com/{0}/{1}'.format(owner, repo)
    return {'kind': 'custom-node', 'url': full, 'repoName': repo, 'owner': owner}


def resolve_model_url(url, hf_file=''):
    if not url or not url.strip():
        raise ValueError('A model URL is required.')
    if re.search(r'civitai\.[a-z]{2,}', url):
        return resolve_civitai_url(url)
    if re.search(r'huggingface\.co', url) or url.startswith('hf://'):
        result = resolve_hf_url(url)
        if not result['path'] and hf_file and hf_file.strip():
            result['path'] = hf_file.strip()
            result['fileName'] = os.path.basename(result['path'])
        return result
    if re.search(r'github\.com', url):
        return resolve_github_url(url)
    raise ValueError('Unrecognized URL. Use a Civitai link (civitai.com, civitai.red, ...), '
                     'a HuggingFace link (huggingface.co / hf://) or a GitHub repo link (github.com).')


# ---------------------------------------------------------------------------
# git (Save to git)
# ---------------------------------------------------------------------------
def run_git(args):
    """Runs git in the scripts folder; stderr is captured as plain lines (git
    writes push progress to stderr, which must never abort the flow)."""
    env = dict(os.environ, GIT_TERMINAL_PROMPT='0')
    proc = subprocess.run(['git', '-C', STATE.scripts_dir] + list(args),
                          capture_output=True, env=env, timeout=180)
    combined = (proc.stdout + proc.stderr).decode('utf-8', 'replace')
    lines = [l.strip() for l in combined.splitlines() if l.strip()]
    return proc.returncode, lines


def git_save(script_name):
    output = []
    code, lines = run_git(['rev-parse', '--is-inside-work-tree'])
    output.extend(lines)
    if code != 0:
        output.append('Not a git repository: ' + STATE.scripts_dir)
        return False, output
    code, lines = run_git(['add', '--', script_name])
    output.extend(lines)
    code, lines = run_git(['commit', '-m', 'Update {0} via model manager UI'.format(script_name)])
    output.extend(lines)
    if code != 0 and any(re.search(r'no changes added to commit|nothing to commit|'
                                   r'nothing added to commit', l) for l in lines):
        output.append('Nothing to commit; skipping push.')
        return True, output
    if code != 0:
        output.append('git commit failed with exit code {0}.'.format(code))
        return False, output
    code, lines = run_git(['push'])
    output.extend(lines)
    if code != 0 and any('no upstream' in l for l in lines):
        output.append('No upstream configured; pushing with --set-upstream origin HEAD.')
        code, lines = run_git(['push', '-u', 'origin', 'HEAD'])
        output.extend(lines)
    if code == 0:
        output.append('Pushed {0}.'.format(script_name))
        return True, output
    output.append('git push failed with exit code {0}.'.format(code))
    return False, output


# ---------------------------------------------------------------------------
# HTTP server
# ---------------------------------------------------------------------------
HTML_TEMPLATE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Model Manager</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root{
    --border:#e3e6ea; --muted:#6b7280; --fg:#1f2328; --bg:#f6f7f9;
    --surface:#ffffff; --accent:#2563eb;
  }
  *{box-sizing:border-box}
  body{margin:0;font:14px/1.45 "Segoe UI",system-ui,sans-serif;color:var(--fg);background:var(--bg)}
  header{display:flex;align-items:center;gap:14px;padding:12px 18px;background:var(--surface);border-bottom:1px solid var(--border)}
  header h1{font-size:17px;margin:0;font-weight:600}
  header .hint{color:var(--muted);font-size:12.5px}
  header select{font:inherit;padding:5px 8px}
  .toolbar{display:flex;gap:10px;align-items:center;padding:10px 18px;border-bottom:1px solid var(--border);background:var(--surface)}
  .btn{font:inherit;padding:6px 14px;border:1px solid var(--border);border-radius:6px;background:var(--surface);cursor:pointer}
  .btn:hover{border-color:#c9ccd1;background:#f2f4f7}
  .btn.primary{background:var(--accent);border-color:var(--accent);color:#fff}
  .btn.primary:hover{background:#1d4ed8}
  .btn:disabled{opacity:.55;cursor:default}
  .btn-xs{font-size:12px;padding:3px 9px;border:1px solid var(--border);border-radius:5px;background:var(--surface);cursor:pointer;color:var(--fg)}
  .btn-xs:hover{border-color:#e05252;color:#c02626;background:#fff5f5}
  .warnings{padding:6px 18px;color:#9a6700;font-size:12.5px;background:#fff8e6;border-bottom:1px solid var(--border)}
  .warnings:empty{display:none}
  main{padding:14px 18px}
  table{width:100%;border-collapse:collapse;background:var(--surface);border:1px solid var(--border);border-radius:8px;font-size:13.5px}
  th{font-weight:600;color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.03em}
  th,td{padding:8px 10px;border-bottom:1px solid var(--border);vertical-align:top;text-align:left}
  #tbl th:nth-child(3){cursor:pointer;user-select:none}
  #tbl th:nth-child(3):hover{background:#f2f4f7}
  tr:last-child td{border-bottom:none}
  tr.off td{opacity:.55}
  td.mono,.mono{font-family:Consolas,"Cascadia Mono",monospace;font-size:12.5px}
  .badge{display:inline-block;padding:2px 8px;border-radius:10px;font-size:11.5px;font-weight:600;white-space:nowrap}
  .b-civ{background:#dbeafe;color:#1d4ed8}
  .b-hf{background:#fef3c7;color:#92400e}
  .b-off{background:#e5e7eb;color:#4b5563;margin-left:6px}
  .b-latest{background:#dcfce7;color:#166534}
  .b-new{background:#ffedd5;color:#c2410c;cursor:pointer;text-decoration:none}
  .b-new:hover{text-decoration:underline}
  .b-unknown{background:#f3f4f6;color:#6b7280}
  .b-missing{background:#fee2e2;color:#b91c1c}
  .b-dash{color:var(--muted)}
  a{color:var(--accent);text-decoration:none}
  a:hover{text-decoration:underline}
  .empty{color:var(--muted);padding:26px;text-align:center}
  #menuView{padding:10px 0}
  .script-card{display:inline-block;width:220px;margin:8px;padding:14px 16px;background:var(--surface);border:1px solid var(--border);border-radius:8px;cursor:pointer;vertical-align:top;transition:box-shadow .12s}
  .script-card:hover{border-color:var(--accent);box-shadow:0 2px 8px rgba(0,0,0,.08)}
  .script-card .sc-name{font-weight:600;font-size:14px}
  .script-card .sc-hint{color:var(--muted);font-size:12px;margin-top:4px}
  .ssh-ok{color:#16a34a;font-weight:600;font-size:14px}
  .ssh-miss{color:#dc2626;font-weight:600;font-size:14px}
  .ssh-unk{color:var(--muted);font-size:12px}
  details.log{margin:10px 18px 20px;color:var(--muted);font-size:12px}
  details.log pre{white-space:pre-wrap;margin:6px 0 0;max-height:180px;overflow:auto;font-family:Consolas,monospace}
  .modal{position:fixed;inset:0;background:rgba(15,18,22,.45);display:flex;align-items:center;justify-content:center;z-index:10}
  .modal.hidden{display:none}
  .modal-card{background:var(--surface);border-radius:10px;padding:18px 20px;width:520px;max-width:94vw;max-height:90vh;overflow:auto;box-shadow:0 12px 40px rgba(0,0,0,.18)}
  .modal-card h3{margin:0 0 12px;font-size:15px}
  .hint-text{color:var(--muted);font-size:12px;word-break:break-all;margin:0 0 6px}
  .modal-card label{display:block;margin:10px 0 4px;font-size:12.5px;color:var(--muted)}
  .modal-card input,.modal-card select{width:100%;font:inherit;padding:6px 8px;border:1px solid var(--border);border-radius:6px}
  .preview{margin:12px 0;padding:10px 12px;background:var(--bg);border:1px solid var(--border);border-radius:8px;font-size:13px}
  .preview:empty{display:none}
  .preview .pv-line{margin:2px 0}
  .preview .pv-label{color:var(--muted);font-size:11.5px;text-transform:uppercase;letter-spacing:.03em}
  .modal-actions{display:flex;gap:10px;justify-content:flex-end;margin-top:16px}
  .err{color:#c02626;font-size:12.5px;margin:10px 0 0}
</style>
</head>
<body>
<header>
  <h1>Model Manager</h1>
  <span class="hint" id="hint">loading…</span>
  <button class="btn" id="btnBack" style="display:none">← Scripts</button>
  <button class="btn" id="btnFolder" style="margin-left:auto">Folder/SSH</button>
</header>
<div class="toolbar">
  <button class="btn" id="btnCheck">Check new versions</button>
  <button class="btn" id="btnAdd">Add model</button>
  <button class="btn" id="btnSshCheck" title="Check which files exist on the server via SSH">SSH check</button>
  <button class="btn" id="btnSshInstall" title="Upload and run the script on the server to install missing files">Install missing</button>
  <button class="btn" id="btnSave" style="margin-left:auto">Save to git</button>
</div>
<div class="warnings" id="warnings"></div>
<main>
<div id="menuView" style="display:none">
  <div id="scriptList"></div>
</div>
<table id="tbl">
  <thead><tr><th>Source</th><th>Model / description</th><th>Target dir</th><th>On server</th><th>Version</th><th>Link</th><th></th></tr></thead>
  <tbody id="tbody"></tbody>
</table>
</main>
<details class="log"><summary>Server log</summary><pre id="log"></pre></details>

<div class="modal hidden" id="modal">
  <div class="modal-card">
    <h3>Add model to <span id="addScript"></span></h3>
    <label>Source URL (Civitai or HuggingFace)</label>
    <input id="addUrl" placeholder="https://civitai.com/models/…  |  https://huggingface.co/…  |  hf://…">
    <button class="btn" id="btnResolve">Resolve</button>
    <div class="preview" id="resolveOut"></div>
    <label>Target dir</label>
    <input id="addDir" list="dirList" placeholder="./models/loras">
    <datalist id="dirList"></datalist>
    <div id="fileWrap" style="display:none">
      <label>File in repo</label>
      <select id="addFile"></select>
    </div>
    <label>Description</label>
    <input id="addDesc" placeholder="optional comment stored on the line">
    <div class="modal-actions">
      <button class="btn" id="btnCancel">Cancel</button>
      <button class="btn primary" id="btnInsert">Insert</button>
    </div>
    <p class="err" id="addError"></p>
  </div>
</div>

<div class="modal hidden" id="dirModal">
  <div class="modal-card">
    <h3>Scripts folder</h3>
    <p class="hint-text" id="curDir"></p>
    <label>Folder containing your *.sh provision scripts</label>
    <input id="newDir" placeholder="E:\path\to\your\provision-scripts">
    <label>SSH host / extra args (for server sync)</label>
    <input id="newSshHost" placeholder="root@host -p 22037 -L 8080:localhost:8080">
    <label>Remote workspace path (ComfyUI folder on server)</label>
    <input id="newRemoteDir" placeholder="/workspace/ComfyUI">
    <div class="modal-actions">
      <button class="btn" id="btnDirCancel">Cancel</button>
      <button class="btn primary" id="btnDirSave">Save</button>
    </div>
    <p class="err" id="dirError"></p>
  </div>
</div>

<script>
'use strict';
const TOKEN = '__TOKEN__';
const $ = s => document.querySelector(s);
let models = [];
let warnings = [];
let currentScript = null;
let resolveResult = null;
let chosenFile = null;
let scriptsDir = '';
let sshHost = '';
let remoteDir = '/workspace/ComfyUI';

function esc(s){
  let t = String(s == null ? '' : s);
  t = t.split('&').join('&' + 'amp;');
  t = t.split('<').join('&' + 'lt;');
  t = t.split('>').join('&' + 'gt;');
  t = t.split('"').join('&' + 'quot;');
  t = t.split("'").join('&#39;');
  return t;
}

async function api(path, opts = {}){
  const init = {
    method: opts.method || 'GET',
    headers: {'X-Auth': TOKEN}
  };
  if (opts.body){
    init.headers['Content-Type'] = 'application/json';
    init.body = JSON.stringify(opts.body);
  }
  const res = await fetch(path, init);
  let data = {};
  try { data = await res.json(); } catch (e) {}
  if (!res.ok || data.error) throw new Error(data.error || ('HTTP ' + res.status));
  return data;
}

function fmtSize(kb){
  if (kb == null) return '';
  const mb = kb / 1024;
  return (mb >= 10 ? mb.toFixed(0) : mb.toFixed(1)) + ' MB';
}

function entryTitle(m){
  if (m.source === 'civitai'){
    if (m.name) return m.name;
    if (m.kind === 'civitai-model') return 'civitai model ' + ((m.ids && m.ids.modelId) || '');
    return 'civitai version ' + ((m.ids && m.ids.versionId) || '');
  }
  return m.description || m.filename || (m.repo ? m.repo + (m.path ? '/' + m.path : '') : '');
}

function badge(cls, text, href){
  const inner = esc(text);
  return href
    ? '<a class="badge ' + cls + '" href="' + esc(href) + '" target="_blank" rel="noopener">' + inner + '</a>'
    : '<span class="badge ' + cls + '">' + inner + '</span>';
}

function sshStatusIcon(m){
  if (!sshHost) return '';
  const st = m.sshStatus;
  if (st === 'present') return '<span class="ssh-ok">✓</span>';
  if (st === 'missing') return '<span class="ssh-miss">✗</span>';
  if (st === 'skip') return '<span class="ssh-unk" title="No filename to match">–</span>';
  return '<span class="ssh-unk">—</span>';
}

function versionCell(m){
  if (m.source !== 'civitai' || !m.active) return '<span class="b-dash">—</span>';
  if (m.kind === 'civitai-model'){
    return m.latestVersion
      ? '<span class="mono" style="font-size:12px">latest: ' + esc(m.latestVersion) + '</span>'
      : '<span class="b-dash">—</span>';
  }
  switch (m.versionStatus){
    case 'latest': return badge('b-latest', 'latest');
    case 'new':    return badge('b-new', 'new: ' + (m.newVersion && m.newVersion.name || ''), m.newVersion && m.newVersion.url);
    case 'missing':return badge('b-missing', 'missing');
    case 'unknown':return badge('b-unknown', 'unknown');
    default:       return '<span class="b-dash">—</span>';
  }
}

let sortMode = 'dir';

function sortedModels(){
  const arr = models.slice();
  if (sortMode === 'dir'){
    arr.sort((a, b) => {
      const da = (a.dir || '').toLowerCase(), db = (b.dir || '').toLowerCase();
      if (da !== db) return da < db ? -1 : 1;
      return a.lineStart - b.lineStart;
    });
  }
  return arr;
}

function showScriptsMenu(scripts){
  const main = document.querySelector('main');
  const tbl = document.getElementById('tbl');
  tbl.style.display = 'none';
  document.getElementById('menuView').style.display = 'block';
  const list = document.getElementById('scriptList');
  list.innerHTML = scripts.map(s =>
    '<div class="script-card" data-script="' + esc(s) + '">' +
      '<div class="sc-name">' + esc(s) + '</div>' +
      '<div class="sc-hint">click to manage models</div>' +
    '</div>'
  ).join('');
  document.getElementById('tbl').style.display = 'none';
  document.querySelector('.toolbar').style.display = 'none';
  document.getElementById('hint').textContent = 'Select a script to manage';
}

function enterScript(script){
  document.getElementById('menuView').style.display = 'none';
  document.getElementById('tbl').style.display = '';
  document.querySelector('.toolbar').style.display = '';
  document.getElementById('btnBack').style.display = '';
  currentScript = script;
  loadModels(script).catch(showErr);
  $('#btnCheck').click();   // auto version check when entering a script
}

function render(){
  const tbody = $('#tbody');
  if (!models.length){
    tbody.innerHTML = '<tr><td colspan="7"><div class="empty">No model download calls found in this script.</div></td></tr>';
  } else {
    tbody.innerHTML = sortedModels().map(m => {
      const src = m.source === 'civitai' ? badge('b-civ','Civitai') : badge('b-hf','HF');
      const off = m.active ? '' : badge('b-off','off');
      let line1 = esc(entryTitle(m));
      let line2 = '';
      if (m.source === 'civitai'){
        if (m.description && m.name) line2 = '<div style="color:var(--muted);font-size:12px">' + esc(m.description) + '</div>';
      } else {
        line2 = '<div class="mono" style="color:var(--muted);font-size:12px">' + esc((m.repo || '') + (m.path ? '/' + m.path : '')) + '</div>';
      }
      const link = m.url
        ? '<a href="' + esc(m.url) + '" target="_blank" rel="noopener">↗</a>'
        : '';
      const toggle = '<button class="btn-xs" data-action="toggle" data-ls="' + m.lineStart + '" data-le="' + m.lineEnd + '">' + (m.active ? 'Disable' : 'Enable') + '</button>';
      const del = '<button class="btn-xs" data-action="delete" data-ls="' + m.lineStart + '" data-le="' + m.lineEnd + '" style="margin-left:6px">Delete</button>';
      return '<tr' + (m.active ? '' : ' class="off"') + '>'
        + '<td>' + src + off + '</td>'
        + '<td><div>' + line1 + '</div>' + line2 + '</td>'
        + '<td class="mono dir-cell" data-ls="' + m.lineStart + '" data-le="' + m.lineEnd + '" title="Click to edit target dir" style="cursor:pointer;text-decoration:underline dotted transparent;text-underline-offset:3px">' + esc(m.dir || '') + '</td>'
        + '<td style="text-align:center">' + sshStatusIcon(m) + '</td>'
        + '<td>' + versionCell(m) + '</td>'
        + '<td>' + link + '</td>'
        + '<td style="white-space:nowrap">' + toggle + del + '</td>'
        + '</tr>';
    }).join('');
  }
  fillDirDatalist();
  $('#warnings').innerHTML = warnings.map(w => '⚠ line ' + w.line + ': ' + esc(w.reason)).join('<br>');
  $('#hint').textContent = currentScript
    ? (models.length + ' model entr' + (models.length === 1 ? 'y' : 'ies') + (warnings.length ? ' · ' + warnings.length + ' parse warning' + (warnings.length === 1 ? '' : 's') : ''))
    : 'no script loaded';
}

function fillDirDatalist(){
  const dirs = [...new Set(models.map(m => m.dir).filter(Boolean))];
  $('#dirList').innerHTML = dirs.map(d => '<option value="' + esc(d) + '">').join('');
}

function startDirEdit(cell){
  const ls = +cell.dataset.ls, le = +cell.dataset.le;
  const m = models.find(x => x.lineStart === ls && x.lineEnd === le);
  if (!m || cell.querySelector('input')) return;
  const input = document.createElement('input');
  input.className = 'dir-edit';
  input.setAttribute('list', 'dirList');
  input.value = m.dir || '';
  input.style.width = '100%';
  input.style.font = 'inherit';
  input.style.padding = '2px 4px';
  cell.textContent = '';
  cell.appendChild(input);
  input.focus();
  input.select();
  const commit = async () => {
    const dir = input.value.trim();
    restoreCell(cell, m);
    if (!dir || dir === (m.dir || '')) return;
    try {
      const r = await api('/api/movedir', {method:'POST', body:{script: currentScript, lineStart: ls, lineEnd: le, dir: dir}});
      models = r.models || [];
      render();
    } catch (e){ showErr(e); render(); }
  };
  input.addEventListener('keydown', ev => {
    if (ev.key === 'Enter') { ev.preventDefault(); input.blur(); }
    if (ev.key === 'Escape') { ev.preventDefault(); input.value = m.dir || ''; input.blur(); }
  });
  input.addEventListener('blur', commit);
}

function restoreCell(cell, m){
  cell.textContent = m.dir || '';
}

async function loadModels(script){
  currentScript = script;
  const r = await api('/api/models?script=' + encodeURIComponent(script));
  models = r.models || [];
  warnings = r.parseWarnings || [];
  render();
}

async function init(){
  let S;
  try { S = await api('/api/state'); }
  catch (e){
    // keep the page skeleton intact so the Folder button can recover the UI
    // without a reload
    $('#hint').textContent = 'server unavailable: ' + e.message;
    return;
  }
  scriptsDir = S.scriptsDir || '';
  sshHost = S.sshHost || '';
  remoteDir = S.remoteDir || '/workspace/ComfyUI';
  $('#btnFolder').title = scriptsDir || 'Set the scripts folder';
  $('#log').textContent = S.logText || '';
  if (!(S.scripts || []).length){
    $('#hint').textContent = S.dirError
      ? 'scripts folder problem: ' + S.dirError
      : 'no *.sh scripts found in ' + 'the scripts folder';
    return;
  }
  // show scripts menu — user clicks a card to enter a script
  showScriptsMenu(S.scripts);
}



document.querySelector('#tbl th:nth-child(3)').addEventListener('click', () => {
  sortMode = (sortMode === 'dir') ? 'file' : 'dir';
  render();
});

$('#btnBack').addEventListener('click', () => {
  document.getElementById('menuView').style.display = '';
  document.getElementById('tbl').style.display = 'none';
  document.querySelector('.toolbar').style.display = 'none';
  document.getElementById('btnBack').style.display = 'none';
  $('#hint').textContent = 'Select a script to manage';
});

document.getElementById('scriptList').addEventListener('click', ev => {
  const card = ev.target.closest('.script-card');
  if (!card) return;
  enterScript(card.dataset.script);
});

$('#btnFolder').addEventListener('click', () => {
  $('#curDir').textContent = scriptsDir ? 'Current: ' + scriptsDir : 'No folder configured.';
  if ($('#newDir')) $('#newDir').value = scriptsDir || '';
  if ($('#newSshHost')) $('#newSshHost').value = sshHost || '';
  if ($('#newRemoteDir')) $('#newRemoteDir').value = remoteDir || '';
  $('#dirError').textContent = '';
  $('#dirModal').classList.remove('hidden');
  if ($('#newDir')) $('#newDir').focus();
});
$('#btnDirCancel').addEventListener('click', () => $('#dirModal').classList.add('hidden'));

$('#btnDirSave').addEventListener('click', async () => {
  const dir = $('#newDir').value.trim();
  const newSsh = $('#newSshHost').value.trim();
  const newRemote = $('#newRemoteDir').value.trim();
  $('#dirError').textContent = '';
  if (!dir){ $('#dirError').textContent = 'Enter a folder path.'; return; }
  try {
    const r = await api('/api/set-dir', {method:'POST', body:{dir: dir}});
    scriptsDir = r.scriptsDir || dir;
    $('#btnFolder').title = scriptsDir;
    // save SSH host + remote dir together
    const sr = await api('/api/ssh-save', {method:'POST', body:{sshHost: newSsh, remoteDir: newRemote}});
    sshHost = sr.sshHost || newSsh;
    remoteDir = sr.remoteDir || newRemote;
    $('#dirModal').classList.add('hidden');
    if (r.logText) $('#log').textContent = r.logText;
    if ((r.scripts || []).length){
      const prevScript = currentScript;
      currentScript = null;
      const toLoad = (r.scripts || []).includes(prevScript) ? prevScript : r.scripts[0];
      await loadModels(toLoad).catch(showErr);
    } else {
      models = []; warnings = []; render();
      $('#hint').textContent = 'no *.sh scripts in ' + scriptsDir;
    }
  } catch (e){
    $('#dirError').textContent = e.message;
    // also log to the server log panel
    if (typeof api === 'function'){
      try {
        const errLog = await fetch('/api/error-log', { method:'POST', headers:{'Content-Type':'application/json','X-Auth': TOKEN}, body: JSON.stringify({msg: e.message}) }).then(r=>r.json());
        if (errLog.logText) $('#log').textContent = errLog.logText;
      } catch(_){}
    }
  }
});

function showErr(e){
  $('#hint').textContent = 'error: ' + e.message;
  $('#log').textContent += (($('#log').textContent ? '\n' : '') + e.message);
  // also log to server
  fetch('/api/error-log', { method:'POST', headers:{'Content-Type':'application/json','X-Auth': TOKEN}, body: JSON.stringify({msg: e.message}) }).then(r=>r.json()).then(d => {
    if (d.logText) $('#log').textContent = d.logText;
  }).catch(()=>{});
}

$('#btnCheck').addEventListener('click', async () => {
  if (!currentScript) return;
  const btn = $('#btnCheck');
  btn.disabled = true; const old = btn.textContent; btn.textContent = 'Checking…';
  try {
    const r = await api('/api/check-versions', {method:'POST', body:{script: currentScript}});
    models = r.models || [];
    render();
    if (r.logText) $('#log').textContent = r.logText;
    $('#hint').textContent = 'version check done';
  } catch (e){ showErr(e); }
  btn.disabled = false; btn.textContent = old;
});

$('#tbody').addEventListener('click', async ev => {
  const dirCell = ev.target.closest('td.dir-cell');
  if (dirCell){ startDirEdit(dirCell); return; }
  const btn = ev.target.closest('button.btn-xs');
  if (!btn) return;
  const ls = +btn.dataset.ls, le = +btn.dataset.le;
  const m = models.find(x => x.lineStart === ls && x.lineEnd === le);
  if (btn.dataset.action === 'toggle'){
    try {
      const r = await api('/api/toggle', {method:'POST', body:{script: currentScript, lineStart: ls, lineEnd: le}});
      models = r.models || [];
      render();
    } catch (e){ showErr(e); }
    return;
  }
  const name = m ? entryTitle(m) : ('lines ' + ls + '-' + le);
  if (!confirm('Confirm delete ' + name + ' from ' + currentScript + '?')) return;
  try {
    const r = await api('/api/delete', {method:'POST', body:{script: currentScript, lineStart: ls, lineEnd: le}});
    models = r.models || [];
    render();
  } catch (e){ showErr(e); }
});

$('#btnSshCheck').addEventListener('click', async () => {
  if (!currentScript) return;
  const btn = $('#btnSshCheck');
  btn.disabled = true; const old = btn.textContent; btn.textContent = 'Checking…';
  try {
    const r = await api('/api/ssh-check', {method:'POST', body:{script: currentScript}});
    models = r.models || [];
    render();
    const ok = models.filter(m => m.sshStatus === 'present').length;
    const miss = models.filter(m => m.sshStatus === 'missing').length;
    $('#hint').textContent = 'SSH check — ✓ ' + ok + ' present, ✗ ' + miss + ' missing';
  } catch (e){ showErr(e); }
  btn.disabled = false; btn.textContent = old;
});

$('#btnSshInstall').addEventListener('click', async () => {
  if (!currentScript) return;
  if (!confirm('Upload and run the script on the SSH server to install missing models? This may take a while.')) return;
  const btn = $('#btnSshInstall');
  btn.disabled = true; const old = btn.textContent; btn.textContent = 'Installing…';
  try {
    const r = await api('/api/ssh-install', {method:'POST', body:{script: currentScript}});
    document.querySelector('details.log').open = true;
    if (r.logText) $('#log').textContent = r.logText;
    // re-check after install
    const r2 = await api('/api/ssh-check', {method:'POST', body:{script: currentScript}});
    models = r2.models || [];
    render();
    $('#hint').textContent = r.ok ? 'Install completed' : 'Install had errors — see log';
  } catch (e){ showErr(e); }
  btn.disabled = false; btn.textContent = old;
});

$('#btnSave').addEventListener('click', async () => {
  if (!currentScript) return;
  const btn = $('#btnSave');
  btn.disabled = true; const old = btn.textContent; btn.textContent = 'Saving…';
  try {
    const r = await api('/api/save', {method:'POST', body:{script: currentScript}});
    document.querySelector('details.log').open = true;
    if (r.logText) $('#log').textContent = r.logText;
    $('#hint').textContent = r.ok ? 'saved to git' : 'git save failed — see server log';
  } catch (e){ showErr(e); }
  btn.disabled = false; btn.textContent = old;
});

function openAdd(){
  resolveResult = null; chosenFile = null;
  $('#addUrl').value = ''; $('#addDir').value = ''; $('#addDesc').value = '';
  $('#resolveOut').innerHTML = ''; $('#addError').textContent = '';
  $('#fileWrap').style.display = 'none';
  $('#addScript').textContent = currentScript || '';
  fillDirDatalist();
  $('#modal').classList.remove('hidden');
  $('#addUrl').focus();
}
$('#btnAdd').addEventListener('click', openAdd);
$('#btnCancel').addEventListener('click', () => $('#modal').classList.add('hidden'));

$('#btnResolve').addEventListener('click', async () => {
  const url = $('#addUrl').value.trim();
  $('#addError').textContent = '';
  if (!url){ $('#addError').textContent = 'Paste a Civitai or HuggingFace URL first.'; return; }
  const btn = $('#btnResolve');
  btn.disabled = true;
  try {
    const r = await api('/api/resolve', {method:'POST', body:{url: url}});
    resolveResult = r.result;
    chosenFile = resolveResult.path || null;
    let html = '';
    if (resolveResult.kind === 'civitai'){
      html += '<div class="pv-line"><span class="pv-label">Civitai model</span><br>' + esc(resolveResult.modelName || resolveResult.modelId) + '</div>';
      html += '<div class="pv-line"><span class="pv-label">Version</span><br>' + esc(resolveResult.versionName || resolveResult.versionId)
        + (resolveResult.autoPinned ? ' <span class="badge b-unknown">auto: newest</span>' : '') + '</div>';
      if (resolveResult.fileName){
        html += '<div class="pv-line"><span class="pv-label">File</span><br><span class="mono">' + esc(resolveResult.fileName) + '</span>'
          + (resolveResult.sizeKB ? ' · ' + fmtSize(resolveResult.sizeKB) : '') + '</div>';
      }
    } else {
      html += '<div class="pv-line"><span class="pv-label">HF repo</span><br><span class="mono">' + esc(resolveResult.repo) + '</span></div>';
      if (resolveResult.path){
        html += '<div class="pv-line"><span class="pv-label">File</span><br><span class="mono">' + esc(resolveResult.path) + '</span></div>';
        $('#fileWrap').style.display = 'none';
      } else if (resolveResult.files && resolveResult.files.length){
        const saf = resolveResult.files.find(f => /\.safetensors$/i.test(f));
        chosenFile = saf || resolveResult.files[0];
        $('#addFile').innerHTML = resolveResult.files.map(f =>
          '<option value="' + esc(f) + '"' + (f === chosenFile ? ' selected' : '') + '>' + esc(f) + '</option>').join('');
        $('#fileWrap').style.display = '';
      } else {
        $('#addError').textContent = 'Repo has no file list; paste a URL that includes the file path.';
      }
    }
    $('#resolveOut').innerHTML = html;
    if (resolveResult.description && !$('#addDesc').value) $('#addDesc').value = resolveResult.description;
  } catch (e){
    resolveResult = null; chosenFile = null;
    $('#resolveOut').innerHTML = '';
    $('#addError').textContent = e.message;
  }
  btn.disabled = false;
});

$('#addFile').addEventListener('change', () => { chosenFile = $('#addFile').value; });

$('#btnInsert').addEventListener('click', async () => {
  const dir = $('#addDir').value.trim();
  const desc = $('#addDesc').value.trim();
  $('#addError').textContent = '';
  if (!resolveResult){ $('#addError').textContent = 'Resolve the URL first.'; return; }
  if (!dir){ $('#addError').textContent = 'Target dir is required.'; return; }
  if (resolveResult.kind === 'hf' && !chosenFile){ $('#addError').textContent = 'Pick a file in the repo.'; return; }
  const btn = $('#btnInsert');
  btn.disabled = true;
  try {
    const r = await api('/api/add', {
      method:'POST',
      body:{ script: currentScript, url: $('#addUrl').value.trim(), dir: dir, file: chosenFile || '', description: desc }
    });
    $('#modal').classList.add('hidden');
    models = r.models || [];
    render();
    $('#hint').textContent = 'added ' + entryTitle(r.entry || {});
  } catch (e){ $('#addError').textContent = e.message; }
  btn.disabled = false;
});

init();
</script>
</body>
</html>"""


class Handler(BaseHTTPRequestHandler):
    server_version = 'ModelManager/2'
    protocol_version = 'HTTP/1.1'

    def log_message(self, fmt, *args):
        pass  # route handlers log meaningful events themselves

    def do_GET(self):
        self._handle('GET')

    def do_POST(self):
        self._handle('POST')

    def _send_bytes(self, body, content_type, status=200):
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_json(self, obj, status=200):
        body = json.dumps(obj, ensure_ascii=False).encode('utf-8')
        self._send_bytes(body, 'application/json; charset=utf-8', status)

    def send_html(self, html):
        self._send_bytes(html.encode('utf-8'), 'text/html; charset=utf-8')

    def read_json_body(self):
        length = int(self.headers.get('Content-Length') or 0)
        if length <= 0:
            return {}
        raw = self.rfile.read(length).decode('utf-8')
        if not raw.strip():
            return {}
        return json.loads(raw)

    def _handle(self, method):
        from urllib.parse import urlsplit, parse_qs
        parts = urlsplit(self.path)
        path = parts.path
        try:
            if path == '/' and method == 'GET':
                self.send_html(HTML_TEMPLATE.replace('__TOKEN__', STATE.token))
                return
            if not path.startswith('/api/'):
                self.send_json({'error': 'Not found'}, 404)
                return
            origin = self.headers.get('Origin')
            expected = 'http://localhost:{0}'.format(self.server.server_address[1])
            if origin and origin != expected:
                self.send_json({'error': 'Cross-origin requests are not allowed.'}, 403)
                return
            if self.headers.get('X-Auth') != STATE.token:
                self.send_json({'error': 'Unauthorized UI request.'}, 403)
                return
            body = self.read_json_body() if method == 'POST' else {}
            query = {k: v[0] for k, v in parse_qs(parts.query).items()}

            with STATE.lock:
                result = self._route(method, path, body, query)
            self.send_json(result)
        except Exception as exc:  # noqa: BLE001 - surfaced to the UI
            try:
                self.send_json({'error': str(exc), 'logText': log_tail_text()}, 500)
            except OSError:
                pass

    def _route(self, method, path, body, query):
        if method == 'GET' and path == '/api/state':
            scripts, dir_error = list_scripts(STATE.scripts_dir)
            return {'scripts': scripts, 'current': None,
                    'scriptsDir': STATE.scripts_dir,
                    'sshHost': get_saved_ssh_host(),
                    'remoteDir': get_saved_remote_dir(),
                    'dirError': dir_error,
                    'logText': log_tail_text()}

        if method == 'POST' and path == '/api/set-dir':
            directory = str(body.get('dir', '')).strip()
            if not directory:
                raise ValueError('A folder path is required.')
            full = os.path.abspath(directory)
            if not os.path.isdir(full):
                raise ValueError('Folder not found: {0}'.format(full))
            scripts, list_error = list_scripts(full)
            if list_error:
                raise ValueError('Cannot list scripts in {0}: {1}'.format(full, list_error))
            old_ssh = get_saved_ssh_host()
            save_settings(scripts_dir=full, ssh_host=old_ssh)
            STATE.scripts_dir = full
            STATE.civitai_cache = {}
            STATE.backed_up = set()
            add_log('Scripts folder set to {0} ({1} script{2} found)'.format(
                full, len(scripts), '' if len(scripts) == 1 else 's'))
            return {'ok': True, 'scripts': scripts, 'scriptsDir': full,
                    'logText': log_tail_text()}

        if method == 'POST' and path == '/api/error-log':
            msg = str(body.get('msg', '') or '')
            if msg:
                add_log('CLIENT ERROR: {0}'.format(msg))
            return {'logText': log_tail_text()}

        if method == 'POST' and path == '/api/ssh-save':
            host = str(body.get('sshHost', '') or '').strip()
            remote = str(body.get('remoteDir', '') or '').strip()
            old_dir = get_saved_scripts_dir()
            save_settings(scripts_dir=old_dir, ssh_host=host, remote_dir=remote)
            add_log("SSH: host='{0}' remote='{1}'".format(host, remote))
            return {'ok': True, 'sshHost': host, 'remoteDir': remote or get_saved_remote_dir(), 'logText': log_tail_text()}

        if method == 'POST' and path == '/api/ssh-check':
            name = str(body.get('script', ''))
            path_full = resolve_script_path(name)
            models, _ = parse_script(path_full)
            ssh_host = get_saved_ssh_host()
            if not ssh_host:
                raise ValueError('No SSH host configured. Set it in the Folder settings.')
            dirs = sorted(set(m['dir'] for m in models if m['active']))
            remote_dir = get_saved_remote_dir()
            add_log('SSH check on {0} for {1} dirs (remote: {2})'.format(ssh_host, len(dirs), remote_dir))
            ssh_args = ssh_host.split()
            remote_files = {}
            for d in dirs:
                ls_cmd = "cd '{0}' && ls -1 '{1}' 2>/dev/null || echo __DIR_NOT_FOUND__".format(remote_dir, d)
                full_cmd = (['ssh', '-o', 'StrictHostKeyChecking=no', '-o', 'ConnectTimeout=10']
                            + ssh_args + [ls_cmd])
                add_log('SSH: $ ' + ' '.join(full_cmd))
                try:
                    proc = subprocess.run(full_cmd, capture_output=True, timeout=60)
                    out = proc.stdout.decode('utf-8', 'replace')
                    err = proc.stderr.decode('utf-8', 'replace')
                    if proc.returncode != 0:
                        add_log('SSH: → exit code {0}'.format(proc.returncode))
                        if err.strip():
                            add_log('SSH: → stderr: ' + err.strip()[:200])
                        if out.strip():
                            add_log('SSH: → stdout: ' + out.strip()[:200])
                        remote_files[d] = None
                        continue
                    if err.strip():
                        add_log('SSH: → stderr: ' + err.strip()[:200])
                    lines = [l.strip() for l in out.splitlines()
                             if l.strip() and l.strip() != '__DIR_NOT_FOUND__']
                    remote_files[d] = lines
                    add_log('SSH: → {0} files'.format(len(lines)))
                except Exception as exc:
                    add_log('SSH: → EXCEPTION: {0}'.format(str(exc)[:200]))
                    remote_files[d] = None
            for m in models:
                if not m['active'] or m['kind'] == 'custom-node':
                    m['sshStatus'] = 'skip'
                    continue
                fn = os.path.basename(m.get('filename') or '')
                if not fn:
                    m['sshStatus'] = 'skip'
                    continue
                if m['dir'] not in remote_files or remote_files[m['dir']] is None:
                    m['sshStatus'] = 'unknown'
                    continue
                found = fn in remote_files[m['dir']]
                if not found and len(remote_files[m['dir']]) < 20:
                    add_log('SSH:  "{0}" NOT in {1}'.format(fn, remote_files[m['dir']]))
                m['sshStatus'] = 'present' if found else 'missing'
            return {'models': models, 'sshHost': ssh_host}

        if method == 'POST' and path == '/api/ssh-install':
            name = str(body.get('script', ''))
            path_full = resolve_script_path(name)
            ssh_host = get_saved_ssh_host()
            if not ssh_host:
                raise ValueError('No SSH host configured. Set it in the Folder settings.')
            remote_dir = get_saved_remote_dir()
            output = []
            file_name = os.path.basename(name)
            ssh_args = ssh_host.split()
            # Upload script via SSH pipe (works with any SSH flags, unlike scp)
            add_log('SSH: upload {0} to {1}:run_{2} via ssh pipe'.format(file_name, ssh_host, file_name))
            with open(path_full, 'r', encoding='utf-8', newline='') as fh:
                script_content = fh.read()
            upload_proc = subprocess.run(
                ['ssh', '-o', 'StrictHostKeyChecking=no', '-o', 'ConnectTimeout=15'] + ssh_args
                + ['cat > "{0}/run_{1}"'.format(remote_dir, file_name)],
                input=script_content.encode('utf-8'), capture_output=True, timeout=120)
            out_lines = [l.strip() for l in (upload_proc.stdout + upload_proc.stderr).decode('utf-8', 'replace').splitlines() if l.strip()]
            output.extend(out_lines)
            for l in out_lines:
                add_log('SSH: ' + l)
            if upload_proc.returncode != 0:
                err_text = (upload_proc.stderr + upload_proc.stdout).decode('utf-8', 'replace')[:500]
                raise ValueError('Upload via SSH failed.\n{0}'.format(err_text))
            add_log('SSH: bash run_{0} on {1} in {2}'.format(file_name, ssh_host, remote_dir))
            run_proc = subprocess.run(
                ['ssh', '-o', 'StrictHostKeyChecking=no', '-o', 'ConnectTimeout=15'] + ssh_args
                + ["cd '{0}' && bash 'run_{1}'".format(remote_dir, file_name)],
                capture_output=True, timeout=600)
            out_lines2 = [l.strip() for l in (run_proc.stdout + run_proc.stderr).decode('utf-8', 'replace').splitlines() if l.strip()]
            output.extend(out_lines2)
            for l in out_lines2:
                add_log('SSH: ' + l)
            add_log('SSH install completed for {0} on {1}'.format(name, ssh_host))
            return {'ok': True, 'output': output, 'logText': log_tail_text()}

        if method == 'GET' and path == '/api/models':
            name = query.get('script', '')
            path_full = resolve_script_path(name)
            models, warnings = parse_script(path_full)
            merge_civitai_cache(name, models)
            return {'models': models, 'parseWarnings': warnings}

        if method == 'POST' and path == '/api/check-versions':
            name = str(body.get('script', ''))
            path_full = resolve_script_path(name)
            models, _ = parse_script(path_full)
            update_civitai_info(models, name)
            return {'models': models, 'logText': log_tail_text()}

        if method == 'POST' and path == '/api/delete':
            name = str(body.get('script', ''))
            path_full = resolve_script_path(name)
            remove_entry_lines(path_full, int(body['lineStart']), int(body['lineEnd']))
            STATE.civitai_cache = {k: v for k, v in STATE.civitai_cache.items()
                                   if not k.startswith(name + '|')}
            models, _ = parse_script(path_full)
            add_log('Deleted lines {0}-{1} from {2}'.format(body['lineStart'],
                                                            body['lineEnd'], name))
            return {'ok': True, 'models': models}

        if method == 'POST' and path == '/api/toggle':
            name = str(body.get('script', ''))
            path_full = resolve_script_path(name)
            new_active = toggle_entry_active(path_full, int(body['lineStart']),
                                             int(body['lineEnd']))
            models, _ = parse_script(path_full)
            merge_civitai_cache(name, models)
            add_log('Toggled entry at lines {0}-{1} in {2} to {3}'.format(
                body['lineStart'], body['lineEnd'], name,
                'active' if new_active else 'inactive'))
            return {'ok': True, 'active': new_active, 'models': models}

        if method == 'POST' and path == '/api/movedir':
            name = str(body.get('script', ''))
            path_full = resolve_script_path(name)
            set_entry_dir(path_full, int(body['lineStart']), int(body['lineEnd']),
                          str(body.get('dir', '')))
            models, _ = parse_script(path_full)
            merge_civitai_cache(name, models)
            add_log("Changed target dir of lines {0}-{1} in {2} to '{3}'".format(
                body['lineStart'], body['lineEnd'], name, body.get('dir', '')))
            return {'ok': True, 'models': models}

        if method == 'POST' and path == '/api/resolve':
            return {'ok': True,
                    'result': resolve_model_url(str(body.get('url', '')), '')}

        if method == 'POST' and path == '/api/add':
            name = str(body.get('script', ''))
            path_full = resolve_script_path(name)
            url = str(body.get('url', ''))
            directory = str(body.get('dir', '')).strip()
            desc = str(body.get('description', '')).strip()
            hf_file = str(body.get('file', '') or '')
            if not directory:
                raise ValueError('Target dir is required.')
            resolved = resolve_model_url(url, hf_file)

            if resolved['kind'] == 'custom-node':
                url = str(resolved['url'])
                folder = str(resolved['repoName'])
                suffix = ' # {0}'.format(desc) if desc else ''
                line = 'install_custom_node {0} {1}{2}'.format(url, folder, suffix)
                new_lines = [line]
                entry = {'source': 'github', 'kind': 'custom-node',
                         'ids': {'repo': url}, 'dir': './custom_nodes',
                         'description': desc, 'url': url, 'name': folder}
            elif resolved['kind'] == 'civitai':
                form = dominant_civitai_form(path_full)
                vid = str(resolved['versionId'])
                # Every inserted call is wrapped so a failed download never
                # aborts the whole provision run under `set -e`.
                safe_desc = safe_echo_text(desc) or 'version {0}'.format(vid)
                suffix = ' # {0}'.format(desc) if desc else ''
                tolerant = " || echo '[provision] download failed: {0}, continuing' >&2".format(safe_desc)
                if form == 'flag':
                    line = 'civitai download --version {0} --out-dir {1}{2}{3}'.format(vid, directory, tolerant, suffix)
                elif form == 'bare':
                    line = 'civitai download {0} --out-dir {1}{2}{3}'.format(vid, directory, tolerant, suffix)
                else:
                    line = 'download_civitai_primary {0} {1}{2}{3}'.format(vid, directory, tolerant, suffix)
                new_lines = [line]
                entry = {'source': 'civitai', 'kind': 'civitai-version',
                         'ids': {'versionId': vid}, 'dir': directory,
                         'description': desc,
                         'url': 'https://civitai.com/models/{0}'.format(resolved['modelId']),
                         'name': ''}
            else:
                repo = str(resolved['repo'])
                hf_path = str(resolved['path'])
                if not hf_path:
                    raise ValueError('No file path resolved for the HuggingFace URL.')
                file_name = str(resolved['fileName']) or os.path.basename(hf_path)
                dest = directory.rstrip('/') + '/' + file_name
                safe_name = safe_echo_text(file_name) or 'huggingface file'
                # Standalone comment above the block survives re-parse as the
                # entry description; the last line carries the tolerance wrapper.
                new_lines = []
                if desc:
                    new_lines.append('# {0}'.format(desc))
                new_lines += ['download_hf_file \\',
                              '  {0} \\'.format(repo),
                              '  {0} \\'.format(hf_path),
                              "  {0} || echo '[provision] download failed: {1}, continuing' >&2".format(dest, safe_name)]
                entry = {'source': 'hf', 'kind': 'hf-file', 'ids': {},
                         'dir': directory, 'description': desc,
                         'url': 'https://huggingface.co/' + repo,
                         'repo': repo, 'path': hf_path, 'filename': file_name}
            pos = insert_entry_lines(path_full, new_lines)
            STATE.civitai_cache = {k: v for k, v in STATE.civitai_cache.items()
                                   if not k.startswith(name + '|')}
            models, _ = parse_script(path_full)
            add_log('Added {0} entry to {1} at line {2}'.format(
                resolved['kind'], name, pos + 2))
            return {'ok': True, 'entry': entry, 'models': models}

        if method == 'POST' and path == '/api/save':
            name = str(body.get('script', ''))
            resolve_script_path(name)
            ok, output = git_save(name)
            for line in output:
                add_log('git: {0}'.format(line))
            return {'ok': ok, 'output': output, 'logText': log_tail_text()}

        raise ValueError('Not found')


def main():
    parser = argparse.ArgumentParser(description='Model Manager web UI')
    parser.add_argument('--port', type=int, default=DEFAULT_PORT)
    parser.add_argument('--scripts-dir', default='')
    parser.add_argument('--no-browser', action='store_true')
    args = parser.parse_args()

    STATE.scripts_dir, STATE.dir_source = resolve_scripts_dir(args.scripts_dir)
    add_log('Model manager UI: scripts in {0} (source: {1})'.format(
        STATE.scripts_dir, STATE.dir_source))

    server = None
    port = args.port
    while server is None and port < args.port + PORT_ATTEMPTS:
        try:
            server = ThreadingHTTPServer(('127.0.0.1', port), Handler)
        except OSError:
            port += 1
    if server is None:
        print('Could not bind a local HTTP port in range {0}..{1}.'.format(
            args.port, args.port + PORT_ATTEMPTS - 1), flush=True)
        sys.exit(1)
    add_log('Model manager UI: http://localhost:{0}/  (Ctrl+C to stop)'.format(port))

    if not args.no_browser:
        threading.Timer(0.5, lambda: webbrowser.open('http://localhost:{0}/'.format(port))).start()

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
