#!/usr/bin/env python3
"""
fetch_eval_images.py - download a small test set for the classes of make_sqz_custom.py from
Wikimedia Commons (free-licensed photos, not ImageNet / COCO).

~N_PER_CLASS 500 px thumbnails per class into artifacts/eval_images/<k>_<name>/, plus
sources.csv (file page URL of every image, for licences / attribution).  Search hits are not
always the right object: look at the contact sheets (contact_*.jpg), delete wrong images and
add their URL to rejected.txt; a rerun tops the classes up (QUERY2 first) and skips every
URL already in sources.csv / rejected.txt.

Usage:  python3 scripts/fetch_eval_images.py      (stdlib + pillow only)
"""
import csv
import hashlib
import json
import os
import sys
import time
import urllib.parse
import urllib.request

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_sqz_custom import CLASSES, LABELS, ROOT

OUT = os.path.join(ROOT, "artifacts", "eval_images")
N_PER_CLASS = 12
UA = "sqz-eval/0.1 (image classifier test set; python urllib)"
API = "https://commons.wikimedia.org/w/api.php"

# Commons search text per ImageNet index (more specific than the ImageNet name)
QUERY = {207: "golden retriever dog", 208: "labrador retriever dog", 281: "tabby cat",
         409: "analog wall clock", 531: "digital wristwatch", 414: "backpack bag",
         748: "handbag purse", 893: "leather wallet", 418: "ballpoint pen",
         487: "mobile phone smartphone", 761: "TV remote control", 504: "coffee mug",
         898: "water bottle", 737: "soda bottle plastic", 508: "computer keyboard",
         620: "laptop computer", 664: "computer monitor", 673: "computer mouse",
         851: "television set", 545: "electric fan", 846: "table lamp", 559: "folding chair",
         721: "pillow cushion bed", 728: "plastic bag", 770: "running shoes",
         837: "sunglasses", 879: "umbrella", 760: "refrigerator kitchen", 849: "teapot",
         671: "mountain bike", 817: "sports car", 948: "granny smith apple", 954: "banana fruit"}
# second, narrower queries used to top up classes after the bad hits were removed
QUERY2 = {531: "casio digital watch", 737: "coca-cola bottle", 721: "pillow",
          728: "plastic shopping bag", 748: "leather handbag", 893: "wallet",
          409: "wall clock", 208: "labrador", 414: "school backpack", 846: "bedside lamp",
          559: "folding chair metal", 879: "open umbrella rain", 671: "mountain bike trail",
          664: "LCD monitor", 761: "remote control", 849: "porcelain teapot"}


def get(url):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read()


def search(q, n):
    p = dict(action="query", generator="search", gsrsearch=f"{q} filetype:bitmap",
             gsrnamespace=6, gsrlimit=n, prop="imageinfo", iiprop="url|mime",
             iiurlwidth=500, format="json")
    js = json.loads(get(API + "?" + urllib.parse.urlencode(p)))
    pages = sorted(js.get("query", {}).get("pages", {}).values(), key=lambda x: x["index"])
    return [(pg["title"], pg["imageinfo"][0]) for pg in pages
            if pg["imageinfo"][0].get("mime") in ("image/jpeg", "image/png")]


def contact_sheets(dirs, new=()):
    """one jpg per 4 classes, 12 thumbs per row, to check the labels by eye (new ones red)."""
    T = 96
    for s in range(0, len(dirs), 4):
        group = dirs[s:s + 4]
        sheet = Image.new("RGB", (T * (N_PER_CLASS + 4), T * len(group)), "white")
        for r, d in enumerate(group):
            for c, fn in enumerate(sorted(os.listdir(os.path.join(OUT, d)))[:N_PER_CLASS + 4]):
                im = Image.open(os.path.join(OUT, d, fn)).convert("RGB")
                im.thumbnail((T - 6, T - 6))
                if (d, fn) in new:
                    sheet.paste((255, 0, 0), (c * T, r * T, c * T + T - 2, r * T + T - 2))
                sheet.paste(im, (c * T + 2, r * T + 2))
        sheet.save(os.path.join(OUT, f"contact_{s // 4:02d}.jpg"), quality=80)


def main():
    labels = open(LABELS).read().splitlines()
    os.makedirs(OUT, exist_ok=True)
    src, rej = os.path.join(OUT, "sources.csv"), os.path.join(OUT, "rejected.txt")
    seen = set(open(rej).read().split()) if os.path.exists(rej) else set()
    if os.path.exists(src):
        seen |= {r[2] for r in csv.reader(open(src))}
    rows, dirs = [], []
    for k, c in enumerate(CLASSES):
        d = f"{k:02d}_{labels[c].replace(' ', '_')}"
        dirs.append(d)
        os.makedirs(os.path.join(OUT, d), exist_ok=True)
        got = len(os.listdir(os.path.join(OUT, d)))
        for q in filter(None, (QUERY2.get(c), QUERY[c])):
            if got >= N_PER_CLASS:
                break
            for title, ii in search(q, 4 * N_PER_CLASS):
                page = ii["descriptionurl"].split("?")[0]
                if got >= N_PER_CLASS or page in seen:
                    continue
                seen.add(page)
                name = hashlib.md5(page.encode()).hexdigest()[:8] + ".jpg"
                fn = os.path.join(OUT, d, name)
                try:
                    with open(fn, "wb") as f:
                        f.write(get(ii["thumburl"]))
                    Image.open(fn).verify()
                    im = Image.open(fn).convert("RGB")
                    if min(im.size) < 150:
                        raise ValueError("too small")
                    im.save(fn, quality=90)          # normalise to RGB jpeg
                except Exception as e:               # noqa: BLE001 - skip any bad download
                    print(f"  skip {title}: {e}")
                    if os.path.exists(fn):
                        os.remove(fn)
                    continue
                rows.append((d, name, page))
                got += 1
                time.sleep(0.2)
        print(f"{d:28s} {got} images")
    with open(src, "a", newline="") as f:
        csv.writer(f).writerows(rows)
    contact_sheets(dirs, {(d, f) for d, f, _ in rows})


if __name__ == "__main__":
    main()
