# Verilator makefile for the current repository layout.
# Uses a top-level filelist.f containing the source paths.

VERILATOR ?= verilator
OUT = ./tmp
FLAGS := --binary --timing -Wno-fatal -Wno-lint -Wno-style -Wno-INITIALDLY
FILELIST := filelist.f
RTL_DIR := rtl
TB_DIR := tb

INCLUDES := -I$(RTL_DIR) -I$(TB_DIR)

.DEFAULT_GOAL := sim
.PHONY: help sim unit conv_default conv_b2 conv_depth5 conv_b2_depth5 shufflenet_real shufflenet_conv1 maxpool system_sqz system_cam fpga_full model sqz_data all clean

help:
	@echo "Targets:"
	@echo "  make sim              -> unit tests + default conv_tb"
	@echo "  make shufflenet_real  -> run tb_shufflenet_real"
	@echo "  make shufflenet_conv1 -> run tb_accelerator_all_patches"
	@echo "  make maxpool          -> run tb_accelerator_maxpool"
	@echo "  make system_sqz       -> full SoC: DVP + QSPI/DMA + SqueezeNet conv1/pool + fire2"
	@echo "  make system_cam       -> full SoC: 320x240 camera, 224 crop, row-streamed conv1+pool+fire2-squeeze"
	@echo "  make model            -> compile artifacts/squeezenet1_1_custom/weights.txt -> build/sqz_custom"
	@echo "  make fpga_full        -> whole custom SqueezeNet on fpga_top (boot ROM over SPI, flash weights, camera)"
	@echo "  make sqz_data         -> regenerate hex/sqz_fire2 (needs numpy onnx onnxruntime pillow)"
	@echo "  make all              -> sim + stress variants"
	@echo "  make unit             -> only unit tests"
	@echo "  make clean            -> remove build artifacts"

run_cfg = \
	@mkdir -p $(OUT)/$(1); \
	$(VERILATOR) $(FLAGS) $(2) --top-module conv_tb -f $(FILELIST) $(INCLUDES) -Mdir $(OUT)/$(1) -o sim >/dev/null; \
	echo "== conv_tb  [$(1)] =="; \
	$(OUT)/$(1)/sim | grep -E "config|^\[|->|coverage|^TOTAL|PASSED|FAILED|PASS [12]"

unit:
	@mkdir -p $(OUT)
	@$(VERILATOR) $(FLAGS) --top-module tb_fifo -f $(FILELIST) $(INCLUDES) -Mdir $(OUT)/tb_fifo -o sim >/dev/null
	@echo "== unit tests =="
	@$(OUT)/tb_fifo/sim | grep -E "PASS|FAIL"
	@$(VERILATOR) $(FLAGS) --top-module tb_pe -f $(FILELIST) $(INCLUDES) -Mdir $(OUT)/tb_pe -o sim >/dev/null
	@$(OUT)/tb_pe/sim | grep -E "PASS|FAIL"

conv_default:
	$(call run_cfg,default,)

conv_b2:
	$(call run_cfg,b2,-DUSE_B2)

conv_depth5:
	$(call run_cfg,depth5,-DFIFO_DEPTH_OVR=5)

conv_b2_depth5:
	$(call run_cfg,b2_depth5,-DUSE_B2 -DFIFO_DEPTH_OVR=5)

shufflenet_real:
	@mkdir -p $(OUT)/shufflenet_real
	@$(VERILATOR) $(FLAGS) --top-module tb_shufflenet_real -f $(FILELIST) $(INCLUDES) -Mdir $(OUT)/shufflenet_real -o sim >/dev/null
	@echo "== tb_shufflenet_real =="
	@$(OUT)/shufflenet_real/sim | grep -E "config|^->|^TOTAL|SUCCESS|FAILED|ERROR|INFERENCE COMPLETE|VERDICT" || true

shufflenet_conv1:
	@mkdir -p $(OUT)/shufflenet_conv1
	@$(VERILATOR) $(FLAGS) --top-module tb_accelerator_all_patches -f $(FILELIST) $(INCLUDES) -Mdir $(OUT)/shufflenet_conv1 -o sim >/dev/null
	@echo "== tb_accelerator_shufflenet_conv1 =="
	@$(OUT)/shufflenet_conv1/sim | grep -E "STARTING|Patch|VERDICT|SUCCESS|FAILED|Mismatch|ERROR" || true

maxpool:
	@mkdir -p $(OUT)/maxpool
	@$(VERILATOR) $(FLAGS) --top-module tb_accelerator_maxpool -f $(FILELIST) $(INCLUDES) -Mdir $(OUT)/maxpool -o sim >/dev/null
	@echo "== tb_accelerator_maxpool =="
	@$(OUT)/maxpool/sim | grep -E "STARTING|Patch|VERDICT|SUCCESS|FAILED|Mismatch|ERROR" || true

system_sqz:
	@mkdir -p $(OUT)/system_sqz logs
	@$(VERILATOR) $(FLAGS) -j 0 --top-module tb_system_sqz -f filelist_system.f tb/tb_system_sqz.sv $(INCLUDES) -Mdir $(OUT)/system_sqz -o sim > $(OUT)/system_sqz/build.log 2>&1 || (grep %Error $(OUT)/system_sqz/build.log; exit 1)
	@echo "== tb_system_sqz (log: logs/system_sqz.log) =="
	@$(OUT)/system_sqz/sim $(PLUSARGS) > logs/system_sqz.log 2>&1 || true
	@grep -E "\[(MCU|CAM|DVP|DMA|SYS) |\[FSM \] layer|===|values differ|max .hw|expected argmax|result pins|SPI |IRQ after|Second|2nd|border fill|CAM|VERDICT|TIMEOUT|ERROR" logs/system_sqz.log || true

system_cam:
	@mkdir -p $(OUT)/system_cam logs
	@$(VERILATOR) $(FLAGS) -j 0 --top-module tb_system_cam -f filelist_system.f tb/tb_system_cam.sv $(INCLUDES) -Mdir $(OUT)/system_cam -o sim > $(OUT)/system_cam/build.log 2>&1 || (grep %Error $(OUT)/system_cam/build.log; exit 1)
	@echo "== tb_system_cam (log: logs/system_cam.log) =="
	@$(OUT)/system_cam/sim $(PLUSARGS) > logs/system_cam.log 2>&1 || true
	@grep -E "\\[(MCU|CAM|SYS) |stripe|===|rows checked|differ|camera frame|VERDICT|TIMEOUT|ERROR" logs/system_cam.log || true

model:
	python3 scripts/compile_squeezenet.py

fpga_full:
	@mkdir -p $(OUT)/fpga_full logs
	@$(VERILATOR) $(FLAGS) -j 0 --top-module tb_fpga_full -f filelist_system.f rtl/fpga/spi_boot_master.sv rtl/fpga/fpga_top.sv tb/tb_fpga_full.sv $(INCLUDES) -Mdir $(OUT)/fpga_full -o sim > $(OUT)/fpga_full/build.log 2>&1 || (grep %Error $(OUT)/fpga_full/build.log; exit 1)
	@echo "== tb_fpga_full (log: logs/fpga_full.log) =="
	@$(OUT)/fpga_full/sim $(PLUSARGS) > logs/fpga_full.log 2>&1 || true
	@grep -E "boot master|inference done|differ|result pins|overrun|VERDICT|TIMEOUT" logs/fpga_full.log || true

sqz_data:
	python3 scripts/gen_sqz_fire2.py
	python3 scripts/gen_cam_stage1.py

sim: unit conv_default

all: sim conv_b2 conv_depth5 conv_b2_depth5 shufflenet_conv1 maxpool

clean:
	@rm -rf $(OUT)
