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

from jinja2 import Environment, FileSystemLoader, select_autoescape

excludedNames = {
    "CNAME",
    "manifest.json",
    "requirements.txt",
    "tools",
    "templates",
    "__pycache__",
}


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
    if fileName.endswith(".html"):
        return True
    if fileName in excludedNames:
        return True
    return False


def sortLikeGitHub(filePath: Path) -> tuple[int, str]:
    return (
        0 if filePath.is_dir() else 1,
        filePath.name.casefold(),
    )


def buildEntries(
    projectTop: Path,
    currentDir: Path,
    depthLevel: int = 0,
) -> list[dict[str, Any]]:
    entries: list[dict[str, Any]] = []

    for childPath in sorted(currentDir.iterdir(), key=sortLikeGitHub):
        if shouldExclude(childPath):
            continue
        relativePath = childPath.relative_to(projectTop).as_posix()
        if childPath.is_dir():
            entries.append(
                {
                    "type": "dir",
                    "name": f"{childPath.name}/",
                    "href": "",
                    "size": "-",
                    "level": depthLevel,
                }
            )
            entries.extend(
                buildEntries(
                    projectTop=projectTop,
                    currentDir=childPath,
                    depthLevel=depthLevel + 1,
                )
            )
            continue
        if childPath.is_file():
            entries.append(
                {
                    "type": "file",
                    "name": childPath.name,
                    "href": "/" + quote(relativePath, safe="/"),
                    "size": formatSize(childPath.stat().st_size),
                    "level": depthLevel,
                }
            )
    return entries


def writeHeaders(projectTop: Path, entries: list[dict[str, Any]]) -> None:
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
        "/index.html",
        "  Content-Type: text/html; charset=utf-8",
        "  Content-Disposition: inline",
        "",
    ]

    for entry in entries:
        if entry["type"] != "file":
            continue
        href = entry["href"]
        filePath = projectTop / href.lstrip("/")
        if not filePath.is_file():
            continue
        textFile = isTextFile(filePath)
        contentType = guessContentType(filePath, textFile)
        lines.append(href)
        lines.append(f"  Content-Type: {contentType}")
        if textFile:
            lines.append("  Content-Disposition: inline")
        else:
            lines.append("  Content-Disposition: attachment")
        lines.append("  X-Robots-Tag: noindex")
        lines.append("")
    headersFile.write_text("\n".join(lines), encoding="utf-8")


def renderIndex(projectTop: Path, manifest: dict[str, Any]) -> None:
    templateDir = projectTop / "templates"
    outputFile = projectTop / "index.html"
    templateEnv = Environment(
        loader=FileSystemLoader(templateDir),
        autoescape=select_autoescape(["html", "xml"]),
        trim_blocks=True,
        lstrip_blocks=True,
    )
    template = templateEnv.get_template("index.html.j2")
    entries = buildEntries(projectTop, projectTop)
    html = template.render(
        site=manifest["site"],
        currentPath="/",
        generatedAt=formatBuildTime(),
        entries=entries,
    )
    outputFile.write_text(html, encoding="utf-8")
    writeHeaders(projectTop, entries)


def main() -> None:
    projectTop = getProjectTop()
    manifestFile = projectTop / "manifest.json"
    manifest = loadJson(manifestFile)
    renderIndex(projectTop, manifest)
    log("Generated index.html")
    log("Generated _headers")


if __name__ == "__main__":
    main()
