# Video Archive Automation

**A PowerShell + FFmpeg project to organize, merge, and normalize personal video archives.**

## The Problem

I had 600+ personal videos collected over the years from mobile phones, iPads, and cameras.

The files were scattered across formats (`MP4`, `MOV`, `AVI`, `3GP`), resolutions, codecs, and orientations.

The goal was simple:

> Consolidate hundreds of recordings into manageable video files (~5 GB each), preserve the original content, and make the archive easier to store and watch across devices.

What initially looked like a simple file-merging task turned into an interesting exercise in media compatibility and automation.

## The Engineering Journey

### 1. First Attempt: Group by File Size

The initial approach was to group videos into batches based on total file size, targeting approximately 5 GB per output.

**Learning:** File size tells us how much storage a video needs, not whether it can be safely combined with another video.

### 2. Second Attempt: Size + File Format

Next, I grouped videos by extension: MP4 with MP4, MOV with MOV, and so on.

This reduced some incompatibilities, but the resulting videos still had playback issues, including frozen frames and slideshow-like behavior.

**Learning:** A file extension is a container, not a guarantee of compatible video streams.

### 3. Third Attempt: Codec and Metadata Compatibility

I introduced `ffprobe` to inspect video properties such as:

- Video and audio codecs
- Resolution and frame rate
- Pixel format and video time base
- Audio sample rate and channel configuration

Videos with matching properties were grouped into compatible batches.

FFmpeg's concat demuxer could then merge many of these using `-c copy`, without re-encoding.

**Learning:** Stream compatibility matters more than filenames or extensions.

### 4. Fourth Attempt: Portrait vs. Landscape

Even after solving stream compatibility, another challenge remained.

Some videos were recorded vertically on phones, while others were recorded horizontally.

To produce consistent output for laptop and TV playback, I introduced a normalization pipeline:

- Standardize output to 1920×1080 at 30 fps
- Preserve the original aspect ratio
- Add black bars where needed instead of cropping or stretching
- Normalize video to H.264 and audio to AAC
- Merge the normalized clips into a single MP4

**Learning:** Sometimes stream copying is enough; sometimes re-encoding is necessary to achieve consistent playback.

### 5. Automation, Recovery, and Safety

With hundreds of videos to process, manually running FFmpeg commands wasn't practical.

PowerShell scripts now handle batch preparation, conversion, merging, logging, and resuming interrupted work.

The workflow follows a few important principles:

- Keep original recordings untouched
- Reuse previously converted clips
- Avoid overwriting completed outputs
- Log failures for investigation
- Verify output playback before considering cleanup

Along the way, I also encountered PowerShell argument-handling issues with paths containing spaces—a reminder that orchestration code needs as much attention as the underlying media commands.

## High-Level Workflow

```text
Original Videos
      |
      v
Inspect Metadata (ffprobe)
      |
      v
Group by Compatibility + Size
      |
      v
Generate Batch Lists
      |
      +----------------------------+
      |                            |
      v                            v
Fast Merge                    Normalize Video
(-c copy)                     (1920x1080, H.264)
      |                            |
      |                            v
      |                       Merge Clips
      |                            |
      +-------------+--------------+
                    |
                    v
             Validate & Review
                    |
                    v
              Video Archive
```

## Scripts

| Script | Purpose |
|---|---|
| `Prepare-VideoBatches.ps1` | Create size-bounded, metadata-compatible batch lists |
| `Process-VideoBatches.ps1` | Merge compatible video streams without re-encoding |
| `Process-NormalizedVideoBatches.ps1` | Normalize resolution, orientation, frame rate, and audio before merging |

### Prerequisites

- Windows PowerShell 5.1 or later
- FFmpeg and FFprobe available on `PATH`
- A `video_compatibility.csv` metadata report for batch preparation

The scripts expect the working directory (`VideoLists`) to sit inside the source-video directory. Generated outputs, logs, and personal metadata reports are excluded from Git.

### Example Usage

Process one normalized batch:

```powershell
.\Process-NormalizedVideoBatches.ps1 -Batch Batch_022
```

Process all eligible normalized batches:

```powershell
.\Process-NormalizedVideoBatches.ps1 -All
```

Run the full operation only after testing a small batch and confirming sufficient disk space. Normalization re-encodes videos and can take significant time.

## Key Takeaways

1. **Start simple, then let failures guide the design.**
2. **Understand the underlying data before automating operations on it.**
3. **Optimize for reliability before speed.**
4. **Design long-running workflows to recover from interruptions.**
5. **Never confuse a successful command with a verified result.**

## Current Status

The batch-merging and normalization workflows have been tested successfully on selected recordings.

Further improvements may include stronger output validation, automated size enforcement, and a complete metadata-report generation script.

---

*Built as a practical personal automation project using PowerShell, FFmpeg, and iterative problem-solving.*