#!/usr/bin/env python3
"""
Convert a Spacan bundle into a COLMAP text sparse model so it can be trained with
gsplat / graphdeco Gaussian Splatting (or anything else that reads COLMAP), using the
LiDAR point cloud as the initial Gaussians instead of running SfM.

    python prepare_splat.py /path/to/Scan_YYYYMMDD_HHMMSS --out /path/to/Scan_colmap
    python prepare_splat.py /path/to/Scan_... --out ... --max-points 600000 --depth-png

Output layout (what gsplat's `simple_trainer.py --data_dir` and 3DGS `train.py -s` expect):

    <out>/
      images/            symlinks (or copies with --copy) to the keyframe JPEGs
      sparse/0/cameras.txt
      sparse/0/images.txt
      sparse/0/points3D.txt
      depth_png/         optional, 16-bit PNG in millimeters (--depth-png)

Only numpy is required.
"""
import argparse
import json
import os
import shutil
import struct
import sys
import zlib

import numpy as np


# ----------------------------------------------------------------------------- PLY

def read_ply(path):
    """Reads the binary little-endian PLY written by Spacan (xyz float32, rgb uint8)."""
    with open(path, "rb") as f:
        header = b""
        while not header.endswith(b"end_header\n"):
            line = f.readline()
            if not line:
                raise ValueError("PLY header not terminated")
            header += line
        n = 0
        for line in header.decode("ascii", "replace").splitlines():
            if line.startswith("element vertex"):
                n = int(line.split()[-1])
        if "binary_little_endian" not in header.decode("ascii", "replace"):
            raise ValueError("expected binary_little_endian PLY")
        dtype = np.dtype([("x", "<f4"), ("y", "<f4"), ("z", "<f4"),
                          ("r", "u1"), ("g", "u1"), ("b", "u1")])
        data = np.fromfile(f, dtype=dtype, count=n)
    xyz = np.stack([data["x"], data["y"], data["z"]], axis=1).astype(np.float64)
    rgb = np.stack([data["r"], data["g"], data["b"]], axis=1).astype(np.uint8)
    return xyz, rgb


# ----------------------------------------------------------------------------- math

def rotmat_to_quat(R):
    """Rotation matrix -> quaternion (qw, qx, qy, qz), COLMAP ordering."""
    m = R
    tr = np.trace(m)
    if tr > 0:
        s = np.sqrt(tr + 1.0) * 2
        qw = 0.25 * s
        qx = (m[2, 1] - m[1, 2]) / s
        qy = (m[0, 2] - m[2, 0]) / s
        qz = (m[1, 0] - m[0, 1]) / s
    elif m[0, 0] > m[1, 1] and m[0, 0] > m[2, 2]:
        s = np.sqrt(1.0 + m[0, 0] - m[1, 1] - m[2, 2]) * 2
        qw = (m[2, 1] - m[1, 2]) / s
        qx = 0.25 * s
        qy = (m[0, 1] + m[1, 0]) / s
        qz = (m[0, 2] + m[2, 0]) / s
    elif m[1, 1] > m[2, 2]:
        s = np.sqrt(1.0 + m[1, 1] - m[0, 0] - m[2, 2]) * 2
        qw = (m[0, 2] - m[2, 0]) / s
        qx = (m[0, 1] + m[1, 0]) / s
        qy = 0.25 * s
        qz = (m[1, 2] + m[2, 1]) / s
    else:
        s = np.sqrt(1.0 + m[2, 2] - m[0, 0] - m[1, 1]) * 2
        qw = (m[1, 0] - m[0, 1]) / s
        qx = (m[0, 2] + m[2, 0]) / s
        qy = (m[1, 2] + m[2, 1]) / s
        qz = 0.25 * s
    q = np.array([qw, qx, qy, qz])
    return q / np.linalg.norm(q)


# OpenGL camera (x right, y up, z back) -> OpenCV camera (x right, y down, z forward)
GL_TO_CV = np.diag([1.0, -1.0, -1.0, 1.0])


def c2w_gl_to_w2c_cv(c2w):
    c2w_cv = c2w @ GL_TO_CV
    return np.linalg.inv(c2w_cv)


# ----------------------------------------------------------------------------- PNG

def write_png16(path, arr_u16):
    """Minimal 16-bit grayscale PNG writer (no PIL dependency)."""
    h, w = arr_u16.shape
    raw = b"".join(b"\x00" + arr_u16[y].astype(">u2").tobytes() for y in range(h))

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", w, h, 16, 0, 0, 0, 0)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", zlib.compress(raw, 6)))
        f.write(chunk(b"IEND", b""))


# ----------------------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("scan", help="Spacan bundle folder (contains transforms.json)")
    ap.add_argument("--out", help="output folder (default: <scan>_colmap)")
    ap.add_argument("--max-points", type=int, default=600_000,
                    help="subsample the LiDAR cloud to at most this many seed points (default 600k)")
    ap.add_argument("--copy", action="store_true", help="copy images instead of symlinking")
    ap.add_argument("--depth-png", action="store_true",
                    help="also convert raw float32 depth to 16-bit PNG (millimeters) in depth_png/")
    ap.add_argument("--min-confidence", type=int, default=2,
                    help="when writing depth PNGs, zero out pixels below this LiDAR confidence (0-2)")
    args = ap.parse_args()

    scan = os.path.abspath(args.scan)
    out = os.path.abspath(args.out or (scan.rstrip("/") + "_colmap"))
    tj_path = os.path.join(scan, "transforms.json")
    if not os.path.exists(tj_path):
        sys.exit(f"transforms.json not found in {scan}")

    with open(tj_path) as f:
        tj = json.load(f)
    frames = tj.get("frames", [])
    if not frames:
        sys.exit("no frames in transforms.json")

    os.makedirs(os.path.join(out, "images"), exist_ok=True)
    os.makedirs(os.path.join(out, "sparse", "0"), exist_ok=True)

    # ---- cameras.txt / images.txt
    cam_lines = ["# Camera list with one line of data per camera:",
                 "#   CAMERA_ID, MODEL, WIDTH, HEIGHT, PARAMS[]",
                 f"# Number of cameras: {len(frames)}"]
    img_lines = ["# Image list with two lines of data per image:",
                 "#   IMAGE_ID, QW, QX, QY, QZ, TX, TY, TZ, CAMERA_ID, NAME",
                 "#   POINTS2D[] as (X, Y, POINT3D_ID)",
                 f"# Number of images: {len(frames)}"]

    for i, fr in enumerate(frames, start=1):
        fx = fr.get("fl_x", tj.get("fl_x"))
        fy = fr.get("fl_y", tj.get("fl_y"))
        cx = fr.get("cx", tj.get("cx"))
        cy = fr.get("cy", tj.get("cy"))
        w = int(fr.get("w", tj.get("w")))
        h = int(fr.get("h", tj.get("h")))
        cam_lines.append(f"{i} PINHOLE {w} {h} {fx:.6f} {fy:.6f} {cx:.6f} {cy:.6f}")

        c2w = np.array(fr["transform_matrix"], dtype=np.float64)
        w2c = c2w_gl_to_w2c_cv(c2w)
        q = rotmat_to_quat(w2c[:3, :3])
        t = w2c[:3, 3]
        name = os.path.basename(fr["file_path"])
        img_lines.append(f"{i} {q[0]:.9f} {q[1]:.9f} {q[2]:.9f} {q[3]:.9f} "
                         f"{t[0]:.6f} {t[1]:.6f} {t[2]:.6f} {i} {name}")
        img_lines.append("")  # no 2D observations

        src = os.path.join(scan, fr["file_path"])
        dst = os.path.join(out, "images", name)
        if os.path.lexists(dst):
            os.remove(dst)
        if args.copy:
            shutil.copy2(src, dst)
        else:
            os.symlink(src, dst)

    with open(os.path.join(out, "sparse", "0", "cameras.txt"), "w") as f:
        f.write("\n".join(cam_lines) + "\n")
    with open(os.path.join(out, "sparse", "0", "images.txt"), "w") as f:
        f.write("\n".join(img_lines) + "\n")

    # ---- points3D.txt from the LiDAR cloud
    ply_rel = tj.get("ply_file_path", "cloud.ply")
    xyz, rgb = read_ply(os.path.join(scan, ply_rel))
    n = len(xyz)
    if n > args.max_points:
        idx = np.random.default_rng(0).choice(n, size=args.max_points, replace=False)
        idx.sort()
        xyz, rgb = xyz[idx], rgb[idx]
    with open(os.path.join(out, "sparse", "0", "points3D.txt"), "w") as f:
        f.write("# 3D point list with one line of data per point:\n")
        f.write("#   POINT3D_ID, X, Y, Z, R, G, B, ERROR, TRACK[] as (IMAGE_ID, POINT2D_IDX)\n")
        f.write(f"# Number of points: {len(xyz)}\n")
        for pid, (p, c) in enumerate(zip(xyz, rgb), start=1):
            f.write(f"{pid} {p[0]:.5f} {p[1]:.5f} {p[2]:.5f} {int(c[0])} {int(c[1])} {int(c[2])} 0.0\n")

    # ---- optional depth PNGs (mm)
    if args.depth_png:
        meta = tj.get("spacan", {})
        dw, dh = int(meta.get("depth_width", 0)), int(meta.get("depth_height", 0))
        if dw and dh:
            os.makedirs(os.path.join(out, "depth_png"), exist_ok=True)
            written = 0
            for fr in frames:
                draw = fr.get("depth_raw")
                if not draw:
                    continue
                depth = np.fromfile(os.path.join(scan, draw), dtype="<f4")
                if depth.size != dw * dh:
                    continue
                depth = depth.reshape(dh, dw)
                craw = fr.get("confidence_raw")
                if craw and os.path.exists(os.path.join(scan, craw)):
                    conf = np.fromfile(os.path.join(scan, craw), dtype="u1").reshape(dh, dw)
                    depth = np.where(conf >= args.min_confidence, depth, 0.0)
                mm = np.clip(np.nan_to_num(depth) * 1000.0, 0, 65535).astype(np.uint16)
                stem = os.path.splitext(os.path.basename(fr["file_path"]))[0]
                write_png16(os.path.join(out, "depth_png", stem + ".png"), mm)
                written += 1
            print(f"depth PNGs: {written}")
        else:
            print("no depth size in transforms.json; skipping depth PNGs")

    print(f"wrote COLMAP model: {out}")
    print(f"  images: {len(frames)}   seed points: {len(xyz)} (of {n})")
    print("train with, e.g.:")
    print(f"  python gsplat/examples/simple_trainer.py default --data_dir {out} --data_factor 1")
    print(f"  python gaussian-splatting/train.py -s {out}")


if __name__ == "__main__":
    main()
