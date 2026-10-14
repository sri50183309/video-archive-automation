#!/usr/bin/env python3
"""Agent V1: explicit approval gate and execution of existing PowerShell V2.

Commands: review, approve, run, status. No deletion of source recordings.
"""
import argparse
import csv
from datetime import datetime, timezone
import hashlib
from pathlib import Path
import sqlite3
import subprocess
import sys

def sha(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()

def now():
    return datetime.now(timezone.utc).isoformat()

def main():
    p = argparse.ArgumentParser(description="Agent V1 approval-controlled archive execution")
    p.add_argument("command", choices=("review", "approve", "run", "status"))
    p.add_argument("--source", required=True, help="Locally staged source folder")
    p.add_argument("--work-dir", required=True, help="Agent state directory")
    p.add_argument("--script", default="scripts/reusable/VideoArchive-v2.ps1")
    args = p.parse_args()
    source = Path(args.source).resolve(strict=True)
    work = Path(args.work_dir).resolve(strict=True)
    if not source.is_dir() or not work.is_dir():
        p.error("Source and work-dir must be directories")
    db = work / "agent_state.sqlite3"
    if not db.is_file():
        p.error("Missing SQLite state; run discovery first")
    archive = source / "Archive_Work"
    settings = archive / "Settings.json"
    manifest = archive / "Manifest.csv"
    plan = archive / "GroupPlan.csv"
    script = Path(args.script).resolve()
    con = sqlite3.connect(str(db), timeout=30)
    try:
        con.execute("""CREATE TABLE IF NOT EXISTS archive_approvals (
            source_path TEXT PRIMARY KEY, plan_hash TEXT NOT NULL,
            manifest_hash TEXT NOT NULL, approved_at TEXT NOT NULL,
            status TEXT NOT NULL, last_run_at TEXT, exit_code INTEGER, log_path TEXT
        )""")
        con.commit()
        row = con.execute("SELECT plan_hash,manifest_hash,approved_at,status,last_run_at,exit_code,log_path FROM archive_approvals WHERE source_path=?", (str(source),)).fetchone()
        if args.command == "status":
            print("State:", row if row else "NOT APPROVED")
            return
        for f in (settings, manifest, plan):
            if not f.is_file():
                p.error(f"Missing V2 prepared plan: {f}")
        import json
        config = json.loads(settings.read_text(encoding="utf-8-sig"))
        plan_hash = sha(plan)
        manifest_hash = sha(manifest)
        if config["PlanHash"].lower() != plan_hash.lower() or config["ManifestHash"].lower() != manifest_hash.lower():
            p.error("Prepared plan hash mismatch; cannot approve or run")
        with plan.open(newline="", encoding="utf-8-sig") as f:
            groups = list(csv.DictReader(f))
        with manifest.open(newline="", encoding="utf-8-sig") as f:
            clips = list(csv.DictReader(f))
        if len(groups) != int(config["GroupCount"]) or len(clips) != int(config["UniqueCount"]):
            p.error("Prepared plan count mismatch")
        print(f"Source: {source}")
        print(f"Clips: {len(clips)} | Groups: {len(groups)} | TargetMinutes: {config['TargetMinutes']} | MaxClips: {config['MaxClips']}")
        for g in groups:
            print(f"  Group {g['Group']}: {g['Clips']} clips, {float(g['Seconds'])/60:.2f} min, {g['Output']}")
        if args.command == "review":
            print("READ ONLY: No approval recorded, no encoding started.")
            return
        if args.command == "approve":
            # Generic approval: accept any internally consistent prepared V2 plan.
            # The approval is bound to the exact manifest and group-plan hashes.
            if not groups or not clips:
                p.error("Cannot approve an empty archive plan")
            if int(config["MaxClips"]) < 1 or int(config["TargetMinutes"]) < 1:
                p.error("Invalid grouping parameters in Settings.json")
            if any(int(g["Clips"]) < 1 or int(g["Clips"]) > int(config["MaxClips"]) for g in groups):
                p.error("Group clip count exceeds configured MaxClips")
            if sum(int(g["Clips"]) for g in groups) != len(clips):
                p.error("Group clip totals do not match the manifest")
            with con:
                con.execute("""INSERT INTO archive_approvals
                    (source_path,plan_hash,manifest_hash,approved_at,status,last_run_at,exit_code,log_path)
                    VALUES (?,?,?,?, 'APPROVED',NULL,NULL,NULL)
                    ON CONFLICT(source_path) DO UPDATE SET
                    plan_hash=excluded.plan_hash,manifest_hash=excluded.manifest_hash,
                    approved_at=excluded.approved_at,status='APPROVED',
                    last_run_at=NULL,exit_code=NULL,log_path=NULL""",
                    (str(source),plan_hash,manifest_hash,now()))
            print("APPROVED and recorded in SQLite. Encoding has NOT started.")
            return
        if not row or row[0] != plan_hash or row[1] != manifest_hash:
            p.error("No approval for this exact plan; run approve first")
        if row[3] == "RUNNING":
            p.error("Previous run marked RUNNING; inspect process and logs before retry")
        if row[3] == "SUCCEEDED":
            p.error("Run already succeeded; no need to encode again")
        if not script.is_file():
            p.error(f"V2 script missing: {script}")
        logs = work / "Logs"
        logs.mkdir(parents=True, exist_ok=True)
        logfile = logs / (source.name + "_run_" + datetime.now().strftime("%Y%m%d_%H%M%S") + ".log")
        command = ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
                   "-File", str(script), "-Mode", "RunAll", "-SourceFolder", str(source), "-ApprovePlan"]
        with con:
            con.execute("UPDATE archive_approvals SET status='RUNNING',last_run_at=?,exit_code=NULL,log_path=? WHERE source_path=?",
                        (now(),str(logfile),str(source)))
        print(f"STARTING V2; log: {logfile}", flush=True)
        try:
            with logfile.open("w", encoding="utf-8") as output:
                proc = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                        text=True, errors="replace", bufsize=1)
                for line in proc.stdout:
                    print(line, end="", flush=True)
                    output.write(line)
                    output.flush()
                rc = proc.wait()
        except BaseException:
            # Leave RUNNING state on unexpected interruption: requires manual review.
            raise
        with con:
            con.execute("UPDATE archive_approvals SET status=?,exit_code=? WHERE source_path=?",
                        ("SUCCEEDED" if rc == 0 else "FAILED",rc,str(source)))
        print(f"V2 exit code: {rc}; status: {'SUCCEEDED' if rc == 0 else 'FAILED'}")
        print("Check output playback manually. Originals remain untouched.")
        if rc:
            raise SystemExit(rc)
    finally:
        con.close()

if __name__ == "__main__":
    main()
