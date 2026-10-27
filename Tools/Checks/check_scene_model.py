"""Verify pinned Core ML bytes, output names, embedded NMS labels and source/license without Core ML."""
import hashlib
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]


def varint(data, offset):
    value = 0
    for shift in range(0, 70, 7):
        byte = data[offset]; offset += 1
        value |= (byte & 127) << shift
        if byte < 128:
            return value, offset
    raise ValueError("invalid protobuf varint")


def fields(data):
    offset = 0
    while offset < len(data):
        tag, offset = varint(data, offset)
        kind, field = tag & 7, tag >> 3
        if kind == 0:
            value, offset = varint(data, offset)
        elif kind in (1, 5):
            size = 8 if kind == 1 else 4
            value = data[offset:offset+size]; offset += size
        elif kind == 2:
            size, offset = varint(data, offset)
            value = data[offset:offset+size]; offset += size
            if len(value) != size:
                raise ValueError("truncated protobuf")
        else:
            raise ValueError("unsupported protobuf field")
        yield field, value
    if offset != len(data):
        raise ValueError("protobuf extent mismatch")


def one(data, field):
    values = [value for key, value in fields(data) if key == field]
    if len(values) != 1:
        raise ValueError(f"expected exactly one field {field}")
    return values[0]


def main():
    source = (ROOT / "LumaPath/Shared/SceneObjectLabels.swift").read_text(encoding="utf-8")
    runtime = (ROOT / "LumaPath/Models/VisionInference.swift").read_text(encoding="utf-8")
    expected = re.search(r'rawClassNames = "([^"]+)"', source)[1].split("|")
    assets = [
        ("YOLOv3TinyFP16.mlmodel", 17_769_580, "73406178d0f5793d0d5d1e38274acd146a744c2245c9b63a11998a5015925dda"),
        ("YOLOv3Int8LUT.mlmodel", 62_200_325, "0e32f297ad9cfc0ea8e67276867956488c7ee10dc87c057da4debc939e20b76d"),
    ]
    for name, size, digest in assets:
        assert name.removesuffix(".mlmodel") in runtime and digest in runtime
        assert str(size) in runtime.replace("_", "")
        data = (ROOT / "LumaPath/Models/Assets" / name).read_bytes()
        assert len(data) == size
        assert hashlib.sha256(data).hexdigest() == digest
        description = one(data, 2)
        outputs = {one(value, 1).decode() for key, value in fields(description) if key == 10}
        assert outputs == {"coordinates", "confidence"}
        license_text = one(one(description, 100), 4).decode()
        assert "https://github.com/pjreddie/darknet" in license_text
        models = [value for key, value in fields(one(data, 202)) if key == 1]
        labels = [value.decode() for key, value in fields(one(one(models[-1], 610), 100)) if key == 1]
        assert labels == expected and len(set(labels)) == 80
        print(f"Verified {name}: {size:,} bytes, SHA-256, detection outputs, all 80 ordered NMS labels and Darknet license reference.")
    print("This does not compile or execute Core ML.")


if __name__ == "__main__":
    main()
