#!/usr/bin/env python3
"""Agent V1 Stage 2: safely stage a limited number of OneDrive-synced videos.

No source mutation or deletion. Python standard library only.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import sqlite3
import sys
import time

CHUNK = 4 * 1024 * 1024


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            chunk = f.read(CHUNK)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def inside(path, root):
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def main():
    ap = argparse.ArgumentParser(description="Safely stage videos listed by Agent V1 discovery")
    ap.add_argument("--source", required=True)
    ap.add_argument("--work-dir", required=True)
    ap.add_argument("--limit", type=int, default=2, help="Maximum files to stage in this run (default: 2)")
    args = ap.parse_args()
    if args.limit < 1:
        ap.error("--limit must be >= 1")

    source = Path(args.source).resolve(strict=True)
    work = Path(args.work_dir).resolve(strict=True)
    if not source.is_dir() or not work.is_dir():
        ap.error("Source and work directory must already exist")
    if inside(source, work) or inside(work, source):
        ap.error("Source and work directory must not overlap")

    db = work / "agent_state.sqlite3"
    if not db.is_file():
        ap.error("Inventory database not found; run discover.py first")
    staging = work / "Staging" / source.name
    staging.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(str(db), timeout=30)
    try:
        con.execute("""CREATE TABLE IF NOT EXISTS staged_files (
            source_path TEXT PRIMARY KEY,
            staged_path TEXT NOT NULL,
            size_bytes INTEGER NOT NULL,
            sha256 TEXT NOT NULL,
            verified_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        )""")
        con.commit()
        # Read the inventory, not the filesystem tree, so only discovered files are eligible.
        rows = con.execute(
            "SELECT source_path, relative_path, size_bytes FROM videos "
            "WHERE source_path = ? OR source_path LIKE ? ORDER BY relative_path COLLATE NOCASE",
            (str(source), str(source) + os.sep + "%"),
        ).fetchall()
        if not rows:
            ap.error("No matching inventory records. Re-run discover.py for this source")
        print(f"Inventory entries: {len(rows)}; staging up to {args.limit} files")
        completed = 0
        skipped = 0
        for source_name, relative_name, inventory_size in rows:
            if completed >= args.limit:
                break
            src = Path(source_name)
            # Resolve existing parents and reject symlink escapes.
            if not inside(src.resolve(strict=True), source):
                raise RuntimeError(f"Source path escapes root: {src}")
            relative = Path(relative_name)
            if relative.is_absolute() or ".." in relative.parts:
                raise RuntimeError(f"Unsafe inventory path: {relative_name}")
            dst = staging / relative
            if not inside(dst.resolve(strict=False), staging.resolve()):
                raise RuntimeError(f"Unsafe staging path: {dst}")
            partial = dst.with_name(dst.name + ".partial")
            existing = con.execute(
                "SELECT staged_path, size_bytes, sha256 FROM staged_files WHERE source_path=?",
                (source_name,),
            ).fetchone()
            if existing and dst.is_file() and str(dst) == existing[0]:
                if dst.stat().st_size == existing[1] and digest(dst) == existing[2]:
                    print(f"SKIP verified: {relative_name}")
                    skipped += 1
                    continue
            if dst.exists():
                raise RuntimeError(f"Unverified destination exists; inspect manually: {dst}")
            if partial.exists():
                print(f"Removing incomplete temporary copy: {partial}")
                partial.unlink()  # Only our staging temporary file; never a source
            if not src.is_file():
                raise RuntimeError(f"Source missing: {src}")
            current_size = src.stat().st_size
            if current_size != inventory_size:
                raise RuntimeError(f"Source size changed since discovery: {src}; re-run discovery")
            free = shutil.disk_usage(staging).free
            if free < current_size + 1024**3:
                raise RuntimeError(f"Insufficient free disk space for {relative_name} (+1 GiB reserve)")
            dst.parent.mkdir(parents=True, exist_ok=True)
            print(f"COPY {relative_name} ({current_size / 1024**2:.1f} MiB)", flush=True)
            src_hash = hashlib.sha256()
            count = 0
            with open(src, "rb") as inp, open(partial, "xb") as out:
                while True:
                    block = inp.read(CHUNK)
                    if not block:
                        break
                    out.write(block)
                    src_hash.update(block)
                    count += len(block)
                out.flush()
                os.fsync(out.fileno())
            if count != current_size or partial.stat().st_size != current_size:
                raise RuntimeError(f"Size mismatch after copying: {relative_name}")
            copied_hash = digest(partial)
            if copied_hash != src_hash.hexdigest():
                raise RuntimeError(f"SHA-256 mismatch after copying: {relative_name}")
            # Confirm source metadata has not changed while copying.
            if src.stat().st_size != current_size:
                raise RuntimeError(f"Source changed during copy: {relative_name}")
            partial.rename(dst)
            with con:
                con.execute(
                    "INSERT OR REPLACE INTO staged_files(source_path, staged_path, size_bytes, sha256) "
                    "VALUES (?, ?, ?, ?)",
                    (source_name, str(dst), current_size, copied_hash),
                )
                con.execute("UPDATE videos SET status='STAGED' WHERE source_path=?", (source_name,))
            completed += 1
            print(f"VERIFIED {relative_name} sha256={copied_hash[:16]}...", flush=True)
        print(f"Run complete: {completed} newly staged; {skipped} previously verified and skipped")
        print(f"Staging location: {staging}")
        print("OneDrive originals untouched. No encoding started.")
    finally:
        con.close()


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, sqlite3.Error) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
