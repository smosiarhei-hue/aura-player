"""Seven-palette, offline asset, contrast and scope regression guards."""
import base64
import json
from pathlib import Path
import re
import struct
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
def source(name): return (ROOT/'Sonivo'/name).read_text()
def hexes(property_name):
    block=source('ThemeFontManager.swift').split(f'var {property_name}: UInt32 {{',1)[1].split('\n    }',1)[0]
    return {n:int(h,16) for n,h in re.findall(r'case \.(\w+): return 0x([A-F0-9]{6})',block)}
def luminance(h):
    c=[((h>>n)&255)/255 for n in (16,8,0)]
    return sum(w*(v/12.92 if v<=.04045 else ((v+.055)/1.055)**2.4) for w,v in zip((.2126,.7152,.0722),c))
def contrast(a,b):
    x,y=sorted((luminance(a),luminance(b)))
    return (y+.05)/(x+.05)
class ResonanceBrandTests(unittest.TestCase):
    def test_exact_seven_approved_palettes_and_canvas_tokens(self):
        accents=hexes('accentHex')
        self.assertEqual(accents,dict(amethyst=0x9875F5,cobalt=0x527CFF,titanium=0xF5A65B,
            lime=0xC5EF68,mint=0x69DFC2,coral=0xFF806D,silver=0xDCE3EF))
        self.assertEqual(set(accents),set(hexes('lightCanvasHex')))
        self.assertEqual(set(accents),set(hexes('darkCanvasHex')))
        self.assertIn('case amethyst, cobalt, titanium, lime, mint, coral, silver',source('ThemeFontManager.swift'))
    def test_small_accent_labels_are_aa_in_both_modes(self):
        for n,h in hexes('accentHex').items():
            self.assertGreaterEqual(contrast(h,hexes('darkCanvasHex')[n]),4.5,n+' dark')
            self.assertGreaterEqual(contrast(hexes('lightAccentHex')[n],hexes('lightCanvasHex')[n]),4.5,n+' light')
    def test_migration_and_appearance_are_persisted_without_resetting_other_preferences(self):
        s=source('ThemeFontManager.swift')
        for expected in ['case "crimson": return .coral','case "sunset": return .titanium',
                         'case "violet": return .amethyst','case "cyan", "emerald": return .mint',
                         'if let saved, let current = Self(rawValue: saved)',
                         'defaults.set(appearance.rawValue, forKey: "settings.appearance")',
                         'defaults.set(selectedTheme.rawValue, forKey: "settings.selectedTheme")']:
            self.assertIn(expected,s)
        self.assertIn('.preferredColorScheme(themeManager.appearance.colorScheme)',source('SonivoLaunchIntro.swift'))
        self.assertNotIn('removePersistentDomain',s)
    def test_async_renderer_provider_captures_no_main_actor_state(self):
        s=source('ThemeFontManager.swift')
        provider=s.split('private nonisolated static func adaptive',1)[1].split('\n}\n',1)[0]
        for unsafe in ['ThemeFontManager','SettingsStore','Task {','DispatchQueue','selectedTheme']:
            self.assertNotIn(unsafe,provider)
        self.assertIn('traits.userInterfaceStyle == .dark ? dark : light',provider)
    def test_palette_picker_preserves_accessibility_and_reduced_motion(self):
        s=source('SonivoAppearanceView.swift')
        for expected in ['AppThemeColor.allCases','AppAppearance.allCases','accessibilityReduceMotion',
                         '.frame(minHeight: 48)','.accessibilityValue(','.accessibilityAddTraits(',
                         'withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25))']:
            self.assertIn(expected,s)
    def test_assets_materialize_from_reviewable_payloads_without_external_packages(self):
        script=(ROOT/'scripts/materialize_app_icons.py').read_text()
        self.assertNotIn('PIL',script)
        for n in ['AppIcon1024.png','AppIcon1024-dark.png','AppIcon1024-tinted.png']:
            b=base64.b64decode((ROOT/'design/app-icon/generated'/f'{n}.b64').read_text().strip(),validate=True)
            self.assertEqual(b[:8],b'\x89PNG\r\n\x1a\n')
            width,height,depth,kind=struct.unpack('>IIBB',b[16:26])
            self.assertEqual((width,height,depth,kind),(1024,1024,8,2)) # opaque RGB, no system mask baked in
        b=base64.b64decode((ROOT/'design/resonance/generated/ResonanceRingMask.png.b64').read_text().strip(),validate=True)
        self.assertEqual(struct.unpack('>IIBB',b[16:26]),(640,640,8,4))
        self.assertIn('Materialize App Icon Variants',(ROOT/'project.yml').read_text())
    def test_icon_composer_sources_are_unmasked_geometry_not_fake_system_render(self):
        for name in ['background.svg','ring-silhouette.svg','warm-edge.svg']:
            s=(ROOT/'design/resonance'/name).read_text()
            for forbidden in ['linearGradient','radialGradient','filter=','clipPath','<text']:
                self.assertNotIn(forbidden,s)
        self.assertIn('not a compiled .icon',(ROOT/'design/resonance/README.md').read_text())
    def test_brand_files_have_no_audio_or_network_runtime_changes(self):
        for name in ['SonivoResonanceSymbol.swift','SonivoAppearanceView.swift','SonivoLaunchMotion.swift']:
            s=source(name)
            for forbidden in ['AVAudioSession','AVPlayer','URLSession','eqBands','MusicHapticsManager','buildWaveQueue']:
                self.assertNotIn(forbidden,s)
if __name__=='__main__':unittest.main()
