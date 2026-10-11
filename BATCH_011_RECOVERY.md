# Batch 011 — Recovery and Outlier Investigation

## Processing milestone

- Total source videos: 661
- Successfully processed: 647 (97.9%)
- Production output videos: 11
- Original videos held for later deletion: 647
- Outlier source videos preserved: 14
- All 11 production outputs passed full video decode and manual playback validation.

## Failure and recovery

The original Batch_011 contained 132 videos.

Processing failed at clip 40 (SAM_0235.MP4) because FFmpeg encountered unsupported or unspecified color metadata during filtering.

An ffprobe metadata scan identified 14 suspicious videos, occupying consecutive positions 40 through 53.

To recover safely:

1. Backed up the original 132-entry batch list.
2. Created Batch_011_Recovery with 118 entries.
3. Copied 39 previously normalized clips into a separate recovery cache.
4. Excluded the 14 suspicious sources without deleting or modifying them.
5. Completed the recovery batch in 49.1 minutes.
6. Verified the merged output with FFmpeg decode exit code 0 and manual playback.

The position-based cache required particular care: removing source entries without preserving the source-to-cache mapping could have reused the wrong clips.

## Outliers awaiting investigation

- SAM_0235.MP4
- SAM_0239.MP4
- SAM_0251.MP4
- SAM_0252.MP4
- SAM_0253.MP4
- SAM_0254.MP4
- SAM_0255.MP4
- SAM_0256.MP4
- SAM_0257.MP4
- SAM_0258.MP4
- SAM_0259.MP4
- SAM_0289.MP4
- SAM_0290.MP4
- SAM_0291.MP4

These files were flagged by metadata inspection; only SAM_0235.MP4 has a confirmed normalization failure.

## Safety

- Never modify or delete the original outliers during investigation.
- Write experimental conversions to separate output files.
- Preserve the original processing lists, caches, and logs.
- Keep personal media and absolute local filesystem paths out of Git.
- Do not permanently delete retired originals without verified independent backups.
