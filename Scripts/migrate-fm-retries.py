#!/usr/bin/env python3
"""FM の撃ち直し集計が無い既存シナリオ記録を、一度だけ物理移行する。"""

import argparse
import errno
import json
import os
from pathlib import Path
import signal
import stat
import sys
import time
import uuid


class MigrationError(Exception):
    pass


DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
COUNTERS = ("retries", "retrySuccesses")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise MigrationError("duplicate JSON key: %s" % key)
        result[key] = value
    return result


def reject_constant(value):
    raise MigrationError("invalid JSON constant: %s" % value)


def counter_pair(usage, where):
    if not isinstance(usage, dict):
        raise MigrationError("%s must be an object" % where)
    present = [key for key in COUNTERS if key in usage]
    for key in present:
        if type(usage[key]) is not int or usage[key] < 0:
            raise MigrationError("%s.%s must be a nonnegative integer" % (where, key))
    # 非0の片方だけでは、もう一方の実測値を復元できない。
    if len(present) == 1 and usage[present[0]] != 0:
        raise MigrationError("%s has incomplete nonzero retry counters" % where)
    changed = len(present) != len(COUNTERS)
    for key in COUNTERS:
        usage.setdefault(key, 0)
    if usage["retrySuccesses"] > usage["retries"]:
        raise MigrationError("%s.retrySuccesses exceeds retries" % where)
    return changed


def migrated_record(raw):
    value = json.loads(raw, object_pairs_hook=unique_object, parse_constant=reject_constant)
    if not isinstance(value, dict):
        raise MigrationError("scenario record must be an object")
    if type(value.get("schemaVersion")) is not int or value["schemaVersion"] != 1:
        raise MigrationError("expected scenario schemaVersion 1")
    usage = value.get("fm")
    if usage is None:
        return None
    changed = counter_pair(usage, "fm")
    by_kind = usage.get("byKind")
    if not isinstance(by_kind, dict):
        raise MigrationError("fm.byKind must be an object")
    for kind, entry in by_kind.items():
        changed = counter_pair(entry, "fm.byKind.%s" % kind) or changed
    for key in COUNTERS:
        if usage[key] != sum(entry[key] for entry in by_kind.values()):
            raise MigrationError("fm.%s differs from its byKind sum" % key)
    if not changed:
        return None
    return (json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n").encode("utf-8")


def signature(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)


def open_child_directory(parent_fd, name):
    info = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if stat.S_ISLNK(info.st_mode):
        return None, 1
    if not stat.S_ISDIR(info.st_mode):
        return None, 0
    return os.open(name, DIRECTORY_FLAGS, dir_fd=parent_fd), 0


def scenario_paths(root_fd):
    paths = []
    skipped_links = 0
    for month in sorted(os.listdir(root_fd)):
        month_fd, skipped = open_child_directory(root_fd, month)
        skipped_links += skipped
        if month_fd is None:
            continue
        try:
            for run in sorted(os.listdir(month_fd)):
                run_fd, skipped = open_child_directory(month_fd, run)
                skipped_links += skipped
                if run_fd is None:
                    continue
                try:
                    for folder in ("scenarios", "superseded"):
                        try:
                            scenarios_fd, skipped = open_child_directory(run_fd, folder)
                        except FileNotFoundError:
                            continue
                        skipped_links += skipped
                        if scenarios_fd is None:
                            continue
                        try:
                            for name in sorted(os.listdir(scenarios_fd)):
                                if not name.endswith(".json"):
                                    continue
                                info = os.stat(name, dir_fd=scenarios_fd, follow_symlinks=False)
                                if stat.S_ISLNK(info.st_mode):
                                    skipped_links += 1
                                elif stat.S_ISREG(info.st_mode):
                                    paths.append(Path(month, run, folder, name))
                        finally:
                            os.close(scenarios_fd)
                finally:
                    os.close(run_fd)
        finally:
            os.close(month_fd)
    return paths, skipped_links


def parent_directory(root_fd, relative_path):
    fd = os.dup(root_fd)
    try:
        # dir_fd + O_NOFOLLOW は、走査後のディレクトリのリンク差し替えにも追随しない。
        for component in relative_path.parts[:-1]:
            next_fd = os.open(component, DIRECTORY_FLAGS, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        return fd
    except BaseException:
        os.close(fd)
        raise


def read_record(root_fd, path):
    parent_fd = parent_directory(root_fd, path)
    try:
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent_fd)
        with os.fdopen(fd, "rb") as source:
            info = os.fstat(source.fileno())
            if not stat.S_ISREG(info.st_mode):
                raise MigrationError("not a regular file")
            return source.read(), info
    finally:
        os.close(parent_fd)


def replace_record(root_fd, path, data, expected_info):
    parent_fd = parent_directory(root_fd, path)
    temporary = ".fm-retries-%s.tmp" % uuid.uuid4().hex
    created = False
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
        fd = os.open(temporary, flags, 0o600, dir_fd=parent_fd)
        created = True
        with os.fdopen(fd, "wb") as destination:
            destination.write(data)
            destination.flush()
            os.fchmod(destination.fileno(), stat.S_IMODE(expected_info.st_mode))
            os.fsync(destination.fileno())
        current = os.stat(path.name, dir_fd=parent_fd, follow_symlinks=False)
        if not stat.S_ISREG(current.st_mode) or signature(current) != signature(expected_info):
            raise MigrationError("record changed during migration; stop writers and rerun")
        os.replace(temporary, path.name, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
        created = False
        os.fsync(parent_fd)
    finally:
        if created:
            os.unlink(temporary, dir_fd=parent_fd)
        os.close(parent_fd)


def finished_metadata(root_fd, run):
    path = run / "run.json"
    try:
        raw, info = read_record(root_fd, path)
    except FileNotFoundError:
        return None
    value = json.loads(raw, object_pairs_hook=unique_object, parse_constant=reject_constant)
    if not isinstance(value, dict):
        raise MigrationError("%s: run metadata must be an object" % path)
    finished_at = value.get("finishedAt")
    if finished_at is not None and (not isinstance(finished_at, str) or not finished_at):
        raise MigrationError("%s: finishedAt must be a nonempty string or null" % path)
    return info if finished_at is not None else None


def update_finished_mtime(root_fd, run, expected_info):
    path = run / "run.json"
    parent_fd = parent_directory(root_fd, path)
    try:
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent_fd)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or signature(info) != signature(expected_info):
                raise MigrationError("%s changed during migration; stop writers and rerun" % path)
            # runStat は scenarios/ が run.json より新しいと進行中と判定する。
            # 内容はそのまま、通常の finish と同じ順で最終更新時刻だけを置く。
            latest = time.time_ns()
            try:
                scenarios_info = os.stat("scenarios", dir_fd=parent_fd, follow_symlinks=False)
                if stat.S_ISDIR(scenarios_info.st_mode):
                    latest = max(latest, scenarios_info.st_mtime_ns)
            except FileNotFoundError:
                pass
            os.utime(fd, ns=(info.st_atime_ns, latest))
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        os.close(parent_fd)


def migrate(root, dry_run):
    root_fd = os.open(root, DIRECTORY_FLAGS)
    try:
        paths, skipped_links = scenario_paths(root_fd)
        plan = {}
        # 破損や復元できない部分移行は、正常な他の記録まで書く前に検出する。
        for path in paths:
            try:
                raw, info = read_record(root_fd, path)
                if migrated_record(raw) is not None:
                    plan.setdefault(path.parent.parent, []).append((path, signature(info)))
            except (OSError, ValueError, MigrationError) as error:
                raise MigrationError("%s: %s" % (path, error)) from error
        metadata = {}
        for run in plan:
            try:
                metadata[run] = finished_metadata(root_fd, run)
            except (OSError, ValueError, MigrationError) as error:
                raise MigrationError("%s: %s" % (run / "run.json", error)) from error
        changed = 0
        touched = 0
        if not dry_run:
            for run, entries in plan.items():
                attempted_write = False
                try:
                    for path, expected in entries:
                        try:
                            raw, info = read_record(root_fd, path)
                            if signature(info) != expected:
                                raise MigrationError("record changed after preflight; stop writers and rerun")
                            data = migrated_record(raw)
                            if data is None:
                                raise MigrationError("record changed after preflight")
                            attempted_write = True
                            replace_record(root_fd, path, data, info)
                            changed += 1
                        except (OSError, ValueError, MigrationError) as error:
                            raise MigrationError("%s: %s" % (path, error)) from error
                finally:
                    if attempted_write and metadata[run] is not None:
                        update_finished_mtime(root_fd, run, metadata[run])
                        touched += 1
        return {"root": os.fspath(root), "dryRun": dry_run, "scanned": len(paths),
                "wouldChange": sum(map(len, plan.values())), "changed": changed,
                "finishedRunsTouched": touched, "symlinksSkipped": skipped_links}
    finally:
        os.close(root_fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path, help="Explicit <project>/results/runs directory")
    parser.add_argument("--dry-run", action="store_true", help="Validate and report without writing")
    arguments = parser.parse_args()
    root = Path(os.path.abspath(arguments.root.expanduser()))
    def interrupt(_signum, _frame):
        raise InterruptedError("migration interrupted")
    signal.signal(signal.SIGTERM, interrupt)
    try:
        summary = migrate(root, arguments.dry_run)
    except (OSError, ValueError, MigrationError) as error:
        detail = "root must not be a symlink" if isinstance(error, OSError) and error.errno in (errno.ELOOP, errno.ENOTDIR) and root.is_symlink() else str(error)
        print("FM retry migration failed: %s" % detail, file=sys.stderr)
        return 1
    print(json.dumps(summary, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
