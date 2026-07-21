"""Convert one RGB image into the Phase-E [1,196,768] patch-A HEX input."""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F
from PIL import Image
from transformers import AutoImageProcessor


PACKAGE_DIR = Path(__file__).resolve().parent.parent
PROCESSOR_DIR = Path(__file__).resolve().parent / "processor"
DEFAULT_IMAGE = PACKAGE_DIR / "inputs" / "sweetie.png"
DEFAULT_OUTPUT = PACKAGE_DIR / "preprocessed" / "embedding_input_patch_A_f32.hex"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", type=Path, default=DEFAULT_IMAGE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    image_path = args.image.resolve()
    output_path = args.output.resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)

    with Image.open(image_path) as decoded:
        source_size = decoded.size
        rgb = decoded.convert("RGB")

    processor = AutoImageProcessor.from_pretrained(
        PROCESSOR_DIR,
        local_files_only=True,
    )
    pixel_values = processor(images=rgb, return_tensors="pt")["pixel_values"]
    if pixel_values.shape != (1, 3, 224, 224):
        raise ValueError(f"Unexpected processor output shape: {tuple(pixel_values.shape)}")

    # F.unfold uses [channel,kernel_y,kernel_x] inside every 16x16 patch,
    # exactly matching the Phase-E PATCH_GEMM input contract.
    patch_a = F.unfold(pixel_values, kernel_size=(16, 16), stride=(16, 16))
    patch_a = patch_a.transpose(1, 2).contiguous()
    if patch_a.shape != (1, 196, 768):
        raise ValueError(f"Unexpected patch tensor shape: {tuple(patch_a.shape)}")

    words = (
        patch_a.cpu().numpy().astype("<f4", copy=False).reshape(-1).view("<u4")
    )
    np.savetxt(output_path, words, fmt="%08X")

    resized_chw = processor.resize(
        image=processor.process_image(rgb, do_convert_rgb=processor.do_convert_rgb),
        size=processor.size,
        resample=processor.resample,
    )
    resized_hwc = resized_chw.permute(1, 2, 0).contiguous().numpy()
    Image.fromarray(resized_hwc).save(output_path.parent / "resized_224_rgb.png")

    summary = "\n".join(
        [
            f"source_image={image_path}",
            f"source_size={source_size[0]}x{source_size[1]}",
            "resized_size=224x224",
            "tensor_shape=[1,196,768]",
            f"fp32_words={words.size}",
            "layout=patch_y,patch_x,channel,kernel_y,kernel_x",
            f"output_hex={output_path}",
        ]
    )
    (output_path.parent / "preprocess_summary.txt").write_text(
        summary + "\n", encoding="utf-8"
    )
    print("PREPROCESS COMPLETED")
    print(summary)


if __name__ == "__main__":
    main()
