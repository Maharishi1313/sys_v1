#!/usr/bin/env python3
"""
gen_cam_stage1.py - stimulus + golden data for tb/tb_system_cam.sv (Option A, 224x224)

Full-resolution row-streaming of SqueezeNet-1.1 stage 1 straight from the camera:
    OV7670-style 320x240 RGB565 frame (artifacts/dog.jpg)  --DVP pins-->
    cam_frontend: centre crop 224x224 at (48, 8), RGB565 -> RGB888 -> int8, row-planar,
                  16-row stripes + 3 halo rows into 3 slots
    per stripe s (14 stripes, 4 pool rows each, the last 3):
      job 2s   : conv1 3x3/s2 (3->64, normalisation folded in) + ReLU + maxpool 3x3/s2
                 on 2n+1 conv rows -> pool stripe buffer        (waits for camera rows)
      job 2s+1 : fire2 squeeze 1x1 (64->16) + ReLU -> rows 4s.. of the padded 55x55 map
The jobs run while the frame is still arriving; the result must equal the full-image
computation exactly.

conv1 here is the original model's conv1 with the input normalisation folded in
(conv1 has no padding, so the fold is exact in float) and re-quantised per channel; the
network input is the raw camera byte (scale 1, zero point 0).  That is exactly what the
fine-tuned model will look like (ml/finetune_squeezenet.py).  The ONNX comparison uses
the original (unfolded) model on the same cropped camera image.

Outputs (hex/cam_stage1/): frame565.hex crop_exp.hex flash.hex desc.hex
    sq_model.hex sq_onnx.hex (padded squeeze map, 16 x 57 x 16 words)  params.txt
"""
import os
import sys

import numpy as np
import onnx
import onnxruntime as ort
from onnx import numpy_helper
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_sqz_fire2 import quantize_multiplier, conv_acc, requant_map   # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODEL = os.path.join(ROOT, "artifacts", "squeezenet1_1.onnx")
IMAGE = os.path.join(ROOT, "artifacts", "dog.jpg")
OUT = os.path.join(ROOT, "hex", "cam_stage1")

CAM_W, CAM_H, CROP = 320, 240, 224
X0, Y0 = (CAM_W - CROP) // 2, (CAM_H - CROP) // 2       # 48, 8
ROWB = 3 * CROP                                          # 672 bytes per row-planar row
CONV = (CROP - 3) // 2 + 1                               # 111
POOL = (CONV - 3) // 2 + 1                               # 55
NP = 4                                                   # pool rows per stripe
ADV, HALO, SLOTS = 4 * NP, 3, 3                          # camera rows per stripe / halo / slots
SLOT_ROWS = ADV + HALO
SLOT_BYTES = SLOT_ROWS * ROWB
WPR = (POOL + 3) // 4                                    # 14 words per pooled / squeeze row
POOL_BUF = 9600                                          # act_mem word of the pool stripe buffer
SQ_BASE = 13312                                          # act_mem word of the padded squeeze map
SQ_RS, SQ_ROWS = WPR + 2, POOL + 2                       # 16 words, 57 rows
SQ_CS = SQ_RS * SQ_ROWS                                  # 912 words per channel frame
FLASH0, FLASH1 = 0x0000, 0x1000


def camera_frame(path):
    """scale + centre crop to the 4:3 sensor frame, RGB565 (same as ml/finetune_squeezenet.py)"""
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
    return np.stack([(r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2)]).astype(np.uint8)


def main():
    os.makedirs(OUT, exist_ok=True)
    model = onnx.load(MODEL)
    init = {t.name: numpy_helper.to_array(t) for t in model.graph.initializer}
    qnode = {n.output[0]: n for n in model.graph.node if n.op_type == "QuantizeLinear"}
    qbyin = {n.input[0]: n for n in model.graph.node if n.op_type == "QuantizeLinear"}

    def act_q(name):
        n = qnode[name]
        return float(init[n.input[1]]), int(init[n.input[2]])

    frame = camera_frame(IMAGE)                                     # 240 x 320 RGB565
    crop = rgb888(frame[Y0:Y0 + CROP, X0:X0 + CROP])                # 3 x 224 x 224 uint8

    # ---- conv1 with the normalisation folded in, re-quantised (input = raw byte) ----
    mean = init["view"].reshape(3).astype(np.float64)
    std = init["view_1"].reshape(3).astype(np.float64)
    s_img = float(init["image_tensor_scale"])
    w0 = init["net.features.0.weight"].astype(np.float64)
    b0 = (init["net.features.0.bias_q"] * init["net.features.0.bias_scale"]).astype(np.float64)
    w0f = w0 * (s_img / std).reshape(1, 3, 1, 1)
    b0f = b0 - (w0 * (mean / std).reshape(1, 3, 1, 1)).sum(axis=(1, 2, 3))
    sw0 = np.abs(w0f).reshape(64, -1).max(axis=1) / 127.0
    w0q = np.clip(np.round(w0f / sw0.reshape(-1, 1, 1, 1)), -127, 127).astype(np.int32)
    s_relu, z_relu = act_q("relu_q")
    s_r1, z_r1 = act_q("relu_1_q")
    b0q = np.round(b0f / sw0).astype(np.int64)
    zin = -128                                                      # uint8 0 -> int8 -128
    bias0 = b0q - zin * w0q.reshape(64, -1).sum(axis=1)
    m0, sh0 = zip(*[quantize_multiplier(sw0[c] / s_relu) for c in range(64)])
    P0 = (bias0, np.array(m0), np.array(sh0), z_relu - 128)

    n1 = qbyin["net.features.3.squeeze.weight"]
    sw1 = init[n1.input[1]].astype(np.float64)
    w1 = np.clip(np.round(init[n1.input[0]] / sw1.reshape(-1, 1, 1, 1)), -128, 127).astype(np.int32)
    b1 = init["net.features.3.squeeze.bias_q"].astype(np.int64)
    bias1 = b1 - (z_relu - 128) * w1.reshape(16, -1).sum(axis=1)
    m1, sh1 = zip(*[quantize_multiplier(s_relu * sw1[c] / s_r1) for c in range(16)])
    P1 = (bias1, np.array(m1), np.array(sh1), z_r1 - 128)

    # ---- bit-exact model on the full image (what the stripes must reproduce) ----
    a0 = crop.astype(np.int32) - 128
    c0 = requant_map(conv_acc(a0, w0q, 2), P0)                      # 64 x 111 x 111
    pool = np.array([[[c0[c, 2*i:2*i+3, 2*j:2*j+3].max() for j in range(POOL)] for i in range(POOL)]
                     for c in range(64)], np.int32)
    pool_w = np.full((64, POOL, 4 * WPR), P0[3], np.int32)          # col 55 = valid_w mask
    pool_w[:, :, :POOL] = pool
    sq = requant_map(conv_acc(pool_w, w1, 1), P1)                   # 16 x 55 x 56
    sq[:, :, POOL:] = P1[3]
    frame_m = np.full((16, SQ_ROWS, 4 * SQ_RS), P1[3], np.int32)
    frame_m[:, 1:POOL + 1, 4:4 + 4 * WPR] = sq

    # ---- ONNX: original model on the same cropped camera image ----
    model.graph.output.append(onnx.helper.make_empty_tensor_value_info("relu_1_q"))
    so = ort.SessionOptions()
    so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
    sess = ort.InferenceSession(model.SerializeToString(), so, providers=["CPUExecutionProvider"])
    outs = sess.run(None, {"image_tensor": crop[None]})
    sq_o = outs[-1][0].astype(np.int32) - 128
    print(f"ONNX top-1 class on the camera crop: {int(np.argmax(outs[0]))}")
    d = np.abs(sq[:, :, :POOL] - sq_o)
    print(f"squeeze 55x55: HW-model (folded conv1) vs ONNX original: max|diff|={d.max()} "
          f"mean={d.mean():.3f} exact={np.mean(d == 0) * 100:.1f}%  <=1: {np.mean(d <= 1) * 100:.1f}%")
    frame_o = frame_m.copy()
    frame_o[:, 1:POOL + 1, 4:4 + POOL] = sq_o

    # ---- files ----
    def wr(path, words, fmt="08x"):
        with open(os.path.join(OUT, path), "w") as f:
            f.writelines(f"{int(v) & 0xFFFFFFFF:{fmt}}\n" for v in words)

    def pack(arr):
        b = arr.reshape(arr.shape[0], arr.shape[1], -1, 4).astype(np.int64) & 0xFF
        return (b[..., 0] | (b[..., 1] << 8) | (b[..., 2] << 16) | (b[..., 3] << 24)).ravel()

    wr("frame565.hex", frame.ravel(), "04x")
    rows = (crop.transpose(1, 0, 2).reshape(CROP, ROWB).astype(np.int64) ^ 0x80).reshape(CROP, -1, 4)
    wr("crop_exp.hex", (rows[..., 0] | (rows[..., 1] << 8) | (rows[..., 2] << 16) | (rows[..., 3] << 24)).ravel())
    wr("sq_model.hex", pack(frame_m))
    wr("sq_onnx.hex", pack(frame_o))

    def blob(wq, p):
        bias, mult, shift, _ = p
        k = wq.reshape(wq.shape[0], -1)
        words = []
        for o in range(0, wq.shape[0], 4):
            for t in range(k.shape[1]):
                words.append(sum((int(k[o + j, t]) & 0xFF) << (8 * j) for j in range(4)))
            words += [int(v) for v in bias[o:o+4]] + [int(v) for v in mult[o:o+4]] + [int(v) for v in shift[o:o+4]]
        return words
    blobs = {0: blob(w0q, P0), 1: blob(w1, P1)}
    flash = np.full(0x2000, 0xFF, np.uint8)
    for base, bl in ((FLASH0, blobs[0]), (FLASH1, blobs[1])):
        for j, v in enumerate(bl):
            flash[base + 4*j: base + 4*j + 4] = [(v >> (8*b)) & 0xFF for b in range(4)]
    with open(os.path.join(OUT, "flash.hex"), "w") as f:
        f.writelines(f"{b:02x}\n" for b in flash)

    def job(k, npass, stride, kpat, base, chstep, ystep, nch, nky, last, xts, yts, ntx, nty, zout,
            fsrc, nwords, mp=0, pxc=0, pyr=0, obase=0, ocs=0, ors=0, owpr=0, opad=0, ovalid=0,
            orows=0, fill=0, wait=0, consume=0):
        d = [(npass << 24) | (stride << 16) | kpat, base, chstep, ystep, nch, nky, last, xts, yts,
             ntx, nty, ntx * nty, (1 << 17) | (mp << 16) | pxc, ((1 if mp else 0) << 20) | ((2 if mp else 0) << 16) | pyr,
             fsrc, (k << 16) | (nwords & 0xFFFF),
             obase, ocs, (owpr << 16) | ors, opad << 16, (orows << 16) | ovalid,
             ((zout & 0xFF) << 8), fill, (1 if wait else 0) | (consume << 1), wait]
        return d + [0] * (32 - len(d))

    jobs, nstripes = [], (POOL + NP - 1) // NP
    for s in range(nstripes):
        n = min(NP, POOL - s * NP)
        jobs += job(27, 16, 2, 0b111, (s % SLOTS) * SLOT_BYTES, CROP, ROWB, 3, 3, 8, 8, 2 * ROWB,
                    WPR * 2, 2 * n + 1, P0[3], FLASH0, len(blobs[0]),
                    mp=1, pxc=WPR * 2, pyr=2 * n + 1,
                    obase=POOL_BUF, ocs=NP * WPR, ors=WPR, owpr=WPR, ovalid=POOL, orows=n,
                    wait=min(s * ADV + 4 * n + 3, CROP), consume=1)
        jobs += job(64, 4, 1, 0b1, 4 * POOL_BUF, NP * WPR * 4, WPR * 4, 64, 1, 3, 4, WPR * 4, WPR, n,
                    P1[3], FLASH1, len(blobs[1]),
                    obase=SQ_BASE + s * NP * SQ_RS, ocs=SQ_CS, ors=SQ_RS, owpr=WPR, opad=1,
                    ovalid=POOL, orows=POOL, fill=16 if s == 0 else 0)
    wr("desc.hex", jobs)
    assert len(jobs) // 32 <= 64

    with open(os.path.join(OUT, "params.txt"), "w") as f:
        f.write(f"camera {CAM_W}x{CAM_H} RGB565, crop {CROP} at ({X0},{Y0}), row-planar {ROWB} B/row\n"
                f"stripes {nstripes} x {NP} pool rows, camera slots {SLOTS} x {SLOT_ROWS} rows "
                f"({SLOT_BYTES} B) at 0x60000000, adv {ADV} halo {HALO}\n"
                f"pool stripe buffer word {POOL_BUF}, squeeze map word {SQ_BASE} ({16*SQ_CS} words)\n"
                f"jobs {len(jobs)//32}; conv1 blob {len(blobs[0])} words, squeeze blob {len(blobs[1])} words\n")
    print(f"wrote {OUT}: {len(jobs)//32} jobs")


if __name__ == "__main__":
    sys.exit(main())
