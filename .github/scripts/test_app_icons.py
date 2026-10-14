import base64
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
BASE_NAMES = ['SonivoMusic', 'SignatureS', 'SonivoWordmark', 'ClassicWave']
STYLES = ['MusicGraphite', 'MusicPrism', 'MusicSapphire', 'MusicNeon']
NAMES = BASE_NAMES + STYLES

class AppIconTests(unittest.TestCase):
    def test_native_packages_share_reference_appearance(self):
        for name in BASE_NAMES:
            package = ROOT/'Sonivo/AppIcons'/f'{name}.icon'
            icon = json.loads((package/'icon.json').read_text())
            self.assertEqual(icon['fill-specializations'][0]['value']['solid'], 'srgb:0.08627,0.08627,0.08627,1.00000')
            for group in icon['groups']:
                self.assertFalse(group['specular'])
                self.assertFalse(group['translucency']['enabled'])
                for layer in group['layers']:
                    self.assertFalse(layer['glass'])
                    self.assertEqual(layer['position']['translation-in-points'], [0,0])
                    svg = ET.parse(package/'Assets'/layer['image-name']).getroot()
                    self.assertEqual(svg.attrib['viewBox'], '0 0 1024 1024')
                    self.assertTrue(any(x.tag.endswith('path') for x in svg))
    def test_new_styles_preserve_geometry_and_registration(self):
        source=ROOT/"Sonivo/AppIcons/SonivoMusic.icon/Assets"
        project=(ROOT/"project.yml").read_text()
        for name in STYLES:
            self.assertIn(name,project)
            manifest=json.loads((ROOT/f"Sonivo/AppIcons/{name}.icon/icon.json").read_text())
            self.assertEqual(manifest["groups"][-1]["name"],"Background")
            self.assertNotEqual(manifest["groups"][0]["name"],"Background")
            for asset in source.glob("*.svg"):
                original=ET.parse(asset).getroot()
                variant=ET.parse(ROOT/f"Sonivo/AppIcons/{name}.icon/Assets/{asset.name}").getroot()
                self.assertEqual([p.attrib["d"] for p in original.iter() if p.tag.endswith("path")],
                                 [p.attrib["d"] for p in variant.iter() if p.tag.endswith("path")])

    def test_music_contours_are_approved_sources(self):
        source = ROOT/'design/icon-composer/SonivoMusic.icon/Assets'
        destination = ROOT/'Sonivo/AppIcons/SonivoMusic.icon/Assets'
        for p in source.glob('*.svg'):
            self.assertEqual(p.read_bytes(), (destination/p.name).read_bytes())
    def test_thumbnails_are_png_and_registered(self):
        for name in NAMES:
            data = base64.b64decode((ROOT/f'design/app-icon/previews/{name}.png.b64').read_text(), validate=False)
            self.assertEqual(data[:8], b'\x89PNG\r\n\x1a\n')
            contents = json.loads((ROOT/f'Sonivo/assets.xcassets/AppIconPreview{name}.imageset/Contents.json').read_text())
            self.assertEqual(contents['images'][0]['filename'], 'preview.png')
    def test_bundle_validator_accepts_complete_and_rejects_missing_alternate(self):
        spec=importlib.util.spec_from_file_location('verify_icons',ROOT/'scripts/verify_app_icon_bundle.py')
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            p=Path(directory);(p/'Assets.car').write_bytes(b'test')
            info={'CFBundleIcons':{'CFBundlePrimaryIcon':{'CFBundleIconName':NAMES[0]},'CFBundleAlternateIcons':{name:{'CFBundleIconName':name} for name in NAMES[1:]}}}
            (p/'Info.plist').write_bytes(plistlib.dumps(info));module.verify(p)
            del info['CFBundleIcons']['CFBundleAlternateIcons']['ClassicWave']
            (p/'Info.plist').write_bytes(plistlib.dumps(info))
            with self.assertRaises(AssertionError):module.verify(p)

if __name__=='__main__':unittest.main()
