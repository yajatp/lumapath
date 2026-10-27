"""Import the user-supplied MHS visual reference without executing bundled scripts.

Usage: python3 Tools/Design/import_deck.py '/path/to/LumaPath deck styled for MHS.zip'
Then run render_deck.cjs with Playwright available to refresh PNG previews/icons.
"""
import base64
import gzip
import json
from pathlib import Path
import re
import sys
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[2]
DEST = ROOT / 'docs/demos'
DEST.mkdir(exist_ok=True)
with zipfile.ZipFile(sys.argv[1]) as archive:
    pages = {}
    for name in ('LumaPath App Screens.html', 'LumaPath Logo Sheet.html'):
        source = archive.read('downloads/' + name).decode()
        template = json.loads(re.search(r'<script type="__bundler/template">(.*?)</script>', source, re.S)[1])
        manifest = json.loads(re.search(r'<script type="__bundler/manifest">(.*?)</script>', source, re.S)[1])
        template = re.sub(r'<script\b[^>]*>.*?</script>', '', template, flags=re.S)
        template = template.replace('sc-camel-view-box', 'viewBox')
        template = re.sub(r'<link[^>]*preconnect[^>]*>', '', template)
        for key, entry in manifest.items():
            if key not in template:
                continue
            data = base64.b64decode(entry['data'])
            if entry.get('compressed'):
                data = gzip.decompress(data)
            # Fonts and photographs are the only non-code resources needed by these static mockups.
            mime = entry['mime']
            extension = {'image/jpeg': '.jpg', 'image/png': '.png'}.get(mime, '.woff2' if 'font' in mime else None)
            if extension is None:
                raise ValueError(f'Unexpected referenced resource: {mime}')
            assets = DEST / 'assets'
            assets.mkdir(exist_ok=True)
            file = assets / (key + extension)
            if mime == 'image/jpeg':
                # Preserve the supplied photographs while bounding gallery download size.
                with tempfile.NamedTemporaryFile(suffix='.jpg') as original:
                    original.write(data)
                    original.flush()
                    file = file.with_suffix('.webp')
                    subprocess.run(['cwebp', '-quiet', '-q', '85', '-resize', '0', '1500', original.name, '-o', str(file)], check=True)
                (assets / (key + extension)).unlink(missing_ok=True)
            else:
                file.write_bytes(data)
            template = template.replace(key, 'assets/' + file.name)
        template = template.replace('<html>', '<html lang="en">')
        title = 'LumaPath — MHS design mockups' if 'Screens' in name else 'LumaPath — MHS logo reference'
        template = template.replace('<head>', '<head><title>' + title + '</title>')
        notice = '<aside style="padding:20px 24px;background:#DDF3E9;color:#14282B;font:17px/1.4 system-ui">Design mockups supplied with the MHS deck. Illustrative scenes, distances and Watch cues are not measured app output. Routes and Community remain unavailable. <a href="../VALIDATION.md">Validation and limitations</a> · <a href="index.html">App screens</a> · <a href="logos.html">Logo sheet</a></aside>'
        responsive = '<style>@media(max-width:600px){body>x-dc>div{padding:32px 16px 64px!important;gap:40px!important}header>div:nth-child(2){font-size:36px!important}figure{zoom:.72}section>div{gap:20px!important}}</style>'
        template = template.replace('</head>', responsive + '</head>')
        template = template.replace('<body>', '<body>' + notice)
        # The export is deliberately static: no imported JavaScript, trackers or network fonts.
        (DEST / ('index.html' if 'Screens' in name else 'logos.html')).write_text(template)
        pages[name] = template
    logo = re.search(r'<svg\b[^>]*>(.*?)</svg>', pages['LumaPath Logo Sheet.html'], re.S)[1]
    header = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" role="img" aria-label="LumaPath lantern">'
    icon = header + '<rect width="1024" height="1024" fill="#006B63"/>' + logo + '</svg>\n'
    for path in ('docs/brand/lumapath-icon.svg', 'Tools/Design/lumapath-lantern.svg'):
        (ROOT / path).write_text(icon)
    (ROOT / 'docs/brand/lumapath-mark-on-dark.svg').write_text(header + logo + '</svg>\n')
