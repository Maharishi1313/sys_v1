#!/usr/bin/env python3
"""
make_sqz_custom.py - SqueezeNet-1.1 int8 for the accelerator: normalisation folded into conv1,
classifier cut down to a list of everyday classes, weights dumped layer by layer as text.

Starts from artifacts/squeezenet1_1.onnx (QDQ: int8 per-channel weights, int32 bias, uint8
activations).  That model takes the image as uint8 / 255 and does (x - mean) / std itself
with a Sub + Div.  Here:

1. Input = the signed camera byte  x_s8 = pixel - 128  (int8, scale 1.0, zero point 0).
   SqueezeNet's normalisation  n_c = (pixel/255 - mean_c) / std_c  is rewritten as
       n_c = x_s8 / (255 std_c) + (128 - 255 mean_c) / (255 std_c)
   and folded into conv1 (exact, conv1 has no padding):
       W'[o,c] = W[o,c] / (255 std_c)                       (the 1/std part -> weights)
       b'[o]   = b[o] + sum_{c,ky,kx} W[o,c,ky,kx] (128 - 255 mean_c) / (255 std_c)
                                                             (the mean part -> bias)
   W' is re-quantised per output channel (int8 symmetric), b' to int32 at scale 1.0 * w_scale.
2. Classifier conv (512 -> 1000, 1x1) keeps only the output channels (= weight rows) of
   CLASSES; with per-channel weight scales this is exact for the kept classes.
3. Writes out/  squeezenet1_1_custom.onnx (+ .data), classes.txt, weights.txt and checks
   the new model against the original one, plus an integer-only model that runs from
   weights.txt alone in the HW convention (int8 = uint8 - 128, tflite_requantizer).

Usage:  python3 scripts/make_sqz_custom.py      (needs numpy, onnx, onnxruntime, pillow)
"""
import os
import sys

import numpy as np
import onnx
import onnxruntime as ort
from onnx import helper, numpy_helper, TensorProto
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_sqz_fire2 import quantize_multiplier   # same fixed point as rtl/tflite_requantizer.sv

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODEL = os.path.join(ROOT, "artifacts", "squeezenet1_1.onnx")
LABELS = os.path.join(ROOT, "artifacts", "labels.txt")
IMAGE = os.path.join(ROOT, "artifacts", "dog.jpg")
OUT = os.path.join(ROOT, "artifacts", "squeezenet1_1_custom")

MEAN = np.array([0.485, 0.456, 0.406])
STD = np.array([0.229, 0.224, 0.225])

# ImageNet indices (artifacts/labels.txt line - 1) of the classes to keep, in output order.
CLASSES = [207, 208, 281,                      # golden retriever, Labrador, tabby cat
           409, 531,                           # analog clock, digital watch
           414, 748, 893,                      # backpack, purse, wallet
           418,                                # ballpoint pen
           487, 761,                           # cellular telephone, remote control
           504, 898, 737,                      # coffee mug, water bottle, pop bottle
           508, 620, 664, 673, 851,            # keyboard, laptop, monitor, mouse, television
           545, 846,                           # electric fan, table lamp
           559, 721,                           # folding chair, pillow
           728, 770, 837, 879,                 # plastic bag, running shoe, sunglasses, umbrella
           760, 849,                           # refrigerator, teapot
           671, 817,                           # mountain bike, sports car
           948, 954]                           # Granny Smith apple, banana


def load():
    m = onnx.load(MODEL)
    init = {t.name: numpy_helper.to_array(t) for t in m.graph.initializer}
    return m, init


def set_init(m, name, arr):
    t = numpy_helper.from_array(np.array(arr, copy=True, order="C"), name)
    for i, old in enumerate(m.graph.initializer):
        if old.name == name:
            m.graph.initializer[i].CopyFrom(t)
            return
    m.graph.initializer.append(t)


def build(m, init):
    g = m.graph
    nodes = list(g.node)

    # ---- 1. fold the normalisation into conv1 ----
    W = init["net.features.0.weight"].astype(np.float64)                      # 64,3,3,3
    b = init["net.features.0.bias_q"].astype(np.float64) * init["net.features.0.bias_scale"]
    k = 1.0 / (255.0 * STD)                                                   # per input ch
    Wf = W * k.reshape(1, 3, 1, 1)
    bf = b + (W * (k * (128.0 - 255.0 * MEAN)).reshape(1, 3, 1, 1)).sum(axis=(1, 2, 3))
    ws = np.abs(Wf).reshape(64, -1).max(axis=1) / 127.0
    set_init(m, "net.features.0.weight", Wf.astype(np.float32))
    set_init(m, "net.features.0.weight_scale", ws.astype(np.float32))
    set_init(m, "net.features.0.weight_zero_point_c1", np.zeros(64, np.int8))
    set_init(m, "net.features.0.bias_q", np.round(bf / ws).astype(np.int32))
    set_init(m, "net.features.0.bias_scale", ws.astype(np.float32))           # in_scale = 1
    set_init(m, "image_s8_scale", np.array(1.0, np.float32))
    set_init(m, "image_s8_zero_point", np.array(0, np.int8))

    # new input: int8 camera byte -> DequantizeLinear -> conv1 (Sub / Div / mean / std gone)
    drop_out = {"view_1_q", "view_q", "image_tensor_updated", "view_1_updated", "view_updated",
                "sub", "sub_q", "sub_updated", "div", "div_q", "div_updated"}
    keep = []
    for n in nodes:
        if any(o in drop_out for o in n.output):
            continue
        if n.op_type == "QuantizeLinear" and n.input[0] == "net.features.0.weight":
            n.input[2] = "net.features.0.weight_zero_point_c1"   # zp tensor is shared, own copy
        if n.op_type == "DequantizeLinear" and n.output[0] == "net.features.0.weight_qdq":
            n.input[2] = "net.features.0.weight_zero_point_c1"
        if n.op_type == "Conv" and n.input[0] == "div_updated":
            n.input[0] = "image_s8_dq"
        keep.append(n)
    keep.insert(0, helper.make_node("DequantizeLinear", ["image_s8", "image_s8_scale",
                                    "image_s8_zero_point"], ["image_s8_dq"]))

    # ---- 2. classifier: keep only the rows (output channels) of CLASSES ----
    idx = np.array(CLASSES)
    pre = "net.classifier.1."
    for nm in ("weight", "weight_scale", "bias_q", "bias_scale"):
        set_init(m, pre + nm, init[pre + nm][idx])
    for n in keep:
        if n.output[0] in (pre + "weight_q", pre + "weight_qdq"):
            n.input[2] = pre + "weight_zero_point_sel"
        if n.output[0] == pre + "bias_qdq":
            n.input[2] = pre + "bias_zero_point_sel"
    set_init(m, pre + "weight_zero_point_sel", np.zeros(len(idx), np.int8))
    set_init(m, pre + "bias_zero_point_sel", np.zeros(len(idx), np.int32))
    reshape = [n for n in keep if n.op_type == "Reshape"][0]
    set_init(m, reshape.input[1], np.array([1, len(idx)], np.int64))

    del g.node[:]
    g.node.extend(keep)
    del g.input[:]
    g.input.append(helper.make_tensor_value_info("image_s8", TensorProto.INT8, [1, 3, 224, 224]))
    g.output[0].type.tensor_type.shape.dim[1].dim_value = len(idx)
    used = {i for n in g.node for i in n.input}
    live = [t for t in g.initializer if t.name in used]
    del g.initializer[:]
    g.initializer.extend(live)
    del g.value_info[:]
    onnx.checker.check_model(m)
    return m


def session(m):
    so = ort.SessionOptions()
    so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
    return ort.InferenceSession(m.SerializeToString(), so, providers=["CPUExecutionProvider"])


# ---- layer list in execution order (convs + the ops between them) -------------------------
def layer_list(m):
    """Walk the QDQ graph and return the HW-relevant ops with their integer parameters."""
    init = {t.name: numpy_helper.to_array(t) for t in m.graph.initializer}
    prod = {o: n for n in m.graph.node for o in n.output}
    qnode = {n.output[0]: n for n in m.graph.node if n.op_type == "QuantizeLinear"}
    cons = {}
    for n in m.graph.node:
        for i in n.input:
            cons.setdefault(i, []).append(n)

    def q_of(tensor):                 # quantised tensor name -> (scale, zp uint8/int8)
        n = qnode[tensor]
        return float(init[n.input[1]]), int(init[n.input[2]])

    def src_q(dq_out):                # DequantizeLinear output -> quantised source tensor
        return prod[dq_out].input[0]

    layers = []
    for n in m.graph.node:
        if n.op_type == "Conv":
            pref = n.input[1][:-len(".weight_qdq")]
            qw = prod[n.input[1]]
            qq = prod[qw.input[0]]                                  # QuantizeLinear(weight)
            wf, sc = init[qq.input[0]], init[qq.input[1]].astype(np.float64)
            wq = np.clip(np.round(wf / sc.reshape(-1, 1, 1, 1)), -128, 127).astype(np.int32)
            bq = init[pref + ".bias_q"].astype(np.int64)
            xin = src_q(n.input[0])
            s_in, z_in = q_of(xin) if xin in qnode else (float(init["image_s8_scale"]), 0)
            relu = cons[n.output[0]][0]
            yq = cons[relu.output[0]][0].output[0]
            s_out, z_out = q_of(yq)
            a = {x.name: helper.get_attribute_value(x) for x in n.attribute}
            layers.append(dict(op="conv", name=pref, in_t=xin, out_t=yq, w=wq, w_scale=sc,
                               bias_q=bq, s_in=s_in, z_in=z_in, s_out=s_out, z_out=z_out,
                               stride=a["strides"][0], pad=a["pads"][0], relu=True))
        elif n.op_type in ("MaxPool", "Concat", "GlobalAveragePool"):
            ins = [src_q(i) for i in n.input]
            yq = cons[n.output[0]][0].output[0]
            d = dict(op=n.op_type.lower(), in_t=ins if n.op_type == "Concat" else ins[0],
                     out_t=yq)
            if n.op_type == "MaxPool":
                a = {x.name: helper.get_attribute_value(x) for x in n.attribute}
                d.update(k=a["kernel_shape"][0], stride=a["strides"][0], ceil=a["ceil_mode"])
            if n.op_type == "GlobalAveragePool":
                d.update(s_in=q_of(ins[0])[0], z_in=q_of(ins[0])[1],
                         s_out=q_of(yq)[0], z_out=q_of(yq)[1])
            layers.append(d)
    # Concat / MaxPool outputs in this model are re-quantised with the scale of their input
    # (checked here), so they need no arithmetic.
    for L in layers:
        if L["op"] in ("concat", "maxpool"):
            ins = L["in_t"] if L["op"] == "concat" else [L["in_t"]]
            qs = {q_of(t) for t in ins} | {q_of(L["out_t"])}
            assert len(qs) == 1, f"{L['op']} changes quantisation: {qs}"
            L["s"], L["z"] = qs.pop()
    return layers


def hw_params(L):
    """HW-convention integer parameters of a conv: activations as int8 = uint8 - 128."""
    z_in_hw = L["z_in"] - 128 if L["in_t"] != "image_s8" else L["z_in"]
    wsum = L["w"].reshape(L["w"].shape[0], -1).sum(axis=1).astype(np.int64)
    bias_hw = L["bias_q"] - z_in_hw * wsum
    mult, shift = zip(*[quantize_multiplier(L["s_in"] * s / L["s_out"]) for s in L["w_scale"]])
    return z_in_hw, bias_hw, np.array(mult, np.int64), np.array(shift, np.int64), L["z_out"] - 128


def write_txt(path, layers, labels):
    def row(v):
        return " ".join(str(int(x)) for x in v)

    with open(path, "w") as f:
        f.write("# SqueezeNet-1.1 int8, normalisation folded into conv1, "
                f"{len(CLASSES)}-class classifier\n")
        f.write("# Activations are int8 = uint8 - 128 (HW convention); after every ReLU the zero\n"
                "# point is -128.  Network input = camera pixel - 128 (scale 1.0, zp 0), no\n"
                "# preprocessing.  Weights: int8, symmetric per output channel (zp 0), one line\n"
                "# per output channel, ordered [in_ch][ky][kx].  bias_hw already contains the\n"
                "# input zero-point term:  acc = sum(w * x_hw) + bias_hw ;\n"
                "# y_hw = clamp(z_out_hw + requant(acc, mult, shift), z_out_hw, 127)\n"
                "# requant = tflite SaturatingRoundingDoublingHighMul(acc, mult) then rounding\n"
                "# right shift by `shift` (shift<0 = left shift first), as rtl/tflite_requantizer.sv.\n"
                "# Float scales are given too: real = scale * (q - zp).\n")
        f.write(f"NUM_LAYERS {len(layers)}\n\n")
        ci = 0
        for li, L in enumerate(layers):
            if L["op"] == "conv":
                o, c, kh, kw = L["w"].shape
                z_in_hw, bias_hw, mult, shift, z_out_hw = hw_params(L)
                f.write(f"LAYER {li} CONV {L['name']}\n")
                f.write(f"  conv{ci}  in {L['in_t']} -> out {L['out_t']}\n")
                f.write(f"  in_ch {c} out_ch {o} kernel {kh}x{kw} stride {L['stride']} "
                        f"pad {L['pad']} relu 1\n")
                f.write(f"  in_scale {L['s_in']:.9g} in_zp_hw {z_in_hw}\n")
                f.write(f"  out_scale {L['s_out']:.9g} out_zp_hw {z_out_hw}\n")
                f.write(f"WEIGHTS {o} {c} {kh} {kw}\n")
                for r in L["w"].reshape(o, -1):
                    f.write(row(r) + "\n")
                f.write(f"BIAS_HW {o}\n{row(bias_hw)}\n")
                f.write(f"MULT {o}\n{row(mult)}\nSHIFT {o}\n{row(shift)}\n")
                f.write(f"W_SCALE {o}\n" + " ".join(f"{s:.9g}" for s in L["w_scale"]) + "\n")
                f.write(f"BIAS_Q {o}\n{row(L['bias_q'])}\n")
                f.write("END\n\n")
                ci += 1
            elif L["op"] == "maxpool":
                f.write(f"LAYER {li} MAXPOOL in {L['in_t']} -> out {L['out_t']}\n"
                        f"  kernel {L['k']}x{L['k']} stride {L['stride']} ceil_mode {L['ceil']}"
                        f"  (same scale {L['s']:.9g}, zp_hw {L['z'] - 128}: no arithmetic)\nEND\n\n")
            elif L["op"] == "concat":
                f.write(f"LAYER {li} CONCAT {' + '.join(L['in_t'])} -> out {L['out_t']}\n"
                        f"  channel concat (same scale {L['s']:.9g}, zp_hw {L['z'] - 128})\n"
                        f"END\n\n")
            else:
                m, sh = quantize_multiplier(L["s_in"] / L["s_out"])
                f.write(f"LAYER {li} GLOBAL_AVGPOOL in {L['in_t']} -> out {L['out_t']}\n"
                        f"  in_scale {L['s_in']:.9g} out_scale {L['s_out']:.9g}  "
                        f"(both zp_hw -128)\n"
                        f"  y_hw = -128 + round( mean_HW(x_hw + 128) * in_scale/out_scale )\n"
                        f"  in_scale/out_scale = {L['s_in'] / L['s_out']:.9g}  "
                        f"(MULT {m} SHIFT {sh})\n"
                        f"  output = class scores, channel i = CLASS i below "
                        f"(argmax = prediction)\nEND\n\n")
        f.write(f"CLASSES {len(CLASSES)}\n")
        for i, c in enumerate(CLASSES):
            f.write(f"{i} {c} {labels[c]}\n")


# ---- integer-only reference that uses only what is in weights.txt ------------------------
def read_txt(path):
    layers, cur = [], None
    lines = iter(open(path).read().splitlines())
    for ln in lines:
        t = ln.split()
        if not t or t[0].startswith("#"):
            continue
        if t[0] == "LAYER":
            cur = dict(op=t[2], out=t[t.index("->") + 2] if "->" in t else None)
            layers.append(cur)
            if t[2] == "CONCAT":
                cur["ins"] = t[3:t.index("->"):2]
            elif t[2] != "CONV":
                cur["ins"] = [t[4]]
            if t[2] == "MAXPOOL":
                nxt = next(lines).split()
                cur.update(k=int(nxt[1].split("x")[0]), stride=int(nxt[3]), ceil=int(nxt[5]))
            elif t[2] == "GLOBAL_AVGPOOL":
                nxt = next(lines).split()
                cur.update(s_in=float(nxt[1]), s_out=float(nxt[3]))
        elif cur is not None and cur["op"] == "CONV":
            if t[0].startswith("conv"):
                cur["ins"], cur["out"] = [t[2]], t[5]
            elif t[0] == "in_ch":
                cur.update(stride=int(t[7]), pad=int(t[9]))
            elif t[0] == "in_scale":
                cur["z_in"] = int(t[3])
            elif t[0] == "out_scale":
                cur["z_out"] = int(t[3])
            elif t[0] == "WEIGHTS":
                o, c, kh, kw = map(int, t[1:])
                cur["w"] = np.array([list(map(int, next(lines).split())) for _ in range(o)],
                                    np.int64).reshape(o, c, kh, kw)
            elif t[0] in ("BIAS_HW", "MULT", "SHIFT"):
                cur[t[0]] = np.array(list(map(int, next(lines).split())), np.int64)
    return layers


def requant(acc, mult, shift, zout):
    """vectorised tflite_requantizer (same arithmetic as gen_sqz_fire2.hw_requant)."""
    m = mult.reshape(-1, 1, 1)
    sh = shift.reshape(-1, 1, 1)
    x = np.where(sh < 0, acc << np.maximum(-sh, 0), acc)
    ab = x * m
    t = ab + np.where(ab >= 0, 1 << 30, 1 - (1 << 30))
    hi = np.where(t >= 0, t >> 31, -((-t) >> 31))
    s = np.maximum(sh, 0)
    rem = hi & ((1 << s) - 1)
    thr = (1 << np.maximum(s - 1, 0)) * (s > 0) + (hi < 0)
    r = np.where(s > 0, (hi >> s) + (rem > thr), hi)
    return np.clip(r + zout, zout, 127)


def conv_int(a, w, stride, pad, zpad):
    if pad:
        a = np.pad(a, ((0, 0), (pad, pad), (pad, pad)), constant_values=zpad)
    o, c, kh, kw = w.shape
    oh, ow = (a.shape[1] - kh) // stride + 1, (a.shape[2] - kw) // stride + 1
    acc = np.zeros((o, oh, ow), np.int64)
    for ky in range(kh):
        for kx in range(kw):
            sl = a[:, ky:ky + stride * oh:stride, kx:kx + stride * ow:stride]
            acc += np.einsum("chw,oc->ohw", sl, w[:, :, ky, kx])
    return acc


def run_int(layers, x_s8):
    """x_s8: [3,224,224] int8 camera bytes -> int8 class scores (HW convention)."""
    T = {"image_s8": x_s8.astype(np.int64)}
    for L in layers:
        a = T[L["ins"][0]]
        if L["op"] == "CONV":
            acc = conv_int(a, L["w"], L["stride"], L["pad"], L["z_in"])
            y = requant(acc + L["BIAS_HW"].reshape(-1, 1, 1), L["MULT"], L["SHIFT"], L["z_out"])
        elif L["op"] == "CONCAT":
            y = np.concatenate([T[i] for i in L["ins"]])
        elif L["op"] == "MAXPOOL":
            k, s = L["k"], L["stride"]
            oh = -(-(a.shape[1] - k) // s) + 1 if L["ceil"] else (a.shape[1] - k) // s + 1
            need = (oh - 1) * s + k - a.shape[1]
            a = np.pad(a, ((0, 0), (0, need), (0, need)), constant_values=-128)
            y = np.max([a[:, ky:ky + s * oh:s, kx:kx + s * oh:s] for ky in range(k)
                        for kx in range(k)], axis=0)
        else:   # GLOBAL_AVGPOOL
            mean = (a + 128).reshape(a.shape[0], -1).mean(axis=1)
            y = np.clip(np.round(mean * L["s_in"] / L["s_out"]), 0, 255).astype(np.int64) - 128
        T[L["out"]] = y
    return y


def camera_crop(path, flip=False, shift=(0, 0)):
    img = Image.open(path).convert("RGB")
    w, h = img.size
    s = 256 / min(w, h)
    img = img.resize((round(w * s), round(h * s)), Image.BILINEAR)
    if flip:
        img = img.transpose(Image.FLIP_LEFT_RIGHT)
    w, h = img.size
    l, t = (w - 224) // 2 + shift[0], (h - 224) // 2 + shift[1]
    return np.asarray(img.crop((l, t, l + 224, t + 224)), np.uint8).transpose(2, 0, 1).copy()


def main():
    os.makedirs(OUT, exist_ok=True)
    data = os.path.join(OUT, "squeezenet1_1_custom.data")
    if os.path.exists(data):          # onnx.save appends to an existing external-data file
        os.remove(data)
    labels = open(LABELS).read().splitlines()
    m0, init = load()
    m = build(onnx.load(MODEL), init)
    onnx_path = os.path.join(OUT, "squeezenet1_1_custom.onnx")
    onnx.save(m, onnx_path, save_as_external_data=True, all_tensors_to_one_file=True,
              location="squeezenet1_1_custom.data")
    m = onnx.load(onnx_path)
    with open(os.path.join(OUT, "classes.txt"), "w") as f:
        f.writelines(f"{i} {c} {labels[c]}\n" for i, c in enumerate(CLASSES))
    layers = layer_list(m)
    txt = os.path.join(OUT, "weights.txt")
    write_txt(txt, layers, labels)
    nconv = sum(L["op"] == "conv" for L in layers)
    nw = sum(L["w"].size for L in layers if L["op"] == "conv")
    print(f"wrote {onnx_path}\n      {txt}  ({len(layers)} layers, {nconv} conv, {nw} weights)")

    # ---- checks: original vs new ONNX vs integer model from weights.txt ----
    s0, s1 = session(m0), session(m)
    tl = read_txt(txt)
    idx = np.array(CLASSES)
    print(f"\n{'test image':24s} {'orig (1000 cls) top-1':28s} {'orig, kept cls':22s} "
          f"{'new ONNX':22s} {'int model (txt)':22s}  max|new-int|")
    for nm, kw in [("dog.jpg", {}), ("dog.jpg flipped", dict(flip=True)),
                   ("dog.jpg shift(-16,-16)", dict(shift=(-16, -16))),
                   ("dog.jpg shift(+16,+16)", dict(shift=(16, 16)))]:
        x = camera_crop(IMAGE, **kw)
        y0 = s0.run(None, {"image_tensor": x[None]})[0][0].astype(np.int32)
        x_s8 = (x.astype(np.int16) - 128).astype(np.int8)
        y1 = s1.run(None, {"image_s8": x_s8[None]})[0][0].astype(np.int32)
        y2 = run_int(tl, x_s8) + 128
        top = lambda y, ids: f"{labels[ids[int(np.argmax(y))]][:16]} ({int(y.max())})"
        print(f"{nm:24s} {labels[int(np.argmax(y0))][:20] + f' ({y0.max()})':28s} "
              f"{top(y0[idx], idx):22s} {top(y1, idx):22s} {top(y2, idx):22s}  "
              f"{np.abs(y1 - y2).max()}")
    x = camera_crop(IMAGE)
    y0 = s0.run(None, {"image_tensor": x[None]})[0][0][idx].astype(float)
    y1 = s1.run(None, {"image_s8": (x.astype(np.int16) - 128).astype(np.int8)[None]})[0][0]
    print(f"\nkept-class scores, original vs new (dog.jpg): corr {np.corrcoef(y0, y1)[0, 1]:.4f}")
    for i in np.argsort(-y1)[:5]:
        print(f"  {labels[CLASSES[i]]:24s} orig {int(y0[i]):3d}  new {int(y1[i]):3d}")


if __name__ == "__main__":
    main()
