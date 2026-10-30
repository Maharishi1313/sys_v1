#!/usr/bin/env python3
"""
eval_sqz_custom.py - accuracy of the original SqueezeNet-1.1 (1000 classes) and of the
custom one (normalisation folded, CLASSES only) on artifacts/eval_images, through an
emulation of the camera path the SoC sees:

    photo -> OV7670 frame 320x240 (scale to cover, centre crop 4:3)
          -> OV7670Simulate (contrast loss, warm AWB, read noise, lens blur)   [cond. "ov7670"]
          -> RGB565 -> RGB888 by bit replication (rtl/cam_frontend.sv)
          -> crop 224x224 at (48, 8) -> network
    The custom model gets the bytes XOR 0x80 (= pixel - 128), the original model the uint8.

Condition "clean" skips OV7670Simulate (still 320x240 + RGB565), as a reference.
Models: orig      - artifacts/squeezenet1_1.onnx, argmax over all 1000 classes
        orig@33   - the same scores, argmax over CLASSES only
        custom    - artifacts/squeezenet1_1_custom/squeezenet1_1_custom.onnx
        int(txt)  - the integer model that runs from weights.txt (HW arithmetic)
Writes artifacts/squeezenet1_1_custom/eval/: results.csv, report.txt, and overlays/ with
the 224x224 camera crop (ov7670 condition) and the predictions drawn on it.

Usage:  python3 scripts/eval_sqz_custom.py      (needs numpy, onnx, onnxruntime, pillow)
"""
import csv
import hashlib
import os
import sys
from collections import Counter

import numpy as np
import onnx
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter, ImageFont

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_sqz_custom import CLASSES, LABELS, MODEL, OUT, ROOT, read_txt, run_int, session

IMAGES = os.path.join(ROOT, "artifacts", "eval_images")
EVAL = os.path.join(OUT, "eval")
CAM_W, CAM_H, CROP = 320, 240, 224
CROP_X0, CROP_Y0 = (CAM_W - CROP) // 2, (CAM_H - CROP) // 2      # 48, 8


class OV7670Simulate:
    """The OV7670 model from the training pipeline, with PIL only (TF.adjust_contrast /
    TF.adjust_brightness on a PIL image are ImageEnhance.Contrast / .Brightness).
    apply_prob = 1: every test frame goes through it; rng makes each image reproducible."""

    def __init__(self, noise_std=4.0, blur_radius=0.5, contrast_factor=0.75, apply_prob=1.0):
        self.noise_std = noise_std
        self.blur_radius = blur_radius
        self.contrast_factor = contrast_factor
        self.apply_prob = apply_prob

    def __call__(self, img, rng):
        if rng.random() > self.apply_prob:
            return img
        # 1. reduced contrast (lower dynamic range)
        img = ImageEnhance.Contrast(img).enhance(self.contrast_factor + rng.uniform(-0.05, 0.05))
        # 2. slight warm cast (OV7670 AWB tends warm)
        r, g, b = img.split()
        r = ImageEnhance.Brightness(r).enhance(1.0 + rng.uniform(0.0, 0.08))
        b = ImageEnhance.Brightness(b).enhance(1.0 - rng.uniform(0.0, 0.05))
        img = Image.merge("RGB", (r, g, b))
        # 3. gaussian read noise
        arr = np.array(img, dtype=np.float32)
        arr += rng.normal(0.0, self.noise_std + rng.uniform(-1, 1), arr.shape).astype(np.float32)
        img = Image.fromarray(np.clip(arr, 0.0, 255.0).astype(np.uint8))
        # 4. slight blur (cheap fixed-focus lens)
        return img.filter(ImageFilter.GaussianBlur(radius=self.blur_radius + rng.uniform(0.0, 0.3)))


def to_frame(img):
    """scale to cover 320x240, centre crop: the scene as the OV7670 frames it."""
    s = max(CAM_W / img.width, CAM_H / img.height)
    img = img.resize((max(CAM_W, round(img.width * s)), max(CAM_H, round(img.height * s))),
                     Image.BILINEAR)
    l, t = (img.width - CAM_W) // 2, (img.height - CAM_H) // 2
    return img.crop((l, t, l + CAM_W, t + CAM_H))


def rgb565(img):
    """RGB888 -> RGB565 -> RGB888 by bit replication, as rtl/cam_frontend.sv."""
    a = np.asarray(img, np.uint8)
    r, g, b = a[..., 0] >> 3, a[..., 1] >> 2, a[..., 2] >> 3
    return np.stack([(r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2)], -1)


def camera(path, sim, rng):
    frame = to_frame(Image.open(path).convert("RGB"))
    if sim is not None:
        frame = sim(frame, rng)
    px = rgb565(frame)[CROP_Y0:CROP_Y0 + CROP, CROP_X0:CROP_X0 + CROP]
    return np.ascontiguousarray(px.transpose(2, 0, 1))              # 3x224x224 uint8


def overlay(px, true, rows, path):
    """camera crop x2 with a caption: true class, then one line per model (green = right)."""
    im = Image.fromarray(px.transpose(1, 2, 0)).resize((2 * CROP, 2 * CROP), Image.NEAREST)
    font = ImageFont.load_default(size=15)
    h = 22 * (len(rows) + 1) + 6
    canvas = Image.new("RGB", (2 * CROP, 2 * CROP + h), (20, 20, 20))
    canvas.paste(im, (0, 0))
    d = ImageDraw.Draw(canvas)
    y = 2 * CROP + 4
    d.text((6, y), f"true: {true}", fill=(230, 230, 230), font=font)
    for text, ok in rows:
        y += 22
        d.text((6, y), text, fill=(90, 220, 90) if ok else (240, 80, 80), font=font)
    canvas.save(path, quality=80)


def main():
    labels = open(LABELS).read().splitlines()
    idx = np.array(CLASSES)
    s_orig = session(onnx.load(MODEL))
    s_new = session(onnx.load(os.path.join(OUT, "squeezenet1_1_custom.onnx")))
    tl = read_txt(os.path.join(OUT, "weights.txt"))
    sim = OV7670Simulate()
    os.makedirs(os.path.join(EVAL, "overlays"), exist_ok=True)

    items = []
    for d in sorted(os.listdir(IMAGES)):
        if os.path.isdir(os.path.join(IMAGES, d)):
            k = int(d.split("_")[0])
            items += [(d, f, k) for f in sorted(os.listdir(os.path.join(IMAGES, d)))]
    print(f"{len(items)} images, {len(CLASSES)} classes")

    models = ["orig", "orig@33", "custom", "int(txt)"]
    res = []
    for n, (d, f, k) in enumerate(items):
        path = os.path.join(IMAGES, d, f)
        for cond in ("clean", "ov7670"):
            seed = int(hashlib.md5(f"{d}/{f}".encode()).hexdigest()[:8], 16)
            px = camera(path, sim if cond == "ov7670" else None, np.random.default_rng(seed))
            y0 = s_orig.run(None, {"image_tensor": px[None]})[0][0].astype(np.int32)
            x_s8 = (px ^ 0x80).view(np.int8)
            y1 = s_new.run(None, {"image_s8": x_s8[None]})[0][0].astype(np.int32)
            y2 = run_int(tl, x_s8) + 128
            p = {"orig": int(np.argmax(y0)),                         # ImageNet index
                 "orig@33": CLASSES[int(np.argmax(y0[idx]))],
                 "custom": CLASSES[int(np.argmax(y1))],
                 "int(txt)": CLASSES[int(np.argmax(y2))]}
            top3 = [CLASSES[i] for i in np.argsort(-y2, kind="stable")[:3]]
            res.append(dict(cond=cond, cls=k, file=f"{d}/{f}", true=CLASSES[k], top3=top3,
                            **{m: p[m] for m in models}))
            if cond == "ov7670":
                os.makedirs(os.path.join(EVAL, "overlays", d), exist_ok=True)
                overlay(px, labels[CLASSES[k]],
                        [(f"custom int8 : {labels[p['int(txt)']]}  ({int(y2.max())})",
                          p["int(txt)"] == CLASSES[k]),
                         (f"orig 1000cls: {labels[p['orig']]}", p["orig"] == CLASSES[k])],
                        os.path.join(EVAL, "overlays", d, f))
        if (n + 1) % 50 == 0:
            print(f"  {n + 1}/{len(items)}")

    with open(os.path.join(EVAL, "results.csv"), "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["condition", "file", "true"] + models + ["custom_top3"])
        for r in res:
            w.writerow([r["cond"], r["file"], labels[r["true"]]] + [labels[r[m]] for m in models]
                       + ["|".join(labels[c] for c in r["top3"])])

    out = []
    acc = lambda rs, m: 100.0 * np.mean([r[m] == r["true"] for r in rs])
    out.append(f"{len(items)} images ({len(CLASSES)} classes, Wikimedia Commons), "
               "camera path 320x240 -> RGB565 -> crop 224 @ (48,8)\n")
    out.append(f"{'top-1 accuracy %':18s}" + "".join(f"{m:>10s}" for m in models)
               + f"{'int top-3':>11s}  {'custom==int':>12s}")
    for cond in ("clean", "ov7670"):
        rs = [r for r in res if r["cond"] == cond]
        t3 = 100.0 * np.mean([r["true"] in r["top3"] for r in rs])
        agree = 100.0 * np.mean([r["custom"] == r["int(txt)"] for r in rs])
        out.append(f"{cond:18s}" + "".join(f"{acc(rs, m):10.1f}" for m in models)
                   + f"{t3:11.1f}  {agree:11.1f}%")
    rs = [r for r in res if r["cond"] == "ov7670"]
    out.append("\nper class (ov7670), top-1 %:   n   orig  custom  int(txt)")
    for k, c in enumerate(CLASSES):
        rk = [r for r in rs if r["cls"] == k]
        out.append(f"  {labels[c]:28s}{len(rk):3d} {acc(rk, 'orig'):6.0f} {acc(rk, 'custom'):7.0f} "
                   f"{acc(rk, 'int(txt)'):9.0f}")
    out.append("\nmost common confusions (ov7670, int(txt)):  true -> predicted")
    for (t, p), n in Counter((r["true"], r["int(txt)"]) for r in rs
                             if r["true"] != r["int(txt)"]).most_common(12):
        out.append(f"  {n:2d}x  {labels[t]} -> {labels[p]}")
    out.append("\nwhat the original 1000-class model said when wrong (ov7670), most common:")
    for (t, p), n in Counter((r["true"], r["orig"]) for r in rs
                             if r["true"] != r["orig"]).most_common(12):
        out.append(f"  {n:2d}x  {labels[t]} -> {labels[p]}")
    txt = "\n".join(out)
    print(txt)
    open(os.path.join(EVAL, "report.txt"), "w").write(txt + "\n")


if __name__ == "__main__":
    main()
