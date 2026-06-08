#!/usr/bin/env python3
"""Calibrate auto-mode thresholds for the trigram detector.

Decision rule (per word W typed in layout of language A, candidate other language B):
    correct  iff  score(W, A) < theta_garbage  AND  score(W', B) - score(W, A) > theta_margin
where W' is W converted to layout B.

We build positives (real B-words mistyped on the A layout -> should correct) and
negatives (real A-words typed correctly -> must NOT correct), sweep the two
thresholds, and report recall at high precision. Cross-script pairs (ru/uk <-> en).

Usage: calibrate.py
"""
import math, os
from collections import defaultdict

HERE = os.path.dirname(__file__)

# --- trigram scoring (mirrors Core/Trigram.swift) ---
def load_model(path):
    floor, table = None, {}
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, _, val = line.rpartition(" ")
        if key == "floor":
            floor = float(val)
        else:
            table[key] = float(val)
    return floor, table

def score(word, model):
    floor, table = model
    chars = "^^" + word.lower() + "$"
    if len(chars) < 3:
        return floor
    s = 0.0
    n = 0
    for i in range(2, len(chars)):
        s += table.get(chars[i-2:i+1], floor)
        n += 1
    return s / n

# --- keyboard transposition maps (aligned rows, lowercase) ---
EN = ["qwertyuiop[]", "asdfghjkl;'", "zxcvbnm,."]
RU = ["йцукенгшщзхъ", "фывапролджэ", "ячсмитьбю"]
UK = ["йцукенгшщзхї", "фівапролджє", "ячсмитьбю"]

def build_map(lang_rows):
    to_en, to_lang = {}, {}
    for er, lr in zip(EN, lang_rows):
        for e, l in zip(er, lr):
            to_en[l] = e
            to_lang[e] = l
    return to_en, to_lang

def conv(word, m):
    out = []
    for c in word:
        if c not in m:
            return None          # not fully mappable -> skip word
        out.append(m[c])
    return "".join(out)

def words(path, mx=4000):
    out = []
    for line in open(path, encoding="utf-8", errors="ignore"):
        p = line.split()
        if len(p) >= 2 and len(p[0]) >= 3 and p[0].isalpha():
            out.append(p[0].lower())
        if len(out) >= mx:
            break
    return out

def evaluate(name, lang_model, en_model, to_en, to_lang, lang_words, en_words):
    # positives: real lang-words mistyped on EN layout -> appear as latin junk;
    #            typed-as = junk under EN, alt = real word under lang.
    pos = []
    for w in lang_words:
        junk = conv(w, to_en)
        if junk:
            pos.append((score(junk, en_model), score(w, lang_model)))
    # also real EN words mistyped on lang layout -> cyrillic junk
    for w in en_words:
        junk = conv(w, to_lang)
        if junk:
            pos.append((score(junk, lang_model), score(w, en_model)))
    # negatives: real words typed correctly (must not fire). typed-as = real,
    #            alt = its junk in the other layout.
    neg = []
    for w in en_words:
        junk = conv(w, to_lang)
        if junk:
            neg.append((score(w, en_model), score(junk, lang_model)))
    for w in lang_words:
        junk = conv(w, to_en)
        if junk:
            neg.append((score(w, lang_model), score(junk, en_model)))
    return pos, neg

def sweep(pos, neg):
    best = None
    for tg10 in range(-160, -20, 2):          # theta_garbage in 0.1 steps
        tg = tg10 / 10.0
        for tm10 in range(0, 100, 2):         # theta_margin
            tm = tm10 / 10.0
            fp = sum(1 for st, sa in neg if st < tg and (sa - st) > tm)
            if fp / max(1, len(neg)) > 0.01:   # precision >= 99%
                continue
            tp = sum(1 for st, sa in pos if st < tg and (sa - st) > tm)
            recall = tp / max(1, len(pos))
            cand = (recall, tg, tm, fp)
            if best is None or recall > best[0]:
                best = cand
    return best

def main():
    en_model = load_model(f"{HERE}/models/en.txt")
    en_words = words(f"{HERE}/holdout/en_test.txt")
    for name, rows, mpath, tpath in [
        ("ru<->en", RU, "models/ru.txt", "holdout/ru_test.txt"),
        ("uk<->en", UK, "models/uk.txt", "holdout/uk_test.txt"),
    ]:
        lm = load_model(f"{HERE}/{mpath}")
        lw = words(f"{HERE}/{tpath}")
        to_en, to_lang = build_map(rows)
        pos, neg = evaluate(name, lm, en_model, to_en, to_lang, lw, en_words)
        best = sweep(pos, neg)
        recall, tg, tm, fp = best
        print(f"{name}: pos={len(pos)} neg={len(neg)}  "
              f"=> recall={recall:.3f} @ precision>=99%  "
              f"(theta_garbage={tg}, theta_margin={tm}, FP={fp}/{len(neg)})")

if __name__ == "__main__":
    main()
