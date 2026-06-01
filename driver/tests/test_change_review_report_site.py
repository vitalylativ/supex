"""Tests for the Change Review static report generator."""

import json
from pathlib import Path

from supex_driver.change_review.report_site import BuildOptions, build_site


def write_json(path: Path, data: object) -> None:
    path.write_text(json.dumps(data), encoding="utf-8")


def make_run(tmp_path: Path) -> Path:
    run = tmp_path / "change-review"
    artifacts = run / "artifacts"
    screenshots = run / "screenshots"
    artifacts.mkdir(parents=True)
    screenshots.mkdir()

    (artifacts / "job.yml").write_text(
        'request: "Retag furniture and normalize material names"\n',
        encoding="utf-8",
    )
    write_json(
        artifacts / "manifest.json",
        {
            "schema_version": "change_review_manifest.v1",
            "job_id": "job-001",
            "title": "Balcony Study Review",
            "screenshots": [
                {
                    "id": "view-iso",
                    "name": "Iso",
                    "before": "screenshots/iso.before.png",
                    "after": "screenshots/iso.after.png",
                    "camera_claim": "matched_generated_view",
                    "related_changes": ["chg-001"],
                }
            ],
        },
    )
    write_json(
        artifacts / "diff.json",
        {
            "schema_version": "change_diff.v1",
            "summary": {
                "requested": 1,
                "warning": 1,
                "forbidden": 0,
                "not_checked": 1,
            },
            "changes": [
                {
                    "id": "chg-001",
                    "entity_key": "persistent_id:123",
                    "change_type": "material_change",
                    "classification": "requested",
                    "before": "Oak",
                    "after": "White Oak",
                    "reason": "Within scope",
                }
            ],
            "not_checked": [
                {"code": "RAW_TOPOLOGY_NOT_CHECKED", "message": "Raw topology was not checked."}
            ],
        },
    )
    write_json(
        artifacts / "checks.json",
        {
            "warnings": [
                {
                    "message": "One screenshot used a matched generated view.",
                }
            ]
        },
    )
    (artifacts / "run.log").write_text("sensitive log", encoding="utf-8")
    (screenshots / "iso.before.png").write_bytes(b"before")
    (screenshots / "iso.after.png").write_bytes(b"after")
    return run


def test_build_site_generates_static_report(tmp_path: Path) -> None:
    run = make_run(tmp_path)

    site = build_site(run)

    assert (site / "index.html").exists()
    assert (site / "assets" / "report.css").exists()
    assert (site / "assets" / "report.js").exists()
    assert (site / "screenshots" / "iso.before.png").exists()
    assert (site / "screenshots" / "iso.after.png").exists()
    assert (site / "artifacts" / "diff.json").exists()

    html = (site / "index.html").read_text(encoding="utf-8")
    assert "Balcony Study Review" in html
    assert "Retag furniture and normalize material names" in html
    assert "Material Change" in html
    assert "Raw topology was not checked" in html


def test_public_build_excludes_logs(tmp_path: Path) -> None:
    run = make_run(tmp_path)

    site = build_site(run, options=BuildOptions(public=True))

    assert not (site / "artifacts" / "run.log").exists()
    assert (site / "artifacts" / "diff.json").exists()
    html = (site / "index.html").read_text(encoding="utf-8")
    assert "Public mode" in html
