#!/usr/bin/env python3
"""
Image / Video → Brainfuck converter (Brainmelt display dialect).

Tape cells hold pixel data; * pushes a frame. Video frames are delta-encoded
(tape is not cleared between frames) and separated with @ (no-op).

Color modes:
  g  grayscale (1 byte / pixel)
  p  palette   (1 byte index / pixel, same HSV rainbow as generatePalette.lua)
  r  RGB       (3 bytes / pixel)

Streams BF to the output file (constant memory w.r.t. frame count).
Decodes video frames on a background thread.
"""

from __future__ import annotations

import argparse
import json
import queue
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Generator, Iterable, List, Optional, Sequence, TextIO, Tuple

try:
    from PIL import Image
except ImportError:
    print("error: Pillow is required (pip install Pillow)", file=sys.stderr)
    sys.exit(1)

try:
    import cv2  # type: ignore
    HAS_CV2 = True
except ImportError:
    HAS_CV2 = False

HAS_FFMPEG = shutil.which("ffmpeg") is not None and shutil.which("ffprobe") is not None
SAMPLE_RATE = 8000
PCM_SILENCE = 128

# Sentinel for the decode queue
_END = object()


# ---------------------------------------------------------------------------
# Palette (exact match to generatePalette.lua)
# ---------------------------------------------------------------------------

def build_palette() -> List[Tuple[int, int, int]]:
    colors: List[Tuple[int, int, int]] = [(0, 0, 0)]
    for index in range(1, 256):
        hue = (index - 1) / 255 * 6
        sector = int(hue)
        fraction = hue - sector
        rising = int(fraction * 255 + 0.5)
        falling = 255 - rising
        if sector == 0:
            r, g, b = 255, rising, 0
        elif sector == 1:
            r, g, b = falling, 255, 0
        elif sector == 2:
            r, g, b = 0, 255, rising
        elif sector == 3:
            r, g, b = 0, falling, 255
        elif sector == 4:
            r, g, b = rising, 0, 255
        else:
            r, g, b = 255, 0, falling
        colors.append((r, g, b))
    return colors


PALETTE = build_palette()


def nearest_palette_index(r: int, g: int, b: int) -> int:
    best = 0
    best_dist = 1 << 30
    for i, (pr, pg, pb) in enumerate(PALETTE):
        d = (r - pr) * (r - pr) + (g - pg) * (g - pg) + (b - pb) * (b - pb)
        if d < best_dist:
            best_dist = d
            best = i
            if d == 0:
                break
    return best


# ---------------------------------------------------------------------------
# Pixel sampling
# ---------------------------------------------------------------------------

def image_to_cells(
    img: Image.Image,
    width: int,
    height: int,
    mode: str,
) -> List[int]:
    """Resize and convert an image to a flat list of tape cell values."""
    resized = img.convert("RGBA").resize((width, height), Image.Resampling.NEAREST)
    pixels = resized.getdata()
    cells: List[int] = []
    append = cells.append
    extend = cells.extend

    if mode == "r":
        for r, g, b, a in pixels:
            if a < 16:
                r = g = b = 0
            extend((r, g, b))
    elif mode == "p":
        for r, g, b, a in pixels:
            if a < 16:
                r = g = b = 0
            append(nearest_palette_index(r, g, b))
    else:
        for r, g, b, a in pixels:
            if a < 16:
                r = g = b = 0
            y = int(0.299 * r + 0.587 * g + 0.114 * b + 0.5)
            append(0 if y < 0 else 255 if y > 255 else y)
    return cells


# ---------------------------------------------------------------------------
# Brainfuck emission (streaming)
# ---------------------------------------------------------------------------

def emit_move(src: int, dst: int) -> str:
    d = dst - src
    if d > 0:
        return ">" * d
    if d < 0:
        return "<" * (-d)
    return ""


def emit_set(current: int, target: int) -> str:
    delta = (target - current) % 256
    if delta > 128:
        delta -= 256
    if delta > 0:
        return "+" * delta
    if delta < 0:
        return "-" * (-delta)
    return ""


def encode_delta(
    prev: Optional[Sequence[int]],
    nxt: Sequence[int],
    start_ptr: int,
    width: int,
    mode: str,
    wrap_rows: bool,
) -> Tuple[str, int]:
    bpp = 3 if mode == "r" else 1
    row_bytes = width * bpp
    ptr = start_ptr
    parts: List[str] = []

    for i, tgt in enumerate(nxt):
        cur = prev[i] if prev is not None else 0
        if cur == tgt:
            continue
        parts.append(emit_move(ptr, i))
        parts.append(emit_set(cur, tgt))
        ptr = i
        if wrap_rows:
            at_row_end = (
                (i + 1) % width == 0
                if bpp == 1
                else (i + 1) % row_bytes == 0
            )
            if at_row_end:
                parts.append("\n")

    return "".join(parts), ptr


def optimize_chunk(code: str, keep_newlines: bool = False) -> str:
    """Local peephole: cancel opposing pairs. Does not keep full program in RAM."""
    if not code:
        return code
    if keep_newlines:
        s = "".join(c for c in code if c != " " and c != "\t" and c != "\r")
    else:
        s = "".join(c for c in code if not c.isspace())

    pairs = (("<>", ""), ("><", ""), ("+-", ""), ("-+", ""))
    prev = None
    while s != prev:
        prev = s
        for a, b in pairs:
            s = s.replace(a, b)
    return s


# ---------------------------------------------------------------------------
# Progress bar (no external deps)
# ---------------------------------------------------------------------------

def format_progress(done: int, total: Optional[int], start: float, prefix: str = "") -> str:
    elapsed = max(0.001, time.monotonic() - start)
    rate = done / elapsed
    if total and total > 0:
        pct = min(100.0, 100.0 * done / total)
        bar_w = 24
        filled = int(bar_w * done / total)
        bar = "█" * filled + "░" * (bar_w - filled)
        eta = (total - done) / rate if rate > 0 else 0
        return (
            f"\r{prefix}[{bar}] {done}/{total} ({pct:5.1f}%) "
            f"{rate:5.1f} fr/s ETA {eta:6.1f}s"
        )
    return f"\r{prefix}{done} frames ({rate:5.1f} fr/s) {elapsed:6.1f}s"


# ---------------------------------------------------------------------------
# Video / image frame sources (generators — constant memory)
# ---------------------------------------------------------------------------

def probe_duration(path: Path) -> float:
    try:
        r = subprocess.run(
            [
                "ffprobe", "-v", "error",
                "-show_entries", "format=duration",
                "-of", "json",
                str(path),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if r.returncode != 0:
            return 0.0
        data = json.loads(r.stdout or "{}")
        return float(data.get("format", {}).get("duration") or 0.0)
    except (json.JSONDecodeError, ValueError, OSError):
        return 0.0


def probe_has_audio(path: Path) -> bool:
    result = subprocess.run(
        [
            "ffprobe", "-v", "error", "-select_streams", "a:0",
            "-show_entries", "stream=index", "-of", "json", str(path),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(f"cannot inspect audio stream: {result.stderr.strip()}")
    return bool(json.loads(result.stdout or "{}").get("streams"))


def iter_audio_blocks(path: Path, block_size: int) -> Generator[List[int], None, None]:
    """Decode the first audio track as streaming 8 kHz unsigned 8-bit mono PCM."""
    proc = subprocess.Popen(
        [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(path),
            "-map", "0:a:0", "-vn", "-ac", "1", "-ar", str(SAMPLE_RATE),
            "-acodec", "pcm_u8", "-f", "u8", "pipe:1",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        bufsize=block_size * 4,
    )
    assert proc.stdout is not None
    try:
        while True:
            block = bytearray()
            while len(block) < block_size:
                data = proc.stdout.read(block_size - len(block))
                if not data:
                    break
                block.extend(data)
            if not block:
                break
            if len(block) < block_size:
                block.extend([PCM_SILENCE] * (block_size - len(block)))
            yield list(block)

        stderr = proc.stderr.read().decode("utf-8", errors="replace") if proc.stderr else ""
        ret = proc.wait()
        if ret != 0:
            raise RuntimeError(f"ffmpeg audio decode failed (code {ret}): {stderr.strip()}")
    finally:
        if proc.poll() is None:
            proc.terminate()
            proc.wait()


def encode_audio_delta(
    prev: Sequence[int],
    nxt: Sequence[int],
    start_ptr: int,
    offset: int,
) -> Tuple[str, int]:
    ptr = start_ptr
    parts: List[str] = []
    for index, target in enumerate(nxt):
        if prev[index] == target:
            continue
        cell = offset + index
        parts.append(emit_move(ptr, cell))
        parts.append(emit_set(prev[index], target))
        ptr = cell
    parts.append(";")
    return "".join(parts), ptr


def estimate_frame_count(duration: float, fps: float, max_frames: Optional[int]) -> Optional[int]:
    if duration <= 0 or fps <= 0:
        return max_frames
    n = int(duration * fps + 0.5)
    if max_frames is not None:
        n = min(n, max_frames)
    return max(1, n)


def iter_video_frames_ffmpeg(
    path: Path,
    width: int,
    height: int,
    mode: str,
    fps: float,
    max_frames: Optional[int],
    frame_queue: queue.Queue,
) -> None:
    """
    Background worker: run ffmpeg, decode PNG frames from a pipe-ish temp
    pattern as they appear, convert to cells, push into queue.
    Pushes _END when finished (or on error, pushes an Exception).
    """
    try:
        vf = f"fps={fps}"
        # Stream raw RGB frames through stdout — no temp files, low memory
        # scale to target size inside ffmpeg for less Python work
        vf = f"fps={fps},scale={width}:{height}:flags=neighbor"
        cmd = [
            "ffmpeg", "-hide_banner", "-loglevel", "error",
            "-i", str(path),
            "-vf", vf,
            "-f", "rawvideo",
            "-pix_fmt", "rgba",
        ]
        if max_frames is not None and max_frames > 0:
            cmd += ["-frames:v", str(max_frames)]
        cmd += ["pipe:1"]

        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=10 ** 7,
        )
        assert proc.stdout is not None

        frame_size = width * height * 4  # RGBA
        produced = 0
        while True:
            if max_frames is not None and produced >= max_frames:
                break
            buf = proc.stdout.read(frame_size)
            if not buf or len(buf) < frame_size:
                break
            img = Image.frombytes("RGBA", (width, height), buf)
            cells = image_to_cells(img, width, height, mode)
            # image_to_cells resizes again — already sized; still OK / cheap
            # Actually already at width x height; resize is no-op-ish
            frame_queue.put(cells)
            produced += 1

        stderr = ""
        if proc.stderr:
            stderr = proc.stderr.read().decode("utf-8", errors="replace")
        ret = proc.wait()
        if ret != 0 and produced == 0:
            frame_queue.put(RuntimeError(f"ffmpeg failed (code {ret}): {stderr.strip()}"))
        else:
            frame_queue.put(_END)
    except Exception as exc:  # noqa: BLE001 — delivered to consumer
        frame_queue.put(exc)


def iter_video_frames_cv2(
    path: Path,
    width: int,
    height: int,
    mode: str,
    fps: float,
    max_frames: Optional[int],
) -> Generator[List[int], None, None]:
    cap = cv2.VideoCapture(str(path))
    if not cap.isOpened():
        raise RuntimeError(f"cannot open video '{path}'")

    src_fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
    duration = total / src_fps if src_fps > 0 else 0.0
    interval = 1.0 / fps if fps > 0 else 1.0

    t = 0.0
    produced = 0
    while t < duration or (duration == 0.0 and produced == 0):
        if max_frames is not None and produced >= max_frames:
            break
        cap.set(cv2.CAP_PROP_POS_MSEC, t * 1000.0)
        ok, bgr = cap.read()
        if not ok:
            if produced == 0:
                cap.set(cv2.CAP_PROP_POS_FRAMES, 0)
                ok, bgr = cap.read()
            if not ok:
                break
        rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
        pil = Image.fromarray(rgb)
        yield image_to_cells(pil, width, height, mode)
        produced += 1
        t += interval
    cap.release()


def iter_image_frames(
    path: Path,
    width: int,
    height: int,
    mode: str,
    max_frames: Optional[int],
) -> Generator[List[int], None, None]:
    img = Image.open(path)
    n = getattr(img, "n_frames", 1)
    if max_frames is not None:
        n = min(n, max_frames)
    for i in range(n):
        try:
            img.seek(i)
        except EOFError:
            break
        yield image_to_cells(img, width, height, mode)


# ---------------------------------------------------------------------------
# Streaming program writer
# ---------------------------------------------------------------------------

def stream_program(
    frames: Iterable[List[int]],
    out: TextIO,
    width: int,
    height: int,
    mode: str,
    memsize: int,
    wrap_rows: bool,
    expected_frames: Optional[int] = None,
    quiet: bool = False,
    audio_blocks: Optional[Iterable[List[int]]] = None,
    sound_length: int = 0,
    audio_fps: float = 0.0,
) -> Tuple[int, int, int]:
    """
    Consume frames one at a time, write BF incrementally.
    Returns (frame_count, suggested_memsize, bytes_written).
    """
    bpp = 3 if mode == "r" else 1
    frame_bytes = width * height * bpp
    audio_offset = frame_bytes
    needed = max(memsize, frame_bytes + sound_length if audio_blocks is not None else frame_bytes)
    if needed < frame_bytes + 16:
        needed = frame_bytes + 16

    prev: Optional[List[int]] = None
    ptr = 0
    count = 0
    written = 0
    audio_iterator = iter(audio_blocks) if audio_blocks is not None else None
    audio_previous = [0] * sound_length
    audio_samples_queued = 0
    start = time.monotonic()
    last_draw = 0.0

    for frame in frames:
        chunk_parts: List[str] = []
        if count > 0:
            chunk_parts.append("\n@\n" if wrap_rows else "@")

        code, ptr = encode_delta(prev, frame, ptr, width, mode, wrap_rows)
        chunk_parts.append(code)
        chunk_parts.append("*")

        chunk = optimize_chunk("".join(chunk_parts), keep_newlines=wrap_rows)
        out.write(chunk)
        written += len(chunk.encode("utf-8"))

        prev = frame
        count += 1

        if audio_iterator is not None:
            target_samples = int(count * SAMPLE_RATE / audio_fps + 0.5)
            while audio_samples_queued < target_samples:
                try:
                    samples = next(audio_iterator)
                except StopIteration:
                    samples = [PCM_SILENCE] * sound_length
                audio_code, ptr = encode_audio_delta(
                    audio_previous, samples, ptr, audio_offset,
                )
                audio_code = optimize_chunk(audio_code)
                out.write(audio_code)
                written += len(audio_code.encode("utf-8"))
                audio_previous = samples
                audio_samples_queued += sound_length

        if not quiet:
            now = time.monotonic()
            if now - last_draw >= 0.1 or (
                expected_frames is not None and count >= expected_frames
            ):
                sys.stderr.write(
                    format_progress(count, expected_frames, start, prefix="encode ")
                )
                sys.stderr.flush()
                last_draw = now

    if not quiet and count:
        sys.stderr.write(
            format_progress(count, expected_frames or count, start, prefix="encode ")
        )
        sys.stderr.write("\n")
        sys.stderr.flush()

    out.flush()
    if audio_iterator is not None and hasattr(audio_iterator, "close"):
        audio_iterator.close()  # type: ignore[attr-defined]
    return count, needed, written


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> None:
    p = argparse.ArgumentParser(
        description="Convert an image or video to Brainfuck for the Brainmelt display.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument("input", type=Path, help="Input image or video path")
    p.add_argument(
        "-o", "--output", type=Path, required=True,
        help="Output .bf file (streamed; required for large videos)",
    )
    p.add_argument("-W", "--width", type=int, default=64, help="Frame width in cells")
    p.add_argument("-H", "--height", type=int, default=48, help="Frame height in cells")
    p.add_argument(
        "-c", "--color", choices=("g", "p", "r"), default="g",
        help="Color mode: g=gray, p=palette, r=RGB",
    )
    p.add_argument(
        "-m", "--memsize", type=int, default=65536,
        help="Minimum tape length (auto-raised to fit frame)",
    )
    p.add_argument("-a", "--audio", action="store_true", help="Include the video soundtrack")
    p.add_argument(
        "-l", "-soundLength", "--soundLength", "--sound-length",
        dest="sound_length", type=int, default=10,
        help="Number of reserved audio sample cells (match the runtime setting)",
    )
    p.add_argument(
        "--fps", type=float, default=4.0,
        help="Sample rate for video (frames per second)",
    )
    p.add_argument(
        "--max-frames", type=int, default=None,
        help="Optional cap on number of frames (no default limit)",
    )
    p.add_argument(
        "--wrap-rows", action="store_true",
        help="Insert newlines after each pixel row (readability)",
    )
    p.add_argument(
        "--queue-size", type=int, default=8,
        help="Decode queue depth (frames buffered between threads)",
    )
    p.add_argument(
        "-q", "--quiet", action="store_true",
        help="Suppress progress messages",
    )
    args = p.parse_args()

    if args.width < 1 or args.height < 1:
        print("error: width and height must be >= 1", file=sys.stderr)
        sys.exit(1)
    if args.fps <= 0:
        print("error: fps must be positive", file=sys.stderr)
        sys.exit(1)
    if args.sound_length < 1:
        print("error: sound length must be positive", file=sys.stderr)
        sys.exit(1)

    path = args.input
    if not path.is_file():
        print(f"error: file not found: {path}", file=sys.stderr)
        sys.exit(1)

    video_exts = {".mp4", ".webm", ".avi", ".mkv", ".mov", ".wmv", ".m4v", ".flv"}
    use_video = path.suffix.lower() in video_exts
    if args.audio and not use_video:
        print("error: audio can only be included from video input", file=sys.stderr)
        sys.exit(1)
    if args.audio and not HAS_FFMPEG:
        print("error: audio conversion requires ffmpeg and ffprobe", file=sys.stderr)
        sys.exit(1)
    if args.audio:
        try:
            if not probe_has_audio(path):
                print("error: input video has no audio track", file=sys.stderr)
                sys.exit(1)
        except RuntimeError as exc:
            print(f"error: {exc}", file=sys.stderr)
            sys.exit(1)

    expected: Optional[int] = None
    if use_video and HAS_FFMPEG:
        duration = probe_duration(path)
        expected = estimate_frame_count(duration, args.fps, args.max_frames)

    if not args.quiet:
        print(
            f"Loading {'video' if use_video else 'image'}: {path} "
            f"→ {args.width}x{args.height} mode={args.color}"
            + (f" (~{expected} frames)" if expected else ""),
            file=sys.stderr,
        )

    # Open output early so we stream
    out_f = args.output.open("w", encoding="utf-8", buffering=1024 * 1024)

    try:
        if use_video:
            if HAS_FFMPEG:
                q: queue.Queue = queue.Queue(maxsize=max(2, args.queue_size))
                worker = threading.Thread(
                    target=iter_video_frames_ffmpeg,
                    args=(
                        path, args.width, args.height, args.color,
                        args.fps, args.max_frames, q,
                    ),
                    daemon=True,
                )
                worker.start()

                def consumer() -> Generator[List[int], None, None]:
                    while True:
                        item = q.get()
                        if item is _END:
                            break
                        if isinstance(item, Exception):
                            raise item
                        yield item  # type: ignore[misc]

                frames_iter: Iterable[List[int]] = consumer()
            elif HAS_CV2:
                if not args.quiet:
                    print(
                        "warning: ffmpeg not found; using OpenCV "
                        "(may fail on AV1)",
                        file=sys.stderr,
                    )
                frames_iter = iter_video_frames_cv2(
                    path, args.width, args.height, args.color,
                    args.fps, args.max_frames,
                )
            else:
                print(
                    "error: video needs ffmpeg (recommended) or opencv-python",
                    file=sys.stderr,
                )
                sys.exit(1)
        else:
            frames_iter = iter_image_frames(
                path, args.width, args.height, args.color, args.max_frames,
            )
            expected = None  # unknown for multi-frame images until done

        count, needed, written = stream_program(
            frames_iter,
            out_f,
            width=args.width,
            height=args.height,
            mode=args.color,
            memsize=args.memsize,
            wrap_rows=args.wrap_rows,
            expected_frames=expected,
            quiet=args.quiet,
            audio_blocks=iter_audio_blocks(path, args.sound_length) if args.audio else None,
            sound_length=args.sound_length if args.audio else 0,
            audio_fps=args.fps,
        )
    except Exception as exc:  # noqa: BLE001
        out_f.close()
        try:
            args.output.unlink(missing_ok=True)
        except OSError:
            pass
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)
    finally:
        out_f.close()

    if count == 0:
        print("error: no frames could be read", file=sys.stderr)
        sys.exit(1)

    if not args.quiet:
        print(
            f"Done: {count} frame(s), suggested memsize={needed}, "
            f"wrote {written:,} bytes → {args.output}",
            file=sys.stderr,
        )


if __name__ == "__main__":
    main()
