"""Builds FFXI-AI.mcpb, the Claude desktop extension, from this folder.

The file goes in the addon's main folder and is committed with the rest, so players download it
straight from the repository. Rebuild and commit it whenever manifest.json or server/index.js change.

A .mcpb file is a zip with manifest.json at its root. Run:  python extension/pack.py
(Anthropic's own tool, `mcpb pack`, makes the same file if you have Node installed.)
"""

import json
import pathlib
import zipfile

HERE = pathlib.Path(__file__).resolve().parent
FILES = ['manifest.json', 'server/index.js']


def main():
    manifest = json.loads((HERE / 'manifest.json').read_text(encoding='utf-8'))
    out = HERE.parent / 'FFXI-AI.mcpb'
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        for name in FILES:
            z.write(HERE / name, name)
    print(f"Built {out} (FFXI-AI {manifest['version']}, {out.stat().st_size} bytes)")


if __name__ == '__main__':
    main()
