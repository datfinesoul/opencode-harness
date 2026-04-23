# FFmpeg Transcoding Cluster with Miscellaneous Hardware

## Overview

This document covers FFmpeg transcoding performance characteristics, hardware acceleration support, and practical guidance for building a distributed transcoding cluster using a mixed bag of old hardware: Android/iPad tablets, an old Mac laptop, and a System76 Lemur.

---

## Architecture: Redis Queue + Worker Nodes

The described setup (Redis queue → worker nodes → Postgres + network storage) maps cleanly to a **pull-based worker model**:

```
[Redis Queue]
      |
   (job)
      |
   Worker (any machine)
      |-- ffmpeg process
      |-- write output to NFS/SMB share
      |-- update Postgres with result
```

Each machine polls Redis for jobs, runs ffmpeg, writes output, and records completion. This is stateless and horizontally scalable — every machine just needs:

- Network access to Redis
- Network access to the shared drive (NFS/SMB)
- Network access to Postgres
- ffmpeg installed

Recommended queue libraries by language:
- **Python**: `rq`, `celery` with Redis broker
- **Node.js**: `bull` / `bullmq`
- **Go**: `asynq`

---

## FFmpeg Hardware Acceleration Overview

FFmpeg supports offloading encode/decode to dedicated silicon on the device (ASIC/NPU), which is dramatically faster and more power-efficient than CPU-only software encoding.

| API | Platform | Notes |
|-----|----------|-------|
| VideoToolbox | macOS / iOS | Apple hardware encoder/decoder |
| VAAPI | Linux (Intel/AMD) | Intel Quick Sync, AMD VCE |
| NVENC/NVDEC | Linux/Windows (Nvidia) | Not relevant for these devices |
| MediaCodec | Android | Hardware encode/decode on tablets |
| V4L2 | Linux ARM | Qualcomm, Exynos, etc. |
| OpenCL | Cross-platform | GPU-based acceleration |
| Quick Sync (QSV) | Intel iGPU | Available via VAAPI on Linux |

---

## Device-by-Device Analysis

### Mac Laptop (Intel, pre-M1)

If the Mac laptop has an **Intel CPU with Sandy Bridge or newer** (2011+), it has Intel Quick Sync Video hardware:

- **H.264 encode/decode**: all generations from Sandy Bridge (2011)
- **HEVC (H.265) encode/decode**: Skylake (6th gen, 2015) and newer
- **VP9 decode**: Kaby Lake (7th gen, 2016) and newer
- **AV1 decode**: Tiger Lake (11th gen, 2020) and newer

FFmpeg on macOS uses **VideoToolbox** for hardware acceleration:

```bash
# H.264 hardware encode via VideoToolbox
ffmpeg -i input.mp4 -c:v h264_videotoolbox -b:v 4M output.mp4

# HEVC hardware encode
ffmpeg -i input.mp4 -c:v hevc_videotoolbox -b:v 3M output.mp4
```

Quick Sync on macOS: Apple exposed Quick Sync starting in OS X Mountain Lion for system apps, and VideoToolbox exposes it to third-party software including FFmpeg.

**Capability**: This machine can do real hardware-accelerated transcoding and is likely your most capable worker for video work, especially if it has a recent enough Intel iGPU.

---

### Mac Laptop (Apple Silicon M1/M2)

If it's an Apple Silicon Mac, the media engine is exceptional:

- **M1**: hardware H.264 + HEVC encode/decode via VideoToolbox; also ProRes decode
- **M1 Pro/Max**: dedicated media engine with H.264, HEVC, ProRes, ProRes RAW; M1 Max has 2 encode engines, 4 ProRes engines
- **M2+**: adds AV1 hardware decode

FFmpeg commands are the same (VideoToolbox), but the underlying hardware is far more capable. An M1 Mac can transcode multiple 4K streams simultaneously.

**Capability**: The single best machine in this list if it is Apple Silicon.

---

### System76 Lemur Pro

The Lemur Pro (lemp) runs Linux and ships with an **Intel Core i5/i7 (Tiger Lake, 11th gen, U-series)**. This means:

- Intel Quick Sync Video via VA-API
- H.264, HEVC (8-bit and 10-bit), VP9, AV1 **hardware decode**
- H.264, HEVC encode in hardware
- Low TDP (~28W) — designed for battery life, not sustained throughput

FFmpeg on Linux with Intel VAAPI:

```bash
# Check VAAPI device
vainfo

# H.264 hardware encode via VAAPI
ffmpeg -hwaccel vaapi -hwaccel_device /dev/dri/renderD128 \
  -i input.mp4 \
  -vf 'format=nv12,hwupload' \
  -c:v h264_vaapi -b:v 4M output.mp4

# HEVC via VAAPI
ffmpeg -hwaccel vaapi -hwaccel_device /dev/dri/renderD128 \
  -i input.mp4 \
  -vf 'format=nv12,hwupload' \
  -c:v hevc_vaapi -b:v 3M output.mp4
```

Required packages on Ubuntu/Debian:
```bash
apt install ffmpeg vainfo intel-media-va-driver-non-free
```

**Capability**: Good hardware-accelerated transcoding. Better sustained throughput than tablets. However, the U-series chip is not high-performance — expect moderate throughput on complex jobs. Best used for H.264 output targeting H.264/HEVC input.

---

### Old Tablets (Android)

Android tablets with a reasonably modern SoC (Qualcomm Snapdragon, Samsung Exynos, MediaTek) have hardware video codecs accessible via **MediaCodec API**. However, running ffmpeg directly on Android is significantly constrained:

#### Option A: Termux + ffmpeg
- Install [Termux](https://termux.dev) from F-Droid
- `pkg install ffmpeg`
- ffmpeg in Termux is **software-only** (no MediaCodec access from the CLI tool)
- Very slow for any real transcoding workload
- CPU-only software encoding on a mobile ARM chip is painful — even 720p H.264 may run at <1x realtime

#### Option B: Custom Android App with MediaCodec
- Build an Android app using MediaCodec API directly
- Can access hardware encode/decode
- Significant development investment
- Practical for a startup project if you control the build pipeline

#### Option C: Use as a Coordinator/Proxy Only
- Tablets act as Redis clients that just poll and dispatch, not actually transcode
- Offload actual encoding to the Mac/Lemur

#### Option D: Remote ffmpeg via SSH
- Run ffmpeg on a capable machine but trigger and monitor it from the tablet
- Tablets run a thin client only

**Recommendation**: Tablets are a poor fit for CPU-based ffmpeg transcoding. If you're set on using them, they work best as job dispatchers or monitors, not workers. If you must use them as workers, use a pre-built Android app with MediaCodec access rather than Termux ffmpeg.

---

### Old iPad Tablets

iPads have very capable Apple-silicon video hardware (A-series chips), but:

- **No terminal access / no ffmpeg** without jailbreaking
- Cannot run worker process in the background
- Severely sandboxed

**Practical use**: iPads have essentially no role as transcoding workers unless jailbroken. Use them purely as monitoring dashboards (web UI for queue status).

---

## Realistic Performance Expectations

| Device | Method | H.264 1080p throughput |
|--------|--------|----------------------|
| Mac (Apple Silicon M1) | VideoToolbox HW | 10–30x realtime |
| Mac (Intel, 8th-11th gen) | VideoToolbox / Quick Sync | 3–10x realtime |
| Mac (Intel, older) | VideoToolbox (if supported) / SW | 1–5x realtime |
| Lemur Pro (Tiger Lake) | VAAPI | 3–8x realtime |
| Android tablet (HW) | MediaCodec app | 2–5x realtime |
| Android tablet (SW via Termux) | libx264 CPU | 0.3–1x realtime |
| iPad | N/A (not usable) | — |

---

## Network Storage Considerations

Writing transcoded files to a network drive adds latency:

- **NFS** (Linux → Linux): low overhead, good sustained throughput
- **SMB** (cross-platform): slightly higher overhead, works everywhere
- For large output files (1080p+), ensure the network link is **gigabit (1GbE)**; Wi-Fi will bottleneck on large writes
- For image transcoding (smaller files), Wi-Fi is generally fine

Recommended: wire the Mac and Lemur to the LAN, let tablets work over Wi-Fi.

---

## Recommended Architecture

```
┌─────────────────────────────────────┐
│  Job Producer (your app)            │
│  → push jobs to Redis               │
└────────────────┬────────────────────┘
                 │
         ┌───────▼────────┐
         │   Redis Queue  │
         └───┬───┬────────┘
             │   │
   ┌─────────┘   └────────────┐
   ▼                          ▼
┌──────────────┐    ┌──────────────────┐
│  Mac Laptop  │    │  System76 Lemur  │
│  VideoToolbox│    │  VAAPI (QSV)     │
│  worker.py   │    │  worker.py       │
└──────┬───────┘    └────────┬─────────┘
       │                     │
       └──────┬──────────────┘
              ▼
    ┌──────────────────┐    ┌──────────┐
    │  Network Drive   │    │ Postgres │
    │  (NFS/SMB)       │    │          │
    └──────────────────┘    └──────────┘

Android Tablets → monitoring dashboard only
iPads → monitoring dashboard only
```

---

## Worker Process Pseudocode

```python
import subprocess, redis, psycopg2

r = redis.Redis(host='redis-host')
pg = psycopg2.connect("dbname=jobs user=...")

while True:
    job = r.blpop('transcode_queue', timeout=5)
    if not job:
        continue

    job_id, input_path, output_path, params = parse(job)

    result = subprocess.run([
        'ffmpeg',
        '-hwaccel', 'videotoolbox',   # or 'vaapi' on Linux
        '-i', input_path,
        '-c:v', 'h264_videotoolbox',  # or 'h264_vaapi'
        *params,
        output_path
    ])

    status = 'done' if result.returncode == 0 else 'failed'
    pg.execute("UPDATE jobs SET status=%s WHERE id=%s", (status, job_id))
    pg.commit()
```

---

## Image Transcoding Notes

For image jobs (JPEG, PNG, WebP, AVIF conversion), ffmpeg handles this well via its image muxers:

```bash
# Convert PNG to WebP
ffmpeg -i input.png output.webp

# Convert JPEG to AVIF
ffmpeg -i input.jpg output.avif

# Resize + convert
ffmpeg -i input.jpg -vf scale=800:-1 output.webp
```

Image transcoding is CPU-bound (no GPU acceleration path in most cases), so all machines including tablets (via Termux) are more viable here — image files are small and conversion is fast even in software.

---

## Key Takeaways

1. **Mac laptop + Lemur** are your real transcoding workers. Focus hardware acceleration effort there.
2. **Tablets (Android)** can contribute for image jobs in Termux, but are impractical for video.
3. **iPads** are useful only as dashboards.
4. Use **VideoToolbox** on macOS and **VAAPI** on Linux for hardware acceleration.
5. Verify Quick Sync generation on the Intel Mac — Skylake (6th gen, 2015) or newer is needed for HEVC; Kaby Lake (7th gen) for VP9.
6. Ensure the shared drive is on a **wired gigabit** connection, not Wi-Fi, for video output.
7. The Redis pull model scales cleanly — add or remove workers without changing the queue.
