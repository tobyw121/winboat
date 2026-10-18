#!/usr/bin/env python3
"""Verify both emulated adapters initialize at the selected boot dimensions.

Uses TCG and the non-GL virtio backend: no GPU or Windows guest required.
The GL variant inherits these same virtio GPU base properties.
"""
import json
import subprocess


for width, height in [(1024, 768), (1366, 768), (1920, 1080), (3840, 2160)]:
    commands = [{"execute": "qmp_capabilities", "id": "caps"}]
    expected = {}
    for adapter, path in [
        ("vga", "/machine/peripheral/helios-bootstrap"),
        ("helios", "/machine/peripheral/heliosgpu/virtio-backend"),
    ]:
        for prop, value in [("xres", width), ("yres", height)]:
            key = f"{adapter}-{prop}"
            expected[key] = value
            commands.append({"execute": "qom-get", "id": key,
                             "arguments": {"path": path, "property": prop}})
    commands.append({"execute": "qom-get", "id": "vram", "arguments": {
        "path": "/machine/peripheral/helios-bootstrap", "property": "vgamem_mb"}})
    expected["vram"] = 64
    commands.append({"execute": "quit", "id": "quit"})
    result = subprocess.run([
        "qemu-system-x86_64", "-machine", "q35", "-accel", "tcg",
        "-m", "128", "-S", "-nodefaults", "-display", "none",
        "-device", f"VGA,id=helios-bootstrap,xres={width},yres={height},vgamem_mb=64",
        "-device", f"virtio-gpu-pci,id=heliosgpu,xres={width},yres={height}",
        "-qmp", "stdio",
    ], input="".join(json.dumps(c) + "\n" for c in commands),
        text=True, capture_output=True, check=True, timeout=20)
    replies = [json.loads(line) for line in result.stdout.splitlines()]
    assert "QMP" in replies[0], result.stdout
    assert not any("error" in r for r in replies), result.stdout
    values = {r["id"]: r.get("return") for r in replies if "id" in r}
    assert all(values.get(key) == value for key, value in expected.items()), (expected, values)
    print(f"QEMU initialized VGA and Helios at {width}x{height}; VGA VRAM=64 MiB")
