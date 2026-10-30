#!/usr/bin/env python3
"""
gen_sqz_fire2.py - stimulus + golden data for tb/tb_system_sqz.sv

Runs SqueezeNet-1.1 (artifacts/squeezenet1_1.onnx, QDQ uint8/int8) on artifacts/dog.jpg and
produces everything the full-SoC testbench needs for the first four accelerator layers:

    L0  features.0 conv 3x3/s2 (3->64) + ReLU + MaxPool 3x3/s2      A -> B
    L1  fire2 squeeze  1x1 (64->16)  + ReLU   -> padded frame         B -> A
    L2  fire2 expand1x1 (16->64)     + ReLU   -> concat ch 0..63      A -> B
    L3  fire2 expand3x3 (16->64,p1)  + ReLU   -> concat ch 64..127    A -> B
(A = act_mem words 0.., B = words 20480..; descriptor addresses are absolute.  The input
patch reaches A through cam_frontend in RAW mode; L0 waits for all its rows.)

The SoC SRAM cannot hold the 224x224 maps, so one top-left patch is run (input 3x65x65,
conv1 32x32, pool / fire2 16x16).  Features exercised on purpose:
    * weight chunks set by the descriptor (L0: 5+5+5+1 passes, L1: 3+1)
    * L1 writes a padded frame (1-word / 1-row z_out border, filled by out_writer) with
      valid_w = 15: column 15 is forced to z_out, the way the last tile column of a
      55-wide map is
    * L3 reads that frame with 3x3 / pad 1, L2 and L3 concatenate through oc_off
    * K = 144 for L3
Golden data: a bit-exact model of the HW (full 16x16) and the ONNX tensors on the part of
the patch that does not depend on pixels outside it (pool/squeeze 15x15, fire2 14x14).

Outputs (hex/sqz_fire2/): frame.hex ifmap_exp.hex flash.hex desc.hex
    l0_model.hex l0_onnx.hex   pool output   (bank B, 64 x 16 x 4 words)
    l1_model.hex l1_onnx.hex   squeeze frame (bank A, 16 x 18 x 6 words, border included)
    l3_model.hex l3_onnx.hex   concat output (bank B, 128 x 16 x 4 words)
    params.txt

Usage:  python3 scripts/gen_sqz_fire2.py      (needs numpy, onnx, onnxruntime, pillow)
"""
import os
import sys

import numpy as np
import onnx
import onnxruntime as ort
from onnx import numpy_helper
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODEL = os.path.join(ROOT, "artifacts", "squeezenet1_1.onnx")
IMAGE = os.path.join(ROOT, "artifacts", "dog.jpg")
OUT = os.path.join(ROOT, "hex", "sqz_fire2")

PH = PW = 65                  # input patch
CH = CW = 32                  # conv1 output
P = 16                        # pool / fire2 spatial size
DVP_W, DVP_H = 160, 40        # DVP frame (2 bytes / pixel) >= 3*65*65 bytes
WSRAM_WORDS = 8192            # 32 KB weight SRAM
FLASH = {0: 0x0000, 1: 0x1000, 2: 0x2000, 3: 0x3000}
# squeeze output frame (padded): row stride 6 words = border + 4 data + border
SQ_RS, SQ_ROWS = 6, P + 2
SQ_CS = SQ_RS * SQ_ROWS
SQ_VALID_W = 15
# act_mem plan (absolute word addresses; the old bank A/B windows)
BANK_A, BANK_B = 0, 20480


# ---- TFLite-style fixed point (mirror rtl/tflite_requantizer.sv) -----------------------
def quantize_multiplier(m):
    """real m>0 -> (M_fixed int32, shift_val) with shift_val>0 = right shift (HW convention)."""
    if m == 0:
        return 0, 0
    mant, exp = np.frexp(m)
    q = int(round(mant * (1 << 31)))
    if q == (1 << 31):
        q //= 2
        exp += 1
    return q, -int(exp)


def hw_requant(acc, bias, mfix, shift, zout, relu):
    """bit-exact model of tflite_requantizer (int32 wrap semantics)."""
    def s32(v):
        v &= 0xFFFFFFFF
        return v - (1 << 32) if v & 0x80000000 else v
    x = s32(acc + bias)
    xs = s32(x << (-shift)) if shift < 0 else x
    ab = xs * mfix
    nudge = (1 << 30) if ab >= 0 else (1 - (1 << 30))
    t = ab + nudge
    hi = s32(t >> 31) if t >= 0 else s32(-((-t) >> 31))
    if shift > 0:
        rem = (hi & ((1 << shift) - 1))
        thr = (1 << (shift - 1)) + (1 if hi < 0 else 0)
        r = (hi >> shift) + (1 if rem > thr else 0)
    else:
        r = hi
    res = r + zout
    lo = zout if relu else -128
    return max(lo, min(127, res))


def conv_acc(a, w, stride):
    """a: [C][H][W] int (already padded as the HW sees it), w: [O][C][KH][KW] -> int64 acc."""
    o, c, kh, kw = w.shape
    oh = (a.shape[1] - kh) // stride + 1
    ow = (a.shape[2] - kw) // stride + 1
    acc = np.zeros((o, oh, ow), np.int64)
    for ky in range(kh):
        for kx in range(kw):
            sl = a[:, ky:ky + stride * oh:stride, kx:kx + stride * ow:stride].astype(np.int64)
            acc += np.einsum("chw,oc->ohw", sl, w[:, :, ky, kx].astype(np.int64))
    return acc


def requant_map(acc, p):
    bias, mult, shift, z = p
    out = np.empty(acc.shape, np.int32)
    for o in range(acc.shape[0]):
        for idx, v in np.ndenumerate(acc[o]):
            out[(o,) + idx] = hw_requant(int(v), int(bias[o]), int(mult[o]), int(shift[o]), z, True)
    return out


def main():
    os.makedirs(OUT, exist_ok=True)
    model = onnx.load(MODEL)
    init = {t.name: numpy_helper.to_array(t) for t in model.graph.initializer}
    qnode = {n.output[0]: n for n in model.graph.node if n.op_type == "QuantizeLinear"}
    qbyin = {n.input[0]: n for n in model.graph.node if n.op_type == "QuantizeLinear"}

    def act_q(name):                       # (scale, zp) of a quantized activation tensor
        n = qnode[name]
        return float(init[n.input[1]]), int(init[n.input[2]])

    def qweight(prefix):
        n = qbyin[prefix + ".weight"]
        wf, sc, zp = init[n.input[0]], init[n.input[1]], init[n.input[2]].astype(np.int32)
        q = np.clip(np.round(wf / sc.reshape(-1, 1, 1, 1)) + zp.reshape(-1, 1, 1, 1), -128, 127)
        return q.astype(np.int32), sc.astype(np.float64), init[prefix + ".bias_q"].astype(np.int64)

    # ---- image -> uint8 NCHW (resize 256 + centre crop 224) ----
    img = Image.open(IMAGE).convert("RGB")
    w, h = img.size
    s = 256 / min(w, h)
    img = img.resize((round(w * s), round(h * s)), Image.BILINEAR)
    w, h = img.size
    l, t = (w - 224) // 2, (h - 224) // 2
    x_u8 = np.asarray(img.crop((l, t, l + 224, t + 224)), np.uint8).transpose(2, 0, 1)[None].copy()

    # ---- ONNX run with intermediate taps ----
    taps = ["div_q", "max_pool2d_q", "relu_1_q", "cat_q"]
    for name in taps:
        model.graph.output.append(onnx.helper.make_empty_tensor_value_info(name))
    so = ort.SessionOptions()
    so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
    sess = ort.InferenceSession(model.SerializeToString(), so, providers=["CPUExecutionProvider"])
    outs = dict(zip([o.name for o in sess.get_outputs()], sess.run(None, {"image_tensor": x_u8})))
    div_q, pool_q, sq_q, cat_q = (outs[n][0] for n in taps)
    print(f"ONNX top-1 class on dog.jpg: {int(np.argmax(outs[sess.get_outputs()[0].name]))}")

    # ---- per-layer integer parameters (HW works on int8 = uint8 - 128) ----
    def layer_params(wq, bq, sw, s_in, z_in, s_out, z_out):
        wsum = wq.reshape(wq.shape[0], -1).sum(axis=1)
        bias = (bq - (z_in - 128) * wsum).astype(np.int64)
        mult, shift = zip(*[quantize_multiplier(s_in * sw[c] / s_out) for c in range(wq.shape[0])])
        return bias, np.array(mult), np.array(shift), z_out - 128

    s_div, z_div = act_q("div_q")
    s_r0, z_r0 = act_q("relu_q")
    s_r1, z_r1 = act_q("relu_1_q")
    s_r2, z_r2 = act_q("relu_2_q")
    s_r3, z_r3 = act_q("relu_3_q")
    assert (s_r2, z_r2) == (s_r3, z_r3) == act_q("cat_q"), "concat inputs must share one scale"
    W, PR = {}, {}
    for i, (pref, sin, zin, sout, zout) in enumerate([
            ("net.features.0", s_div, z_div, s_r0, z_r0),
            ("net.features.3.squeeze", s_r0, z_r0, s_r1, z_r1),
            ("net.features.3.expand1x1", s_r1, z_r1, s_r2, z_r2),
            ("net.features.3.expand3x3", s_r1, z_r1, s_r2, z_r2)]):
        wq, sw, bq = qweight(pref)
        W[i] = wq
        PR[i] = layer_params(wq, bq, sw, sin, zin, sout, zout)
    Z = PR[0][3]

    # ---- bit-exact HW model ----
    a0 = div_q[:, :PH, :PW].astype(np.int32) - 128
    c0 = requant_map(conv_acc(a0, W[0], 2), PR[0])                       # 64 x 32 x 32
    pad = np.full((64, CH + 1, CW + 1), Z, np.int32)
    pad[:, :CH, :CW] = c0
    pool_m = np.array([[[pad[c, 2*i:2*i+3, 2*j:2*j+3].max() for j in range(P)] for i in range(P)]
                       for c in range(64)], np.int32)
    sq_m = requant_map(conv_acc(pool_m, W[1], 1), PR[1])                 # 16 x 16 x 16
    sq_m[:, :, SQ_VALID_W:] = PR[1][3]                                   # valid_w masking
    e1_m = requant_map(conv_acc(sq_m, W[2], 1), PR[2])
    sq_pad = np.full((16, P + 2, P + 2), PR[1][3], np.int32)
    sq_pad[:, 1:P+1, 1:P+1] = sq_m
    e3_m = requant_map(conv_acc(sq_pad, W[3], 1), PR[3])
    cat_m = np.concatenate([e1_m, e3_m])                                 # 128 x 16 x 16

    pool_o = pool_q[:, :P, :P].astype(np.int32) - 128
    sq_o = sq_q[:, :P, :P].astype(np.int32) - 128
    cat_o = cat_q[:, :P, :P].astype(np.int32) - 128
    for name, mdl, gold, n in (("L0 pool", pool_m, pool_o, 15), ("L1 squeeze", sq_m, sq_o, 15),
                               ("fire2 concat", cat_m, cat_o, 14)):
        d = np.abs(mdl[:, :n, :n] - gold[:, :n, :n])
        print(f"{name:12s}: HW-model vs ONNX on {n}x{n}: max|diff|={d.max()}  "
              f"mismatches={np.count_nonzero(d)}/{d.size}")

    # ---- files ----
    def wr_words(path, words):
        with open(path, "w") as f:
            f.writelines(f"{int(v) & 0xFFFFFFFF:08x}\n" for v in words)

    def pack(arr):                       # [C][H][W4*4] int8 -> words, little-endian
        b = arr.reshape(arr.shape[0], arr.shape[1], -1, 4).astype(np.int64) & 0xFF
        return (b[..., 0] | (b[..., 1] << 8) | (b[..., 2] << 16) | (b[..., 3] << 24)).ravel()

    flat_u8 = div_q[:, :PH, :PW].ravel()
    frame = np.zeros(DVP_W * DVP_H * 2, np.uint8)
    frame[:flat_u8.size] = flat_u8
    with open(os.path.join(OUT, "frame.hex"), "w") as f:
        f.writelines(f"{b:02x}\n" for b in frame)
    ib = (frame.astype(np.int64) ^ 0x80).reshape(-1, 4)
    wr_words(os.path.join(OUT, "ifmap_exp.hex"), ib[:, 0] | (ib[:, 1] << 8) | (ib[:, 2] << 16) | (ib[:, 3] << 24))

    def blob(wq, p):                    # n_passes blocks of (k_len + 12) words
        bias, mult, shift, _ = p
        k = wq.reshape(wq.shape[0], -1)
        words = []
        for o in range(0, wq.shape[0], 4):
            for t in range(k.shape[1]):
                words.append(sum((int(k[o + j, t]) & 0xFF) << (8 * j) for j in range(4)))
            words += [int(v) for v in bias[o:o+4]] + [int(v) for v in mult[o:o+4]] + [int(v) for v in shift[o:o+4]]
        return words

    flash = np.full(0x6000, 0xFF, np.uint8)
    blobs = {}
    for i in range(4):
        blobs[i] = blob(W[i], PR[i])
        for j, v in enumerate(blobs[i]):
            flash[FLASH[i] + 4*j: FLASH[i] + 4*j + 4] = [(v >> (8*b)) & 0xFF for b in range(4)]
    with open(os.path.join(OUT, "flash.hex"), "w") as f:
        f.writelines(f"{b:02x}\n" for b in flash)

    def desc(i, flip, stride, kpat, base, chstep, ystep, nch, nky, last, xts, yts, ntx, nty,
             mp=0, pxc=0, pyr=0, pst=0, nopad=0, ppl=0,
             obase=0, ocs=0, ors=0, owpr=0, ooff=0, opad=0, ovalid=0, orows=0, fill=0,
             wait_rows=0):
        k = W[i].shape[1] * W[i].shape[2] * W[i].shape[3]
        npass = W[i].shape[0] // 4
        assert k <= 1023 and (ppl or npass) * (k + 12) <= WSRAM_WORDS
        d = [(flip << 31) | ((npass & 0x7F) << 24) | (stride << 16) | kpat,
             base, chstep, ystep, nch, nky, last, xts, yts, ntx, nty, ntx * nty,
             (1 << 17) | (mp << 16) | pxc, (nopad << 20) | (pst << 16) | pyr,
             FLASH[i], (k << 16) | (len(blobs[i]) & 0xFFFF),
             obase, ocs, (owpr << 16) | ors, (opad << 16) | ooff, (orows << 16) | ovalid,
             ((npass & 0xFF) << 16) | ((PR[i][3] & 0xFF) << 8) | ppl, fill,
             1 if wait_rows else 0, wait_rows]
        return d + [0] * (32 - len(d))

    sq_el = SQ_RS * 4                    # padded squeeze frame: elements per row / channel
    descs = (
        # L0: camera image at A (raw mode, one stripe) -> pool at B; waits for all DVP rows
        desc(0, 1, 2, 0b111, 4 * BANK_A, PH * PW, PW, 3, 3, 8, 8, 2 * PW, CW // 4, CH,
             mp=1, pxc=CW // 4, pyr=CH, pst=2, nopad=1, ppl=5,
             obase=BANK_B, ocs=P * P // 4, ors=P // 4, owpr=P // 4, orows=P, wait_rows=DVP_H)
        + desc(1, 1, 1, 0b1, 4 * BANK_B, P * P, P, 64, 1, 3, 4, P, P // 4, P, ppl=3,
               obase=BANK_A, ocs=SQ_CS, ors=SQ_RS, owpr=P // 4, opad=1, ovalid=SQ_VALID_W, orows=P, fill=16)
        + desc(2, 0, 1, 0b1, 4 * BANK_A + sq_el + 4, SQ_CS * 4, sq_el, 16, 1, 3, 4, sq_el, P // 4, P,
               obase=BANK_B, ocs=P * P // 4, ors=P // 4, owpr=P // 4, orows=P)
        + desc(3, 1, 1, 0b111, 4 * BANK_A + 3, SQ_CS * 4, sq_el, 16, 3, 5, 4, sq_el, P // 4, P,
               obase=BANK_B, ocs=P * P // 4, ors=P // 4, owpr=P // 4, ooff=64, orows=P))
    wr_words(os.path.join(OUT, "desc.hex"), descs)

    sq_frame = np.full((16, SQ_ROWS, SQ_RS * 4), PR[1][3], np.int32)    # border = z_out
    sq_frame[:, 1:P+1, 4:4+P] = sq_m
    sq_frame_o = sq_frame.copy()
    sq_frame_o[:, 1:P+1, 4:4+P] = sq_o
    wr_words(os.path.join(OUT, "l0_model.hex"), pack(pool_m))
    wr_words(os.path.join(OUT, "l0_onnx.hex"), pack(pool_o))
    wr_words(os.path.join(OUT, "l1_model.hex"), pack(sq_frame))
    wr_words(os.path.join(OUT, "l1_onnx.hex"), pack(sq_frame_o))
    wr_words(os.path.join(OUT, "l3_model.hex"), pack(cat_m))
    wr_words(os.path.join(OUT, "l3_onnx.hex"), pack(cat_o))

    with open(os.path.join(OUT, "params.txt"), "w") as f:
        f.write(f"image {IMAGE}\n")
        for i in range(4):
            f.write(f"L{i}: k={W[i].shape[1]*W[i].shape[2]*W[i].shape[3]} oc={W[i].shape[0]} "
                    f"blob {len(blobs[i])} words @flash 0x{FLASH[i]:x} z_out {PR[i][3]}\n")
            f.write("  desc: " + " ".join(f"{v:08x}" for v in descs[32*i:32*i+25]) + "\n")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    sys.exit(main())
