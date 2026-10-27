"""Generate native adaptive semantic colors from the reviewed LumaPath tokens."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
tokens = json.loads((ROOT / 'docs/design/tokens.json').read_text())
assets = ROOT / 'LumaPath/App/Assets.xcassets'
assets.mkdir(exist_ok=True)
(assets / 'Contents.json').write_text(json.dumps({'info': {'author': 'xcode', 'version': 1}}, indent=2) + '\n')
for role in tokens['themes']['light']:
    colors = []
    for theme, appearances in [
        ('light', []),
        ('dark', [{'appearance': 'luminosity', 'value': 'dark'}]),
        ('lightIncreasedContrast', [{'appearance': 'luminosity', 'value': 'light'}, {'appearance': 'contrast', 'value': 'high'}]),
        ('darkIncreasedContrast', [{'appearance': 'luminosity', 'value': 'dark'}, {'appearance': 'contrast', 'value': 'high'}]),
    ]:
        value = tokens['themes'][theme][role].lstrip('#')
        entry = {'idiom': 'universal', 'color': {'color-space': 'srgb', 'components': {
            **{name: f'{int(value[i:i+2], 16) / 255:.8f}' for name, i in [('red', 0), ('green', 2), ('blue', 4)]}, 'alpha': '1.000'}}}
        if appearances:
            entry['appearances'] = appearances
        colors.append(entry)
    folder = assets / f'Luma.{role}.colorset'
    folder.mkdir(exist_ok=True)
    (folder / 'Contents.json').write_text(json.dumps({'colors': colors, 'info': {'author': 'xcode', 'version': 1}}, indent=2) + '\n')
