#!/usr/bin/env python3
"""Merge frequency lists from several corpora into one "word count" list.

Each source is normalized to the same total mass before adding, so a 1M-sentence
Leipzig corpus does not drown the 50k subtitle list (the only colloquial one,
and the only one that writes "ё"). Accepts the FrequencyWords "word count"
format and Leipzig's "id<TAB>word<TAB>count" words.txt. Output is sorted by
count, scaled to MASS per source, ready for gen.py.

Words are kept only if every letter is in the language's script (--script
cyrillic|latin): web crawls carry foreign words and brands, which would teach
a Cyrillic model Latin trigrams. --weight gives each list's share (default 1).

Usage: merge.py --script cyrillic [--weight 2,1,1] <list> [<list> ...] > merged.txt
"""
import sys, argparse, unicodedata
from collections import defaultdict

MASS = 1e8   # per source; gen.py's --min-count 2 then keeps anything above 2e-8 of a corpus

def in_script(word, script):
    for ch in word:
        if ch in "'ʼ-":
            continue
        name = unicodedata.name(ch, "")
        if script == "cyrillic" and not name.startswith("CYRILLIC"):
            return False
        if script == "latin" and not name.startswith("LATIN"):
            return False
    return True

def read(path):
    counts = defaultdict(float)
    for line in open(path, encoding="utf-8", errors="ignore"):
        parts = line.rstrip("\n").split("\t") if "\t" in line else line.split()
        if len(parts) < 2:
            continue
        word, cnt = (parts[1], parts[2]) if len(parts) >= 3 else (parts[0], parts[1])
        try:
            counts[word.lower()] += float(cnt)
        except ValueError:
            continue
    return counts

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--script", choices=["cyrillic", "latin"], required=True)
    ap.add_argument("--weight", default="", help="comma-separated share per list, default 1 each")
    ap.add_argument("lists", nargs="+")
    a = ap.parse_args()
    weights = [float(x) for x in a.weight.split(",")] if a.weight else [1.0] * len(a.lists)
    total = defaultdict(float)
    for path, wt in zip(a.lists, weights):
        counts = {w: c for w, c in read(path).items() if in_script(w, a.script)}
        mass = sum(counts.values())
        for w, c in counts.items():
            total[w] += c / mass * MASS * wt
    for w, c in sorted(total.items(), key=lambda kv: -kv[1]):
        sys.stdout.write(f"{w} {c:.3f}\n")

if __name__ == "__main__":
    main()
