#!/usr/bin/env python3
"""Move verified LOCAL staged archive sources into local ToBeDeleted; never touch OneDrive."""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import sqlite3
import subprocess
from datetime import datetime

def digest(path):
    h=hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda:f.read(4*1024*1024),b""):
            h.update(chunk)
    return h.hexdigest()

def inside(path, root):
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False

def main():
    p=argparse.ArgumentParser()
    p.add_argument("--source",required=True)
    p.add_argument("--work-dir",required=True)
    p.add_argument("--execute",action="store_true",help="Move verified staged files; default is dry run")
    a=p.parse_args()
    source=Path(a.source).resolve(strict=True)
    work=Path(a.work_dir).resolve(strict=True)
    if source != work/"Staging"/"IndiaTrips":
        p.error("Pilot cleanup is restricted to the local IndiaTrips staging directory")
    archive=source/"Archive_Work"
    settings=archive/"Settings.json"
    manifest=archive/"Manifest.csv"
    plan=archive/"GroupPlan.csv"
    cfg=json.loads(settings.read_text(encoding="utf-8-sig"))
    if digest(manifest).lower()!=cfg["ManifestHash"].lower() or digest(plan).lower()!=cfg["PlanHash"].lower():
        p.error("Plan/manifest integrity check failed")
    with manifest.open(newline="",encoding="utf-8-sig") as f: clips=list(csv.DictReader(f))
    with plan.open(newline="",encoding="utf-8-sig") as f: groups=list(csv.DictReader(f))
    if len(clips)!=97 or len(groups)!=10 or len(clips)!=int(cfg["UniqueCount"]) or len(groups)!=int(cfg["GroupCount"]):
        p.error("Unexpected IndiaTrips plan; refuse cleanup")
    db=sqlite3.connect(str(work/"agent_state.sqlite3"))
    try:
        row=db.execute("SELECT status,plan_hash,manifest_hash FROM archive_approvals WHERE source_path=?",(str(source),)).fetchone()
        if not row or row[0]!="SUCCEEDED" or row[1].lower()!=digest(plan).lower() or row[2].lower()!=digest(manifest).lower():
            p.error("No matching successful agent execution")
    finally: db.close()
    # Check all archive files are present, non-empty, and have readable audio/video streams.
    for g in groups:
        output=archive/"GroupedVideos"/g["Output"]
        if not output.is_file() or output.stat().st_size==0: p.error(f"Archive output missing: {output}")
        result=subprocess.run(["ffprobe","-v","error","-show_entries","stream=codec_type","-of","csv=p=0",str(output)],capture_output=True,text=True)
        streams=result.stdout.splitlines()
        if result.returncode or "video" not in streams or "audio" not in streams:
            p.error(f"Archive output probe failed: {output}")
    destroot=work/"ToBeDeleted"/"IndiaTrips"
    planned=[]
    for clip in clips:
        src=Path(clip["SourcePath"])
        if not inside(src,source) or inside(src,archive) or not src.is_file() or src.is_symlink():
            p.error(f"Unsafe or missing staged source: {src}")
        if digest(src).lower()!=clip["SHA256"].lower():
            p.error(f"Source hash mismatch: {src}")
        relative=src.relative_to(source)
        dest=destroot/relative
        if dest.exists() or dest.is_symlink(): p.error(f"Destination already exists: {dest}")
        planned.append((src,dest,clip["SHA256"]))
    print(f"Verified {len(planned)} local sources, {len(groups)} archive outputs, and successful SQLite status.")
    if not a.execute:
        print("DRY RUN ONLY. No files moved. Re-run with --execute to move local staging copies.")
        return
    destroot.mkdir(parents=True,exist_ok=True)
    audit=work/"Logs"/("IndiaTrips_cleanup_"+datetime.now().strftime("%Y%m%d_%H%M%S")+".csv")
    audit.parent.mkdir(parents=True,exist_ok=True)
    with audit.open("w",newline="",encoding="utf-8") as f:
        w=csv.writer(f);w.writerow(["source","destination","sha256","status"])
        for src,dest,expected in planned:
            dest.parent.mkdir(parents=True,exist_ok=True)
            try:
                src.rename(dest)
                status="MOVED" if digest(dest).lower()==expected.lower() else "MOVED_HASH_MISMATCH_REVIEW"
            except Exception as e:
                status="FAILED: "+str(e)
            w.writerow([str(src),str(dest),expected,status]);f.flush()
            print(f"{status}: {src.name}")
            if status!="MOVED":
                raise RuntimeError(f"Cleanup stopped; inspect audit {audit}")
    print(f"Completed local move. Audit: {audit}. OneDrive originals untouched.")

if __name__=="__main__": main()
