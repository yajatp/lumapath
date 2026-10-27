"""Deterministic analytic RGB-D room simulator. Generated labels are never detector predictions."""
from __future__ import annotations
import argparse
import base64
import hashlib
import io
import json
import math
from pathlib import Path
import uuid
import numpy as np
from PIL import Image

VERSION = "lumapath-analytic-room-1"
WIDTH, HEIGHT, DW, DH = 320, 240, 64, 48
FX, FY, CX, CY = 230.0, 230.0, 160.0, 120.0
CONDITIONS = ("normal", "dim", "depthDropout", "missingDepth")
CATALOG = {1: "floor", 2: "wall", 3: "bed", 4: "dining table", 5: "door", 6: "floor corridor", 7: "chair"}


def b64(data):
    return base64.b64encode(data).decode("ascii")


def room(seed):
    """All scene assets are project-generated cuboids, in right-handed ARKit-style world axes."""
    rng = np.random.default_rng(seed)
    offset = float(rng.uniform(-0.10, 0.10))
    boxes = []
    def box(low, high, color, instance):
        boxes.append((np.array(low, float), np.array(high, float), np.array(color, float), instance))
    box((-2, -0.06, -4), (2, 0, 0.5), (0.58, 0.55, 0.49), 1)
    box((-0.43, 0.002, -3.5), (0.48, 0.008, -0.25), (0.36, 0.49, 0.44), 6)
    box((-2.05, 0, -4), (-2, 2.7, 0.5), (0.76, 0.78, 0.74), 2)
    box((2, 0, -4), (2.05, 2.7, 0.5), (0.75, 0.77, 0.72), 2)
    box((-2, 0, -3.65), (-0.30, 2.7, -3.60), (0.80, 0.79, 0.72), 2)
    box((0.65, 0, -3.65), (2, 2.7, -3.60), (0.80, 0.79, 0.72), 2)
    box((-0.30, 2.15, -3.65), (0.65, 2.7, -3.60), (0.80, 0.79, 0.72), 2)
    box((-0.29, 0.02, -3.62), (0.64, 2.14, -3.56), (0.38, 0.23, 0.12), 5)
    box((0.49, 0.95, -3.55), (0.57, 1.00, -3.48), (0.78, 0.67, 0.25), 5)
    # Bed: frame, mattress, contrasting blanket, headboard and two pillows.
    box((-1.80+offset, 0.12, -3.1), (-0.62+offset, 0.35, -1.20), (0.30, 0.18, 0.09), 3)
    box((-1.78+offset, 0.35, -3.08), (-0.64+offset, 0.56, -1.22), (0.85, 0.85, 0.79), 3)
    box((-1.76+offset, 0.56, -2.60), (-0.66+offset, 0.60, -1.24), (0.20, 0.35, 0.54), 3)
    box((-1.84+offset, 0.10, -3.18), (-0.58+offset, 1.0, -3.10), (0.34, 0.22, 0.12), 3)
    for x in (-1.72, -1.18):
        box((x+offset, 0.56, -3.02), (x+offset+0.46, 0.67, -2.67), (0.94, 0.92, 0.82), 3)
    # Table and four legs, all carrying one instance ID.
    box((0.78+offset, 0.76, -2.72), (1.84+offset, 0.84, -1.62), (0.58, 0.36, 0.17), 4)
    for x in (0.82, 1.70):
        for z in (-2.58, -1.76):
            box((x+offset, 0, z), (x+offset+0.09, 0.76, z+0.09), (0.36, 0.22, 0.10), 4)
    box((1.0, 0.41, -1.2), (1.50, 0.48, -0.70), (0.34, 0.19, 0.12), 7)
    box((1.0, 0.48, -0.78), (1.50, 1.08, -0.70), (0.40, 0.23, 0.13), 7)
    for x in (1.02, 1.40):
        for z in (-1.18, -0.80):
            box((x, 0, z), (x+0.07, 0.41, z+0.07), (0.30, 0.17, 0.10), 7)
    return boxes


def rays(width, height, position, yaw):
    scale_x, scale_y = width/WIDTH, height/HEIGHT
    u, v = np.meshgrid(np.arange(width), np.arange(height))
    # Original-image pixel centers use the same scaling contract as CameraIntrinsics.scaled.
    optical = np.stack(((u-CX*scale_x)/(FX*scale_x), (v-CY*scale_y)/(FY*scale_y), np.ones_like(u)), -1)
    c, s = math.cos(yaw), math.sin(yaw)
    rotation = np.array(((c, 0, s), (0, 1, 0), (-s, 0, c)))
    camera = optical * np.array((1, -1, -1))
    return camera @ rotation.T, optical, rotation


def trace(boxes, origin, directions):
    shape = directions.shape[:-1]
    nearest = np.full(shape, np.inf)
    ids = np.zeros(shape, np.uint8)
    colors = np.zeros((*shape, 3), float)
    normals = np.zeros((*shape, 3), float)
    # Avoid 0*infinity at parallel slab boundaries; handle those axes explicitly.
    inverse = np.divide(1.0, directions, out=np.zeros_like(directions), where=np.abs(directions)>1e-10)
    parallel = np.abs(directions)<=1e-10
    for low, high, color, instance in boxes:
        t1, t2 = (low-origin)*inverse, (high-origin)*inverse
        near, far = np.minimum(t1, t2), np.maximum(t1, t2)
        outside = parallel & ((origin<low) | (origin>high))
        near = np.where(parallel, -np.inf, near); far = np.where(parallel, np.inf, far)
        enter, leave = near.max(-1), far.min(-1)
        hit = (leave>=np.maximum(enter, 0)) & ~outside.any(-1) & (enter>0.0001) & (enter<nearest)
        axes = near.argmax(-1)
        surface_normal = np.zeros_like(directions)
        np.put_along_axis(surface_normal, axes[..., None], -np.sign(np.take_along_axis(directions, axes[..., None], axis=-1)), axis=-1)
        nearest[hit] = enter[hit]; ids[hit] = instance; colors[hit] = color; normals[hit] = surface_normal[hit]
    return nearest, ids, colors, normals


def render(seed, index, condition):
    boxes = room(seed)
    origin = np.array((0.035*math.sin(index*0.5), 1.15, -0.025*index))
    yaw = 0.045*math.sin(index*0.45)
    directions, optical, rotation = rays(WIDTH, HEIGHT, origin, yaw)
    distance, ids, color, normals = trace(boxes, origin, directions)
    light = np.array((-0.5, 0.8, 0.6)); light /= np.linalg.norm(light)
    shade = 0.35+0.65*np.maximum(0, normals @ light)
    # Small procedural texture and sensor perturbations; no photographic assets or people.
    rng = np.random.default_rng(seed*100_000+index)
    points = origin + directions*np.where(np.isfinite(distance), distance, 0)[..., None]
    texture = 0.96+0.04*np.sin(points[..., 0]*35)*np.sin(points[..., 2]*24)
    rgb = np.clip(color*shade[..., None]*texture[..., None], 0, 1)
    if condition == "dim": rgb *= 0.12
    rgb += rng.normal(0, 0.005 if condition != "dim" else 0.012, rgb.shape)
    rgb = np.uint8(np.clip(rgb, 0, 1)*255)
    output = io.BytesIO(); Image.fromarray(rgb).save(output, format="JPEG", quality=87, exif=b"")
    depth_rays, depth_optical, _ = rays(DW, DH, origin, yaw)
    ideal, depth_ids, _, _ = trace(boxes, origin, depth_rays)
    ranges = ideal*np.linalg.norm(depth_optical, axis=-1)
    valid = np.isfinite(ideal) & (ideal>=0.3) & (ranges<=4)
    noise = rng.normal(0, 0.003+0.001*np.nan_to_num(ideal, posinf=0)**2, ideal.shape)
    raw = ideal+noise
    dropout = rng.random(ideal.shape)<(0.35 if condition == "depthDropout" else 0.01)
    raw[~valid | dropout] = np.nan
    confidence = np.where(np.isfinite(raw), 2, 0).astype(np.uint8)
    ground_truth = []
    for instance, label in CATALOG.items():
        y, x = np.where(ids==instance)
        if len(x)<4: continue
        object_ranges = ranges[(depth_ids==instance) & np.isfinite(ranges)]
        ground_truth.append(dict(instanceID=instance, label=label,
            imageBounds=dict(minX=float(x.min()/WIDTH), minY=float(y.min()/HEIGHT), maxX=float((x.max()+1)/WIDTH), maxY=float((y.max()+1)/HEIGHT)),
            visiblePixels=int(len(x)), nearestVisibleRangeMeters=float(object_ranges.min()) if len(object_ranges) else None))
    transform = np.eye(4); transform[:3, :3] = rotation; transform[:3, 3] = origin
    return dict(jpeg=b64(output.getvalue()), depthFloat32LE=None if condition=="missingDepth" else b64(raw.astype("<f4").tobytes()),
        confidenceUInt8=None if condition=="missingDepth" else b64(confidence.tobytes()),
        idealDepthFloat32LE=b64(ideal.astype("<f4").tobytes()), instanceMaskUInt8=b64(depth_ids.tobytes()),
        groundTruth=ground_truth, cameraToWorld=transform.flatten(order="F").tolist(), lighting=condition,
        _rgb=rgb, _ideal=ideal, _raw=raw, _ids=ids)


def session(seed=303, split="test", condition="mixed", count=12):
    if split not in ("train", "validation", "test") or not 1<=count<=24 or condition not in (*CONDITIONS, "mixed"):
        raise ValueError("unsupported simulation configuration")
    environment=f"synthetic-room-{seed}"
    identity=uuid.uuid5(uuid.NAMESPACE_URL, f"{VERSION}/{seed}/{condition}")
    recipe=[(a.tolist(),b.tolist(),c.tolist(),i) for a,b,c,i in room(seed)]
    samples=[]
    for index in range(count):
        actual=CONDITIONS[min(3,index*4//count)] if condition=="mixed" else condition
        rendered=render(seed,index,actual)
        missing=actual=="missingDepth"
        time=float(index)
        frame=dict(metadataVersion=3, capabilityRevision=1,
            envelope=dict(schemaVersion=2,frameID=dict(sessionID=str(identity),generation=1,sequence=index+1),sourceMode="demoReplay",captureTimeMonotonic=time,createdTimeMonotonic=time,expiresAtMonotonic=time+0.3),
            imageSize=dict(width=WIDTH,height=HEIGHT),depthSize=None if missing else dict(width=DW,height=DH),
            confidenceSize=None if missing else dict(width=DW,height=DH),
            intrinsics=dict(fx=FX,fy=FY,cx=CX,cy=CY),cameraToWorld=rendered.pop("cameraToWorld"),
            orientation="landscapeRight",viewportSize=dict(width=WIDTH,height=HEIGHT),
            imageToDisplay=dict(a=1,b=0,c=0,d=1,tx=0,ty=0),depthKind="none" if missing else "sceneDepth",tracking="normal")
        samples.append(dict(frame=frame, rasterSize=dict(width=DW,height=DH), **{k:v for k,v in rendered.items() if not k.startswith("_")}))
    return dict(schemaVersion=1,synthetic=True,sourceMode="demoReplay",generator=VERSION,id=str(identity),
        environmentID=environment,split=split,layoutSHA256=hashlib.sha256(json.dumps(recipe,sort_keys=True).encode()).hexdigest(),
        description="Procedural cuboid room; generated labels and ideal depth are ground truth, not detector output.",
        limitations=["Not photorealistic or calibrated to an iPhone sensor", "No real-person data", "Floor corridor is a region label, not a validated clear route", "Cannot establish real-world detector accuracy or safety"],samples=samples)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output",type=Path); parser.add_argument("--demo-only",action="store_true")
    args=parser.parse_args(); args.output.mkdir(parents=True,exist_ok=False)
    datasets=[session()]
    if not args.demo_only:
        datasets += [session(seed,split,condition) for seed,split in ((101,"train"),(202,"validation"),(303,"test")) for condition in CONDITIONS]
    for data in datasets:
        name=f"{data['environmentID']}-{data['split']}-{data['id'][:8]}.lumasim.json"
        (args.output/name).write_text(json.dumps(data,separators=(",",":"),allow_nan=False),encoding="utf-8")
    print(json.dumps(dict(synthetic=True,sessions=len(datasets),frames=sum(len(d['samples']) for d in datasets),output=str(args.output.resolve()))))


if __name__=="__main__": main()
