"""Generate a static website for a Supex Change Review run."""

from __future__ import annotations

import argparse
import html
import json
import re
import shutil
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Any


IMAGE_SUFFIXES = {".png", ".jpg", ".jpeg", ".webp"}
PUBLIC_ARTIFACT_ALLOWLIST = {
    "job.yml",
    "manifest.json",
    "diff.json",
    "checks.json",
}


@dataclass(frozen=True)
class SourceLayout:
    """Resolved source folders for one Change Review run."""

    root: Path
    artifacts_dir: Path
    screenshots_dir: Path


@dataclass(frozen=True)
class BuildOptions:
    """Static report generation options."""

    public: bool = False
    include_models: bool = False
    include_logs: bool = False


def build_site(
    source: Path,
    output: Path | None = None,
    *,
    options: BuildOptions | None = None,
) -> Path:
    """Build a static report site from a Change Review artifact folder."""
    opts = options or BuildOptions()
    layout = resolve_layout(source)
    output_dir = output or layout.root / "site"
    data = load_report_data(layout)

    if output_dir.exists():
        shutil.rmtree(output_dir)
    (output_dir / "assets").mkdir(parents=True)
    (output_dir / "screenshots").mkdir()
    (output_dir / "artifacts").mkdir()

    copied_screenshots = copy_screenshots(layout, output_dir)
    copied_artifacts = copy_artifacts(layout, output_dir, opts)
    copy_downloads(layout, output_dir, opts)

    html_text = render_html(data, copied_screenshots, copied_artifacts, opts)
    (output_dir / "index.html").write_text(html_text, encoding="utf-8")
    (output_dir / "assets" / "report.css").write_text(render_css(), encoding="utf-8")
    (output_dir / "assets" / "report.js").write_text(render_js(), encoding="utf-8")

    return output_dir


def resolve_layout(source: Path) -> SourceLayout:
    """Resolve supported source layouts to the Change Review run root."""
    source = source.expanduser().resolve()
    candidates = [
        source,
        source / "change-review",
    ]
    for root in candidates:
        artifacts_dir = root / "artifacts"
        if artifacts_dir.is_dir():
            return SourceLayout(
                root=root,
                artifacts_dir=artifacts_dir,
                screenshots_dir=root / "screenshots",
            )
    raise FileNotFoundError(
        f"Could not find an artifacts/ folder under {source} or {source / 'change-review'}"
    )


def load_report_data(layout: SourceLayout) -> dict[str, Any]:
    """Load report JSON/YAML-adjacent inputs with permissive fallbacks."""
    artifacts = layout.artifacts_dir
    job_text = read_text_if_exists(artifacts / "job.yml")
    manifest = read_json_if_exists(artifacts / "manifest.json")
    diff = read_json_if_exists(artifacts / "diff.json")
    checks = read_json_if_exists(artifacts / "checks.json")

    return {
        "job_text": job_text,
        "manifest": manifest,
        "diff": diff,
        "checks": checks,
        "request": extract_request(job_text, manifest),
        "title": str(manifest.get("title") or "Supex Change Review"),
        "job_id": str(manifest.get("job_id") or layout.root.name),
    }


def read_text_if_exists(path: Path) -> str:
    if not path.exists():
        return ""
    return path.read_text(encoding="utf-8")


def read_json_if_exists(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def extract_request(job_text: str, manifest: dict[str, Any]) -> str:
    """Extract a human request from manifest or simple YAML."""
    request = manifest.get("request")
    if isinstance(request, str) and request.strip():
        return request.strip()

    match = re.search(r"(?m)^request:\s*(.+?)\s*$", job_text)
    if not match:
        return "No request recorded."
    value = match.group(1).strip()
    if len(value) >= 2 and value[0] in {"'", '"'} and value[-1] == value[0]:
        return value[1:-1]
    return value


def copy_screenshots(layout: SourceLayout, output_dir: Path) -> dict[str, str]:
    """Copy screenshots and return source-name to relative output path mapping."""
    copied: dict[str, str] = {}
    if not layout.screenshots_dir.exists():
        return copied

    target_dir = output_dir / "screenshots"
    for path in sorted(layout.screenshots_dir.iterdir()):
        if path.is_file() and path.suffix.lower() in IMAGE_SUFFIXES:
            target = target_dir / path.name
            shutil.copy2(path, target)
            copied[path.name] = str(Path("screenshots") / path.name)
    return copied


def copy_artifacts(
    layout: SourceLayout,
    output_dir: Path,
    options: BuildOptions,
) -> dict[str, str]:
    """Copy safe artifacts and return filename to relative output path mapping."""
    copied: dict[str, str] = {}
    target_dir = output_dir / "artifacts"
    for path in sorted(layout.artifacts_dir.iterdir()):
        if not path.is_file():
            continue
        if should_skip_artifact(path, options):
            continue
        target = target_dir / path.name
        shutil.copy2(path, target)
        copied[path.name] = str(Path("artifacts") / path.name)
    return copied


def should_skip_artifact(path: Path, options: BuildOptions) -> bool:
    """Return whether an artifact should be omitted from the generated site."""
    suffix = path.suffix.lower()
    if suffix == ".skp" and not options.include_models:
        return True
    if path.name == "run.log" and not options.include_logs:
        return True
    if options.public and path.name not in PUBLIC_ARTIFACT_ALLOWLIST:
        return True
    return False


def copy_downloads(layout: SourceLayout, output_dir: Path, options: BuildOptions) -> None:
    """Copy optional downloads such as review copies."""
    if not options.include_models:
        return
    downloads_dir = output_dir / "downloads"
    downloads_dir.mkdir(exist_ok=True)
    for path in sorted(layout.root.rglob("*.skp")):
        if "site" in path.relative_to(layout.root).parts:
            continue
        shutil.copy2(path, downloads_dir / path.name)


def screenshot_pairs(
    data: dict[str, Any],
    copied_screenshots: dict[str, str],
) -> list[dict[str, Any]]:
    """Return screenshot pairs from manifest hints or filename conventions."""
    manifest = data["manifest"]
    screenshots = manifest.get("screenshots")
    if isinstance(screenshots, list) and screenshots:
        pairs = []
        for index, item in enumerate(screenshots):
            if not isinstance(item, dict):
                continue
            before = screenshot_relpath(item.get("before"), copied_screenshots)
            after = screenshot_relpath(item.get("after"), copied_screenshots)
            pairs.append({
                "id": item.get("id") or f"view-{index + 1}",
                "name": item.get("name") or item.get("id") or f"View {index + 1}",
                "before": before,
                "after": after,
                "camera_claim": item.get("camera_claim") or item.get("camera_status") or "unknown",
                "related_changes": item.get("related_changes") or [],
            })
        return pairs

    stems: dict[str, dict[str, str]] = defaultdict(dict)
    for name, relpath in copied_screenshots.items():
        stem = Path(name).stem
        if stem.endswith(".before"):
            stems[stem.removesuffix(".before")]["before"] = relpath
        elif stem.endswith(".after"):
            stems[stem.removesuffix(".after")]["after"] = relpath

    pairs = []
    for index, (stem, values) in enumerate(sorted(stems.items())):
        pairs.append({
            "id": f"view-{index + 1}",
            "name": stem.replace("_", " ").replace("-", " ").title(),
            "before": values.get("before"),
            "after": values.get("after"),
            "camera_claim": "unknown",
            "related_changes": [],
        })
    return pairs


def screenshot_relpath(value: Any, copied_screenshots: dict[str, str]) -> str | None:
    if not isinstance(value, str) or not value:
        return None
    name = Path(value).name
    return copied_screenshots.get(name) or value


def diff_changes(data: dict[str, Any]) -> list[dict[str, Any]]:
    changes = data["diff"].get("changes", [])
    return [item for item in changes if isinstance(item, dict)]


def diff_summary(data: dict[str, Any]) -> Counter[str]:
    summary = data["diff"].get("summary")
    if isinstance(summary, dict):
        counter = Counter()
        for key, value in summary.items():
            if isinstance(value, int):
                counter[key] = value
        return counter

    counter = Counter()
    for change in diff_changes(data):
        classification = str(change.get("classification") or "unclassified")
        counter[classification] += 1
    return counter


def checks_items(checks: dict[str, Any], key: str) -> list[Any]:
    value = checks.get(key)
    return value if isinstance(value, list) else []


def render_html(
    data: dict[str, Any],
    copied_screenshots: dict[str, str],
    copied_artifacts: dict[str, str],
    options: BuildOptions,
) -> str:
    pairs = screenshot_pairs(data, copied_screenshots)
    changes = diff_changes(data)
    summary = diff_summary(data)
    grouped = group_changes_by_type(changes)
    status = infer_status(summary, data["checks"])

    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{e(data["title"])}</title>
  <link rel="stylesheet" href="assets/report.css">
</head>
<body>
  <header class="topbar">
    <div>
      <p class="eyebrow">Supex Change Review</p>
      <h1>{e(data["title"])}</h1>
    </div>
    <div class="status status-{status.lower().replace(" ", "-")}">{e(status)}</div>
  </header>

  <main>
    <section class="panel hero">
      <div>
        <h2>Request</h2>
        <p class="request">{e(data["request"])}</p>
      </div>
      <div class="chips">
        {render_chip("Requested", summary.get("requested", 0), "neutral")}
        {render_chip("Warnings", summary.get("warning", summary.get("warnings", 0)), "warning")}
        {render_chip("Forbidden", summary.get("forbidden", 0), "danger")}
        {render_chip("Not checked", summary.get("not_checked", 0), "muted")}
      </div>
    </section>

    {render_review_first(data)}
    {render_visual_evidence(pairs, changes)}
    {render_changes(grouped)}
    {render_attention(data)}
    {render_claim_ledger(data, copied_artifacts)}
    {render_not_checked(data)}
    {render_scope(data)}
    {render_artifacts(copied_artifacts, options)}
  </main>

  <script src="assets/report.js"></script>
</body>
</html>
"""


def infer_status(summary: Counter[str], checks: dict[str, Any]) -> str:
    if summary.get("forbidden", 0) > 0 or checks_items(checks, "failed"):
        return "Blocked"
    if summary.get("warning", 0) > 0 or summary.get("warnings", 0) > 0:
        return "Needs human review"
    return "Ready for review"


def render_chip(label: str, value: int, tone: str) -> str:
    return f'<div class="chip {tone}"><span>{e(str(value))}</span>{e(label)}</div>'


def render_review_first(data: dict[str, Any]) -> str:
    checks = data["checks"]
    warnings = checks_items(checks, "warnings")
    failed = checks_items(checks, "failed")
    items = failed[:3] + warnings[:5]
    if not items:
        body = "<p>No high-priority review items were listed in checks.json.</p>"
    else:
        body = "<ul>" + "".join(f"<li>{e(item_text(item))}</li>" for item in items) + "</ul>"
    return f"""
    <section class="panel attention">
      <h2>Review These First</h2>
      {body}
    </section>
    """


def render_visual_evidence(
    pairs: list[dict[str, Any]],
    changes: list[dict[str, Any]],
) -> str:
    if not pairs:
        return """
    <section class="panel">
      <h2>Visual Evidence</h2>
      <p>No screenshot pairs were found.</p>
    </section>
        """

    cards = []
    for pair in pairs:
        before = render_image(pair.get("before"), "Before")
        after = render_image(pair.get("after"), "After")
        cards.append(f"""
        <article class="view-card" id="{e(str(pair["id"]))}">
          <div class="view-card-header">
            <h3>{e(str(pair["name"]))}</h3>
            <span class="badge">{e(str(pair["camera_claim"]).replace("_", " "))}</span>
          </div>
          <div class="compare">
            <figure>{before}<figcaption>Before</figcaption></figure>
            <figure>{after}<figcaption>After</figcaption></figure>
          </div>
          <p class="fineprint">Screenshots support visual review; they are not proof of model correctness.</p>
        </article>
        """)

    return f"""
    <section class="panel">
      <h2>Visual Evidence</h2>
      <div class="evidence-grid">
        {"".join(render_evidence_tile(pair, changes) for pair in pairs)}
      </div>
      <div class="view-list">
        {"".join(cards)}
      </div>
    </section>
    """


def render_evidence_tile(pair: dict[str, Any], changes: list[dict[str, Any]]) -> str:
    related = pair.get("related_changes") or []
    count = len(related) if related else len(changes)
    return f"""
      <a class="evidence-tile" href="#{e(str(pair["id"]))}">
        <strong>{e(str(pair["name"]))}</strong>
        <span>{count} related changes</span>
        <small>{e(str(pair["camera_claim"]).replace("_", " "))}</small>
      </a>
    """


def render_image(path: Any, alt: str) -> str:
    if not isinstance(path, str) or not path:
        return '<div class="missing-image">Missing image</div>'
    return f'<img src="{e(path)}" alt="{e(alt)}">'


def group_changes_by_type(changes: list[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for change in changes:
        key = str(change.get("change_type") or "other_change")
        grouped[key].append(change)
    return dict(sorted(grouped.items()))


def render_changes(grouped: dict[str, list[dict[str, Any]]]) -> str:
    if not grouped:
        body = "<p>No structured changes were found in diff.json.</p>"
    else:
        body = "".join(render_change_group(change_type, rows) for change_type, rows in grouped.items())
    return f"""
    <section class="panel">
      <h2>Changed Items</h2>
      {body}
    </section>
    """


def render_change_group(change_type: str, rows: list[dict[str, Any]]) -> str:
    table_rows = "".join(render_change_row(row) for row in rows)
    return f"""
    <details open>
      <summary>{e(change_type.replace("_", " ").title())} ({len(rows)})</summary>
      <div class="table-wrap">
        <table>
          <thead>
            <tr>
              <th>ID</th>
              <th>Entity</th>
              <th>Classification</th>
              <th>Before</th>
              <th>After</th>
              <th>Reason</th>
            </tr>
          </thead>
          <tbody>{table_rows}</tbody>
        </table>
      </div>
    </details>
    """


def render_change_row(row: dict[str, Any]) -> str:
    change_id = str(row.get("id") or "")
    entity = str(row.get("entity_key") or row.get("entity") or row.get("name") or "")
    classification = str(row.get("classification") or "")
    before = compact_json(row.get("before"))
    after = compact_json(row.get("after"))
    reason = str(row.get("reason") or "")
    return f"""
    <tr id="{e(change_id)}">
      <td><code>{e(change_id)}</code></td>
      <td>{e(entity)}</td>
      <td><span class="label">{e(classification)}</span></td>
      <td>{e(before)}</td>
      <td>{e(after)}</td>
      <td>{e(reason)}</td>
    </tr>
    """


def render_attention(data: dict[str, Any]) -> str:
    diff = data["diff"]
    checks = data["checks"]
    unexpected = diff.get("unexpected_changes", [])
    warnings = checks_items(checks, "warnings")
    failed = checks_items(checks, "failed")
    forbidden = [row for row in diff_changes(data) if row.get("classification") == "forbidden"]
    return f"""
    <section class="panel attention">
      <h2>Review Attention</h2>
      {render_item_list("Forbidden Changes", forbidden)}
      {render_item_list("Failed Checks", failed)}
      {render_item_list("Unexpected Changes", unexpected)}
      {render_item_list("Warnings", warnings)}
    </section>
    """


def render_item_list(title: str, items: list[Any]) -> str:
    if not items:
        return f"<h3>{e(title)}</h3><p>None listed.</p>"
    rows = "".join(f"<li>{e(item_text(item))}</li>" for item in items)
    return f"<h3>{e(title)}</h3><ul>{rows}</ul>"


def render_claim_ledger(data: dict[str, Any], artifacts: dict[str, str]) -> str:
    summary = diff_summary(data)
    rows = [
        ("Original file was not modified", "See checks", artifacts.get("checks.json"), "File-level check only."),
        ("Requested changes were classified", str(summary.get("requested", 0)), artifacts.get("diff.json"), "Scoped by job.yml."),
        ("Forbidden changes were checked", str(summary.get("forbidden", 0)), artifacts.get("checks.json"), "Only configured categories."),
        ("Not-checked limitations were recorded", str(summary.get("not_checked", 0)), artifacts.get("diff.json"), "Not a correctness proof."),
    ]
    body = "".join(
        f"<tr><td>{e(claim)}</td><td>{e(status)}</td><td>{artifact_link(link)}</td><td>{e(limitation)}</td></tr>"
        for claim, status, link, limitation in rows
    )
    return f"""
    <section class="panel">
      <h2>Claim Ledger</h2>
      <div class="table-wrap">
        <table>
          <thead><tr><th>Claim</th><th>Status</th><th>Evidence</th><th>Limitation</th></tr></thead>
          <tbody>{body}</tbody>
        </table>
      </div>
    </section>
    """


def render_not_checked(data: dict[str, Any]) -> str:
    not_checked = data["diff"].get("not_checked")
    if not isinstance(not_checked, list):
        not_checked = []
    if not_checked:
        body = "<ul>" + "".join(f"<li>{e(item_text(item))}</li>" for item in not_checked) + "</ul>"
    else:
        body = """
        <ul>
          <li>Raw face/edge topology was not checked unless listed in artifacts.</li>
          <li>Whole-model non-regression was not checked.</li>
          <li>Design, code, BIM, IFC, estimate, and render correctness were not checked.</li>
        </ul>
        """
    return f"""
    <section class="panel muted-panel">
      <h2>Not Checked</h2>
      {body}
    </section>
    """


def render_scope(data: dict[str, Any]) -> str:
    job_text = data["job_text"]
    if not job_text:
        return ""
    return f"""
    <section class="panel">
      <h2>Scope Contract</h2>
      <pre>{e(job_text)}</pre>
    </section>
    """


def render_artifacts(artifacts: dict[str, str], options: BuildOptions) -> str:
    if not artifacts:
        return ""
    rows = "".join(f"<li>{artifact_link(path)}</li>" for path in artifacts.values())
    privacy_note = "Public mode: only allowlisted artifacts were copied." if options.public else ""
    return f"""
    <section class="panel">
      <h2>Artifacts</h2>
      <p>{e(privacy_note)}</p>
      <ul>{rows}</ul>
    </section>
    """


def artifact_link(path: str | None) -> str:
    if not path:
        return "Not copied"
    return f'<a href="{e(path)}">{e(Path(path).name)}</a>'


def compact_json(value: Any) -> str:
    if isinstance(value, str):
        return value
    if value is None:
        return ""
    return json.dumps(value, ensure_ascii=False, separators=(",", ": "))


def item_text(item: Any) -> str:
    if isinstance(item, str):
        return item
    if isinstance(item, dict):
        for key in ("message", "summary", "reason", "code", "id"):
            value = item.get(key)
            if value:
                return str(value)
        return compact_json(item)
    return str(item)


def e(value: str) -> str:
    return html.escape(value, quote=True)


def render_css() -> str:
    return """
:root {
  color-scheme: light;
  --bg: #f6f5f2;
  --panel: #ffffff;
  --ink: #1f2933;
  --muted: #65717f;
  --line: #d8dce0;
  --accent: #2563eb;
  --warning: #b7791f;
  --danger: #b91c1c;
  --ok: #047857;
}

* { box-sizing: border-box; }
body {
  margin: 0;
  font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  background: var(--bg);
  color: var(--ink);
}
a { color: var(--accent); }
.topbar {
  display: flex;
  justify-content: space-between;
  gap: 24px;
  align-items: center;
  padding: 28px clamp(20px, 5vw, 56px);
  border-bottom: 1px solid var(--line);
  background: #ffffff;
}
.eyebrow {
  margin: 0 0 4px;
  color: var(--muted);
  font-size: 13px;
  text-transform: uppercase;
  letter-spacing: 0.08em;
}
h1, h2, h3 { margin-top: 0; }
h1 { margin-bottom: 0; font-size: clamp(28px, 4vw, 44px); }
main {
  width: min(1180px, calc(100vw - 32px));
  margin: 28px auto 64px;
}
.panel {
  background: var(--panel);
  border: 1px solid var(--line);
  border-radius: 8px;
  padding: 24px;
  margin-bottom: 18px;
}
.hero {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto;
  gap: 24px;
}
.request { font-size: 20px; line-height: 1.45; }
.status {
  border-radius: 999px;
  padding: 8px 14px;
  border: 1px solid var(--line);
  background: #f8fafc;
  font-weight: 700;
  white-space: nowrap;
}
.status-blocked { color: var(--danger); border-color: #fecaca; background: #fff1f2; }
.status-needs-human-review { color: var(--warning); border-color: #fde68a; background: #fffbeb; }
.status-ready-for-review { color: var(--ok); border-color: #a7f3d0; background: #ecfdf5; }
.chips {
  display: grid;
  grid-template-columns: repeat(2, minmax(120px, 1fr));
  gap: 10px;
}
.chip {
  border: 1px solid var(--line);
  border-radius: 8px;
  padding: 12px;
  color: var(--muted);
}
.chip span { display: block; color: var(--ink); font-size: 24px; font-weight: 800; }
.chip.warning span { color: var(--warning); }
.chip.danger span { color: var(--danger); }
.chip.muted span { color: var(--muted); }
.attention { border-left: 4px solid var(--warning); }
.muted-panel { background: #f9fafb; }
.evidence-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
  gap: 12px;
  margin-bottom: 22px;
}
.evidence-tile {
  display: grid;
  gap: 4px;
  padding: 14px;
  border: 1px solid var(--line);
  border-radius: 8px;
  text-decoration: none;
  color: var(--ink);
  background: #fbfcfd;
}
.evidence-tile small { color: var(--muted); }
.view-card {
  border-top: 1px solid var(--line);
  padding-top: 20px;
  margin-top: 20px;
}
.view-card-header {
  display: flex;
  justify-content: space-between;
  gap: 16px;
}
.badge, .label {
  display: inline-flex;
  align-items: center;
  border: 1px solid var(--line);
  border-radius: 999px;
  padding: 3px 9px;
  color: var(--muted);
  font-size: 13px;
}
.compare {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 16px;
}
figure { margin: 0; }
figcaption { color: var(--muted); margin-top: 6px; }
img {
  width: 100%;
  max-height: 620px;
  object-fit: contain;
  border: 1px solid var(--line);
  border-radius: 6px;
  background: #eef1f4;
}
.missing-image {
  display: grid;
  place-items: center;
  min-height: 220px;
  border: 1px dashed var(--line);
  border-radius: 6px;
  color: var(--muted);
  background: #f8fafc;
}
.fineprint { color: var(--muted); font-size: 13px; }
details {
  border-top: 1px solid var(--line);
  padding-top: 14px;
  margin-top: 14px;
}
summary {
  cursor: pointer;
  font-weight: 700;
}
.table-wrap { overflow-x: auto; margin-top: 12px; }
table {
  width: 100%;
  border-collapse: collapse;
  font-size: 14px;
}
th, td {
  text-align: left;
  border-bottom: 1px solid var(--line);
  padding: 10px 8px;
  vertical-align: top;
}
th { color: var(--muted); font-weight: 700; }
pre {
  overflow-x: auto;
  padding: 16px;
  background: #111827;
  color: #f9fafb;
  border-radius: 6px;
}
code { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
@media (max-width: 780px) {
  .topbar, .hero, .compare { grid-template-columns: 1fr; }
  .topbar { align-items: flex-start; }
}
@media print {
  body { background: #fff; }
  .panel { break-inside: avoid; }
  a::after { content: " (" attr(href) ")"; font-size: 10px; color: var(--muted); }
}
"""


def render_js() -> str:
    return """
document.querySelectorAll('a[href^="#"]').forEach((link) => {
  link.addEventListener("click", () => {
    const target = document.querySelector(link.getAttribute("href"));
    if (!target) return;
    target.classList.add("flash");
    window.setTimeout(() => target.classList.remove("flash"), 1200);
  });
});
"""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build a static Supex Change Review report website."
    )
    parser.add_argument(
        "source",
        type=Path,
        help="Change Review run folder, or a run folder containing change-review/.",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=None,
        help="Output site directory. Defaults to <source>/site.",
    )
    parser.add_argument(
        "--public",
        action="store_true",
        help="Copy only public-safe allowlisted artifacts.",
    )
    parser.add_argument(
        "--include-models",
        action="store_true",
        help="Copy .skp downloads into the generated site.",
    )
    parser.add_argument(
        "--include-logs",
        action="store_true",
        help="Copy run.log into the generated site.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    site = build_site(
        args.source,
        args.out,
        options=BuildOptions(
            public=args.public,
            include_models=args.include_models,
            include_logs=args.include_logs,
        ),
    )
    print(site)


if __name__ == "__main__":
    main()

