#!/usr/bin/env python3
"""Build a character-trigram model from a frequency word list.

Input: a "word<space>count" list (Hermit Dave FrequencyWords format).
Output: the text model consumed by Core/Trigram.swift —
    floor <logprob>
    <trigram> <logprob>     # conditional log P(c3 | c1 c2)

Words are lowercased and filtered to alphabetic characters; each is padded
"^^" + word + "$" so word-initial/final patterns count. Trigram counts are
weighted by the word's corpus frequency. Add-k smoothing; unseen trigrams get
`floor` (clearly below any observed value) so wrong-layout junk scores low.

Usage: gen.py <freq_list.txt> [--min-count N] [--k 0.1] > model.txt
"""
import sys, math, argparse, unicodedata
from collections import defaultdict

def is_alpha(ch):
    return unicodedata.category(ch).startswith("L")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("freq")
    ap.add_argument("--min-count", type=int, default=2)
    ap.add_argument("--k", type=float, default=0.1)
    ap.add_argument("--top", type=int, default=200_000)
    a = ap.parse_args()

    ctx = defaultdict(float)          # count(c1 c2)
    tri = defaultdict(float)          # count(c1 c2 c3)
    seen_third = set()                # distinct 3rd chars (smoothing vocab)

    n = 0
    for line in open(a.freq, encoding="utf-8", errors="ignore"):
        parts = line.split()
        if len(parts) < 2:
            continue
        word, cnt = parts[0], parts[-1]
        try:
            cnt = float(cnt)
        except ValueError:
            continue
        if cnt < a.min_count:
            continue
        w = word.lower()
        if not w or any(not is_alpha(c) for c in w):
            continue
        n += 1
        if n > a.top:
            break
        padded = "^^" + w + "$"
        for i in range(2, len(padded)):
            c1, c2, c3 = padded[i-2], padded[i-1], padded[i]
            ctx[c1+c2] += cnt
            tri[c1+c2+c3] += cnt
            seen_third.add(c3)

    V = max(1, len(seen_third))
    k = a.k
    out = {}
    lo = math.inf
    for t, c in tri.items():
        p = (c + k) / (ctx[t[:2]] + k * V)
        lp = math.log(p)
        out[t] = lp
        lo = min(lo, lp)
    floor = lo - 3.0   # unseen trigram: clearly below any observed value

    w = sys.stdout.write
    w(f"# trigram model: {n} words, {len(out)} trigrams, V(3rd)={V}\n")
    w(f"floor {floor:.4f}\n")
    for t in sorted(out):
        w(f"{t} {out[t]:.4f}\n")

if __name__ == "__main__":
    main()
