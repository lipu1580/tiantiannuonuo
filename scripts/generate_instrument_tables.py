#!/usr/bin/env python3
"""Generate one-period, signed 16-bit harmonic wavetables (stdlib only)."""

import math
from pathlib import Path


TABLE_SIZE = 1024
PEAK = 32767
OUTPUT_DIR = Path(__file__).resolve().parents[1] / "rtl" / "audio"
# Coefficients are relative sine-harmonic amplitudes, not runtime DDS units.
PRESETS = {
    "organ_1024.hex": (1.0, 0.50, 0.25, 0.125),
    "pluck_1024.hex": (1.0, 0.62, 0.45, 0.32, 0.24, 0.17, 0.12, 0.08),
}


def generate(coefficients):
    raw = [
        sum(
            amplitude * math.sin(2.0 * math.pi * harmonic * index / TABLE_SIZE)
            for harmonic, amplitude in enumerate(coefficients, start=1)
        )
        for index in range(TABLE_SIZE)
    ]
    scale = PEAK / max(abs(value) for value in raw)
    # Explicit symmetric nearest rounding avoids a negative DC truncation bias.
    samples = [
        int(math.copysign(math.floor(abs(value * scale) + 0.5), value))
        for value in raw
    ]
    if min(samples) != -PEAK or max(samples) != PEAK or sum(samples) != 0:
        raise ValueError("wavetable must have symmetric full-scale peaks and zero DC")
    if any(samples[index] != -samples[-index] for index in range(1, TABLE_SIZE)):
        raise ValueError("wavetable lost its periodic odd symmetry")
    return samples


def main():
    for filename, coefficients in PRESETS.items():
        samples = generate(coefficients)
        path = OUTPUT_DIR / filename
        path.write_text("".join(f"{value & 0xFFFF:04X}\n" for value in samples), encoding="ascii")
        print(f"{filename}: {len(samples)} samples, {len(coefficients)} harmonics, "
              f"range=[{min(samples)}, {max(samples)}], DC={sum(samples)}")


if __name__ == "__main__":
    main()
