#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import os
import re
import shutil
import socket
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit


CONTENT_LENGTH = re.compile(r"^content-length:\s*(\d+)\s*$", re.IGNORECASE | re.MULTILINE)


def dependency_name(url: str) -> str:
    path = urlsplit(url).path
    name = Path(path).name
    if "/WGS/" in path:
        return name.split(".", 1)[0]
    return name


def dependency_urls(align_info: Path, sra: Path, mirror_host: str) -> list[str]:
    result = subprocess.run(
        [str(align_info), str(sra)],
        check=True,
        capture_output=True,
        text=True,
    )
    urls: dict[str, None] = {}
    for row in csv.reader(result.stdout.splitlines()):
        if len(row) < 4 or row[2].lower() == "true":
            continue
        location = row[3]
        if not location.startswith("remote::"):
            continue
        url = location.removeprefix("remote::")
        parsed = urlsplit(url)
        if mirror_host:
            parsed = parsed._replace(netloc=mirror_host)
            url = urlunsplit(parsed)
        urls[url] = None
    return list(urls)


def probe_ip(curl: str, host: str, ip: str, url: str) -> tuple[int, str]:
    command = [
        curl,
        "-LsS",
        "--range",
        "0-262143",
        "--connect-timeout",
        "5",
        "--max-time",
        "10",
        "--resolve",
        f"{host}:443:{ip}",
        "-o",
        os.devnull,
        "-w",
        "%{size_download}",
        url,
    ]
    result = subprocess.run(command, capture_output=True, text=True)
    try:
        downloaded = int(float(result.stdout.strip() or 0))
    except ValueError:
        downloaded = 0
    return downloaded, ip


def mirror_ips(curl: str, url: str) -> list[str]:
    host = urlsplit(url).hostname
    if not host:
        raise RuntimeError(f"Dependency URL has no host: {url}")
    addresses = sorted(
        {
            item[4][0]
            for item in socket.getaddrinfo(host, 443, socket.AF_INET, socket.SOCK_STREAM)
        }
    )
    if not addresses:
        raise RuntimeError(f"No IPv4 address found for {host}")
    with ThreadPoolExecutor(max_workers=len(addresses)) as pool:
        probes = [pool.submit(probe_ip, curl, host, ip, url) for ip in addresses]
        scores = [future.result() for future in as_completed(probes)]
    scores.sort(reverse=True)
    if scores[0][0] == 0:
        raise RuntimeError(f"All dependency mirror probes failed for {host}")
    print(
        "MIRROR "
        + f"host={host} "
        + " ".join(f"ip={ip}:probe_bytes={downloaded}" for downloaded, ip in scores),
        flush=True,
    )
    return [ip for _, ip in scores]


def content_length(curl: str, url: str, resolve_ip: str) -> int:
    host = urlsplit(url).hostname
    if not host:
        raise RuntimeError(f"Dependency URL has no host: {url}")
    command = [curl, "-fsSIL", "--retry", "5", "--retry-all-errors"]
    if resolve_ip:
        command.extend(["--resolve", f"{host}:443:{resolve_ip}"])
    command.append(url)
    result = subprocess.run(command, check=True, capture_output=True, text=True)
    matches = CONTENT_LENGTH.findall(result.stdout)
    if not matches:
        raise RuntimeError(f"Content-Length is missing for {url}")
    return int(matches[-1])


def seed_chunks(partial: Path, chunk_dir: Path, expected_bytes: int, chunk_size: int) -> None:
    if not partial.exists():
        return
    if partial.stat().st_size > expected_bytes:
        raise RuntimeError(f"Dependency partial is larger than expected: {partial}")
    with partial.open("rb") as source:
        chunk_index = 0
        while True:
            data = source.read(chunk_size)
            if not data:
                break
            chunk = chunk_dir / f"{chunk_index:06d}.part"
            if chunk.exists() and chunk.stat().st_size != len(data):
                raise RuntimeError(f"Cannot merge existing chunk with partial: {chunk}")
            if not chunk.exists():
                chunk.write_bytes(data)
            chunk_index += 1
    partial.unlink()


def download_range_chunk(
    curl: str,
    url: str,
    host: str,
    ips: list[str],
    chunk: Path,
    start: int,
    end: int,
    chunk_index: int,
) -> None:
    expected = end - start + 1
    if chunk.exists() and chunk.stat().st_size > expected:
        raise RuntimeError(f"Chunk is larger than expected: {chunk}")
    attempt = 0
    while not chunk.exists() or chunk.stat().st_size < expected:
        current_size = chunk.stat().st_size if chunk.exists() else 0
        current_start = start + current_size
        piece = chunk.with_name(chunk.name + ".next")
        piece.unlink(missing_ok=True)
        ip = ips[(chunk_index + attempt) % len(ips)]
        command = [
            curl,
            "-fLsS",
            "--range",
            f"{current_start}-{end}",
            "--connect-timeout",
            "10",
            "--max-time",
            "90",
            "--resolve",
            f"{host}:443:{ip}",
            "-o",
            str(piece),
            url,
        ]
        result = subprocess.run(command, capture_output=True, text=True)
        downloaded = piece.stat().st_size if piece.exists() else 0
        remaining = expected - current_size
        if downloaded > remaining:
            raise RuntimeError(f"Range response is larger than requested: {piece}")
        if downloaded:
            with chunk.open("ab") as output, piece.open("rb") as source:
                shutil.copyfileobj(source, output, length=8 * 1024 * 1024)
            piece.unlink()
        elif result.returncode != 0:
            time.sleep(2)
        attempt += 1
    print(f"CHUNK_READY index={chunk_index} bytes={expected}", flush=True)


def parallel_download(
    curl: str,
    url: str,
    destination: Path,
    ips: list[str],
    expected_bytes: int,
    workers: int,
) -> None:
    partial = destination.with_name(destination.name + ".part")
    chunk_dir = destination.with_name("." + destination.name + ".chunks")
    chunk_dir.mkdir(parents=True, exist_ok=True)
    chunk_count = workers * 4
    chunk_size = (expected_bytes + chunk_count - 1) // chunk_count
    seed_chunks(partial, chunk_dir, expected_bytes, chunk_size)
    host = urlsplit(url).hostname
    if not host:
        raise RuntimeError(f"Dependency URL has no host: {url}")

    jobs = []
    with ThreadPoolExecutor(max_workers=workers) as pool:
        for index, start in enumerate(range(0, expected_bytes, chunk_size)):
            end = min(start + chunk_size, expected_bytes) - 1
            chunk = chunk_dir / f"{index:06d}.part"
            jobs.append(
                pool.submit(
                    download_range_chunk,
                    curl,
                    url,
                    host,
                    ips,
                    chunk,
                    start,
                    end,
                    index,
                )
            )
        for job in as_completed(jobs):
            job.result()

    with partial.open("wb") as output:
        for index in range(len(jobs)):
            chunk = chunk_dir / f"{index:06d}.part"
            with chunk.open("rb") as source:
                shutil.copyfileobj(source, output, length=8 * 1024 * 1024)
    if partial.stat().st_size != expected_bytes:
        raise RuntimeError(f"Combined dependency has the wrong size: {partial}")
    os.replace(partial, destination)
    shutil.rmtree(chunk_dir)


def download(curl: str, url: str, destination: Path, resolve_ips: list[str], workers: int) -> None:
    expected_bytes = content_length(curl, url, resolve_ips[0])
    partial = destination.with_name(destination.name + ".part")
    if destination.exists():
        if destination.stat().st_size != expected_bytes:
            raise RuntimeError(f"Dependency has the wrong size: {destination}")
        return
    if partial.exists() and partial.stat().st_size > expected_bytes:
        raise RuntimeError(f"Dependency partial is larger than expected: {partial}")
    if partial.exists() and partial.stat().st_size == expected_bytes:
        os.replace(partial, destination)
        return

    if expected_bytes >= 64 * 1024 * 1024 and workers > 1:
        parallel_download(curl, url, destination, resolve_ips, expected_bytes, workers)
        return

    host = urlsplit(url).hostname
    if not host:
        raise RuntimeError(f"Dependency URL has no host: {url}")
    command = [
        curl,
        "-fL",
        "--retry",
        "100",
        "--retry-all-errors",
        "--retry-delay",
        "5",
        "--continue-at",
        "-",
    ]
    if resolve_ips:
        command.extend(["--resolve", f"{host}:443:{resolve_ips[0]}"])
    command.extend(["-o", str(partial), url])
    subprocess.run(command, check=True)
    if partial.stat().st_size != expected_bytes:
        raise RuntimeError(
            f"Dependency size mismatch: {partial} expected={expected_bytes} "
            f"actual={partial.stat().st_size}"
        )
    os.replace(partial, destination)


def link_dependency(source: Path, destination: Path) -> None:
    if destination.exists():
        if destination.stat().st_size != source.stat().st_size:
            raise RuntimeError(f"Existing dependency has the wrong size: {destination}")
        return
    try:
        os.link(source, destination)
    except OSError:
        shutil.copy2(source, destination)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sra", required=True, type=Path)
    parser.add_argument("--align-info", required=True, type=Path)
    parser.add_argument("--cache-dir", required=True, type=Path)
    parser.add_argument("--curl", default="curl")
    parser.add_argument("--mirror-host", default="sra-downloadb.be-md.ncbi.nlm.nih.gov")
    parser.add_argument("--resolve-ip", default="")
    parser.add_argument("--workers", type=int, default=12)
    args = parser.parse_args()

    if not args.sra.is_file():
        raise FileNotFoundError(args.sra)
    args.cache_dir.mkdir(parents=True, exist_ok=True)
    urls = dependency_urls(args.align_info, args.sra, args.mirror_host)
    selected_ips: dict[str, list[str]] = {}
    for url in urls:
        name = dependency_name(url)
        shared = args.cache_dir / name
        local = args.sra.parent / name
        if local.is_file() and local.stat().st_size > 0:
            if not shared.exists():
                link_dependency(local, shared)
            elif shared.stat().st_size != local.stat().st_size:
                raise RuntimeError(f"Dependency cache mismatch: {name}")
            print(f"CACHE_EXISTING name={name} bytes={local.stat().st_size}", flush=True)
            continue
        if shared.is_file() and shared.stat().st_size > 0:
            link_dependency(shared, local)
            print(f"CACHE_LINK name={name} bytes={shared.stat().st_size}", flush=True)
            continue

        local_partial = local.with_name(local.name + ".part")
        shared_partial = shared.with_name(shared.name + ".part")
        if local_partial.exists() and not shared_partial.exists():
            os.replace(local_partial, shared_partial)

        host = urlsplit(url).hostname or ""
        resolve_ips = [args.resolve_ip] if args.resolve_ip else []
        if not resolve_ips:
            if host not in selected_ips:
                selected_ips[host] = mirror_ips(args.curl, url)
            resolve_ips = selected_ips[host]
        print(f"DOWNLOAD_DEPENDENCY name={name} url={url}", flush=True)
        download(args.curl, url, shared, resolve_ips, args.workers)
        link_dependency(shared, local)
        print(f"READY_DEPENDENCY name={name} bytes={shared.stat().st_size}", flush=True)
    print(f"DONE dependencies={len(urls)} sra={args.sra}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
