# %% [markdown]
# # SqueezeNet-1.1 fine-tune for the edge-CNN SoC (run on Colab / Kaggle, not locally)
#
# Produces `export/squeezenet_cam_int8.onnx` + `export/classes.txt` for the accelerator:
#
# 1. **Camera-faithful data path** - every training/eval image goes through what the SoC sees:
#    scale/crop to the OV7670 frame (320x240, 4:3) -> RGB565 quantisation -> centre crop
#    224x224 (x0 = 48, y0 = 8).  The network input is the raw 8-bit RGB of that crop.
# 2. **Fine-tune** ImageNet-pretrained `torchvision.models.squeezenet1_1` on N classes
#    (classifier conv 512 -> N).
# 3. **Fold the normalisation into conv1** (exact: conv1 has no padding), so the model takes
#    raw pixels 0..255 and the SoC needs no mean/std hardware.
# 4. **Static int8 PTQ** with onnxruntime in QDQ form - the same structure as
#    `artifacts/squeezenet1_1.onnx`: per-channel int8 weights, int32 bias, per-tensor uint8
#    activations.  Then the HW constraints are enforced and checked:
#      * input quantisation scale 1.0, zero point 0 (camera byte == quantised input)
#      * both inputs of every Fire concat share the concat's scale / zero point
#      * MaxPool keeps its input's scale / zero point
# 5. Accuracy of float, folded and int8 models on the camera-emulated validation set, and
#    a few raw RGB565 320x240 test frames (`export/frames/*.bin`) for the testbench.
#
# **Data**: an ImageFolder directory (one sub-folder per class) at `DATA_DIR`, or the helper
# below that builds one from Caltech-256 for the classes in `CLASSES`.  Adding photos taken
# with the OV7670 itself (same classes) helps a lot with the camera's colour / noise.
#
# Colab: Runtime -> GPU, then `!pip install onnx onnxruntime` and run all cells.

# %%
import copy, math, os, random, shutil, tarfile, urllib.request
import numpy as np
import torch, torch.nn as nn
import torchvision
from torchvision import transforms
from PIL import Image

SEED = 0
random.seed(SEED); np.random.seed(SEED); torch.manual_seed(SEED)
DEVICE = "cuda" if torch.cuda.is_available() else "cpu"

DATA_DIR = "data/cam_classes"     # ImageFolder root (train/val split is done here)
EXPORT = "export"
CAM_W, CAM_H, CROP = 320, 240, 224
CROP_X0, CROP_Y0 = (CAM_W - CROP) // 2, (CAM_H - CROP) // 2   # 48, 8 - must match the SoC
EPOCHS, BATCH, LR = 25, 64, 1e-3
VAL_FRAC = 0.15
CALIB_IMAGES = 400
MEAN = [0.485, 0.456, 0.406]
STD = [0.229, 0.224, 0.225]

# Everyday objects that can be shown to the camera.  Matched as substrings of the
# Caltech-256 folder names ("041.coffee-mug" ...); edit freely (20-30 classes).
CLASSES = ["backpack", "beer-mug", "binoculars", "calculator", "cereal-box", "coffee-mug",
           "computer-keyboard", "computer-mouse", "eyeglasses", "frying-pan", "hammer",
           "headphones", "laptop", "light-bulb", "screwdriver", "soda-can", "spoon",
           "teapot", "teddy-bear", "tennis-ball", "toaster", "umbrella", "watch", "wine-bottle",
           "scissors"]

# %% [markdown]
# ## Optional: build DATA_DIR from Caltech-256
# (skip if you already have an ImageFolder; Caltech-256 is ~1.2 GB)

# %%
def build_from_caltech256(root="data", classes=CLASSES, out=DATA_DIR):
    url = "https://data.caltech.edu/records/nyy15-4j048/files/256_ObjectCategories.tar"
    tar = os.path.join(root, "256_ObjectCategories.tar")
    src = os.path.join(root, "256_ObjectCategories")
    os.makedirs(root, exist_ok=True)
    if not os.path.isdir(src):
        if not os.path.exists(tar):
            print("downloading Caltech-256 ...")
            urllib.request.urlretrieve(url, tar)
        with tarfile.open(tar) as t:
            t.extractall(root)
    folders = sorted(os.listdir(src))
    os.makedirs(out, exist_ok=True)
    for c in classes:
        hit = [f for f in folders if f.split(".", 1)[-1] == c] or [f for f in folders if c in f]
        if not hit:
            print(f"  !! no Caltech-256 folder for '{c}' - drop it or add your own images")
            continue
        dst = os.path.join(out, c)
        if not os.path.isdir(dst):
            shutil.copytree(os.path.join(src, hit[0]), dst)
        print(f"  {c:20s} <- {hit[0]} ({len(os.listdir(dst))} images)")

if not os.path.isdir(DATA_DIR):
    build_from_caltech256()

# %% [markdown]
# ## Camera emulation (what the SoC writes into SRAM)

# %%
def to_camera_frame(img: Image.Image) -> Image.Image:
    """Scale + centre crop any picture to the 4:3 OV7670 frame (320x240)."""
    w, h = img.size
    s = max(CAM_W / w, CAM_H / h)
    img = img.resize((max(CAM_W, round(w * s)), max(CAM_H, round(h * s))), Image.BILINEAR)
    w, h = img.size
    l, t = (w - CAM_W) // 2, (h - CAM_H) // 2
    return img.crop((l, t, l + CAM_W, t + CAM_H))

def rgb565_roundtrip(a: np.ndarray) -> np.ndarray:
    """uint8 HxWx3 -> RGB565 -> RGB888 by bit replication (what the camera front end does)."""
    r = a[..., 0] >> 3; g = a[..., 1] >> 2; b = a[..., 2] >> 3
    return np.stack([(r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2)], -1).astype(np.uint8)

def rgb565_words(frame: Image.Image) -> np.ndarray:
    a = np.asarray(frame.convert("RGB"), np.uint16)
    return ((a[..., 0] >> 3) << 11) | ((a[..., 1] >> 2) << 5) | (a[..., 2] >> 3)

def soc_input(frame: Image.Image) -> np.ndarray:
    """camera frame -> 3x224x224 float32 raw pixel values 0..255 (the folded model's input)."""
    a = rgb565_roundtrip(np.asarray(frame.convert("RGB"), np.uint8))
    a = a[CROP_Y0:CROP_Y0 + CROP, CROP_X0:CROP_X0 + CROP]
    return a.transpose(2, 0, 1).astype(np.float32)

class CamTransform:
    """train: photometric/geometric augmentation, then exactly the camera path."""
    def __init__(self, train):
        self.aug = transforms.Compose([
            transforms.RandomResizedCrop((CAM_H, CAM_W), scale=(0.35, 1.0), ratio=(1.1, 1.6)),
            transforms.RandomHorizontalFlip(),
            transforms.ColorJitter(0.3, 0.3, 0.3, 0.03),
        ]) if train else None
    def __call__(self, img):
        img = img.convert("RGB")
        frame = self.aug(img) if self.aug else to_camera_frame(img)
        return torch.from_numpy(soc_input(frame))       # raw 0..255

# %%
full = torchvision.datasets.ImageFolder(DATA_DIR)
classes = full.classes
N = len(classes)
idx = list(range(len(full))); random.shuffle(idx)
n_val = int(len(idx) * VAL_FRAC)
train_ds = torch.utils.data.Subset(torchvision.datasets.ImageFolder(DATA_DIR, CamTransform(True)), idx[n_val:])
val_ds = torch.utils.data.Subset(torchvision.datasets.ImageFolder(DATA_DIR, CamTransform(False)), idx[:n_val])
train_dl = torch.utils.data.DataLoader(train_ds, BATCH, shuffle=True, num_workers=2, drop_last=True)
val_dl = torch.utils.data.DataLoader(val_ds, BATCH, num_workers=2)
print(f"{N} classes, {len(train_ds)} train / {len(val_ds)} val images")
assert N <= 128, "result_o[6:0] carries up to 128 classes (more: read RESULT over SPI)"

# %% [markdown]
# ## Model: raw pixels in, normalisation inside (folded later)

# %%
class Normalize(nn.Module):
    def __init__(self):
        super().__init__()
        self.register_buffer("m", torch.tensor(MEAN).view(1, 3, 1, 1) * 255)
        self.register_buffer("s", torch.tensor(STD).view(1, 3, 1, 1) * 255)
    def forward(self, x):
        return (x - self.m) / self.s

net = torchvision.models.squeezenet1_1(weights="IMAGENET1K_V1")
net.classifier[1] = nn.Conv2d(512, N, 1)
nn.init.normal_(net.classifier[1].weight, 0, 0.01); nn.init.zeros_(net.classifier[1].bias)
model = nn.Sequential(Normalize(), net).to(DEVICE)

def evaluate(m, dl=val_dl):
    m.eval(); ok = tot = 0
    with torch.no_grad():
        for x, y in dl:
            ok += (m(x.to(DEVICE)).argmax(1).cpu() == y).sum().item(); tot += len(y)
    return ok / tot

# %% [markdown]
# ## Fine-tune (classifier first, then everything)

# %%
def train(m, epochs, lr, params):
    opt = torch.optim.AdamW(params, lr=lr, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, lr, total_steps=epochs * len(train_dl))
    crit = nn.CrossEntropyLoss(label_smoothing=0.1)
    for ep in range(epochs):
        m.train()
        for x, y in train_dl:
            opt.zero_grad()
            loss = crit(m(x.to(DEVICE)), y.to(DEVICE))
            loss.backward(); opt.step(); sched.step()
        print(f"epoch {ep+1}/{epochs}  loss {loss.item():.3f}  val acc {evaluate(m):.3f}")

train(model, 3, LR, net.classifier.parameters())
train(model, EPOCHS, LR / 3, model.parameters())
acc_float = evaluate(model)

# %% [markdown]
# ## Fold the normalisation into conv1 (exact - conv1 has no padding)
# conv(w, (x - m)/s) + b  =  conv(w / s, x) + b - sum(w * m / s)

# %%
folded = copy.deepcopy(net).cpu().eval()
c1 = folded.features[0]
assert c1.padding == (0, 0)
m = torch.tensor(MEAN).view(1, 3, 1, 1) * 255
s = torch.tensor(STD).view(1, 3, 1, 1) * 255
with torch.no_grad():
    w = c1.weight.clone()
    c1.weight.copy_(w / s)
    c1.bias.copy_(c1.bias - (w * m / s).sum(dim=(1, 2, 3)))
x = torch.rand(4, 3, CROP, CROP) * 255
with torch.no_grad():
    d = (folded(x) - model.cpu()(x)).abs().max().item()
model.to(DEVICE)
print(f"fold check: max |folded - original| = {d:.2e}")
assert d < 1e-3
folded = folded.to(DEVICE)
acc_folded = evaluate(folded)

# %% [markdown]
# ## Export float ONNX, static int8 QDQ quantisation

# %%
import onnx
from onnx import numpy_helper
from onnxruntime.quantization import (quantize_static, CalibrationDataReader, QuantType,
                                      QuantFormat, CalibrationMethod)
from onnxruntime.quantization.shape_inference import quant_pre_process
import onnxruntime as ort

os.makedirs(EXPORT, exist_ok=True)
fp32 = os.path.join(EXPORT, "squeezenet_cam_fp32.onnx")
pre = os.path.join(EXPORT, "squeezenet_cam_pre.onnx")
int8 = os.path.join(EXPORT, "squeezenet_cam_int8.onnx")
torch.onnx.export(folded.cpu(), torch.zeros(1, 3, CROP, CROP), fp32, input_names=["image"],
                  output_names=["logits"], opset_version=17, dynamic_axes=None)
quant_pre_process(fp32, pre)

class Calib(CalibrationDataReader):
    def __init__(self):
        self.it = iter([train_ds.dataset.samples[i][0] for i in idx[n_val:][:CALIB_IMAGES]])
    def get_next(self):
        p = next(self.it, None)
        if p is None:
            return None
        return {"image": soc_input(to_camera_frame(Image.open(p).convert("RGB")))[None]}

quantize_static(pre, int8, Calib(), quant_format=QuantFormat.QDQ, per_channel=True,
                activation_type=QuantType.QUInt8, weight_type=QuantType.QInt8,
                calibrate_method=CalibrationMethod.Percentile,
                extra_options={"CalibPercentile": 99.999, "WeightSymmetric": True,
                               "ActivationSymmetric": False})

# %% [markdown]
# ## Enforce the hardware's quantisation constraints
# * input Q: scale 1, zp 0         * Concat inputs share the concat's (scale, zp)
# * MaxPool output Q == its input Q (the HW pools in the int8 domain, no requant)

# %%
mq = onnx.load(int8)
g = mq.graph
inits = {t.name: t for t in g.initializer}
prod = {o: n for n in g.node for o in n.output}

def set_init(name, value, dtype):
    t = numpy_helper.from_array(np.array(value, dtype=dtype), name)
    inits[name].CopyFrom(t)

def q_of(tensor):           # QuantizeLinear consuming 'tensor'
    return next(n for n in g.node if n.op_type == "QuantizeLinear" and n.input[0] == tensor)

def own_qparams(qnode, scale, zp):
    """give qnode private (scale, zp) initializers with the given values"""
    for k, (v, dt) in ((1, (scale, np.float32)), (2, (zp, np.uint8))):
        name = qnode.name + ("_hw_scale" if k == 1 else "_hw_zp")
        if name not in inits:
            g.initializer.append(numpy_helper.from_array(np.array(v, dt), name))
            inits[name] = g.initializer[-1]
        else:
            set_init(name, v, dt)
        qnode.input[k] = name
    # the matching DequantizeLinear nodes must use the same parameters
    for n in g.node:
        if n.op_type == "DequantizeLinear" and n.input[0] == qnode.output[0]:
            n.input[1], n.input[2] = qnode.input[1], qnode.input[2]

def qparams(qnode):
    return (float(numpy_helper.to_array(inits[qnode.input[1]])),
            int(numpy_helper.to_array(inits[qnode.input[2]])))

own_qparams(q_of("image"), 1.0, 0)
for n in g.node:
    if n.op_type == "Concat":
        sc, zp = qparams(q_of(n.output[0]))
        for i in n.input:
            dq = prod[i]                       # DequantizeLinear <- QuantizeLinear <- Relu
            own_qparams(prod[dq.input[0]], sc, zp)
    if n.op_type == "MaxPool":
        dq = prod[n.input[0]]
        sc, zp = qparams(prod[dq.input[0]])
        own_qparams(q_of(n.output[0]), sc, zp)
onnx.checker.check_model(mq)
onnx.save(mq, int8)

so = ort.SessionOptions()
so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
sess = ort.InferenceSession(int8, so, providers=["CPUExecutionProvider"])
ok = tot = 0
for i in idx[:n_val]:
    p, y = train_ds.dataset.samples[i]
    x = soc_input(to_camera_frame(Image.open(p).convert("RGB")))[None]
    ok += int(np.argmax(sess.run(None, {"image": x})[0]) == y); tot += 1
acc_int8 = ok / tot
print(f"val accuracy  float {acc_float:.3f}  folded {acc_folded:.3f}  int8 {acc_int8:.3f}")

# %% [markdown]
# ## Artifacts for the SoC flow

# %%
with open(os.path.join(EXPORT, "classes.txt"), "w") as f:
    f.writelines(f"{i} {c}\n" for i, c in enumerate(classes))
os.makedirs(os.path.join(EXPORT, "frames"), exist_ok=True)
for k, i in enumerate(idx[:8]):
    p, y = full.samples[i]
    frame = to_camera_frame(Image.open(p).convert("RGB"))
    rgb565_words(frame).astype("<u2").tofile(os.path.join(EXPORT, "frames", f"frame{k}_class{y}.bin"))
with open(os.path.join(EXPORT, "report.txt"), "w") as f:
    f.write(f"classes {N}\nval float {acc_float:.4f}\nval folded {acc_folded:.4f}\nval int8 {acc_int8:.4f}\n"
            f"camera {CAM_W}x{CAM_H} RGB565, crop {CROP} at ({CROP_X0},{CROP_Y0}), input = raw RGB888 0..255\n")
shutil.make_archive("squeezenet_cam_export", "zip", EXPORT)
print("download squeezenet_cam_export.zip (int8 onnx, classes.txt, frames/, report.txt)")
