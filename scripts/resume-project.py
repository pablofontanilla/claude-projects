#!/usr/bin/env python3
"""Resolve a project and return structured context for /project:resume and /project:close.

Usage: resume-project.py [project-name-or-number]
Output: JSON to stdout (see resolve_project for schema).
"""

import datetime
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

import yaml

def load_preset_skill_suggestions(preset_name: str, root: Path) -> dict[str, list[str]]:
    """Read skill_suggestions from presets/<name>/preset.yaml; return empty dict if absent."""
    if not preset_name:
        return {}
    preset_yaml = root / "presets" / preset_name / "preset.yaml"
    if not preset_yaml.is_file():
        return {}
    try:
        data = yaml.safe_load(preset_yaml.read_text()) or {}
    except yaml.YAMLError:
        return {}
    raw = data.get("skill_suggestions", {})
    if not isinstance(raw, dict):
        return {}
    return {k: list(v) for k, v in raw.items() if isinstance(v, list)}

ALWAYS_PRESENT = {"CLAUDE.md", "README.md", ".gitignore"}


def parse_frontmatter(path: Path) -> dict[str, Any]:
    """Extract YAML frontmatter between --- delimiters."""
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return {}

    if not lines or lines[0].strip() != "---":
        return {}

    fm_lines: list[str] = []
    for line in lines[1:]:
        if line.strip() == "---":
            break
        fm_lines.append(line)
    else:
        return {}

    try:
        result = yaml.safe_load("\n".join(fm_lines))
    except yaml.YAMLError:
        return {}
    if not isinstance(result, dict):
        return {}
    for k, v in result.items():
        if isinstance(v, (datetime.date, datetime.datetime)):
            result[k] = str(v)
    return result


def normalize_worktrees(raw: Any, fallback_branch: str) -> list[dict[str, str]]:
    """Normalize any worktree frontmatter format to list[dict] with repo, branch, path."""
    if not raw:
        return []
    if isinstance(raw, str):
        raw = [raw]
    if isinstance(raw, dict):
        return [
            {"repo": str(repo), "branch": str(branch),
             "path": f"repos/{repo}/.worktrees/{branch}"}
            for repo, branch in raw.items()
        ]
    if isinstance(raw, list):
        result: list[dict[str, str]] = []
        for item in raw:
            if isinstance(item, dict):
                repo = str(item.get("repo", ""))
                branch = str(item.get("branch", fallback_branch))
                path = str(item.get("path", f"repos/{repo}/.worktrees/{branch}"))
                result.append({"repo": repo, "branch": branch, "path": path})
            else:
                item = str(item)
                result.append(
                    {"repo": item, "branch": fallback_branch,
                     "path": f"repos/{item}/.worktrees/{fallback_branch}"})
        return result
    return []


def parse_reference_files(text: str) -> list[dict[str, str]]:
    """Parse the Reference Files markdown table into [{filename, description}]."""
    in_section = False
    found_header = False
    skipped_separator = False
    results = []

    for line in text.splitlines():
        if re.match(r"^##\s+Reference Files", line, re.IGNORECASE):
            in_section = True
            continue

        if in_section and not found_header:
            if "|" in line and "File" in line:
                found_header = True
            elif line.startswith("## "):
                break
            continue

        if found_header and not skipped_separator:
            if re.match(r"^\|[-\s|]+\|$", line):
                skipped_separator = True
            continue

        if skipped_separator:
            if not line.strip() or line.startswith("## "):
                break
            cells = [c.strip() for c in line.split("|")]
            cells = [c for c in cells if c]
            if len(cells) >= 2:
                filename = cells[0].strip("`")
                description = cells[1]
                results.append({"filename": filename, "description": description})

    return results


def list_project_files(project_dir: Path) -> list[str]:
    """Recursively list files relative to project_dir, sorted."""
    files = []
    for root, dirs, filenames in os.walk(project_dir):
        dirs[:] = [d for d in dirs if d != ".git"]
        for f in filenames:
            rel = os.path.relpath(os.path.join(root, f), project_dir)
            files.append(rel)
    files.sort()
    return files


def find_unregistered_files(
    all_files: list[str], manifest_files: list[dict[str, str]]
) -> list[str]:
    """Files on disk not in the Reference Files manifest or ALWAYS_PRESENT."""
    known = ALWAYS_PRESENT | {m["filename"] for m in manifest_files}
    return [f for f in all_files if f not in known and not f.startswith(".")]


def extract_checklist(text: str) -> dict:
    """Extract checked/unchecked items with their section headings."""
    current_section = ""
    checked_items = []
    unchecked_items = []

    for line in text.splitlines():
        heading_match = re.match(r"^#{2,3}\s+(.+)", line)
        if heading_match:
            current_section = heading_match.group(1).strip()
            continue

        item_match = re.match(r"^\s*- \[([ x])\] (.+)$", line)
        if item_match:
            done = item_match.group(1) == "x"
            entry = {"text": item_match.group(2).strip(), "section": current_section}
            if done:
                checked_items.append(entry)
            else:
                unchecked_items.append(entry)

    return {
        "checked": len(checked_items),
        "unchecked": len(unchecked_items),
        "total": len(checked_items) + len(unchecked_items),
        "unchecked_items": unchecked_items,
        "checked_items": checked_items,
    }


def resolve_preset_context(preset: str, root: Path) -> dict:
    """Resolve the preset's context file and docs directory."""
    if not preset:
        return {"context_file": None, "docs": []}
    preset_dir = root / "presets" / preset
    ctx_file = preset_dir / "context.md"
    context_file = str(ctx_file.relative_to(root)) if ctx_file.is_file() else None
    docs_dir = preset_dir / "docs"
    docs = []
    if docs_dir.is_dir():
        docs = [
            {"name": p.stem, "path": str(p.relative_to(root))}
            for p in sorted(docs_dir.glob("*.md"))
        ]
    return {"context_file": context_file, "docs": docs}


def resolve_repo_context(repos: list[str], root: Path, preset_name: str = "") -> list[dict[str, str]]:
    """For each repo, find context files (repo CLAUDE.md and/or active preset context)."""
    results = []
    for repo in repos:
        repo_claude = root / "repos" / repo / "CLAUDE.md"
        if repo_claude.is_file():
            results.append({
                "repo": repo,
                "path": str(repo_claude.relative_to(root)),
                "source": "repo",
            })

        if preset_name:
            ctx = root / "presets" / preset_name / "context" / f"{repo}.md"
            if ctx.is_file():
                results.append({
                    "repo": repo,
                    "path": str(ctx.relative_to(root)),
                    "source": "preset",
                })

    return results


def resolve_worktree_status(
    worktrees: list[dict[str, str]], root: Path
) -> list[dict]:
    """Check status of declared worktrees."""
    if not worktrees:
        return []

    results = []
    for wt in worktrees:
        wt_path = root / wt["path"]
        entry: dict = {
            "repo": wt["repo"],
            "branch": wt["branch"],
            "path": wt["path"],
            "exists": False,
            "dirty": False,
            "dirty_count": 0,
            "ahead": 0,
            "no_upstream": False,
            "error": None,
        }
        if not wt_path.is_dir():
            results.append(entry)
            continue

        entry["exists"] = True

        try:
            status_result = subprocess.run(
                ["git", "-C", str(wt_path), "status", "--porcelain"],
                capture_output=True, text=True,
            )
            if status_result.returncode != 0:
                entry["error"] = f"git status failed: {status_result.stderr.strip()}"
            elif status_result.stdout.strip():
                lines = [l for l in status_result.stdout.splitlines() if l.strip()]
                entry["dirty"] = True
                entry["dirty_count"] = len(lines)

            upstream_check = subprocess.run(
                ["git", "-C", str(wt_path), "rev-parse", "--verify", "@{upstream}"],
                capture_output=True, text=True,
            )
            if upstream_check.returncode != 0:
                entry["no_upstream"] = True
            else:
                ahead_result = subprocess.run(
                    ["git", "-C", str(wt_path), "rev-list", "--count", "@{upstream}..HEAD"],
                    capture_output=True, text=True,
                )
                if ahead_result.returncode == 0 and ahead_result.stdout.strip():
                    entry["ahead"] = int(ahead_result.stdout.strip())
        except (OSError, ValueError) as exc:
            entry["error"] = str(exc)

        results.append(entry)
    return results


def get_recent_names(root: Path) -> list[str]:
    """Get recent non-done project names via recent-projects.py --names."""
    script = root / "scripts" / "recent-projects.py"
    if not script.is_file():
        return _fallback_project_names(root)
    try:
        result = subprocess.run(
            [sys.executable, str(script), "--names"],
            capture_output=True, text=True,
            env={**os.environ, "CLAUDE_PROJECT_DIR": str(root)},
        )
        if result.returncode != 0:
            return _fallback_project_names(root)
        return [l.strip() for l in result.stdout.splitlines() if l.strip()]
    except OSError:
        return _fallback_project_names(root)


def _fallback_project_names(root: Path) -> list[str]:
    """Fallback: list project directories sorted alphabetically."""
    projects_dir = root / "projects"
    if not projects_dir.is_dir():
        return []
    return sorted(d.name for d in projects_dir.iterdir() if d.is_dir())


def resolve_project(arg: str | None, root: Path) -> dict:
    """Resolve a project argument and return full structured context.

    Returns a dict with:
      status: "ok" | "not_found" | "no_projects" | "out_of_range" | "no_argument"
      error_message: str (when status != "ok")
      alternatives: list[str] (when status != "ok")
      project: dict (only when status == "ok")
    """
    projects_dir = root / "projects"

    if not projects_dir.is_dir():
        return {"status": "no_projects", "error_message": "No projects/ directory found.", "alternatives": []}

    # Resolve argument to a project name
    if arg is None:
        names = get_recent_names(root)
        if not names:
            return {"status": "no_projects", "error_message": "No active projects found.", "alternatives": []}
        return {"status": "no_argument", "alternatives": names}

    if arg.isdigit():
        names = get_recent_names(root)
        idx = int(arg) - 1
        if idx < 0 or idx >= len(names):
            return {
                "status": "out_of_range",
                "error_message": f"Only {len(names)} projects exist.",
                "alternatives": names,
            }
        project_name = names[idx]
    else:
        project_name = arg

    project_dir = projects_dir / project_name
    if not project_dir.is_dir():
        all_names = sorted(d.name for d in projects_dir.iterdir() if d.is_dir())
        return {
            "status": "not_found",
            "error_message": f"Project '{project_name}' not found.",
            "alternatives": all_names,
        }

    # Build full project context
    claude_md = project_dir / "CLAUDE.md"
    readme = project_dir / "README.md"

    if claude_md.is_file():
        context_file = str(claude_md.relative_to(root))
        context_type = "claude_md"
        try:
            text = claude_md.read_text()
        except OSError:
            text = ""
    elif readme.is_file():
        context_file = str(readme.relative_to(root))
        context_type = "readme"
        try:
            text = readme.read_text()
        except OSError:
            text = ""
    else:
        context_file = None
        context_type = "none"
        text = ""

    fm = parse_frontmatter(claude_md) if claude_md.is_file() else {}
    has_frontmatter = bool(fm)

    repos_list = fm.get("repos", [])
    if isinstance(repos_list, str):
        repos_list = [repos_list] if repos_list else []

    ref_files = parse_reference_files(text) if text else []
    all_files = list_project_files(project_dir)
    unregistered = find_unregistered_files(all_files, ref_files) if ref_files else []
    checklist = extract_checklist(text) if text else {
        "checked": 0, "unchecked": 0, "total": 0,
        "unchecked_items": [], "checked_items": [],
    }
    preset = fm.get("preset", "")
    if isinstance(preset, list):
        preset = preset[0] if preset else ""
    repo_context = resolve_repo_context(repos_list, root, preset_name=preset)
    preset_ctx = resolve_preset_context(preset, root)

    project_type = fm.get("type", "")
    if isinstance(project_type, list):
        project_type = project_type[0] if project_type else ""
    preset_skills = load_preset_skill_suggestions(preset, root)
    suggestions = preset_skills.get(project_type, [])

    frontmatter = dict(fm)
    frontmatter["repos"] = repos_list

    branch = fm.get("branch", "")
    if isinstance(branch, list):
        branch = branch[0] if branch else ""
    worktrees = normalize_worktrees(fm.get("worktrees", []), branch)
    worktree_repos = [wt["repo"] for wt in worktrees]
    worktree_status = resolve_worktree_status(worktrees, root)

    return {
        "status": "ok",
        "project": {
            "name": project_name,
            "dir": str(project_dir.relative_to(root)),
            "context_file": context_file,
            "context_type": context_type,
            "has_frontmatter": has_frontmatter,
            "frontmatter": frontmatter,
            "reference_files": ref_files,
            "has_reference_files": bool(ref_files),
            "all_files": all_files,
            "unregistered_files": unregistered,
            "checklist": checklist,
            "repo_context_files": repo_context,
            "preset_context": preset_ctx["context_file"],
            "preset_docs": preset_ctx["docs"],
            "skill_suggestions": suggestions,
            "branch": branch,
            "worktree_repos": worktree_repos,
            "worktree_status": worktree_status,
        },
    }


def main():
    root = Path(os.environ.get("CLAUDE_PROJECT_DIR", Path(__file__).resolve().parent.parent))
    arg = sys.argv[1] if len(sys.argv) > 1 else None
    result = resolve_project(arg, root)
    print(json.dumps(result, indent=2, default=str))


if __name__ == "__main__":
    main()
