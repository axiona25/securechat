#!/usr/bin/env python3
"""Generate call sound effects as WAV files for SecureChat."""
import math
import os
import struct
import wave

SOUNDS_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "assets", "sounds")
os.makedirs(SOUNDS_DIR, exist_ok=True)
SAMPLE_RATE = 44100


def generate_wav(filename, segments):
    """Generate a WAV file from segments of (freq_hz, duration_sec, volume) tuples."""
    filepath = os.path.join(SOUNDS_DIR, filename)
    samples = []
    for freq, duration, volume in segments:
        num_samples = int(SAMPLE_RATE * duration)
        for i in range(num_samples):
            if freq == 0:
                samples.append(0)
            else:
                t = i / SAMPLE_RATE
                sample = volume * math.sin(2 * math.pi * freq * t)
                samples.append(max(-32768, min(32767, int(sample * 32767))))
    with wave.open(filepath, "w") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(SAMPLE_RATE)
        frames = b"".join(struct.pack("<h", s) for s in samples)
        wav.writeframes(frames)
    return filepath


# Ringback tone: 440 Hz 1 s on, 3 s off (repeated 10 times = 40 s)
segments = []
for _ in range(10):
    segments.append((440, 1.0, 0.3))
    segments.append((0, 3.0, 0))
generate_wav("ringback.wav", segments)

# Ringtone: 800 Hz + 1000 Hz alternating, 0.5 s on, 0.5 s off (20 times = 20 s)
segments = []
for _ in range(20):
    segments.append((800, 0.25, 0.4))
    segments.append((1000, 0.25, 0.4))
    segments.append((0, 0.5, 0))
generate_wav("ringtone.wav", segments)

# Busy tone: 480 Hz 0.5 s on, 0.5 s off (6 times = 6 s)
segments = []
for _ in range(6):
    segments.append((480, 0.5, 0.4))
    segments.append((0, 0.5, 0))
generate_wav("busy.wav", segments)

# End call: short beep 0.2 s
generate_wav("end.wav", [(660, 0.2, 0.4)])

print("Generated: ringback.wav, ringtone.wav, busy.wav, end.wav in", SOUNDS_DIR)
