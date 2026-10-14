#!/usr/bin/env python3
"""Check source integrity only. Native validation is performed by actool/ictool."""
import json
from pathlib import Path
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / 'design/icon-composer/AppIcon.icon'
icon = json.loads((PACKAGE / 'icon.json').read_text())
assert len(icon['groups']) == 1
assert icon['groups'][0]['lighting'] == 'combined'
layers = icon['groups'][0]['layers']
assert len(layers) == 2
for layer in layers:
    name = layer['image-name']
    assert Path(name).name == name
    assert layer['position']['scale'] == 1
    assert layer['position']['translation-in-points'] == [0, 0]
    svg = ET.parse(PACKAGE / 'Assets' / name).getroot()
    assert svg.attrib['viewBox'] == '0 0 1024 1024'
    assert {x.tag.rsplit('}', 1)[-1] for x in svg.iter()} <= {'svg', 'title', 'path'}
    assert all('filter' not in x.attrib for x in svg.iter())
    assert any(x.tag.endswith('path') for x in svg.iter())
assert icon['supported-platforms']['squares'] == 'shared'
assert icon['fill-specializations'][0]['value']['solid'].split(',')[-1] == '1.00000'
print('Source integrity passed. This is not a native rendering or compilation result.')
