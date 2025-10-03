# Mini Video Uniquizer (macOS/Linux)

Fast starter kit to build your own *video uniquizer* without a bot.  
**Pipeline**: emulate bot-like transform → strip metadata → controlled transcode → subtle visual/audio tweaks → dynamic watermark → manifest.

> ⚠️ Use only on content you have rights to distribute. No script can guarantee 100% immunity from takedowns/complaints.

## Quick Start (macOS)

1. Install FFmpeg (if not installed):
   ```bash
   brew install ffmpeg
   ```
2. Unzip this kit and `cd` into the folder.
3. Make scripts executable:
   ```bash
   chmod +x process_protective.sh check_quality.sh run.sh
   ```
4. Drop your `.mp4`/`.mov` files into this folder.
5. Run **batch**:
   ```bash
   ./run.sh
   ```
   or process one file:
   ```bash
   ./process_protective.sh input.mov
   ```
6. Outputs: `*_final.mp4` + `manifest.csv`.  
   Optional quality check (if you also have `*_bot.*` pairs):
   ```bash
   ./check_quality.sh
   ```

## Tuning Quality
Open `process_protective.sh` and adjust:
- `TARGET_BITRATE="3000k"` → raise to `3500k`/`4000k` for higher quality.
- `NOISE_LEVEL=1` → keep small to avoid visible artifacts.
- `RANDOM_CROP_PX=2..4` → micro-crop/pad to alter pixel layout.
- `WATERMARK_OPACITY=0.08..0.12` → nearly invisible UID tag.

## Parallel Batch (Python)
`process_cli.py` runs multiple files in parallel:
```bash
python3 process_cli.py --jobs 4
```

## Optional: Docker (build locally)
This is a minimal example; ensure your base image has ffmpeg.
```
FROM ubuntu:22.04
RUN apt-get update && apt-get install -y ffmpeg python3 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY . /app
RUN chmod +x process_protective.sh check_quality.sh run.sh
CMD ["bash", "-lc", "./run.sh"]
```

## Notes
- The pipeline **does not** bypass legal rights or platform ToS.
- Advanced platforms may still detect content via audio/visual fingerprints or human review.
- For large-scale ops, rotate parameters (FPS, noise, crop), keep `manifest.csv`, and test small batches first (SSIM/PSNR).
