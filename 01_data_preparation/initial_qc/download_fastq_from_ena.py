#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Windows/macOS/Linux 通用 FASTQ 自动下载器

用法：
  python download_fastq_windows.py swedish_prjeb60564_runs.tsv -o fastq -j 4

特点：
- 读取 TSV 的 fastq_ftp 字段
- 支持 ; 分隔的 paired-end FASTQ
- 不依赖 wget/curl/which，Windows 可直接运行
- 支持断点续传：已有 .part 临时文件会继续下载
- 已下载完成的文件会自动跳过
- 失败自动重试，并写入 failed_downloads.txt
"""

from __future__ import annotations

import argparse
import csv
import os
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path


def normalize_url(raw: str) -> str:
    raw = raw.strip().lstrip("\ufeff")
    if raw.startswith(("http://", "https://", "ftp://")):
        # ENA FTP 链接转 HTTPS，通常在 Windows/校园网下更稳
        return "https://" + raw[len("ftp://"):] if raw.startswith("ftp://") else raw
    return "https://" + raw


def iter_fastq_urls(tsv_path: Path) -> list[str]:
    urls: list[str] = []
    with tsv_path.open("r", encoding="utf-8-sig", newline="") as f:
        reader = csv.DictReader(f, delimiter="\t")
        if not reader.fieldnames or "fastq_ftp" not in reader.fieldnames:
            raise ValueError(f"TSV 中没有 fastq_ftp 字段；当前字段为：{reader.fieldnames}")
        for row in reader:
            cell = (row.get("fastq_ftp") or "").strip()
            if not cell:
                continue
            for part in cell.split(";"):
                part = part.strip()
                if part:
                    urls.append(normalize_url(part))
    return list(dict.fromkeys(urls))


def human_size(n: int) -> str:
    units = ["B", "KB", "MB", "GB", "TB"]
    size = float(n)
    for unit in units:
        if size < 1024 or unit == units[-1]:
            return f"{size:.1f}{unit}"
        size /= 1024
    return f"{n}B"


def download_one(url: str, out_dir: Path, retries: int = 3, timeout: int = 60) -> tuple[str, bool, str]:
    filename = url.rstrip("/").split("/")[-1]
    target = out_dir / filename
    part = out_dir / (filename + ".part")

    if target.exists() and target.stat().st_size > 0:
        return url, True, f"SKIP 已存在: {target.name} ({human_size(target.stat().st_size)})"

    for attempt in range(1, retries + 1):
        try:
            downloaded = part.stat().st_size if part.exists() else 0
            headers = {"User-Agent": "Mozilla/5.0"}
            if downloaded > 0:
                headers["Range"] = f"bytes={downloaded}-"

            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                status = getattr(resp, "status", None)

                # 如果服务器不支持 Range，会从头返回 200；此时重新下载，避免文件重复拼接
                mode = "ab"
                if downloaded > 0 and status == 200:
                    downloaded = 0
                    mode = "wb"
                elif downloaded == 0:
                    mode = "wb"

                total_header = resp.headers.get("Content-Length")
                remote_remaining = int(total_header) if total_header and total_header.isdigit() else None
                expected_total = downloaded + remote_remaining if remote_remaining is not None else None

                last_report = time.time()
                with part.open(mode + "") as f:
                    while True:
                        chunk = resp.read(1024 * 1024)
                        if not chunk:
                            break
                        f.write(chunk)
                        downloaded += len(chunk)
                        now = time.time()
                        if now - last_report >= 20:
                            if expected_total:
                                pct = downloaded / expected_total * 100
                                print(f"下载中 {filename}: {human_size(downloaded)}/{human_size(expected_total)} ({pct:.1f}%)", flush=True)
                            else:
                                print(f"下载中 {filename}: {human_size(downloaded)}", flush=True)
                            last_report = now

            if part.exists() and part.stat().st_size > 0:
                if target.exists():
                    target.unlink()
                os.replace(part, target)
                return url, True, f"OK 下载完成: {target.name} ({human_size(target.stat().st_size)})"

        except Exception as e:
            if attempt < retries:
                time.sleep(min(30, attempt * 5))
            else:
                return url, False, f"FAIL 下载失败: {filename}；原因：{type(e).__name__}: {e}"

    return url, False, f"FAIL 下载失败: {filename}"


def main() -> int:
    parser = argparse.ArgumentParser(description="从 ENA/SRA TSV 自动下载 FASTQ 文件，Windows 通用版")
    parser.add_argument("tsv", type=Path, help="包含 fastq_ftp 字段的 TSV 文件")
    parser.add_argument("-o", "--out-dir", type=Path, default=Path("fastq"), help="输出目录，默认 fastq")
    parser.add_argument("-j", "--jobs", type=int, default=4, help="并发下载数，默认 4")
    parser.add_argument("--retries", type=int, default=3, help="失败重试次数，默认 3")
    parser.add_argument("--list-only", action="store_true", help="只列出链接，不实际下载")
    args = parser.parse_args()

    args.out_dir.mkdir(parents=True, exist_ok=True)
    urls = iter_fastq_urls(args.tsv)

    print(f"发现 {len(urls)} 个 FASTQ 文件链接", flush=True)
    if args.list_only:
        print("\n".join(urls))
        return 0

    failed: list[str] = []
    with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as executor:
        futures = [executor.submit(download_one, u, args.out_dir, args.retries) for u in urls]
        for future in as_completed(futures):
            url, ok, msg = future.result()
            print(msg, flush=True)
            if not ok:
                failed.append(url)

    if failed:
        fail_log = args.out_dir / "failed_downloads.txt"
        fail_log.write_text("\n".join(failed) + "\n", encoding="utf-8")
        print(f"\n有 {len(failed)} 个文件失败，已写入：{fail_log}", flush=True)
        return 1

    print("\n全部下载完成", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
