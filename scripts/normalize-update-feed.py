#!/usr/bin/env python3
"""Give generated deltas immutable, URL-safe build names before signing the feed."""
from pathlib import Path
import re
import sys
import urllib.parse
import xml.etree.ElementTree as ET

def normalize(folder, version, build):
    namespace = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
    ET.register_namespace('sparkle', namespace)
    tree = ET.parse(folder / 'appcast.xml')
    for enclosure in tree.findall(f'./channel/item/{{{namespace}}}deltas/enclosure'):
        old = enclosure.attrib[f'{{{namespace}}}deltaFrom']
        assert re.fullmatch(r'[1-9]\d*', old)
        url = urllib.parse.urlsplit(enclosure.attrib['url'])
        original = urllib.parse.unquote(url.path.rsplit('/', 1)[1])
        assert Path(original).name == original and original.endswith('.delta')
        name = f'WovenMatter_{version}_{build}_from_{old}_arm64.delta'
        (folder / original).rename(folder / name)
        enclosure.attrib['url'] = urllib.parse.urlunsplit(url._replace(path=url.path.rsplit('/', 1)[0] + '/' + name))
    tree.write(folder / 'appcast.xml', encoding='utf-8', xml_declaration=True)

if __name__ == '__main__':
    normalize(Path(sys.argv[1]), sys.argv[2], int(sys.argv[3]))
