# Agent V1: Running a new OneDrive video folder

Run one collection at a time from the repository root in Windows PowerShell. Replace SOURCE and WORK in each command with your paths. These stages do not modify or delete OneDrive originals.

Example SOURCE: C:\Users\om\OneDrive\Video\RandomVideos\Sriram_Niagara
Example WORK: E:\LenovoLaptop\Personnel\Videos\IpadUpload - Copy\VideoAgent
Example STAGED: E:\LenovoLaptop\Personnel\Videos\IpadUpload - Copy\VideoAgent\Staging\Sriram_Niagara

## Steps

1. Discover (metadata only): `python .\agent_v1\discover.py --source "SOURCE" --work-dir "WORK"`.
2. Stage a two-file pilot: `python .\agent_v1\stage.py --source "SOURCE" --work-dir "WORK" --limit 2`. After review, repeat with a sufficiently large limit to stage remaining files. Copies are SHA-256 checked. Reading online-only OneDrive files may hydrate them on C:; monitor free space on C: and E:.
3. Prepare: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\scripts\reusable\VideoArchive-v2.ps1" -Mode Prepare -SourceFolder "STAGED" -TargetMinutes 30 -MaxClips 10`. Adjust grouping limits to the collection. Prepare only after staging all intended clips; inspect STAGED\Archive_Work\GroupPlan.csv and Manifest.csv. An existing plan cannot be overwritten.
4. Review: `python .\agent_v1\execute.py review --source "STAGED" --work-dir "WORK"`.
5. Approve: `python .\agent_v1\execute.py approve --source "STAGED" --work-dir "WORK"`. Approval is recorded in SQLite against the exact manifest and plan hashes.
6. Run: `python .\agent_v1\execute.py run --source "STAGED" --work-dir "WORK"`. Check status with `python .\agent_v1\execute.py status --source "STAGED" --work-dir "WORK"`.
7. Inspect the validated MP4s and manually review playback before any cleanup or cloud publishing.

## Important limits

- The scripts are separate stages; a unified unattended agent.py and job queue are not yet implemented.
- The execution approval is generic for internally consistent V2 plans; it no longer requires IndiaTrips' 97 clips and 10 groups.
- The engine currently stops on an unreadable clip during Prepare; skip-and-report is future work.
- An interrupted execution can remain RUNNING in SQLite. Inspect logs and processes before manually recovering; there is no automatic crash recovery.
- Generic OneDrive publishing, archive renaming to TopFolder_VolN.mp4, and moving cloud originals to ToBeDeleted are NOT implemented. Existing cleanup.py operates on local staged copies only.
- Do not run concurrent jobs sharing the same state and source leaf-name staging folder.
- No original recordings are permanently deleted by this workflow.
