#!/usr/bin/env python3
"""Safe, read-only inventory for local and OneDrive-synced video folders."""
import argparse
import csv
import os
from pathlib import Path
import sqlite3
from datetime import datetime, timezone

EXTENSIONS = {".mp4", ".mov", ".m4v", ".mkv", ".avi", ".wmv", ".3gp", ".mts", ".m2ts", ".mpeg", ".mpg", ".mod", ".vob", ".webm", ".ts"}
OFFLINE = 0x1000  # Windows FILE_ATTRIBUTE_OFFLINE


def main():
    p = argparse.ArgumentParser(description="Agent V1: inventory videos without downloading or changing originals")
    p.add_argument("--source", required=True, help="Source folder, including OneDrive-synced folders")
    p.add_argument("--work-dir", required=True, help="Separate local work folder (NOT within source)")
    args = p.parse_args()

    source = Path(args.source).resolve(strict=True)
    work = Path(args.work_dir).resolve()
    if not source.is_dir():
        p.error("--source must be a directory")
    if source == work or source in work.parents or work in source.parents:
        p.error("Source and work directory must not contain each other")
    work.mkdir(parents=True, exist_ok=True)
    db_path = work / "agent_state.sqlite3"
    csv_path = work / "inventory.csv"

    con = sqlite3.connect(str(db_path))
    try:
        con.execute("""CREATE TABLE IF NOT EXISTS videos (
            source_path TEXT PRIMARY KEY, relative_path TEXT NOT NULL,
            size_bytes INTEGER NOT NULL, extension TEXT NOT NULL,
            offline INTEGER NOT NULL, status TEXT NOT NULL,
            discovered_at TEXT NOT NULL
        )""")
        seen = set()
        rows = []
        errors = []
        now = datetime.now(timezone.utc).isoformat()
        for base, dirs, files in os.walk(str(source), followlinks=False):
            dirs[:] = [d for d in dirs if not (Path(base) / d).is_symlink()]
            for name in sorted(files):
                path = Path(base) / name
                if path.suffix.lower() not in EXTENSIONS:
                    continue
                try:
                    stat = path.stat()  # metadata only; does not open video contents
                    attrs = getattr(stat, "st_file_attributes", 0)
                    offline = bool(attrs & OFFLINE)
                    rel = str(path.relative_to(source))
                    record = (str(path), rel, stat.st_size, path.suffix.lower(),
                              int(offline), "DISCOVERED", now)
                    rows.append(record)
                    seen.add(str(path))
                except OSError as exc:
                    errors.append(f"{path}: {exc}")
        # Transaction: update inventory, retaining future workflow states.
        with con:
            for record in rows:
                con.execute("""INSERT INTO videos
                  (source_path, relative_path, size_bytes, extension, offline, status, discovered_at)
                  VALUES (?, ?, ?, ?, ?, ?, ?)
                  ON CONFLICT(source_path) DO UPDATE SET
                  relative_path=excluded.relative_path, size_bytes=excluded.size_bytes,
                  extension=excluded.extension, offline=excluded.offline,
                  discovered_at=excluded.discovered_at""", record)
        with csv_path.open("w", newline="", encoding="utf-8-sig") as fp:
            writer = csv.writer(fp)
            writer.writerow(["relative_path", "size_bytes", "extension", "offline"])
            for r in sorted(rows, key=lambda x: x[1].lower()):
                writer.writerow([r[1], r[2], r[3], r[4]])
        print(f"Source: {source}")
        print(f"Videos discovered: {len(rows)}")
        print(f"Offline placeholders: {sum(r[4] for r in rows)}")
        print(f"Reported size (GiB): {sum(r[2] for r in rows) / (1024**3):.2f}")
        print(f"Inventory CSV: {csv_path}")
        print(f"SQLite database: {db_path}")
        print(f"Metadata errors: {len(errors)}")
        for err in errors[:10]:
            print(f"  WARNING: {err}")
        if errors:
            raise SystemExit(2)
    finally:
        con.close()


if __name__ == "__main__":
    main()
