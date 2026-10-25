"""Face detection (SCRFD, 5 landmarks) and identity embedding (ArcFace R50),
InsightFace buffalo_l weights via onnxruntime."""

import os

import cv2
import numpy as np
import onnxruntime as ort

from store import WORK

MODELS = os.path.join(WORK, "models")
DET_SIZE = 640
ARCFACE_DST = np.array(
    [[38.2946, 51.6963], [73.5318, 51.5014], [56.0252, 71.7366],
     [41.5493, 92.3655], [70.7299, 92.2041]], dtype=np.float32)


def _session(name, providers):
    opts = ort.SessionOptions()
    opts.intra_op_num_threads = 4
    return ort.InferenceSession(os.path.join(MODELS, name), opts, providers=providers)


def _nms(dets, thresh=0.4):
    x1, y1, x2, y2, s = dets.T
    areas = (x2 - x1 + 1) * (y2 - y1 + 1)
    order = s.argsort()[::-1]
    keep = []
    while order.size:
        i = order[0]
        keep.append(i)
        xx1 = np.maximum(x1[i], x1[order[1:]])
        yy1 = np.maximum(y1[i], y1[order[1:]])
        xx2 = np.minimum(x2[i], x2[order[1:]])
        yy2 = np.minimum(y2[i], y2[order[1:]])
        inter = np.maximum(0, xx2 - xx1 + 1) * np.maximum(0, yy2 - yy1 + 1)
        order = order[1:][inter / (areas[i] + areas[order[1:]] - inter) <= thresh]
    return keep


class Recognizer:
    def __init__(self, providers=("CPUExecutionProvider",)):
        self.det = _session("det_10g.onnx", list(providers))
        self.rec = _session("w600k_r50.onnx", list(providers))
        self.det_in = self.det.get_inputs()[0].name
        self.rec_in = self.rec.get_inputs()[0].name
        self._anchors = {}

    def detect(self, bgr, threshold=0.5):
        h, w = bgr.shape[:2]
        scale = DET_SIZE / max(h, w)
        nh, nw = int(round(h * scale)), int(round(w * scale))
        canvas = np.zeros((DET_SIZE, DET_SIZE, 3), dtype=np.uint8)
        canvas[:nh, :nw] = cv2.resize(bgr, (nw, nh))
        blob = cv2.dnn.blobFromImage(canvas, 1 / 128, (DET_SIZE, DET_SIZE),
                                     (127.5, 127.5, 127.5), swapRB=True)
        out = self.det.run(None, {self.det_in: blob})
        boxes, kpss, scores = [], [], []
        for i, stride in enumerate((8, 16, 32)):
            s, b, k = out[i][:, 0], out[i + 3] * stride, out[i + 6] * stride
            n = DET_SIZE // stride
            if stride not in self._anchors:
                grid = np.stack(np.mgrid[:n, :n][::-1], axis=-1).reshape(-1, 2)
                self._anchors[stride] = np.repeat(grid * stride, 2, axis=0).astype(np.float32)
            c = self._anchors[stride]
            idx = np.where(s >= threshold)[0]
            box = np.hstack([c - b[:, :2], c + b[:, 2:]])
            kps = (c[:, None, :] + k.reshape(-1, 5, 2))
            boxes.append(box[idx]); kpss.append(kps[idx]); scores.append(s[idx])
        boxes = np.vstack(boxes) / scale
        kpss = np.vstack(kpss) / scale
        scores = np.concatenate(scores)
        if not len(scores):
            return []
        keep = _nms(np.hstack([boxes, scores[:, None]]))
        return [(boxes[i], kpss[i], float(scores[i])) for i in keep]

    def embed(self, bgr, kps):
        m, _ = cv2.estimateAffinePartial2D(kps.astype(np.float32), ARCFACE_DST, method=cv2.LMEDS)
        face = cv2.warpAffine(bgr, m, (112, 112), borderValue=0.0)
        v = sum(self.rec.run(None, {self.rec_in: cv2.dnn.blobFromImage(
            img, 1 / 127.5, (112, 112), (127.5, 127.5, 127.5), swapRB=True)})[0][0]
            for img in (face, np.ascontiguousarray(face[:, ::-1])))
        return v / np.linalg.norm(v), face
