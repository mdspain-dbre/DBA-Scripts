#!/usr/bin/env python3
"""Migrate the unicorn PostgreSQL database from AWS RDS to GCP Cloud SQL.

The script streams a pg_dump from the source RDS instance, compresses it with
gzip, uploads the result directly to GCS, and then starts a Cloud SQL import.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from datetime import datetime
from typing import Iterable


def env(name: str, default: str) -> str:
    value = os.environ.get(name)
    return default if value in (None, "") else value


def build_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Stream an AWS RDS PostgreSQL dump into GCS and import it into Cloud SQL."
    )
    parser.add_argument("--aws-profile", default=env("AWS_PROFILE", "inscape-production-us-1-inscape-aws-ops"))
    parser.add_argument("--aws-region", default=env("AWS_REGION", "us-east-1"))
    parser.add_argument("--source-rds-instance", default=env("SOURCE_RDS_INSTANCE", "prod-rds-unicorn-dev-pg18"))
    parser.add_argument("--source-db", default=env("SOURCE_DB", "unicorn"))
    parser.add_argument("--source-db-user", default=env("SOURCE_DB_USER", "root"))
    parser.add_argument("--source-db-password", default=env("SOURCE_DB_PASSWORD", ""))
    parser.add_argument("--gcp-project-id", default=env("GCP_PROJECT_ID", "vz-inscape-portfolio-dev"))
    parser.add_argument("--target-cloudsql-instance", default=env("TARGET_CLOUDSQL_INSTANCE", "admin-portal-db"))
    parser.add_argument("--target-db", default=env("TARGET_DB", "unicorn"))
    parser.add_argument("--gcs-bucket", default=env("GCS_BUCKET", "pointsdb-backup"))
    parser.add_argument("--gcs-prefix", default=env("GCS_PREFIX", "unicorn-postgres"))
    parser.add_argument("--import-async", default=env("IMPORT_ASYNC", "false"))
    parser.add_argument("--pg-dump-bin", default=env("PG_DUMP_BIN", "/opt/homebrew/opt/postgresql@18/bin/pg_dump"))
    return parser.parse_args()


def run_checked(command: Iterable[str], *, env_overrides: dict[str, str] | None = None) -> subprocess.Popen:
    merged_env = os.environ.copy()
    if env_overrides:
        merged_env.update(env_overrides)
    return subprocess.Popen(
        list(command),
        env=merged_env,
        stdout=subprocess.PIPE,
        stderr=sys.stderr,
    )


def resolve_rds_endpoint(profile: str, region: str, instance_id: str) -> tuple[str, str]:
    result = subprocess.run(
        [
            "aws",
            "--profile",
            profile,
            "--region",
            region,
            "rds",
            "describe-db-instances",
            "--db-instance-identifier",
            instance_id,
            "--query",
            "DBInstances[0].Endpoint.[Address,Port]",
            "--output",
            "text",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    parts = result.stdout.split()
    if len(parts) < 2:
        raise RuntimeError(f"Unexpected RDS endpoint output: {result.stdout!r}")
    return parts[0], parts[1]


def main() -> int:
    args = build_args()

    source_host, source_port = resolve_rds_endpoint(args.aws_profile, args.aws_region, args.source_rds_instance)
    print(f"Source RDS: {source_host}:{source_port}")

    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    gcs_uri = f"gs://{args.gcs_bucket.rstrip('/')}/{args.gcs_prefix}/{args.source_db}_{timestamp}.sql.gz"
    print(f"Streaming pg_dump | gzip | gcloud storage cp -> {gcs_uri}")

    pg_dump_env = {"PGPASSWORD": args.source_db_password}
    pg_dump_cmd = [
        args.pg_dump_bin,
        f"--host={source_host}",
        f"--port={source_port}",
        f"--username={args.source_db_user}",
        f"--dbname={args.source_db}",
        "--format=plain",
        "--encoding=UTF8",
        "--no-owner",
        "--no-privileges",
        "--quote-all-identifiers",
    ]

    pg_dump_proc = run_checked(pg_dump_cmd, env_overrides=pg_dump_env)
    gzip_proc = subprocess.Popen(["gzip", "-c"], stdin=pg_dump_proc.stdout, stdout=subprocess.PIPE, stderr=sys.stderr)
    assert pg_dump_proc.stdout is not None
    pg_dump_proc.stdout.close()

    gcloud_upload_proc = subprocess.Popen(
        ["gcloud", "--project", args.gcp_project_id, "storage", "cp", "-", gcs_uri],
        stdin=gzip_proc.stdout,
        stderr=sys.stderr,
    )
    assert gzip_proc.stdout is not None
    gzip_proc.stdout.close()

    upload_exit = gcloud_upload_proc.wait()
    gzip_exit = gzip_proc.wait()
    pg_dump_exit = pg_dump_proc.wait()
    if pg_dump_exit != 0:
        raise subprocess.CalledProcessError(pg_dump_exit, pg_dump_cmd)
    if gzip_exit != 0:
        raise subprocess.CalledProcessError(gzip_exit, ["gzip", "-c"])
    if upload_exit != 0:
        raise subprocess.CalledProcessError(upload_exit, ["gcloud", "storage", "cp", "-", gcs_uri])

    print("Verifying uploaded object")
    subprocess.run(["gcloud", "--project", args.gcp_project_id, "storage", "ls", "-l", gcs_uri], check=True)

    print("Starting Cloud SQL import")
    if args.import_async.lower() == "true":
        op = subprocess.run(
            [
                "gcloud",
                "--project",
                args.gcp_project_id,
                "sql",
                "import",
                "sql",
                args.target_cloudsql_instance,
                gcs_uri,
                f"--database={args.target_db}",
                "--async",
                "--format=value(name)",
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        operation_id = op.stdout.strip()
        print(f"Import started asynchronously. Operation: {operation_id}")
        print(f"Track with: gcloud --project {args.gcp_project_id} sql operations describe {operation_id}")
    else:
        subprocess.run(
            [
                "gcloud",
                "--project",
                args.gcp_project_id,
                "sql",
                "import",
                "sql",
                args.target_cloudsql_instance,
                gcs_uri,
                f"--database={args.target_db}",
                "--quiet",
            ],
            check=True,
        )
        print("Import completed successfully")

    print("Done")
    print(f"GCS object: {gcs_uri}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())