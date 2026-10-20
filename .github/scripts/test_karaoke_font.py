"""Verify the real licensed font, deterministic packaging and macOS registration."""
import base64, hashlib, importlib.util, platform, shutil, struct, subprocess, tempfile, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('font_materializer', ROOT/'scripts/materialize_karaoke_font.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
DATA = base64.b64decode((ROOT/'design/typography/Onest-Bold.ttf.b64').read_text().strip(), validate=True)
def table(tag):
    count = struct.unpack_from('>H', DATA, 4)[0]
    for i in range(count):
        name, checksum, offset, length = struct.unpack_from('>4sIII', DATA, 12 + 16*i)
        if name == tag.encode(): return DATA[offset:offset+length]
    raise AssertionError('Missing font table: ' + tag)
class KaraokeFontTests(unittest.TestCase):
    def test_actual_bold_font_identity(self):
        self.assertEqual(hashlib.sha256(DATA).hexdigest(), module.EXPECTED_SHA256)
        self.assertEqual(DATA[:4], b'\0\1\0\0')
        names = table('name'); count, offset = struct.unpack_from('>HH', names, 2)
        values = []
        for i in range(count):
            platform_id, encoding, language, name_id, size, start = struct.unpack_from('>6H', names, 6 + 12*i)
            if platform_id == 3 and name_id == 6:
                values.append(names[offset+start:offset+start+size].decode('utf-16-be'))
        self.assertTrue(values)
        self.assertEqual(set(values), {'Onest-Bold'})
        self.assertEqual(struct.unpack_from('>H', table('OS/2'), 4)[0], 700)
        self.assertTrue(struct.unpack_from('>H', table('OS/2'), 62)[0] & (1 << 5))
        self.assertNotIn(b'fvar', DATA[12:12 + 16*struct.unpack_from('>H', DATA, 4)[0]])

    def test_materialization_is_idempotent_and_rejects_corruption(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); src = root/'design/typography/Onest-Bold.ttf.b64'
            src.parent.mkdir(parents=True)
            src.write_text(base64.b64encode(DATA).decode())
            result = module.materialize(root)
            self.assertEqual(result.read_bytes(), DATA)
            previous = result.stat().st_mtime_ns
            module.materialize(root)
            self.assertEqual(result.stat().st_mtime_ns, previous)
            src.write_text(base64.b64encode(DATA[:-1]).decode())
            with self.assertRaises(ValueError): module.materialize(root)

    def test_bundle_registration_and_lyric_only_scope(self):
        project = (ROOT/'project.yml').read_text()
        for value in ['UIAppFonts:', 'KaraokeFonts/Onest-Bold.ttf', 'path: Sonivo/KaraokeFonts', 'materialize_karaoke_font.py']:
            self.assertIn(value, project)
        self.assertIn('type: folder\n        buildPhase: resources', project)
        helper = (ROOT/'Sonivo/KaraokeTypography.swift').read_text()
        self.assertIn('"Onest-Bold"', helper)
        self.assertIn('.custom(postScriptName, fixedSize: size)', helper)
        for file in ['TypographyLyricsView.swift', 'StaggeredLyricsView.swift', 'KineticLyricsView.swift', 'lyricsview.swift', 'PlayerScreenV2.swift']:
            self.assertIn('KaraokeTypography.font(size:', (ROOT/'Sonivo'/file).read_text())
        self.assertIn('SIL OPEN FONT LICENSE', (ROOT/'Sonivo/KaraokeFonts/OFL-Onest.txt').read_text())

    @unittest.skipUnless(platform.system() == 'Darwin' and shutil.which('swiftc'), 'CoreText registration needs macOS')
    def test_coretext_loads_onest_and_cyrillic_without_fallback(self):
        font = module.materialize()
        swift = '''import Foundation
import CoreText
let url = URL(fileURLWithPath: CommandLine.arguments[1])
precondition(CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil))
let font = CTFontCreateWithName("Onest-Bold" as CFString, 50, nil)
precondition((CTFontCopyPostScriptName(font) as String) == "Onest-Bold")
let text = Array("Музыка — это то, что мы чувствуем. Ёж ABC 0123".utf16)
var glyphs = [CGGlyph](repeating: 0, count: text.count)
precondition(CTFontGetGlyphsForCharacters(font, text, &glyphs, text.count))
precondition(glyphs.allSatisfy { $0 != 0 })
'''
        with tempfile.TemporaryDirectory() as temp:
            src = Path(temp)/'check.swift'; binary = Path(temp)/'check'
            src.write_text(swift)
            subprocess.run(['swiftc', str(src), '-o', str(binary)], check=True, capture_output=True, timeout=90)
            subprocess.run([str(binary), str(font)], check=True, capture_output=True, timeout=20)
