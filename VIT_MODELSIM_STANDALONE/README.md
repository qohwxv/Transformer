# Standalone ViT ModelSim package

This folder contains one complete file-backed pure-SystemVerilog inference
package. It has no symlinks and does not read weights or HDL from outside the
folder.

## Layout

```text
vit_modelsim_standalone/
├── *.sv                         controller, NPU, behavioral datapath and TB
├── vit_phase_e_pure_sv.f        SystemVerilog compilation order
├── run_modelsim.do              compile and run full 249-command inference
├── parameters/                  one shared set of 200 model parameter HEX files
├── inputs/
│   └── sweetie.png              source RGB image
├── preprocessing/
│   ├── prepare_image.py         image -> normalized patch-A conversion
│   ├── processor/               local ViT preprocessing configuration
│   └── requirements.txt         Python preprocessing dependencies
├── preprocessed/
│   └── embedding_input_patch_A_f32.hex
│                                  one ModelSim input, [1,196,768], 150528 words
└── results/                     ModelSim checkpoints, prediction and transcript
```

## Prepare or replace the image

The bundled image is prepared with:

```bash
python3 preprocessing/prepare_image.py
```

For another local JPEG/PNG:

```bash
python3 preprocessing/prepare_image.py --image /absolute/path/new_image.jpg
```

Both commands overwrite only
`preprocessed/embedding_input_patch_A_f32.hex`. Model weights do not change.
The script uses the included ViT processor configuration for RGB conversion,
resize to 224x224, rescale and normalization, then patch16 unfolding into
`[1,196,768]` order. It does not load the 12-layer model or regenerate weights.

## Run ModelSim

From the ModelSim Transcript, use the package's current absolute path:

```tcl
do /absolute/path/vit_modelsim_standalone/run_modelsim.do
```

The `.do` script finds its own directory, so the whole folder may be copied or
moved without editing internal paths. It uses `CHECKPOINT_INJECT=0` and writes
all outputs to `results/`. Completion is confirmed by:

```text
PASS functional run complete: commands=249 checkpoints=249
```

The final result is `results/prediction.txt`.

`run_modelsim.do` deliberately does not hard-code an expected class, so the
same script works after replacing the image. The bundled Sweetie Python
reference is retained in `preprocessed/python_reference_prediction.txt` only
as a diagnostic reference.
