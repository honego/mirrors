#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 honeok <i@honeok.com>

import json
import mimetypes
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import quote

from jinja2 import Environment, FileSystemLoader

excludedDirs = {
    "publish",
    "release-worktree",
    "tools",
    "templates",
    "__pycache__",
}

excludedFiles = {
    "CNAME",
    "manifest.json",
    "requirements.txt",
}

defaultIcon = "https://fastly.jsdelivr.net/gh/devicons/devicon@latest/icons/linux/linux-original.svg"


def getProjectTop() -> Path:
    projectTop = subprocess.check_output(
        ["git", "rev-parse", "--show-toplevel"],
        text=True,
    ).strip()
    return Path(projectTop)


def loadJson(jsonFile: Path) -> dict[str, Any]:
    with jsonFile.open("r", encoding="utf-8") as file:
        return json.load(file)


def log(message: str) -> None:
    scriptName = Path(__file__).name
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"{timestamp} [{scriptName}] {message}")


def formatSize(fileSize: int) -> str:
    if fileSize < 1024:
        return f"{fileSize} B"
    if fileSize < 1024 * 1024:
        return f"{fileSize / 1024:.1f} KiB"
    return f"{fileSize / 1024 / 1024:.1f} MiB"


def formatBuildTime() -> str:
    return (
        datetime.now(timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace(
            "+00:00",
            "Z",
        )
    )


def isTextFile(filePath: Path) -> bool:
    try:
        data = filePath.read_bytes()[:8192]
    except OSError:
        return False
    if not data:
        return True
    if b"\x00" in data:
        return False
    for encoding in ("utf-8", "utf-16", "utf-16-le", "utf-16-be"):
        try:
            data.decode(encoding)
            return True
        except UnicodeDecodeError:
            continue
    return False


def guessContentType(filePath: Path, textFile: bool) -> str:
    if textFile:
        return "text/plain; charset=utf-8"
    contentType, _ = mimetypes.guess_type(filePath.name)

    if contentType:
        return contentType
    return "application/octet-stream"


def shouldExclude(filePath: Path) -> bool:
    fileName = filePath.name

    if fileName.startswith("."):
        return True
    if fileName.startswith("_"):
        return True
    if filePath.is_dir():
        return fileName in excludedDirs
    if fileName.endswith(".html"):
        return True
    if fileName in excludedFiles:
        return True
    return False


def sortLikeGitHub(filePath: Path) -> tuple[int, str]:
    return (
        0 if filePath.is_dir() else 1,
        filePath.name.casefold(),
    )


def getCurrentPath(projectTop: Path, currentDir: Path) -> str:
    relativePath = currentDir.relative_to(projectTop).as_posix()
    if relativePath == ".":
        return "/"
    return f"/{relativePath}/"


def buildEntries(
    projectTop: Path,
    currentDir: Path,
) -> list[dict[str, Any]]:
    entries: list[dict[str, Any]] = []

    for childPath in sorted(currentDir.iterdir(), key=sortLikeGitHub):
        if shouldExclude(childPath):
            continue
        childStat = childPath.stat()
        if childPath.is_dir():
            entries.append(
                {
                    "type": "dir",
                    "name": f"{childPath.name}/",
                    "title": childPath.name,
                    "href": quote(childPath.name, safe="") + "/",
                    "size": "-",
                    "sizeBytes": 0,
                    "sortName": childPath.name.casefold(),
                }
            )
            continue
        if childPath.is_file():
            entries.append(
                {
                    "type": "file",
                    "name": childPath.name,
                    "title": childPath.name,
                    "href": quote(childPath.name, safe=""),
                    "size": formatSize(childStat.st_size),
                    "sizeBytes": childStat.st_size,
                    "sortName": childPath.name.casefold(),
                }
            )
    return entries


def iterPublicFiles(projectTop: Path, currentDir: Path) -> list[Path]:
    publicFiles: list[Path] = []

    for childPath in sorted(currentDir.iterdir(), key=sortLikeGitHub):
        if childPath.is_dir():
            if shouldExclude(childPath):
                continue
            publicFiles.extend(iterPublicFiles(projectTop, childPath))
            continue
        if not childPath.is_file():
            continue
        if childPath.name == "index.html":
            publicFiles.append(childPath)
            continue
        if shouldExclude(childPath):
            continue
        publicFiles.append(childPath)

    return publicFiles


def iterPublicDirs(projectTop: Path, currentDir: Path) -> list[Path]:
    publicDirs = [currentDir]

    for childPath in sorted(currentDir.iterdir(), key=sortLikeGitHub):
        if not childPath.is_dir():
            continue
        if shouldExclude(childPath):
            continue
        publicDirs.extend(iterPublicDirs(projectTop, childPath))

    return publicDirs


def writeHeaders(projectTop: Path) -> None:
    headersFile = projectTop / "_headers"
    cacheControl = "public, max-age=300, stale-while-revalidate=30, stale-if-error=60"

    lines = [
        "/*",
        f"  Cache-Control: {cacheControl}",
        "  X-Content-Type-Options: nosniff",
        "",
        "https://:project.pages.dev/*",
        "  X-Robots-Tag: noindex",
        "",
    ]

    for filePath in iterPublicFiles(projectTop, projectTop):
        href = "/" + quote(filePath.relative_to(projectTop).as_posix(), safe="/")
        if not filePath.is_file():
            continue
        if filePath.name == "index.html":
            textFile = True
            contentType = "text/html; charset=utf-8"
        else:
            textFile = isTextFile(filePath)
            contentType = guessContentType(filePath, textFile)
        lines.append(href)
        lines.append(f"  Content-Type: {contentType}")
        lines.append("  Content-Disposition: inline")
        lines.append("  X-Robots-Tag: noindex")
        lines.append("")
    headersFile.write_text("\n".join(lines), encoding="utf-8")


def normalizeManifest(manifest: dict[str, Any]) -> dict[str, Any]:
    site = dict(manifest["site"])
    site.setdefault("icon", defaultIcon)
    return {**manifest, "site": site}


def renderIndex(projectTop: Path, manifest: dict[str, Any]) -> None:
    templateDir = projectTop / "templates"
    templateEnv = Environment(
        loader=FileSystemLoader(templateDir),
        autoescape=True,
        trim_blocks=True,
        lstrip_blocks=True,
    )
    template = templateEnv.get_template("index.html.j2")
    generatedAt = formatBuildTime()

    for currentDir in iterPublicDirs(projectTop, projectTop):
        outputFile = currentDir / "index.html"
        html = template.render(
            site=manifest["site"],
            currentPath=getCurrentPath(projectTop, currentDir),
            generatedAt=generatedAt,
            entries=buildEntries(
                projectTop=projectTop,
                currentDir=currentDir,
            ),
        )
        outputFile.write_text(html, encoding="utf-8")
    writeHeaders(projectTop)


def main() -> None:
    projectTop = getProjectTop()
    manifestFile = projectTop / "manifest.json"
    manifest = normalizeManifest(loadJson(manifestFile))
    renderIndex(projectTop, manifest)
    log("Generated index.html")
    log("Generated _headers")


if __name__ == "__main__":
    main()
