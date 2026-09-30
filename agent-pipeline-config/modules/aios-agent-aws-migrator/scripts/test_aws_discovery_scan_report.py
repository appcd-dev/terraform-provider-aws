#!/usr/bin/env python3
"""Tests for the AWS scan inventory PR artifact."""
from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from aws_discovery_scan_report import build_report, render_markdown


def main() -> None:
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        identity = root / "identity.json"
        identity.write_text(json.dumps({"Account": "123456789012", "Arn": "arn:aws:iam::123456789012:role/scan"}))
        state = root / "terraform.tfstate"
        state.write_text(json.dumps({"resources": [
            {"mode": "managed", "type": "aws_s3_bucket", "instances": [{}, {}]},
            {"mode": "managed", "type": "aws_iam_role", "instances": [{}]},
            {"mode": "data", "type": "aws_ignored", "instances": [{}]},
        ]}))
        log = root / "cloud2code.log"
        log.write_text("""permission skips: ImportState=1 Resources=0 Read=1 (search logs for permission_skipped); continuing with partial tfstate
scan integrity: listed=5 imported=3 import_state_skipped=1 read_skipped=1 read_failed=0 throttled_types=0
Scanning aws_iam_role [1/2] Done! (imported=1 skipped=1 permission_skipped=1 filtered=0 nil_state=0 read_failed=0)
Scanning aws_s3_bucket [2/3] Done! (imported=2 skipped=1 permission_skipped=1 filtered=0 nil_state=0 read_failed=0)
{"time":"2026-09-29T00:00:00Z","level":"WARN","msg":"permission_skipped","resource_type":"aws_iam_role","id":"sensitive-resource-id","phase":"ImportState","error":"AccessDenied: User is not authorized to perform: iam:GetRolePolicy"}
{"time":"2026-09-29T00:00:01Z","level":"WARN","msg":"permission_skipped","resource_type":"aws_s3_bucket","id":"sensitive-bucket","phase":"Read","error":"AccessDenied: User is not authorized to perform: s3:GetBucketTagging"}
""", encoding="utf-8")

        report = build_report("us-east-1", str(identity), str(state), str(log))
        assert report["aws_account_id"] == "123456789012"
        assert report["aws_region"] == "us-east-1"
        assert report["state_path_available"] is True
        assert report["scan_integrity"]["read_skipped"] == 1
        assert report["scan_integrity"]["permission_skipped_import_state"] == 1
        assert report["completeness"].startswith("partial")
        assert report["verification_checks"]["state_imported_count_matches_aggregate"] == "pass"
        assert report["permission_warning_detail_coverage_percent"] == 100.0
        assert report["verification_checks"]["individual_resources_denials_match_resources_counter"] == "pass"
        assert report["verification_checks"]["per_type_listed_outcomes_reconcile"] == "pass"
        assert report["evidence_warnings"] == []
        assert report["resource_types_found"] == [
            {"resource_type": "aws_iam_role", "resource_count": 1},
            {"resource_type": "aws_s3_bucket", "resource_count": 2},
        ]
        skipped = {item["resource_type"]: item for item in report["resource_types_skipped"]}
        assert set(skipped) == {"aws_iam_role", "aws_s3_bucket"}
        assert skipped["aws_iam_role"]["reasons"][0]["phase"] == "ImportState"
        assert "iam:GetRolePolicy" in skipped["aws_iam_role"]["reasons"][0]["aws_api_operations"]
        assert skipped["aws_s3_bucket"]["reasons"][0]["phase"] == "Read"
        assert "s3:GetBucketTagging" in skipped["aws_s3_bucket"]["reasons"][0]["aws_api_operations"]
        markdown = render_markdown(report)
        assert "123456789012" in markdown and "us-east-1" in markdown
        assert "aws_s3_bucket" in markdown and "s3:GetBucketTagging" in markdown
        assert "sensitive-resource-id" not in markdown

        # Summary-only output has no per-resource warning details: expose the
        # unknown per-type remainder rather than fabricating a denial reason.
        sparse = root / "sparse.log"
        sparse.write_text("""permission skips: ImportState=0 Resources=0 Read=6 (search logs for permission_skipped); continuing with partial tfstate
scan integrity: listed=6 imported=0 import_state_skipped=0 read_skipped=6 read_failed=0 throttled_types=0
Scanning aws_iam_role [0/6] Done! (imported=0 skipped=0 permission_skipped=6 filtered=0 nil_state=0 read_failed=0)
{"time":"2026-09-29T00:00:02Z","level":"WARN","msg":"permission_skipped","resource_type":"aws_iam_role","phase":"Read","error":"AccessDenied: User is not authorized to perform: iam:GetRole"}
{"time":"2026-09-29T00:00:03Z","level":"WARN","msg":"permission_skipped","resource_type":"aws_service","phase":"Resources","error":"AccessDenied: User is not authorized to perform: service:ListThings"}
""")
        sparse_report = build_report("eu-west-1", None, None, str(sparse))
        assert sparse_report["state_path_available"] is False
        assert sparse_report["resource_types_skipped"][0]["resource_type"] == "aws_iam_role"
        role_reasons = sparse_report["resource_types_skipped"][0]["reasons"]
        observed = next(reason for reason in role_reasons if reason["phase"] == "Read")
        unknown = next(reason for reason in role_reasons if reason["phase"] == "unknown")
        assert observed["count"] == 1 and observed["aws_api_operations"] == ["iam:GetRole"]
        assert unknown["count"] == 5 and "do not provide" in unknown["reason"]
        assert sparse_report["permission_warning_detail_coverage_percent"] == 16.7
        assert sparse_report["completeness"].startswith("unresolved")
        assert sparse_report["verification_checks"]["per_type_listed_outcomes_reconcile"] == "pass"
        assert sparse_report["verification_checks"]["individual_resources_denials_match_resources_counter"] == "mismatch"
        assert any("Resources/list permission-denial warning records" in warning for warning in sparse_report["evidence_warnings"])
        sparse_markdown = render_markdown(sparse_report)
        assert "unknown is not treated as zero or success" in sparse_markdown
        assert "Terraform state is missing" in sparse_markdown
        assert "5 have no specific action/reason" in sparse_markdown

        # An internally inconsistent counter set is called unresolved, not
        # rounded into success or hidden by downstream split reconciliation.
        mismatch = root / "mismatch.log"
        mismatch.write_text("""scan integrity: listed=10 imported=8 import_state_skipped=0 read_skipped=0 read_failed=0 throttled_types=0
Scanning aws_iam_role [8/10] Done! (imported=8 skipped=0 permission_skipped=0 filtered=0 nil_state=0 read_failed=0)
""")
        mismatch_report = build_report("us-east-1", None, None, str(mismatch))
        assert mismatch_report["completeness"].startswith("unresolved")
        assert mismatch_report["verification_checks"]["per_type_listed_outcomes_reconcile"] == "mismatch"
        assert any("Treat the inventory as unresolved" in warning for warning in mismatch_report["evidence_warnings"])
    print("OK: AWS discovery scan report")


if __name__ == "__main__":
    main()
