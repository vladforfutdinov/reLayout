#!/usr/bin/env python3
"""Keep only the words of a frequency list that a dictionary knows.

The OpenSubtitles-derived FrequencyWords lists are not monolingual: the
Ukrainian one is a quarter Russian by mass ("что", "как", "это"), which taught
the uk model to accept Russian. A word-form list from a real dictionary
(dict_uk's dict_corp_vis.txt for uk: first token of each line) is the filter.

Usage: filter.py <freq_list.txt> <forms.txt> > clean_freq_list.txt
"""
import sys

def main():
    freq, forms_path = sys.argv[1], sys.argv[2]
    forms = set()
    for line in open(forms_path, encoding="utf-8", errors="ignore"):
        t = line.split()
        if t:
            forms.add(t[0].lower().replace("’", "'"))
    for line in open(freq, encoding="utf-8", errors="ignore"):
        parts = line.split()
        if len(parts) >= 2 and parts[0].lower() in forms:
            sys.stdout.write(line)

if __name__ == "__main__":
    main()
