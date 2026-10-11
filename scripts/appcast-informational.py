#!/usr/bin/env python3
"""Mark appcast items informational for installs below a version.

Sparkle key rotation (2026-10): installs older than 1.3.8 embed the old public
key and would fail the signature check on any newer item ("improperly signed").
With <sparkle:informationalUpdate><sparkle:belowVersion>, those installs are
shown "a new version is available" with the release page as the link instead,
while newer installs update normally. Idempotent; also adds the <link> the
informational update opens. Drop the step once no pre-1.3.8 install is left.

Usage: appcast-informational.py <appcast.xml> <below-version>
"""
import re, sys

def main():
    path, below = sys.argv[1], sys.argv[2]
    x = open(path, encoding="utf-8").read()
    block = ("<sparkle:informationalUpdate><sparkle:belowVersion>%s</sparkle:belowVersion>"
             "</sparkle:informationalUpdate>" % below)

    def patch(m):
        item = m.group(0)
        if "sparkle:informationalUpdate" in item:
            return item
        url = re.search(r'<enclosure url="([^"]+)"', item)
        link = ""
        if url and "<link>" not in item:
            tag = re.search(r"/releases/download/([^/]+)/", url.group(1))
            if tag:
                link = "<link>%s/releases/tag/%s</link>" % (url.group(1).split("/releases/")[0], tag.group(1))
        return item.replace("<enclosure", link + block + "<enclosure", 1)

    y = re.sub(r"<item>.*?</item>", patch, x, flags=re.S)
    if y != x:
        open(path, "w", encoding="utf-8").write(y)
    print("patched" if y != x else "unchanged")

if __name__ == "__main__":
    main()
