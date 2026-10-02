#!/usr/bin/env python3
"""Offline, dependency-free checks for a vendored repository standard.

This module deliberately makes no network calls and never executes configured
commands unless --run-checks is explicitly supplied. A successful check is not
evidence of a production deployment, backup, or restore.
"""
from __future__ import annotations

import argparse
import ast
import fnmatch
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
from typing import Any

MANIFEST = "ai/repo-standard.json"
WORKFLOW = ".github/workflows/repo-standard.yml"
BEGIN = "<!-- repo-standard:begin -->"
END = "<!-- repo-standard:end -->"
PROFILES = {"app", "service", "ops", "overlay", "snapshot", "skills"}
TEXT_EXTENSIONS = {".md", ".rst", ".txt", ".adoc", ".csv"}
MEDIA_EXTENSIONS = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".pdf", ".mp4", ".woff", ".woff2"}
SECRET_PATTERNS = [
    re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\b"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\b(?:sk-proj-|sk-ant-api)[A-Za-z0-9_-]{25,}\b"),
]
PLACEHOLDER = re.compile(r"\b(?:CHANGE_ME|REPLACE_ME|YOUR_SECRET_HERE)\b|<TODO>|\{\{\s*(?:repo|project|profile|name)\s*\}\}", re.I)


class StandardError(Exception):
    """A validation failure safe to show without printing file contents."""


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def relative_path(value: Any) -> str:
    if not isinstance(value, str) or not value or "\\" in value or "\x00" in value:
        raise StandardError("Expected a nonempty POSIX relative path")
    path = PurePosixPath(value)
    if path.is_absolute() or any(part in {"", ".", ".."} for part in value.split("/")):
        raise StandardError(f"Unsafe relative path: {value!r}")
    if path.parts[0] == ".git":
        raise StandardError("The .git directory is never a managed content path")
    return value


class Tree:
    """Read an existing repo with optional planned file and symlink changes."""

    def __init__(self, root: Path, files: dict[str, bytes] | None = None,
                 links: dict[str, str] | None = None):
        self.root = root.resolve()
        self.files = files or {}
        self.links = links or {}

    def path(self, name: str) -> Path:
        name = relative_path(name)
        path = self.root / name
        try:
            path.resolve().relative_to(self.root)
        except (ValueError, RuntimeError):
            raise StandardError(f"Path escapes repository or has a symlink loop: {name}") from None
        return path

    def exists(self, name: str) -> bool:
        return name in self.files or name in self.links or self.path(name).exists()

    def read(self, name: str) -> bytes:
        self.path(name)
        if name in self.files:
            return self.files[name]
        try:
            return self.path(name).read_bytes()
        except OSError as exc:
            raise StandardError(f"Cannot read {name}: {exc.strerror}") from None

    def text(self, name: str) -> str:
        try:
            return self.read(name).decode("utf-8")
        except UnicodeError:
            raise StandardError(f"Expected UTF-8 text: {name}") from None

    def link(self, name: str) -> str | None:
        self.path(name)
        if name in self.links:
            return self.links[name]
        path = self.path(name)
        return os.readlink(path) if path.is_symlink() else None


def load_manifest(tree: Tree) -> dict[str, Any]:
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise StandardError(f"Duplicate manifest key: {key}")
            result[key] = value
        return result
    try:
        value = json.loads(tree.text(MANIFEST), object_pairs_hook=unique)
    except json.JSONDecodeError as exc:
        raise StandardError(f"Invalid manifest JSON at line {exc.lineno}") from None
    if not isinstance(value, dict):
        raise StandardError("Manifest must be an object")
    return value


def skill_metadata(content: str, path: str) -> tuple[str, str]:
    lines = content.splitlines()
    if not lines or lines[0] != "---" or "---" not in lines[1:]:
        raise StandardError(f"Missing skill frontmatter: {path}")
    front = lines[1:lines[1:].index("---") + 1]
    fields: dict[str, str] = {}
    for key in ("name", "description"):
        for index, line in enumerate(front):
            match = re.match(rf"^{key}:\s*(.*)$", line)
            if match:
                chunks = [match.group(1)]
                for following in front[index + 1:]:
                    if following and not following[0].isspace():
                        break
                    chunks.append(following.strip())
                fields[key] = " ".join(chunks).strip().strip("\"'")
                if fields[key].startswith(("|", ">")):
                    fields[key] = fields[key][1:].lstrip("-+ ")
                break
        if not fields.get(key):
            raise StandardError(f"Missing skill {key}: {path}")
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", fields["name"]):
        raise StandardError(f"Invalid skill name: {path}")
    return fields["name"], fields["description"]


def wrapper_text(name: str, description: str, target: str) -> str:
    return ("---\nname: " + json.dumps(name) + "\ndescription: " + json.dumps(description, ensure_ascii=False)
            + "\n---\n\nRead and follow the [canonical repository skill](" + target + ").\n"
            + "The linked file is the single source of instructions and supporting references.\n")


def routing_block(manifest: dict[str, Any]) -> str:
    skills = manifest.get("skills", [])
    references = "\n".join(f"- [{PurePosixPath(p).parent.name}]({p})" for p in skills)
    return (f"{BEGIN}\n## Repository standard\n\n"
            "Use [the shared core](ai/standard/core.md) and "
            f"[the {manifest['profile']} profile](ai/standard/profile.md) for applicable work.\n"
            "[Repository configuration](ai/repo-standard.json) lists the local checks, knowledge sources, "
            "skills, and deployment boundaries. Existing repository-specific rules remain in force.\n\n"
            "Load the relevant canonical skill when developing or operating this repository:\n"
            f"{references}\n{END}")


def has_agents_import(content: str) -> bool:
    """An example inside a code fence or comment is not an active import."""
    content = re.sub(r"<!--.*?-->", "", content, flags=re.S)
    fence = None
    for line in content.splitlines():
        marker = re.match(r"^\s*(`{3,}|~{3,})", line)
        if marker:
            if fence is None:
                fence = marker.group(1)[0]
            elif marker.group(1)[0] == fence:
                fence = None
            continue
        if fence is None and re.fullmatch(r"\s*@(?:\./)?AGENTS\.md\s*", line):
            return True
    return False


def in_snapshot_metadata(path: str, manifest: dict[str, Any]) -> bool:
    for pattern in manifest["snapshot"]["metadata_paths"]:
        if pattern.endswith("/**"):
            prefix = pattern[:-3]
            if path == prefix or path.startswith(prefix + "/"):
                return True
        elif path == pattern:
            return True
    return False


def schema_errors(manifest: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    if manifest.get("schema_version") != 1:
        errors.append("schema_version must be 1")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", str(manifest.get("repository", ""))):
        errors.append("repository must be owner/name")
    if manifest.get("profile") not in PROFILES:
        errors.append("Unknown repository profile")
    if manifest.get("adapter_mode", "symlink") not in {"symlink", "wrapper"}:
        errors.append("adapter_mode must be symlink or wrapper")
    if manifest.get("profile") == "snapshot":
        snapshot = manifest.get("snapshot")
        paths = snapshot.get("metadata_paths") if isinstance(snapshot, dict) else None
        if not isinstance(paths, list) or not paths:
            errors.append("snapshot profile requires snapshot.metadata_paths")
        else:
            for pattern in paths:
                try:
                    if not isinstance(pattern, str):
                        raise StandardError("Snapshot metadata paths must be strings")
                    prefix = pattern[:-3] if pattern.endswith("/**") else pattern
                    relative_path(prefix)
                    if any(char in prefix for char in "*?[]"):
                        raise StandardError("Snapshot metadata paths permit only literals or a precise trailing /** subtree")
                except StandardError as exc:
                    errors.append(str(exc))
        if manifest.get("checks"):
            errors.append("snapshot profile permits no executable command checks; validate only vendored metadata")
    modules = manifest.get("modules")
    if not isinstance(modules, list) or any(not isinstance(x, str) or not x for x in modules):
        errors.append("modules must be an array of names")
    knowledge = manifest.get("knowledge")
    if not isinstance(knowledge, dict) or not all(knowledge.get(x) for x in ("current", "decisions", "learnings", "runbooks")):
        errors.append("knowledge must map current, decisions, learnings, and runbooks to paths")
    checks = manifest.get("checks")
    if not isinstance(checks, list):
        errors.append("checks must be an array")
    else:
        names = set()
        for check in checks:
            if not isinstance(check, dict):
                errors.append("Every check must be an object")
                continue
            name, argv, paths = check.get("name"), check.get("argv"), check.get("paths")
            if not isinstance(name, str) or not name or name in names:
                errors.append("Check names must be nonempty and unique")
            else:
                names.add(name)
            if check.get("kind") != "offline":
                errors.append(f"Check {name!r} must explicitly declare kind offline")
            if not isinstance(argv, list) or not argv or any(not isinstance(x, str) or not x or "\x00" in x for x in argv):
                errors.append(f"Check {name!r} needs a nonempty argv array")
            elif Path(argv[0]).name in {"sh", "bash", "zsh", "fish", "cmd", "powershell", "pwsh"} and any(x in argv for x in ("-c", "/c", "-Command")):
                errors.append(f"Check {name!r} may not execute a shell command string")
            if not isinstance(paths, list) or not paths or any(not isinstance(x, str) or not x or x.startswith("/") or ".." in x.split("/") for x in paths):
                errors.append(f"Check {name!r} needs safe relative path globs")
    skills = manifest.get("skills")
    if not isinstance(skills, list) or not skills or any(not isinstance(x, str) for x in skills):
        errors.append("skills must list canonical SKILL.md paths")
    elif len(set(skills)) != len(skills):
        errors.append("skills must not contain duplicates")
    gates = manifest.get("existing_ci", [])
    if not isinstance(gates, list):
        errors.append("existing_ci must be an array")
    else:
        for gate in gates:
            if not isinstance(gate, dict) or not isinstance(gate.get("name"), str) or not gate["name"]:
                errors.append("Every existing_ci gate needs a name")
                continue
            try:
                workflow = relative_path(gate.get("workflow"))
                if not workflow.startswith(".github/workflows/") or not workflow.endswith((".yml", ".yaml")):
                    raise StandardError("existing_ci workflow must name a repository GitHub workflow")
            except StandardError as exc:
                errors.append(str(exc))
            paths = gate.get("paths")
            if not isinstance(paths, list) or not paths or any(not isinstance(p, str) or not p or p.startswith("/") or ".." in p.split("/") for p in paths):
                errors.append(f"Existing CI gate {gate['name']!r} needs safe path globs")
    deployment = manifest.get("deployment")
    if not isinstance(deployment, dict) or not deployment.get("mode") or not deployment.get("description"):
        errors.append("deployment must declare mode and description")
    source = manifest.get("source")
    if not isinstance(source, dict) or not all(isinstance(source.get(k), str) and source[k] for k in ("repository", "version", "revision")):
        errors.append("source must contain repository, version, and revision")
    elif not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", source["revision"]):
        errors.append("source.revision must be a full immutable Git commit hash")
    managed = manifest.get("managed_files")
    if not isinstance(managed, dict) or not managed:
        errors.append("managed_files must record vendored file hashes")
    else:
        for path, expected in managed.items():
            try:
                relative_path(path)
                if not path.startswith("ai/standard/") and path != WORKFLOW:
                    raise StandardError("Managed ownership is restricted to ai/standard/ and the exact repo-standard workflow")
            except StandardError as exc:
                errors.append(str(exc))
            if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-f]{64}", expected):
                errors.append(f"Invalid managed checksum: {path}")
        for required in ("ai/standard/core.md", "ai/standard/profile.md", "ai/standard/validate_repo.py", "ai/standard/VERSION", "ai/standard/LICENSE", WORKFLOW):
            if required not in managed:
                errors.append(f"Required managed file missing: {required}")
    return errors


def scan_text(path: str, content: str) -> list[str]:
    errors = []
    if any(pattern.search(content) for pattern in SECRET_PATTERNS):
        errors.append(f"Potential credential material in {path}; inspect locally (content redacted)")
    if PLACEHOLDER.search(content):
        errors.append(f"Unresolved scaffold placeholder in {path}")
    return errors


def linked_paths(content: str):
    # Inline Markdown paths only; remote URLs and anchors are not repo paths.
    for value in re.findall(r"\[[^\]]*\]\(([^)]+)\)", content):
        value = value.split("#", 1)[0].strip()
        if value and not re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*:", value):
            yield value


def validate(tree: Tree) -> list[str]:
    try:
        manifest = load_manifest(tree)
    except StandardError as exc:
        return [str(exc)]
    errors = schema_errors(manifest)
    if errors:
        return errors
    if manifest["profile"] == "snapshot":
        required_metadata = {MANIFEST, "AGENTS.md", "CLAUDE.md", *manifest["managed_files"],
                             *manifest["skills"], *manifest["knowledge"].values()}
        for path in required_metadata:
            if not in_snapshot_metadata(path, manifest):
                errors.append(f"Required governance path falls outside snapshot metadata scope: {path}")
    for path, expected in manifest["managed_files"].items():
        try:
            data = tree.read(path)
            if digest(data) != expected:
                errors.append(f"Managed file differs from locked content: {path}")
            if path.endswith(".py"):
                try:
                    ast.parse(data, filename=path)
                except SyntaxError:
                    errors.append(f"Invalid Python syntax in managed validator: {path}")
            # The validator contains detection regexes rather than credentials.
            if not path.endswith("validate_repo.py"):
                errors.extend(scan_text(path, data.decode("utf-8")))
        except (StandardError, UnicodeError) as exc:
            errors.append(str(exc))
    try:
        if tree.text("ai/standard/VERSION").strip() != manifest["source"]["version"]:
            errors.append("Vendored VERSION differs from source.version")
        errors.extend(scan_text(MANIFEST, tree.text(MANIFEST)))
    except StandardError as exc:
        errors.append(str(exc))
    for role, path in manifest["knowledge"].items():
        try:
            if not tree.exists(relative_path(path)):
                errors.append(f"Knowledge source {role!r} does not exist: {path}")
        except StandardError as exc:
            errors.append(str(exc))
    for gate in manifest.get("existing_ci", []):
        try:
            if not tree.text(gate["workflow"]).strip():
                errors.append(f"Empty delegated CI workflow: {gate['workflow']}")
        except StandardError as exc:
            errors.append(str(exc))
    names = set()
    for path in manifest["skills"]:
        try:
            relative_path(path)
            if PurePosixPath(path).name != "SKILL.md":
                raise StandardError(f"Canonical skill must end in SKILL.md: {path}")
            content = tree.text(path)
            name, description = skill_metadata(content, path)
            if name in names:
                errors.append(f"Duplicate discoverable skill name: {name}")
            names.add(name)
            for parent in (".agents/skills", ".claude/skills"):
                alias = f"{parent}/{name}"
                if manifest["profile"] == "snapshot" and not in_snapshot_metadata(alias + "/SKILL.md", manifest):
                    errors.append(f"Skill adapter falls outside snapshot metadata scope: {alias}")
                if manifest.get("adapter_mode", "symlink") == "wrapper":
                    target = os.path.relpath(path, alias)
                    actual = tree.text(alias + "/SKILL.md")
                    if actual != wrapper_text(name, description, target):
                        errors.append(f"Skill wrapper does not match canonical skill: {alias}/SKILL.md")
                else:
                    target = os.path.relpath(str(PurePosixPath(path).parent), parent)
                    if tree.link(alias) != target:
                        errors.append(f"Missing or incorrect discoverable skill link: {alias}")
            for reference in linked_paths(content):
                resolved = (tree.root / PurePosixPath(path).parent / reference).resolve()
                try:
                    rel = resolved.relative_to(tree.root).as_posix()
                except ValueError:
                    raise StandardError(f"Skill reference escapes repository: {path}") from None
                if not tree.exists(rel):
                    errors.append(f"Skill reference does not exist: {path} -> {reference}")
        except StandardError as exc:
            errors.append(str(exc))
    try:
        agents = tree.text("AGENTS.md")
        block = routing_block(manifest)
        if agents.count(BEGIN) != 1 or agents.count(END) != 1 or block not in agents:
            errors.append("AGENTS.md managed routing block is missing or inconsistent")
        claude = tree.text("CLAUDE.md")
        if not has_agents_import(claude):
            errors.append("CLAUDE.md must import @AGENTS.md on its own line")
    except StandardError as exc:
        errors.append(str(exc))
    return errors


def git(root: Path, *args: str) -> bytes:
    result = subprocess.run(["git", "-C", str(root), *args], stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, check=False)
    if result.returncode:
        raise StandardError(f"Git inspection failed: {args[0]}")
    return result.stdout


def changed_paths(root: Path, base: str | None) -> tuple[list[str], str | None]:
    if not (root / ".git").exists():
        if base:
            raise StandardError("--base requires a Git repository")
        return [], None
    reference = base or "HEAD"
    try:
        revision = git(root, "rev-parse", "--verify", "--end-of-options", reference + "^{commit}").decode().strip()
    except StandardError:
        if base:
            raise StandardError("Cannot resolve requested base commit") from None
        # A new repository without HEAD has only new/untracked content.
        paths = git(root, "ls-files", "--cached", "--others", "--exclude-standard", "-z")
        return sorted({p.decode() for p in paths.split(b"\0") if p}), None
    paths = git(root, "diff", "--no-renames", "--name-only", "-z", revision, "--")
    untracked = git(root, "ls-files", "--others", "--exclude-standard", "-z")
    return sorted({p.decode() for p in (paths + untracked).split(b"\0") if p}), revision


def is_document(path: str) -> bool:
    return PurePosixPath(path).suffix.lower() in TEXT_EXTENSIONS | MEDIA_EXTENSIONS


def builtin_coverage(path: str, manifest: dict[str, Any]) -> bool:
    return (path == MANIFEST or path in manifest["managed_files"] or
            path.startswith((".agents/skills/", ".claude/skills/")))


def matches(path: str, pattern: str) -> bool:
    return fnmatch.fnmatchcase(path, pattern) or (pattern.startswith("**/") and fnmatch.fnmatchcase(path, pattern[3:]))


def selects(check: dict[str, Any], paths: list[str]) -> bool:
    # Broad source globs must not run application suites for prose edits. A
    # documented check explicitly targeting SKILL.md or *.md remains meaningful.
    return any(matches(path, pattern) and (not is_document(path) or is_document(pattern))
               for path in paths for pattern in check["paths"])


def changed_content_errors(tree: Tree, paths: list[str], revision: str | None) -> list[str]:
    errors = []
    for name in paths:
        try:
            path = tree.path(name)
            if not path.is_file() or path.is_symlink():
                continue
            if revision:
                patch = git(tree.root, "diff", "--no-ext-diff", "--unified=0", revision, "--", name).decode("utf-8", "replace")
                additions = "\n".join(line[1:] for line in patch.splitlines() if line.startswith("+") and not line.startswith("+++"))
                if not patch:  # Newly untracked file.
                    additions = path.read_text(encoding="utf-8")
            else:
                additions = path.read_text(encoding="utf-8")
            if name != "ai/standard/validate_repo.py":
                errors.extend(scan_text(name, additions))
        except UnicodeError:
            continue
        except (StandardError, OSError) as exc:
            errors.append(str(exc))
    return errors


def check_repo(root: Path, base: str | None = None, run_checks: bool = False) -> tuple[list[str], list[str]]:
    tree = Tree(root)
    errors = validate(tree)
    messages = []
    if errors:
        return errors, messages
    manifest = load_manifest(tree)
    try:
        paths, revision = changed_paths(tree.root, base)
        errors.extend(changed_content_errors(tree, paths, revision))
    except StandardError as exc:
        return [str(exc)], messages
    scoped_paths = paths
    if manifest["profile"] == "snapshot":
        scoped_paths = [path for path in paths if in_snapshot_metadata(path, manifest)]
        excluded_count = len(paths) - len(scoped_paths)
        if excluded_count:
            messages.append(f"NOT VALIDATED: {excluded_count} application snapshot path(s) outside metadata scope; only added-line credential screening applied")
    selected = [check for check in manifest["checks"] if selects(check, scoped_paths)]
    check_scripts = {arg for check in manifest["checks"] for arg in check["argv"][1:]
                     if not arg.startswith("-") and PurePosixPath(arg).suffix in {".py", ".sh", ".js", ".mjs", ".ts"}}
    delegated = [gate for gate in manifest.get("existing_ci", []) if selects(gate, scoped_paths)]
    def covered_by_existing_ci(path):
        if path in check_scripts or path.startswith("ai/standard/"):
            return False
        return any(matches(path, pattern) for gate in delegated for pattern in gate["paths"])
    uncovered = [p for p in scoped_paths if not is_document(p) and not builtin_coverage(p, manifest)
                 and not any(matches(p, pattern) for c in manifest["checks"] for pattern in c["paths"])
                 and not covered_by_existing_ci(p)]
    errors.extend(f"Changed source/config has no declared offline check: {p}" for p in uncovered)
    if errors:
        return errors, messages
    for gate in delegated:
        messages.append(f"DELEGATED {gate['name']}: {gate['workflow']} (not executed or verified here)")
    if not run_checks:
        messages.append(f"Static standard checks passed; {len(selected)} matching command check(s) not run (use --run-checks)")
        return errors, messages
    if not selected:
        messages.append("Static standard checks passed; SKIPPED command checks (no changed paths require additional checks)")
    for check in selected:
        argv = check["argv"]
        executable = argv[0]
        if "/" in executable:
            try:
                command_path = tree.path(executable)
                available = command_path.is_file() and os.access(command_path, os.X_OK)
            except StandardError:
                available = False
        else:
            available = shutil.which(executable) is not None
        if not available:
            errors.append(f"NOT RUN {check['name']}: required executor unavailable: {executable}")
            continue
        try:
            # Do not echo output: failing tools can include secrets or huge logs.
            environment = os.environ.copy()
            environment["REPO_STANDARD_CHANGED_FILES"] = json.dumps(paths)
            environment["REPO_STANDARD_BASE"] = revision or ""
            result = subprocess.run(argv, cwd=tree.root, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, timeout=300, check=False, env=environment)
            if result.returncode:
                errors.append(f"FAIL {check['name']}: exit {result.returncode}; rerun locally for tool output")
            else:
                messages.append(f"PASS {check['name']}")
        except (OSError, subprocess.TimeoutExpired):
            errors.append(f"FAIL {check['name']}: command could not finish within 300 seconds")
    return errors, messages


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", nargs="?", default=".")
    parser.add_argument("--base")
    parser.add_argument("--run-checks", action="store_true")
    args = parser.parse_args(argv)
    errors, messages = check_repo(Path(args.target), args.base, args.run_checks)
    for message in messages:
        print(message)
    for error in errors:
        print("ERROR: " + error, file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
