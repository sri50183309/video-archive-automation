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

## Standalone: Normalize and Merge Videos from a Folder

Want to cherry-pick a few recordings (for example, Shravan's singing videos discovered in `RandomVidoes`) and combine them into **one MP4**, without preparing archive batches or running V2/V3?

Copy the selected original clips into a separate folder, then run the standalone PowerShell script. It reads supported video files directly in that folder (not subfolders), **in filename order**, normalizes to 1920×1080 H.264 at 30 fps with aspect-ratio-preserving black bars, normalizes audio to AAC stereo at 48 kHz, supplies silence for clips without audio, and merges them into one MP4. The originals are not changed or deleted.

```powershell
& "E:\LenovoLaptop\Personnel\Videos\IpadUpload - Copy\VideoLists\scripts\reusable\Merge-SelectedVideos.ps1" `
  -SourceFolder "E:\SelectedSingingVideos" `
  -OutputFile "E:\MergedSingingVideos.mp4"
```

The output must be **outside** the input folder, and the output directory must already exist. The script refuses to overwrite an existing output, writes to a `.partial.mp4` file first, and performs a full FFmpeg decode check before promoting it to the requested filename. If the command fails, inspect the partial file before retrying. Check playback manually afterward. FFmpeg and FFprobe must be on `PATH`.

**Practical tips:** Name clips `001_...`, `002_...` to control playback order. Use copies of selected clips from `ToBeDeleted` rather than moving or deleting those originals. Encoding is CPU-intensive and may take time on older laptops. Start with two short clips to verify the workflow before a larger merge.

## Key Takeaways

1. **Start simple, then let failures guide the design.**
2. **Understand the underlying data before automating operations on it.**
3. **Optimize for reliability before speed.**
4. **Design long-running workflows to recover from interruptions.**
5. **Never confuse a successful command with a verified result.**

## Archive Engine V2 and Multi-Folder Orchestrator V3

The repository also includes a newer SHA256-inventory-driven workflow, separate from the earlier metadata-compatible batch scripts:

| Script | Role |
|---|---|
| `scripts/reusable/VideoArchive-v2.ps1` | Prepare source inventory and group plans; encode and validate archive groups |
| `scripts/reusable/VideoArchive-v3.ps1` | Orchestrate V2 across independent folders, stop on failure, and allow configurable cooling periods |
| `scripts/reusable/Move-VideoOriginalsToBeDeleted.ps1` | **Specific, one-time** reversible relocation for BalVihar and ShravanSportsVideos after review; not a generic cleanup command |

V3 uses explicit plan approval before `RunAll`; its default parameters are 12 minutes and 5 clips per group, both configurable. Review each generated plan before approving it. Do not assume that a process exit or an existing output file alone proves successful playback.

The committed relocation script remains **specific to BalVihar and ShravanSportsVideos**; it is not the ad hoc RandomVidoes move procedure. A generalized, tested replacement remains future work. The dedicated relocation script has a `Preview` mode that checks expected inventory, archive outputs, manifest/plan hashes, and each source SHA256 before any move. In `Move` mode it journals relocation and checks SHA256 again at the destination. It **does not permanently delete files**. If interrupted during relocation, inspect the journal and destination folders before attempting any retry; it is not automatically crash-resumable.

### Recorded project results (through October 13, 2026)

| Source collection | Original recordings | Archive MP4s | Notes |
|---|---:|---:|---|
| iPad archive (initial project) | 661 | 12 | Original archiving project |
| ShravanSingingVideo | 62 | 13 | 57 SHA256-unique recordings |
| ShravanSchoolPerformance | 58 | 12 | 51 SHA256-unique recordings |
| BalVihar | 55 | 7 | 44 unique; 11 exact duplicates |
| ShravanSportsVideos | 35 | 4 | 31 unique; 4 exact duplicates |
| RandomVidoes | 219 | 20 | 212 SHA256-unique; 7 exact duplicates; all 20 groups automatically validated and manually reviewed |
| **Total** | **1,090** | **68** | Six source collections |

For the two most recent collections, **90 originals** (75 unique recordings and 15 exact duplicates) were moved to their respective `ToBeDeleted` folders and SHA256-verified after relocation. The relocation journal was retained locally, not committed to GitHub.

**Validation exception:** BalVihar Group 1 had an approximately 79.82-second duration discrepancy and did **not** pass automated duration validation. The output was manually played and accepted; the other six BalVihar groups and all four ShravanSportsVideos groups passed automated validation. Manual acceptance must not be represented as an automated pass.

**RandomVidoes relocation (October 13, 2026):** After all 20 groups passed automated validation and manual playback review, all 219 source recordings were moved into `RandomVidoes/ToBeDeleted` using a one-time manifest-driven PowerShell move. A subsequent path/count check confirmed 219 of 219 files present, zero missing. No post-move SHA256 verification was performed for this collection; do not confuse the path/count check with hash verification. No originals were permanently deleted. The validated MP4 archives were left untouched.

**Current status:** Six collections have been processed. Python-based agentic orchestration and automatic crash recovery are future work, not implemented features. Original recordings, private manifests, generated media, and local journals should remain outside the repository.

---

*Built as a practical personal automation project using PowerShell, FFmpeg, and iterative problem-solving.*