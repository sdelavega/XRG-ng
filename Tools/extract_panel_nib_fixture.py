#!/usr/bin/env python3
"""Extract one legacy graph-panel archive without loading the rest of the app."""
from pathlib import Path
import argparse
import plistlib


def extract(class_name: str, destination: Path) -> Path:
    root = Path(__file__).resolve().parents[1]
    archive = plistlib.loads((root / 'Resources/MainMenu.nib/keyedobjects.nib').read_bytes())
    objects = archive['$objects']
    panel_index = next(index for index, value in enumerate(objects)
                       if isinstance(value, dict)
                       and any(isinstance(value.get(key), plistlib.UID)
                               and objects[value[key].data] == class_name
                               for key in ('NSClassName', 'NSWindowClass')))
    if 'NSWindowView' in objects[panel_index]:
        # Isolate the window shell without starting any panel miners. Its autosave
        # name must also be absent so fixture loading cannot alter live settings.
        objects[panel_index]['NSFrameAutosaveName'] = plistlib.UID(0)
        content = objects[objects[panel_index]['NSWindowView'].data]
        objects[content['NSSubviews'].data]['NS.objects'] = []
    object_data = objects[archive['$top']['IB.objectdata'].data]
    owner = object_data['NSRoot']
    oids = objects[object_data['NSOidsKeys'].data]['NS.objects']
    values = objects[object_data['NSOidsValues'].data]['NS.objects']
    identifiers = dict(zip((key.data for key in oids), values))
    objects[objects[owner.data]['NSClassName'].data] = 'NSObject'
    for key in ('NSNextResponder', 'NSSuperview'):
        objects[panel_index][key] = plistlib.UID(0)
    for key in ('NSConnections', 'NSVisibleWindows'):
        objects[object_data[key].data]['NS.objects'] = []
    objects[object_data['NSObjectsKeys'].data]['NS.objects'] = [plistlib.UID(panel_index)]
    objects[object_data['NSObjectsValues'].data]['NS.objects'] = [owner]
    objects[object_data['NSOidsKeys'].data]['NS.objects'] = [owner, plistlib.UID(panel_index)]
    objects[object_data['NSOidsValues'].data]['NS.objects'] = [identifiers[owner.data], identifiers[panel_index]]
    # Leave unreachable objects in place so the retained payload keeps its exact UIDs.
    destination.write_bytes(plistlib.dumps(archive, fmt=plistlib.FMT_BINARY, sort_keys=False))
    return destination


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('class_name')
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    print(extract(args.class_name, args.destination))
