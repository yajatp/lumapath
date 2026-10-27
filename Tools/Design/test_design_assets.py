"""Protect the native palette against drift from the approved semantic tokens."""
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]

class NativePaletteTests(unittest.TestCase):
    def test_all_native_variants_match_tokens(self):
        tokens = json.loads((ROOT / 'docs/design/tokens.json').read_text())
        for role in tokens['themes']['light']:
            asset = ROOT / f'LumaPath/App/Assets.xcassets/Luma.{role}.colorset/Contents.json'
            variants = json.loads(asset.read_text())['colors']
            self.assertEqual(len(variants), 4, role)
            for theme, entry in zip(tokens['themes'], variants):
                with self.subTest(role=role, theme=theme):
                    expected = tokens['themes'][theme][role].lstrip('#')
                    actual = entry['color']['components']
                    for name, offset in [('red', 0), ('green', 2), ('blue', 4)]:
                        self.assertAlmostEqual(float(actual[name]), int(expected[offset:offset + 2], 16) / 255, places=7)
                    self.assertEqual(actual['alpha'], '1.000')
                    appearances = {a['appearance']: a['value'] for a in entry.get('appearances', [])}
                    if 'IncreasedContrast' in theme:
                        self.assertEqual(appearances['contrast'], 'high')
                    if theme.startswith('dark'):
                        self.assertEqual(appearances['luminosity'], 'dark')

    def test_reading_and_control_contrast(self):
        themes = json.loads((ROOT / 'docs/design/tokens.json').read_text())['themes']
        def luminance(value):
            channels = [int(value[i:i + 2], 16) / 255 for i in (1, 3, 5)]
            linear = [v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4 for v in channels]
            return sum(v * w for v, w in zip(linear, (0.2126, 0.7152, 0.0722)))
        for theme, colors in themes.items():
            for foreground, background, minimum in [
                ('text.primary', 'background', 7), ('text.secondary', 'surface', 4.5),
                ('text.onAccent', 'accent', 4.5), ('text.onAccent', 'accent.pressed', 4.5),
                ('disabled.text', 'disabled.fill', 4.5), ('border.strong', 'surface', 3),
                ('selection.text', 'selection.fill', 4.5), ('danger.text', 'danger.fill', 4.5),
            ]:
                with self.subTest(theme=theme, foreground=foreground, background=background):
                    a, b = sorted((luminance(colors[foreground]), luminance(colors[background])))
                    self.assertGreaterEqual((b + 0.05) / (a + 0.05), minimum)

if __name__ == '__main__':
    unittest.main()
