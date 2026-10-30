#!/usr/bin/env python3
"""
compile_squeezenet.py - compile the customised SqueezeNet-1.1 (weights.txt) for the SoC

Input : artifacts/squeezenet1_1_custom/weights.txt  (int8 weights, BIAS_HW, MULT, SHIFT per conv,
        hardware conventions: activations int8 = uint8 - 128, ReLU zero point -128)
Output (default build/sqz_custom/):
    flash_image.bin      raw bytes to program into the weight flash at --flash-base
    flash_image.hex      the same as Intel HEX (absolute addresses, for flash programmers)
    flash_sim.hex        $readmemh byte image for the W25Q16JV simulation model
    boot_rom.hex         64-bit words {AXI addr, data}: what rtl/fpga/spi_boot_master.sv sends over
                         SPI (camera CSRs, head config, all job descriptors, START), FFFFFFFF_FFFFFFFF ends
    boot_rom.mem         the same, one 64-bit hex word per line without @ (Vivado/Quartus init file)
    job_list.txt         human-readable job list + memory plan
    frame565.hex         a 320x240 RGB565 test frame (camera emulation of --image)
    cls_exp.hex          expected classifier buffer CLS in act_mem (bit-exact, for simulation)
    golden.txt           expected class / score of that frame (bit-exact model of the hardware)
    classes.txt          class id -> name

Execution plan at 224x224 (act_mem = 160 KB = 40960 words):
    stage 1 (row-streamed from the camera, 14 stripes): conv1+ReLU+maxpool -> fire2.squeeze
    stage b (11 stripes of 5 rows): fire2.expand1x1 / expand3x3 -> fire3.squeeze
    fire3.expand (+maxpool) ; fire4.squeeze
    stage c (3 stripes of 9 rows): fire4.expand -> fire5.squeeze
    fire5.expand (+maxpool) ; fire6..fire9 (squeeze, expand1x1, expand3x3) ; classifier conv
    head: argmax of the per-class sums of the classifier maps (= global average pool + argmax)

Usage:  python3 scripts/compile_squeezenet.py [--image IMG] [--flash-base 0x0] [--out DIR]
Needs numpy and pillow only.
"""
import argparse
import os
import sys

import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# ---------------------------------------------------------------- SoC constants
ACT_WORDS = 40960
WSRAM_WORDS = 8192
MAX_JOBS = 128
CSR, DESC = 0xA000_0000, 0xA001_0000
ACT_AXI = 0x6000_0000
CAM_W, CAM_H, CROP = 320, 240, 224
X0, Y0 = (CAM_W - CROP) // 2, (CAM_H - CROP) // 2
ROWB = 3 * CROP                                   # bytes of a row-planar camera row
ADV, HALO, SLOTS = 16, 3, 3                       # camera stripe geometry (4 pool rows / stripe)
SLOT_BYTES = (ADV + HALO) * ROWB
Z = -128                                          # zero point of every ReLU output (int8)
ACC_MIN, ACC_MAX = -(1 << 23), (1 << 23) - 1      # 24-bit PE accumulator


# =============================================================================
#  weights.txt
# =============================================================================
def parse_weights(path):
    lines = open(path).read().splitlines()
    layers, i = [], 0
    while i < len(lines):
        ln = lines[i].strip()
        if ln.startswith("LAYER"):
            parts = ln.split()
            L = {"idx": int(parts[1]), "type": parts[2], "name": parts[3] if len(parts) > 3 else ""}
            i += 1
            while not lines[i].strip().startswith("END"):
                t = lines[i].split()
                if t and t[0] == "in_ch":
                    kv = dict(zip(t[0::2], t[1::2]))
                    L.update(in_ch=int(kv["in_ch"]), out_ch=int(kv["out_ch"]),
                             k=int(kv["kernel"].split("x")[0]), stride=int(kv["stride"]),
                             pad=int(kv["pad"]), relu=int(kv["relu"]))
                elif t and t[0] == "out_scale":
                    L["out_zp"] = int(t[3])
                elif t and t[0] == "WEIGHTS":
                    o, c, kh, kw = map(int, t[1:5])
                    w = [list(map(int, lines[i + 1 + r].split())) for r in range(o)]
                    L["w"] = np.array(w, np.int64).reshape(o, c, kh, kw)
                    i += o
                elif t and t[0] in ("BIAS_HW", "MULT", "SHIFT"):
                    L[t[0].lower()] = np.array(list(map(int, lines[i + 1].split())), np.int64)
                    i += 1
                i += 1
            layers.append(L)
        elif ln.startswith("CLASSES"):
            n = int(ln.split()[1])
            classes = [lines[i + 1 + c].split(None, 2)[2] for c in range(n)]
            i += n
        i += 1
    return layers, classes


# =============================================================================
#  bit-exact model of the hardware arithmetic (numpy)
# =============================================================================
def requant(acc, bias, mult, shift, zout, relu=True):
    """rtl/tflite_requantizer.sv, vectorised; acc [O,...], bias/mult/shift [O]"""
    sh = lambda a: a.reshape((-1,) + (1,) * (acc.ndim - 1))
    def s32(v):
        v = v & 0xFFFFFFFF
        return np.where(v >= 1 << 31, v - (1 << 32), v)
    x = s32(acc + sh(bias))
    s = sh(shift)
    x = np.where(s < 0, s32(x << np.maximum(-s, 0)), x)
    ab = x * sh(mult)
    t = ab + np.where(ab >= 0, 1 << 30, 1 - (1 << 30))
    hi = s32(np.where(t >= 0, t >> 31, -((-t) >> 31)))
    sp = np.maximum(s, 0)
    rem = hi & ((1 << sp) - 1)
    thr = (1 << np.maximum(sp - 1, 0)) + (hi < 0)
    r = np.where(s > 0, (hi >> sp) + (rem > thr), hi)
    res = r + zout
    return np.clip(res, zout if relu else -128, 127)


SAT = {"count": 0}


def conv(x, L, pad_val=Z):
    k, s, p = L["k"], L["stride"], L["pad"]
    if p:
        x = np.pad(x, ((0, 0), (p, p), (p, p)), constant_values=pad_val)
    win = np.lib.stride_tricks.sliding_window_view(x, (k, k), axis=(1, 2))[:, ::s, ::s]
    acc = np.einsum("chwij,ocij->ohw", win.astype(np.int64), L["w"])
    SAT["count"] += int(np.count_nonzero((acc < ACC_MIN) | (acc > ACC_MAX)))
    acc = np.clip(acc, ACC_MIN, ACC_MAX)
    return requant(acc, L["bias_hw"], L["mult"], L["shift"], L["out_zp"], bool(L["relu"]))


def maxpool(x):                     # 3x3 / 2, valid windows (sizes here never need ceil padding)
    win = np.lib.stride_tricks.sliding_window_view(x, (3, 3), axis=(1, 2))[:, ::2, ::2]
    return win.max(axis=(3, 4))


def run_model(img_s8, convs):
    """img_s8: [3][224][224] int (pixel - 128).  Returns the classifier maps [33][13][13]."""
    x = maxpool(conv(img_s8, convs[0]))
    for f in range(8):
        sq, e1, e3 = convs[1 + 3 * f: 4 + 3 * f]
        s_ = conv(x, sq)
        x = np.concatenate([conv(s_, e1), conv(s_, e3)])
        if f in (1, 3):
            x = maxpool(x)
    return conv(x, convs[25])


# =============================================================================
#  camera emulation (same as ml/finetune_squeezenet.py and the SoC front end)
# =============================================================================
def camera_frame(path):
    img = Image.open(path).convert("RGB")
    w, h = img.size
    s = max(CAM_W / w, CAM_H / h)
    img = img.resize((max(CAM_W, round(w * s)), max(CAM_H, round(h * s))), Image.BILINEAR)
    w, h = img.size
    l, t = (w - CAM_W) // 2, (h - CAM_H) // 2
    a = np.asarray(img.crop((l, t, l + CAM_W, t + CAM_H)), np.uint16)
    return ((a[..., 0] >> 3) << 11) | ((a[..., 1] >> 2) << 5) | (a[..., 2] >> 3)


def rgb888(p565):
    r, g, b = (p565 >> 11) & 31, (p565 >> 5) & 63, p565 & 31
    return np.stack([(r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2)]).astype(np.int64)


# =============================================================================
#  feature-map buffers in act_mem (word addresses)
# =============================================================================
class Buf:
    """C channel frames of H rows; wpr data words per row.  padded: one border word left/right
    and one border row top/bottom (for 3x3/pad-1 consumers)."""
    def __init__(self, name, base, C, H, W, padded=False, rows=None):
        self.name, self.base, self.C, self.H, self.W, self.padded = name, base, C, H, W, padded
        self.wpr = (W + 3) // 4
        self.rs = self.wpr + 2 if padded else self.wpr
        self.rows = rows if rows is not None else H          # rows stored (stripe buffers: < H)
        self.cs = self.rs * (self.rows + 2 if padded else self.rows)
        self.words = self.C * self.cs
        assert 0 <= base and base + self.words <= ACT_WORDS, f"{name} does not fit"

    def __repr__(self):
        return (f"{self.name:5s} words {self.base:5d}..{self.base + self.words - 1:5d}  "
                f"{self.C:3d} ch x {self.rows:2d} rows x {self.W:3d} px  "
                f"{'padded' if self.padded else 'plain '} rs={self.rs} cs={self.cs}")


def check_overlap(live):
    iv = sorted((b.base, b.base + b.words, b.name) for b in live)
    for (a0, a1, an), (b0, b1, bn) in zip(iv, iv[1:]):
        assert a1 <= b0, f"buffers {an} and {bn} overlap"


# =============================================================================
#  compiler
# =============================================================================
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--weights", default=os.path.join(ROOT, "artifacts/squeezenet1_1_custom/weights.txt"))
    ap.add_argument("--image", default=os.path.join(ROOT, "artifacts/eval_images/11_coffee_mug/00.jpg"))
    ap.add_argument("--flash-base", type=lambda v: int(v, 0), default=0,
                    help="byte offset of the weights in the flash (e.g. 0x400000 behind a bitstream)")
    ap.add_argument("--out", default=os.path.join(ROOT, "build/sqz_custom"))
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)

    layers, classes = parse_weights(a.weights)
    convs = [L for L in layers if L["type"] == "CONV"]
    assert len(convs) == 26 and len(classes) <= 128
    NCLS = len(classes)

    # ------------------------------------------------ weight blobs -> flash
    flash = bytearray()
    blob = {}                                      # conv index -> (flash byte offset, k, npass, words)
    for ci, L in enumerate(convs):
        O = L["w"].shape[0]
        Op = (O + 3) // 4 * 4                      # output channels padded to whole passes
        k = L["w"][0].size
        w = np.zeros((Op, k), np.int64); w[:O] = L["w"].reshape(O, k)
        bias = np.zeros(Op, np.int64); bias[:O] = L["bias_hw"]
        mult = np.zeros(Op, np.int64); mult[:O] = L["mult"]
        shift = np.zeros(Op, np.int64); shift[:O] = L["shift"]
        words = []
        for o in range(0, Op, 4):
            for t in range(k):
                words.append(sum((int(w[o + j, t]) & 0xFF) << (8 * j) for j in range(4)))
            for arr in (bias, mult, shift):
                words += [int(v) & 0xFFFFFFFF for v in arr[o:o + 4]]
        while len(flash) % 256:                    # blobs start on a flash page
            flash.append(0xFF)
        blob[ci] = (a.flash_base + len(flash), k, Op // 4, len(words))
        for v in words:
            flash += int(v & 0xFFFFFFFF).to_bytes(4, "little")

    # ------------------------------------------------ job builder
    jobs, notes = [], []

    def job(ci, *, base, chstep, ystep, ntx, nty, out, oy0=0, oc_off=0, valid_w=0,
            pool=False, wait_rows=0, consume=0, fill=False, nch=None, nky=None):
        L = convs[ci]
        src, k, npass, nwords = blob[ci]
        kk, s = L["k"], L["stride"]
        ppl = 0 if npass * (k + 12) <= WSRAM_WORDS else WSRAM_WORDS // (k + 12)
        pyr = nty if pool else 0
        d = [((npass & 0x7F) << 24) | (s << 16) | ((1 << kk) - 1),
             base, chstep, ystep, L["in_ch"] if nch is None else nch, kk if nky is None else nky,
             3 * s + kk - 1, 4 * s, s * ystep, ntx, nty, ntx * nty,
             (L["relu"] << 17) | (int(pool) << 16) | (ntx if pool else 0),
             ((1 << 20) | (2 << 16) | pyr) if pool else 0,
             src, (k << 16) | (nwords & 0xFFFF),
             out.base + oy0 * out.rs, out.cs, (out.wpr << 16) | out.rs,
             (int(out.padded) << 16) | oc_off, (out.H << 16) | valid_w,
             ((npass & 0xFF) << 16) | ((L["out_zp"] & 0xFF) << 8) | ppl,
             out.C if fill else 0, (1 if wait_rows else 0) | (consume << 1), wait_rows]
        jobs.append(d + [0] * (32 - len(d)))
        notes.append(f"job {len(jobs) - 1:3d}: {L['name']:28s} k={k:4d} passes={npass:3d} "
                     f"rows {oy0:2d}+{nty:<2d} -> {out.name}{' +pool' if pool else ''}"
                     f"{f' oc_off {oc_off}' if oc_off else ''}{f' wait cam {wait_rows}' if wait_rows else ''}"
                     f"{' fill' if fill else ''}{f' (weights in {npass // ppl + (npass % ppl > 0)} loads)' if ppl else ''}")

    def rd_1x1(b, oy0):          # element address of pixel (oy0, 0) for a 1x1 consumer
        return 4 * b.base + ((oy0 + 1) * b.rs + 1) * 4 if b.padded else 4 * b.base + oy0 * b.rs * 4

    def rd_3x3(b, oy0):          # top-left of the 3x3/pad-1 window of output (oy0, 0)
        assert b.padded
        return 4 * b.base + oy0 * b.rs * 4 + 3

    def fire_full(f, sq_in, sq_out, cat_out, pool=False):
        """squeeze (layer-by-layer) is done by the caller; expand1x1 + expand3x3 over all rows."""
        e1, e3 = 2 + 3 * (f - 2), 3 + 3 * (f - 2)
        H, W = sq_out.H, sq_out.W
        ntx = (W + 3) // 4
        if pool:
            ntx += ntx % 2                         # stride-2 pooling pairs x chunks
        for ci, oc in ((e1, 0), (e3, convs[e1]["out_ch"])):
            k3 = convs[ci]["k"] == 3
            job(ci, base=rd_3x3(sq_out, 0) if k3 else rd_1x1(sq_out, 0), chstep=4 * sq_out.cs,
                ystep=4 * sq_out.rs, ntx=ntx, nty=H, out=cat_out, oc_off=oc,
                valid_w=cat_out.W, pool=pool)

    def squeeze_full(ci, src, dst):
        job(ci, base=rd_1x1(src, 0), chstep=4 * src.cs, ystep=4 * src.rs, ntx=src.wpr, nty=src.H,
            out=dst, valid_w=dst.W, fill=dst.padded)

    plan = []
    # ------------------------------------------------ stage 1: camera -> conv1 -> pool -> fire2.squeeze
    NP = 4
    cam = Buf("CAM", 0, 1, SLOTS * (ADV + HALO), CROP * 3)        # 3 slots, row-planar (bookkeeping)
    pool1 = Buf("POOL1", 9600, 64, 55, 55, rows=NP)
    S2 = Buf("S2", ACT_WORDS - 16 * 57 * 16, 16, 55, 55, padded=True)
    check_overlap([cam, pool1, S2]); plan += [cam, pool1, S2]
    for st in range((55 + NP - 1) // NP):
        n = min(NP, 55 - st * NP)
        job(0, base=(st % SLOTS) * SLOT_BYTES, chstep=CROP, ystep=ROWB, ntx=28, nty=2 * n + 1,
            out=pool1, valid_w=55, pool=True, wait_rows=min(st * ADV + 4 * n + 3, CROP), consume=1)
        job(1, base=4 * pool1.base, chstep=4 * pool1.cs, ystep=4 * pool1.rs, ntx=14, nty=n,
            out=S2, oy0=st * NP, valid_w=55, fill=(st == 0))

    # ------------------------------------------------ stage b: fire2.expand -> fire3.squeeze (5-row stripes)
    S3 = Buf("S3", 0, 16, 55, 55, padded=True)
    E2 = Buf("E2", S3.base + S3.words, 128, 55, 55, rows=5)
    check_overlap([S2, S3, E2]); plan += [S3, E2]
    for st in range(11):
        oy0 = 5 * st
        job(2, base=rd_1x1(S2, oy0), chstep=4 * S2.cs, ystep=4 * S2.rs, ntx=14, nty=5, out=E2, valid_w=55)
        job(3, base=rd_3x3(S2, oy0), chstep=4 * S2.cs, ystep=4 * S2.rs, ntx=14, nty=5, out=E2,
            oc_off=64, valid_w=55)
        job(4, base=4 * E2.base, chstep=4 * E2.cs, ystep=4 * E2.rs, ntx=14, nty=5, out=S3, oy0=oy0,
            valid_w=55, fill=(st == 0))

    # ------------------------------------------------ fire3.expand + pool ; fire4.squeeze
    P3 = Buf("P3", S3.base + S3.words, 128, 27, 27)
    check_overlap([S3, P3]); plan.append(P3)
    fire_full(3, None, S3, P3, pool=True)
    S4 = Buf("S4", 0, 32, 27, 27, padded=True)
    check_overlap([P3, S4]); plan.append(S4)
    squeeze_full(7, P3, S4)

    # ------------------------------------------------ stage c: fire4.expand -> fire5.squeeze (9-row stripes)
    E4 = Buf("E4", S4.base + S4.words, 256, 27, 27, rows=9)
    S5 = Buf("S5", E4.base + E4.words, 32, 27, 27, padded=True)
    check_overlap([S4, E4, S5]); plan += [E4, S5]
    for st in range(3):
        oy0 = 9 * st
        job(8, base=rd_1x1(S4, oy0), chstep=4 * S4.cs, ystep=4 * S4.rs, ntx=7, nty=9, out=E4, valid_w=27)
        job(9, base=rd_3x3(S4, oy0), chstep=4 * S4.cs, ystep=4 * S4.rs, ntx=7, nty=9, out=E4,
            oc_off=128, valid_w=27)
        job(10, base=4 * E4.base, chstep=4 * E4.cs, ystep=4 * E4.rs, ntx=7, nty=9, out=S5, oy0=oy0,
            valid_w=27, fill=(st == 0))

    # ------------------------------------------------ fire5.expand + pool ; fire6..9 ; classifier
    P5 = Buf("P5", 0, 256, 13, 13)
    check_overlap([S5, P5]); plan.append(P5)
    fire_full(5, None, S5, P5, pool=True)
    cur = P5
    places = {6: (13312, 17632), 7: (0, 20992), 8: (0, 5760), 9: (0, 5760)}   # (S, C) word bases
    for f in (6, 7, 8, 9):
        sqc = 1 + 3 * (f - 2)                      # conv index of fire f squeeze
        Cs = convs[sqc]["out_ch"]
        Ce = convs[sqc + 1]["out_ch"] + convs[sqc + 2]["out_ch"]
        S = Buf(f"S{f}", places[f][0], Cs, 13, 13, padded=True)
        C = Buf(f"C{f}", places[f][1], Ce, 13, 13)
        check_overlap([cur, S]); squeeze_full(sqc, cur, S)
        check_overlap([S, C]); fire_full(f, None, S, C)
        plan += [S, C]
        cur = C
    CLS = Buf("CLS", 32384, (NCLS + 3) // 4 * 4, 13, 13)
    check_overlap([cur, CLS]); plan.append(CLS)
    job(25, base=rd_1x1(cur, 0), chstep=4 * cur.cs, ystep=4 * cur.rs, ntx=4, nty=13, out=CLS, valid_w=13)
    assert len(jobs) <= MAX_JOBS, len(jobs)

    # ------------------------------------------------ boot program (what the FPGA block sends over SPI)
    boot = [(CSR + 0x40, (CAM_H << 16) | CAM_W), (CSR + 0x44, (Y0 << 16) | X0),
            (CSR + 0x48, (CROP << 16) | CROP), (CSR + 0x4C, 0), (CSR + 0x50, ACT_AXI),
            (CSR + 0x54, SLOT_BYTES), (CSR + 0x58, (SLOTS << 24) | (HALO << 16) | ADV),
            (CSR + 0x5C, ROWB), (CSR + 0x18, (CLS.cs << 16) | NCLS),
            (CSR + 0x1C, ACT_AXI + 4 * CLS.base), (CSR + 0x20, 1)]
    for j, d in enumerate(jobs):
        boot += [(DESC + 128 * j + 4 * w, d[w]) for w in range(25)]
    boot.append((CSR + 0x00, len(jobs)))                     # START (re-sent for every new frame)

    # ------------------------------------------------ golden on the test image
    frame = camera_frame(a.image)
    img = rgb888(frame[Y0:Y0 + CROP, X0:X0 + CROP]) - 128
    cls_maps = run_model(img, convs)                          # [33][13][13]
    sums = cls_maps.reshape(NCLS, -1).sum(axis=1) + 3 * 13 * Z  # + the 3 masked px per row (HW layout)
    pred = int(np.argmax(sums))

    # ------------------------------------------------ files
    def w(name, text):
        with open(os.path.join(a.out, name), "w") as f:
            f.write(text)

    open(os.path.join(a.out, "flash_image.bin"), "wb").write(bytes(flash))
    ihex = [":02000004%04X%02X" % ((a.flash_base >> 16) & 0xFFFF,
            (-(2 + 4 + ((a.flash_base >> 24) & 0xFF) + ((a.flash_base >> 16) & 0xFF))) & 0xFF)]
    upper = a.flash_base >> 16
    for off in range(0, len(flash), 16):
        addr = a.flash_base + off
        if addr >> 16 != upper:
            upper = addr >> 16
            ihex.append(":02000004%04X%02X" % (upper, (-(2 + 4 + (upper >> 8) + (upper & 0xFF))) & 0xFF))
        chunk = flash[off:off + 16]
        rec = [len(chunk), (addr >> 8) & 0xFF, addr & 0xFF, 0] + list(chunk)
        ihex.append(":" + "".join(f"{b:02X}" for b in rec) + f"{(-sum(rec)) & 0xFF:02X}")
    ihex.append(":00000001FF")
    w("flash_image.hex", "\n".join(ihex) + "\n")
    w("flash_sim.hex", f"@{a.flash_base:x}\n" + "".join(f"{b:02x}\n" for b in flash))
    w("boot_rom.hex", "".join(f"{ad:08x}{da & 0xFFFFFFFF:08x}\n" for ad, da in boot) + "ffffffffffffffff\n")
    w("boot_rom.mem", "".join(f"{ad:08x}{da & 0xFFFFFFFF:08x}\n" for ad, da in boot) + "ffffffffffffffff\n")
    w("frame565.hex", "".join(f"{v:04x}\n" for v in frame.ravel()))
    cls_buf = np.full((CLS.C, 13, 4 * CLS.wpr), Z, np.int64)          # HW layout incl. masked px
    cls_buf[:NCLS, :, :13] = cls_maps
    b = cls_buf.reshape(CLS.C, 13, -1, 4) & 0xFF
    w("cls_exp.hex", "".join(f"{int(v):08x}\n" for v in
                             (b[..., 0] | (b[..., 1] << 8) | (b[..., 2] << 16) | (b[..., 3] << 24)).ravel()))
    w("classes.txt", "".join(f"{i} {c}\n" for i, c in enumerate(classes)))
    top = np.argsort(-sums)[:5]
    w("golden.txt", f"image {a.image}\nclass {pred} {classes[pred]}\nscore {int(sums[pred])}\n"
      + "top5 " + " ".join(f"{int(c)}:{classes[c]}:{int(sums[c])}" for c in top) + "\n"
      + f"jobs {len(jobs)}\nboot_entries {len(boot)}\nflash_bytes {len(flash)}\nflash_base 0x{a.flash_base:x}\n"
      + f"acc_saturations {SAT['count']}\ncls_base_word {CLS.base}\ncls_words {CLS.words}\n")
    w("job_list.txt", "Memory plan (act_mem words):\n" + "\n".join(f"  {b}" for b in plan)
      + "\n\nJobs:\n" + "\n".join(notes) + "\n")
    print(f"{len(jobs)} jobs, {len(boot)} boot writes, flash {len(flash)} bytes at 0x{a.flash_base:x}")
    print(f"golden: class {pred} ({classes[pred]}) score {int(sums[pred])}; "
          f"top5 {[classes[c] for c in top]}; accumulator saturations {SAT['count']}")
    print(f"wrote {a.out}")


if __name__ == "__main__":
    sys.exit(main())
