"""Check guest-visible SMBIOS/CPUID using a tiny diagnostic disk, never Windows."""
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import time
import uuid

directory = Path(sys.argv[1])
image = sys.argv[2]
settings = json.loads((directory / "settings.json").read_text())
# 16-bit boot sector: CPUID(1), test ECX bit 31, print 0/1 to debug port E9.
code = bytes.fromhex("31c08ed866b8010000000fa2660fbae11f7206b030e6e9ebfeb031e6e9ebfe")
with open(directory / "boot.img", "wb") as diagnostic_disk:
    diagnostic_disk.write(code.ljust(510, b"\0") + b"\x55\xaa")
    diagnostic_disk.truncate(16 * 1024 * 1024)


def parse_tables(data):
    records = {}
    offset = 0
    while offset + 4 <= len(data):
        kind, length = data[offset:offset + 2]
        assert length >= 4, "Invalid SMBIOS structure length"
        end = data.index(b"\0\0", offset + length)
        strings = data[offset + length:end].split(b"\0")
        assert kind not in records or kind not in (1, 2, 3), "Duplicate identity table"
        records[kind] = (data[offset:offset + length], strings)
        offset = end + 2
        if kind == 127:
            break
    return records


for case in settings["cases"]:
    reduced = case["reduced"]
    name = f"winboat-identity-test-{os.getpid()}-{int(reduced)}"
    env = [item for key, value in case["environment"].items() for item in ("-e", f"{key}={value}")]
    boot = """
set -Eeuo pipefail
APP=Windows DEBUG=N ARCH=amd64 CPU=Test BOOT_MODE=windows KVM=N CPU_MODEL=max ARGUMENTS=''
source /run/utils.sh
source /run/proc.sh >&2
exec qemu-system-x86_64 -machine q35,accel=tcg -m 128M -nodefaults \
    -cpu "$CPU_FLAGS" $SM_BIOS -uuid "$UUID" -display none -serial none -monitor none \
    -drive file=/identity/boot.img,format=raw,if=ide -boot c -no-reboot \
    -chardev file,id=bootdebug,path=/identity/cpu.out -device isa-debugcon,iobase=0xe9,chardev=bootdebug \
    -chardev file,id=biosdebug,path=/identity/bios.log -device isa-debugcon,iobase=0x402,chardev=biosdebug -qmp stdio
"""
    output = directory / "cpu.out"
    output.unlink(missing_ok=True)
    errors = open(directory / "qemu.log", "w+")
    process = subprocess.Popen(["docker", "run", "--rm", "-i", "--name", name, "--network", "none",
                                "-v", f"{directory}:/identity", "-v", f"{directory / 'hardware'}:/storage/.winboat-hardware:ro",
                                *env, "--entrypoint", "bash", image, "-c", boot],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors)
    buffer = b""

    def receive(timeout=90):
        global buffer
        deadline = time.monotonic() + timeout
        while True:
            if b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                if line.strip():
                    return json.loads(line)
            remaining = deadline - time.monotonic()
            assert remaining > 0, "QMP timed out"
            readable, _, _ = select.select([process.stdout], [], [], remaining)
            assert readable, "QMP timed out"
            chunk = os.read(process.stdout.fileno(), 65536)
            assert chunk, "QEMU exited before its QMP response"
            buffer += chunk

    def command(execute, arguments=None):
        message = {"execute": execute, "id": "identity-check"}
        if arguments is not None:
            message["arguments"] = arguments
        process.stdin.write((json.dumps(message) + "\n").encode())
        process.stdin.flush()
        while True:
            response = receive(10)
            if response.get("id") == "identity-check":
                assert "error" not in response, response
                return response["return"]

    def dump(address, size, filename):
        result = command("human-monitor-command", {"command-line": f'pmemsave 0x{address:x} 0x{size:x} "/identity/{filename}"'})
        assert not result.strip(), result
        return (directory / filename).read_bytes()

    try:
        assert "QMP" in receive()
        command("qmp_capabilities")
        deadline = time.monotonic() + 15
        while not output.exists() or not output.read_bytes():
            assert time.monotonic() < deadline, "Diagnostic boot sector did not execute"
            assert process.poll() is None, "QEMU stopped during boot"
            time.sleep(0.05)
        assert output.read_bytes() == (b"0" if reduced else b"1"), "Guest CPUID hypervisor bit differs from the selected mode"
        command("stop")
        memory = dump(0, 0x100000, "memory.bin")
        table_address = table_size = 0
        for offset in range(0xF0000, 0x100000 - 32, 16):
            if memory[offset:offset + 5] == b"_SM3_" and sum(memory[offset:offset + memory[offset + 6]]) % 256 == 0:
                table_size = int.from_bytes(memory[offset + 12:offset + 16], "little")
                table_address = int.from_bytes(memory[offset + 16:offset + 24], "little")
                break
            if memory[offset:offset + 4] == b"_SM_" and sum(memory[offset:offset + memory[offset + 5]]) % 256 == 0:
                table_size = int.from_bytes(memory[offset + 22:offset + 24], "little")
                table_address = int.from_bytes(memory[offset + 24:offset + 28], "little")
                break
        assert 0 < table_size < 0x100000 and table_address > 0, "Firmware SMBIOS entry point not found"
        records = parse_tables(dump(table_address, table_size, "tables.bin"))
        profile = settings["profile"]
        for kind, fields in [(1, ["systemManufacturer", "systemProduct", "systemVersion", "systemSerial"]),
                             (2, ["boardManufacturer", "boardProduct", "boardVersion", "boardSerial"])]:
            formatted, strings = records[kind]
            for index, field in enumerate(fields, 4):
                assert strings[formatted[index] - 1].decode() == profile[field], field
        assert str(uuid.UUID(bytes_le=records[1][0][8:24])) == profile["uuid"]
        assert records[3][1][records[3][0][7] - 1].decode() == profile["chassisSerial"]
        command("quit")
        assert process.wait(timeout=10) == 0
        print(f"Guest SMBIOS, UUID, serials and CPUID passed: reduced CPU identifiers={reduced}", flush=True)
    except Exception:
        if process.poll() is None:
            print(command('human-monitor-command', {'command-line': 'info registers'}), file=sys.stderr)
        if (directory / 'bios.log').exists():
            print((directory / 'bios.log').read_text(errors='replace')[-6000:], file=sys.stderr)
        errors.seek(0)
        print(errors.read(), file=sys.stderr)
        raise
    finally:
        subprocess.run(["docker", "rm", "-f", name], capture_output=True, timeout=30)
        process.wait(timeout=10)
        errors.close()
