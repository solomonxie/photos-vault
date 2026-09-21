"""SFace (OpenCV Zoo, Apache-2.0) -> quantised CoreML, for on-device face
recognition.

Run once, on a Mac, into the project venv:

    venv/bin/python scripts/convert_sface.py

Writes `ios/Runner/SFace.mlpackage`. Committed output, not a build step —
the conversion needs torch and coremltools, and nobody should have to
install 2 GB of Python to build the app.

Source: https://huggingface.co/opencv/face_recognition_sface
"""

import os
import subprocess
import sys

import coremltools as ct
import coremltools.optimize.coreml as cto
import torch
from onnx2torch import convert

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
ONNX = os.path.join(ROOT, "build", "model-conversion", "sface.onnx")
OUT = os.path.join(ROOT, "ios", "Runner", "SFace.mlpackage")

# What SFace was trained on: 112x112 BGR, raw 0-255, no mean subtraction.
SIDE = 112


def main() -> int:
    if not os.path.exists(ONNX):
        print(f"missing {ONNX} — download it first", file=sys.stderr)
        return 1

    print("onnx -> torch")
    model = convert(ONNX).eval()

    example = torch.rand(1, 3, SIDE, SIDE) * 255
    with torch.no_grad():
        reference = model(example)
    print("  output", tuple(reference.shape))

    print("torch -> coreml")
    traced = torch.jit.trace(model, example)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="data", shape=(1, 3, SIDE, SIDE))],
        outputs=[ct.TensorType(name="embedding")],
        minimum_deployment_target=ct.target.iOS16,
        compute_precision=ct.precision.FLOAT16,
    )

    print("quantising weights to int8")
    mlmodel = cto.linear_quantize_weights(
        mlmodel,
        cto.OptimizationConfig(
            global_config=cto.OpLinearQuantizerConfig(
                mode="linear_symmetric", dtype="int8"
            )
        ),
    )

    if os.path.exists(OUT):
        subprocess.run(["rm", "-rf", OUT], check=True)
    mlmodel.save(OUT)
    size = subprocess.run(
        ["du", "-sh", OUT], capture_output=True, text=True
    ).stdout.split()[0]
    print(f"wrote {OUT} ({size})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
