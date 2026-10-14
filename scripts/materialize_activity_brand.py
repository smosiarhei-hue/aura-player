#!/usr/bin/env python3
"""Decode versioned transparent brand masks for app and Live Activity targets."""
import base64
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def main():
    for key in ('Music','Signature','Wordmark','Classic'):
        source=ROOT/'design/dynamic-island/assets'/f'{key}.png.b64'
        destination=ROOT/'SharedActivity/BrandAssets.xcassets'/f'SonivoBrand{key}.imageset'/'mask.png'
        destination.parent.mkdir(parents=True,exist_ok=True)
        destination.write_bytes(base64.b64decode(source.read_text().strip(),validate=True))
if __name__=='__main__':main()
