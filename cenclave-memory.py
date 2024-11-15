#!/usr/bin/env python3

import sys
from pathlib import Path

import tomli

units = {"B": 1, "K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4}


def human_readable_size(size):
    """Get a size as a human readable string-size."""
    for i, unit in enumerate(units.keys()):
        if size < 1024.0 or i == (len(units) - 1):
            break
        size /= 1024.0
    return f"{size:.2f}{unit}"


def parse_human_readable(size):
    """Convert a human readable string-size to an integer."""
    unit = size[-1]
    number = size[:-1]
    return int(float(number) * units[unit])


def run(manifest_path: Path):
    """Read the manifest.sgx to determine the effective enclave size."""
    with open(manifest_path, "rb") as f:
        manifest = tomli.load(f)

    enclave_size = parse_human_readable(manifest["sgx"]["enclave_size"])

    print("Declared enclave size:", human_readable_size(enclave_size))

    files_size = 0
    for item in manifest["sgx"]["trusted_files"]:
        path = Path(item["uri"].split(":")[1])
        if path.is_file():
            files_size += path.stat().st_size  # in bytes

    print("Files size:", human_readable_size(files_size))

    print(
        "Available app memory size:",
        human_readable_size(enclave_size - files_size),
    )


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <python.manifest.sgx>")
        exit(1)

    run(sys.argv[1])
