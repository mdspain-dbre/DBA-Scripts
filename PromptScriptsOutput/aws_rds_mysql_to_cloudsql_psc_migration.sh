#!/usr/bin/env bash
set -euo pipefail
umask 077

# -----------------------------------------------------------------------------
# Script intent
# -----------------------------------------------------------------------------
# This script orchestrates a staged migration from AWS RDS MySQL to
# Google Cloud SQL MySQL using a dump-and-restore workflow.
#
# Design goals:
# - Keep source operations read-only.
# - Make each stage rerunnable where practical.
# - Record resource identifiers for safe, explicit cleanup.
# - Support safer secret handling via AWS SSM Parameter Store.
#
# Operational model:
# - Run one stage at a time (recommended), or run-all.
# - Each stage logs details into a timestamped run directory.
# - Long-running tasks (transfer/import watch) are backgrounded with nohup.
# -----------------------------------------------------------------------------

# AWS RDS MySQL -> GCP Cloud SQL MySQL migration orchestrator
# - Source operations are read-only (mysqldump)
# - Target creation/import is staged and idempotent where possible
# - Resource IDs are logged for unambiguous cleanup
#
# Usage:
#   chmod +x aws_rds_mysql_to_cloudsql_psc_migration.sh
#   ./aws_rds_mysql_to_cloudsql_psc_migration.sh preflight
#   ./aws_rds_mysql_to_cloudsql_psc_migration.sh create-target
#   ./aws_rds_mysql_to_cloudsql_psc_migration.sh stage-buckets
#   ./aws_rds_mysql_to_cloudsql_psc_migration.sh launch-dump-host
#   ./aws_rds_mysql_to_cloudsql_psc_migration.sh start-dump
#   ./aws_rds_mysql_to_cloudsql_psc_migration.sh transfer-to-gcs
#   ./aws_rds_mysql_to_cloudsql_psc_migration.sh patch-flag
#   ./aws_rds_mysql_to_cloudsql_psc_migration.sh start-import
#   ./aws_rds_mysql_to_cloudsql_psc_migration.sh create-master-user
#   ./aws_rds_mysql_to_cloudsql_psc_migration.sh verify
#
# Optional one-shot (runs all stages except cleanup):
#   ./aws_rds_mysql_to_cloudsql_psc_migration.sh run-all
#
# Cleanup is intentionally separate and requires explicit user confirmation.

#######################################
# Configuration (override via env vars)
#######################################
AWS_PROFILE="${AWS_PROFILE:-inscape-production-us-1-inscape-aws-ops}"
AWS_REGION="${AWS_REGION:-us-east-1}"
RDS_ENDPOINT="${RDS_ENDPOINT:-prod-rds-auxdb-qa-80-20240808.cujpo2r0mujo.us-east-1.rds.amazonaws.com}"
RDS_PORT="${RDS_PORT:-3306}"
RDS_USER="${RDS_USER:-master}"
RDS_PASSWORD="${RDS_PASSWORD:-}" # required
RDS_PASSWORD_PARAM="${RDS_PASSWORD_PARAM:-}" # optional SSM parameter path for source DB password

GCP_PROJECT_ID="${GCP_PROJECT_ID:-vz-inscape-portfolio-dev}"
GCP_REGION="${GCP_REGION:-us-west1}"
GCP_ZONE="${GCP_ZONE:-us-west1-a}"
CLOUDSQL_INSTANCE="${CLOUDSQL_INSTANCE:-auxdb-qa-dre-test2}"
CLOUDSQL_DB_VERSION="${CLOUDSQL_DB_VERSION:-MYSQL_8_0}"
CLOUDSQL_TIER="${CLOUDSQL_TIER:-db-custom-2-7680}"
CLOUDSQL_DISK_SIZE_GB="${CLOUDSQL_DISK_SIZE_GB:-300}"
CLOUDSQL_ROOT_PASSWORD="${CLOUDSQL_ROOT_PASSWORD:-}" # required
ALLOWED_PSC_PROJECTS="${ALLOWED_PSC_PROJECTS:-vz-inscape-portfolio-dev,vz-inscape-dev}"

# Source SG allowed to access RDS
SOURCE_CLIENT_SG_ID="${SOURCE_CLIENT_SG_ID:-sg-750d9c02}"

# If empty, script tries to discover from default VPC and first public subnet in AZ.
DUMP_VPC_ID="${DUMP_VPC_ID:-}"
DUMP_SUBNET_ID="${DUMP_SUBNET_ID:-}"
DUMP_SG_ID="${DUMP_SG_ID:-}"

# S3/GCS staging
S3_BUCKET="${S3_BUCKET:-auxdb-qa-mysql-dump-$(date +%Y%m%d)}"
S3_KEY="${S3_KEY:-auxdb_full_$(date +%Y%m%d_%H%M%S).sql.gz}"
GCS_BUCKET="${GCS_BUCKET:-gs://auxdb-qa-mysql-dump-$(date +%Y%m%d)}"
GCS_OBJECT="${GCS_OBJECT:-${S3_KEY}}"

# Local state/logging
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="${SCRIPT_DIR}/migration_run_$(date +%Y%m%d_%H%M%S)"
STATE_FILE="${RUN_DIR}/resource_state.log"
LOG_FILE="${RUN_DIR}/migration.log"
IMPORT_WATCH_SCRIPT="${RUN_DIR}/watch_import.sh"
TRANSFER_SCRIPT="${RUN_DIR}/transfer_s3_to_gcs.sh"

mkdir -p "${RUN_DIR}"

touch "${STATE_FILE}" "${LOG_FILE}"

#######################################
# Helpers
#######################################
# Helper functions are intentionally small and composable.
# They provide:
# - uniform logging
# - state persistence between stages
# - command execution wrappers for aws/gcloud
# - safety checks (required secrets and values)

log() {
  local msg="$1"
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${msg}" | tee -a "${LOG_FILE}"
}

record_state() {
  local key="$1"
  local value="$2"
  printf '%s=%s\n' "${key}" "${value}" | tee -a "${STATE_FILE}" >/dev/null
}

require_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || {
    log "ERROR: Missing required command: ${cmd}"
    exit 1
  }
}

require_nonempty() {
  local name="$1"
  local value="$2"
  if [[ -z "${value}" ]]; then
    log "ERROR: Required variable ${name} is empty"
    exit 1
  fi
}

require_secret() {
  # Source DB password can come from either:
  # - RDS_PASSWORD (plaintext env var)
  # - RDS_PASSWORD_PARAM (SSM Parameter name/path)
  # At least one is required before any source access.
  if [[ -z "${RDS_PASSWORD}" && -z "${RDS_PASSWORD_PARAM}" ]]; then
    log "ERROR: Set either RDS_PASSWORD or RDS_PASSWORD_PARAM"
    exit 1
  fi
}

resolve_rds_password() {
  # Resolve source DB password at runtime.
  # Plaintext env var takes precedence for simplicity, otherwise read from SSM.
  if [[ -n "${RDS_PASSWORD}" ]]; then
    printf '%s' "${RDS_PASSWORD}"
    return 0
  fi

  aws_cmd ssm get-parameter \
    --name "${RDS_PASSWORD_PARAM}" \
    --with-decryption \
    --query 'Parameter.Value' \
    --output text
}

rds_field_by_endpoint() {
  # Convenience wrapper to query one RDS field by matching endpoint.
  # This lets us enforce same-VPC/same-AZ placement for the dump host.
  local jmes="$1"
  aws_cmd rds describe-db-instances \
    --query "DBInstances[?Endpoint.Address=='${RDS_ENDPOINT}'].${jmes} | [0]" \
    --output text
}

wait_for_s3_object_stable() {
  # Wait until object size is unchanged for N checks.
  # This reduces the chance of streaming a still-growing dump to GCS.
  local bucket="$1"
  local key="$2"
  local checks="${3:-3}"
  local interval="${4:-60}"

  local prev=""
  local cur=""
  local stable_count=0

  log "Waiting for s3://${bucket}/${key} size to stabilize"
  while true; do
    cur=$(aws_cmd s3api head-object --bucket "${bucket}" --key "${key}" --query 'ContentLength' --output text 2>/dev/null || echo "MISSING")
    if [[ "${cur}" == "MISSING" ]]; then
      stable_count=0
      prev=""
    elif [[ -n "${prev}" && "${cur}" == "${prev}" ]]; then
      stable_count=$((stable_count + 1))
      if (( stable_count >= checks )); then
        log "S3 object size stable at ${cur} bytes"
        return 0
      fi
    else
      stable_count=0
      prev="${cur}"
    fi
    sleep "${interval}"
  done
}

aws_cmd() {
  aws --profile "${AWS_PROFILE}" --region "${AWS_REGION}" "$@"
}

gcloud_cmd() {
  gcloud --project "${GCP_PROJECT_ID}" "$@"
}

confirm_or_exit() {
  local prompt="$1"
  local answer
  read -r -p "${prompt} [y/N]: " answer
  if [[ "${answer}" != "y" && "${answer}" != "Y" ]]; then
    log "User did not confirm. Exiting stage."
    exit 0
  fi
}

#######################################
# Stage 1: Preflight
#######################################
preflight() {
  # Stage purpose:
  # - verify local tooling and auth context
  # - verify mandatory credentials/inputs
  # - collect basic quota/policy diagnostics into run logs
  #
  # Side effects:
  # - read-only checks only
  # - no cloud resources are created or modified here
  log "Running preflight checks"
  require_cmd aws
  require_cmd gcloud
  require_cmd jq
  require_cmd mysql

  require_secret
  require_nonempty "CLOUDSQL_ROOT_PASSWORD" "${CLOUDSQL_ROOT_PASSWORD}"

  log "Checking AWS caller identity"
  aws_cmd sts get-caller-identity | tee -a "${LOG_FILE}" >/dev/null

  log "Checking gcloud auth account"
  gcloud auth list --filter=status:ACTIVE --format='value(account)' | tee -a "${LOG_FILE}" >/dev/null

  log "Checking source RDS instance metadata"
  aws_cmd rds describe-db-instances \
    --query "DBInstances[?Endpoint.Address=='${RDS_ENDPOINT}'].[DBInstanceIdentifier,Engine,EngineVersion,AvailabilityZone,VpcSecurityGroups[*].VpcSecurityGroupId]" \
    --output table | tee -a "${LOG_FILE}" >/dev/null

  log "Checking Cloud SQL org policy constraints/sql.restrictPublicIp"
  gcloud resource-manager org-policies describe constraints/sql.restrictPublicIp \
    --project "${GCP_PROJECT_ID}" --format=json | tee -a "${LOG_FILE}" >/dev/null || true

  log "Checking AWS EC2 quota snapshot"
  aws_cmd service-quotas list-service-quotas --service-code ec2 \
    --query 'Quotas[?contains(QuotaName, `On-Demand`) || contains(QuotaName, `Running`)][QuotaName,Value]' \
    --output table | tee -a "${LOG_FILE}" >/dev/null || true

  log "Checking GCP compute CPU quotas"
  gcloud compute project-info describe --project "${GCP_PROJECT_ID}" \
    --format='json(quotas)' | jq '.quotas[] | select(.metric|test("CPUS|IN_USE_ADDRESSES"))' \
    | tee -a "${LOG_FILE}" >/dev/null || true

  log "Preflight complete"
}

#######################################
# Stage 2: Inventory source DBs
#######################################
inventory_source() {
  # Stage purpose:
  # - inventory user databases and estimated size from source
  # - persist database list for dump command construction
  #
  # Side effects:
  # - writes source_db_sizes.tsv and SOURCE_DATABASE_LIST in state file
  log "Inventorying source user databases and estimated sizes"

  local source_pwd
  source_pwd="$(resolve_rds_password)"

  MYSQL_PWD="${source_pwd}" mysql \
    -h "${RDS_ENDPOINT}" -P "${RDS_PORT}" -u "${RDS_USER}" -N -e "
      SELECT
        table_schema AS database_name,
        ROUND(SUM(data_length + index_length)/1024/1024,2) AS size_mb
      FROM information_schema.tables
      WHERE table_schema NOT IN ('mysql','sys','information_schema','performance_schema','innodb','tmp')
      GROUP BY table_schema
      ORDER BY size_mb DESC;
    " | tee "${RUN_DIR}/source_db_sizes.tsv"

  local db_list
  db_list=$(awk '{print $1}' "${RUN_DIR}/source_db_sizes.tsv" | paste -sd' ' -)
  record_state "SOURCE_DATABASE_LIST" "${db_list}"
  log "Source DB list recorded"
}

#######################################
# Stage 3: Create Cloud SQL target
#######################################
create_target() {
  # Stage purpose:
  # - create Cloud SQL target instance with PSC-only networking
  # - set edition/tier/storage and root password
  #
  # Side effects:
  # - creates Cloud SQL instance in target project
  # - stores connection name in state file
  log "Creating Cloud SQL instance with private PSC configuration"

  gcloud_cmd sql instances create "${CLOUDSQL_INSTANCE}" \
    --database-version="${CLOUDSQL_DB_VERSION}" \
    --region="${GCP_REGION}" \
    --tier="${CLOUDSQL_TIER}" \
    --edition=ENTERPRISE \
    --availability-type=ZONAL \
    --storage-type=SSD \
    --storage-size="${CLOUDSQL_DISK_SIZE_GB}" \
    --storage-auto-increase \
    --root-password="${CLOUDSQL_ROOT_PASSWORD}" \
    --no-assign-ip \
    --enable-private-service-connect \
    --allowed-psc-projects="${ALLOWED_PSC_PROJECTS}" \
    --backup-start-time=03:00

  local conn_name
  conn_name=$(gcloud_cmd sql instances describe "${CLOUDSQL_INSTANCE}" --format='value(connectionName)')
  record_state "CLOUDSQL_CONNECTION_NAME" "${conn_name}"
  log "Cloud SQL created: ${conn_name}"
}

#######################################
# Stage 4: Buckets + IAM grants
#######################################
stage_buckets() {
  # Stage purpose:
  # - create/prepare S3 and GCS staging buckets
  # - enforce bucket hardening and encryption settings
  # - grant Cloud SQL service account read access to dump object location
  #
  # Side effects:
  # - creates buckets if absent
  # - modifies bucket IAM and/or project IAM (fallback)
  log "Creating S3 bucket with SSE-S3 + public block"

  if ! aws_cmd s3api head-bucket --bucket "${S3_BUCKET}" >/dev/null 2>&1; then
    if [[ "${AWS_REGION}" == "us-east-1" ]]; then
      aws_cmd s3api create-bucket --bucket "${S3_BUCKET}"
    else
      aws_cmd s3api create-bucket \
        --bucket "${S3_BUCKET}" \
        --create-bucket-configuration LocationConstraint="${AWS_REGION}"
    fi
  fi

  aws_cmd s3api put-public-access-block --bucket "${S3_BUCKET}" \
    --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

  aws_cmd s3api put-bucket-encryption --bucket "${S3_BUCKET}" \
    --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

  record_state "S3_BUCKET" "${S3_BUCKET}"

  log "Creating GCS bucket with UBLA in ${GCP_REGION}"
  if ! gcloud storage buckets describe "${GCS_BUCKET}" >/dev/null 2>&1; then
    gcloud storage buckets create "${GCS_BUCKET}" --project="${GCP_PROJECT_ID}" --location="${GCP_REGION}" --uniform-bucket-level-access
  fi

  record_state "GCS_BUCKET" "${GCS_BUCKET}"

  log "Granting Cloud SQL service account objectViewer on GCS bucket"
  local project_number cloudsql_sa
  project_number=$(gcloud projects describe "${GCP_PROJECT_ID}" --format='value(projectNumber)')
  cloudsql_sa="service-${project_number}@gcp-sa-cloud-sql.iam.gserviceaccount.com"

  # Bucket-scope preferred
  if ! gcloud storage buckets add-iam-policy-binding "${GCS_BUCKET}" \
    --member="serviceAccount:${cloudsql_sa}" \
    --role='roles/storage.objectViewer' >/dev/null 2>&1; then

    log "Bucket IAM failed; applying fallback project-level role"
    gcloud projects add-iam-policy-binding "${GCP_PROJECT_ID}" \
      --member="serviceAccount:${cloudsql_sa}" \
      --role='roles/storage.objectViewer' >/dev/null
  fi

  record_state "CLOUDSQL_SERVICE_ACCOUNT" "${cloudsql_sa}"
}

#######################################
# Stage 5: Launch throwaway dump EC2
#######################################
launch_dump_host() {
  # Stage purpose:
  # - create short-lived IAM role/profile and dump EC2 host
  # - enforce network placement in same VPC/AZ as source RDS
  # - ensure source client SG is attached and ingress rule is present
  #
  # Side effects:
  # - creates IAM role, inline policy, and instance profile
  # - launches EC2 instance and optional SG
  # - may authorize ingress on SOURCE_CLIENT_SG_ID
  log "Preparing IAM role/profile for dump EC2"

  local role_name profile_name policy_name trust_json policy_json aws_account_id
  local secret_access_statements param_path parameter_arn
  role_name="auxdb-dump-ec2-role-$(date +%Y%m%d%H%M%S)"
  profile_name="auxdb-dump-ec2-profile-$(date +%Y%m%d%H%M%S)"
  policy_name="auxdb-dump-s3-write-policy"

  trust_json="${RUN_DIR}/ec2-trust.json"
  policy_json="${RUN_DIR}/ec2-s3-inline-policy.json"

  aws_account_id=$(aws_cmd sts get-caller-identity --query 'Account' --output text)
  record_state "AWS_ACCOUNT_ID" "${aws_account_id}"

  secret_access_statements=""
  if [[ -n "${RDS_PASSWORD_PARAM}" ]]; then
    # Least-privilege secret access is only added when SSM parameter usage
    # is enabled. This avoids broad secret permissions by default.
    param_path="${RDS_PASSWORD_PARAM#/}"
    parameter_arn="arn:aws:ssm:${AWS_REGION}:${aws_account_id}:parameter/${param_path}"

    secret_access_statements=$(cat <<JSON
,    {
      "Effect": "Allow",
      "Action": [
        "ssm:GetParameter"
      ],
      "Resource": "${parameter_arn}"
    },
    {
      "Effect": "Allow",
      "Action": [
        "kms:Decrypt"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "kms:ViaService": "ssm.${AWS_REGION}.amazonaws.com",
          "kms:CallerAccount": "${aws_account_id}"
        }
      }
    }
JSON
)

    record_state "RDS_PASSWORD_PARAM" "${RDS_PASSWORD_PARAM}"
    record_state "RDS_PASSWORD_PARAM_ARN" "${parameter_arn}"
  fi

  cat > "${trust_json}" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON

  cat > "${policy_json}" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:AbortMultipartUpload",
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": [
        "arn:aws:s3:::${S3_BUCKET}",
        "arn:aws:s3:::${S3_BUCKET}/*"
        ]
    }
${secret_access_statements}
  ]
}
JSON

  aws_cmd iam create-role --role-name "${role_name}" --assume-role-policy-document "file://${trust_json}" >/dev/null
  aws_cmd iam attach-role-policy --role-name "${role_name}" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore >/dev/null
  aws_cmd iam put-role-policy --role-name "${role_name}" --policy-name "${policy_name}" --policy-document "file://${policy_json}" >/dev/null

  aws_cmd iam create-instance-profile --instance-profile-name "${profile_name}" >/dev/null
  aws_cmd iam add-role-to-instance-profile --instance-profile-name "${profile_name}" --role-name "${role_name}" >/dev/null

  record_state "DUMP_EC2_ROLE" "${role_name}"
  record_state "DUMP_EC2_PROFILE" "${profile_name}"
  record_state "DUMP_EC2_ROLE_POLICY" "${policy_name}"

  local rds_vpc_id rds_az rds_attached_sg subnet_vpc subnet_az
  rds_vpc_id=$(rds_field_by_endpoint "DBSubnetGroup.VpcId")
  rds_az=$(rds_field_by_endpoint "AvailabilityZone")
  rds_attached_sg=$(aws_cmd rds describe-db-instances --query "DBInstances[?Endpoint.Address=='${RDS_ENDPOINT}'].VpcSecurityGroups[].VpcSecurityGroupId" --output text)

  if [[ -z "${rds_vpc_id}" || "${rds_vpc_id}" == "None" || -z "${rds_az}" || "${rds_az}" == "None" ]]; then
    log "ERROR: Could not resolve source RDS VPC/AZ from endpoint ${RDS_ENDPOINT}"
    exit 1
  fi

  record_state "SOURCE_RDS_VPC_ID" "${rds_vpc_id}"
  record_state "SOURCE_RDS_AZ" "${rds_az}"

  if [[ " ${rds_attached_sg} " != *" ${SOURCE_CLIENT_SG_ID} "* ]]; then
    log "ERROR: SOURCE_CLIENT_SG_ID=${SOURCE_CLIENT_SG_ID} is not attached to source RDS. Update SOURCE_CLIENT_SG_ID first."
    exit 1
  fi

  if [[ -n "${DUMP_VPC_ID}" && "${DUMP_VPC_ID}" != "${rds_vpc_id}" ]]; then
    log "ERROR: DUMP_VPC_ID (${DUMP_VPC_ID}) must match source RDS VPC (${rds_vpc_id})"
    exit 1
  fi
  DUMP_VPC_ID="${rds_vpc_id}"

  if [[ -z "${DUMP_SUBNET_ID}" ]]; then
    DUMP_SUBNET_ID=$(aws_cmd ec2 describe-subnets \
      --filters Name=vpc-id,Values="${DUMP_VPC_ID}" Name=availability-zone,Values="${rds_az}" Name=map-public-ip-on-launch,Values=true \
      --query 'Subnets[0].SubnetId' --output text)
  fi

  if [[ "${DUMP_SUBNET_ID}" == "None" || -z "${DUMP_SUBNET_ID}" ]]; then
    log "ERROR: Could not find a public subnet in source RDS VPC/AZ (${DUMP_VPC_ID}/${rds_az}). Set DUMP_SUBNET_ID explicitly."
    exit 1
  fi

  subnet_vpc=$(aws_cmd ec2 describe-subnets --subnet-ids "${DUMP_SUBNET_ID}" --query 'Subnets[0].VpcId' --output text)
  subnet_az=$(aws_cmd ec2 describe-subnets --subnet-ids "${DUMP_SUBNET_ID}" --query 'Subnets[0].AvailabilityZone' --output text)
  if [[ "${subnet_vpc}" != "${rds_vpc_id}" || "${subnet_az}" != "${rds_az}" ]]; then
    log "ERROR: DUMP_SUBNET_ID must be in source RDS VPC/AZ (${rds_vpc_id}/${rds_az}); got ${subnet_vpc}/${subnet_az}."
    exit 1
  fi

  if [[ -z "${DUMP_SG_ID}" ]]; then
    DUMP_SG_ID=$(aws_cmd ec2 create-security-group \
      --group-name "auxdb-dump-host-$(date +%Y%m%d%H%M%S)" \
      --description "Dump host for auxdb migration" \
      --vpc-id "${DUMP_VPC_ID}" \
      --query GroupId --output text)
  fi

  # RDS SG should allow 3306 from this SG if needed. This call is harmless if rule exists.
  aws_cmd ec2 authorize-security-group-ingress \
    --group-id "${SOURCE_CLIENT_SG_ID}" \
    --ip-permissions "[{\"IpProtocol\":\"tcp\",\"FromPort\":3306,\"ToPort\":3306,\"UserIdGroupPairs\":[{\"GroupId\":\"${DUMP_SG_ID}\"}]}]" >/dev/null 2>&1 || true

  log "Resolving latest Amazon Linux 2023 AMI"
  local al2023_ami instance_id
  al2023_ami=$(aws_cmd ssm get-parameter \
    --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
    --query 'Parameter.Value' --output text)

  instance_id=$(aws_cmd ec2 run-instances \
    --image-id "${al2023_ami}" \
    --instance-type t3.medium \
    --iam-instance-profile Name="${profile_name}" \
    --subnet-id "${DUMP_SUBNET_ID}" \
    --security-group-ids "${DUMP_SG_ID}" \
    --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":200,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=auxdb-migration-dump-host}]' \
    --query 'Instances[0].InstanceId' --output text)

  record_state "DUMP_EC2_INSTANCE_ID" "${instance_id}"
  record_state "DUMP_EC2_SG_ID" "${DUMP_SG_ID}"
  record_state "DUMP_EC2_SUBNET_ID" "${DUMP_SUBNET_ID}"
  record_state "DUMP_VPC_ID" "${DUMP_VPC_ID}"

  log "Waiting for EC2 ${instance_id} to be running and managed by SSM"
  aws_cmd ec2 wait instance-running --instance-ids "${instance_id}"

  # Wait until SSM recognizes instance
  for _ in $(seq 1 30); do
    if aws_cmd ssm describe-instance-information \
      --filters "Key=InstanceIds,Values=${instance_id}" \
      --query 'InstanceInformationList[0].InstanceId' --output text | grep -q "${instance_id}"; then
      break
    fi
    sleep 10
  done

  log "Dump host ready: ${instance_id}"
}

#######################################
# Stage 6: Start mysqldump on EC2 via SSM
#######################################
start_dump() {
  # Stage purpose:
  # - submit remote dump command via SSM Run Command
  # - install required tools on EC2 (mysql, pigz)
  # - run mysqldump pipeline -> sanitize SQL -> gzip -> S3 upload
  #
  # Security note:
  # - if RDS_PASSWORD_PARAM is set, password is resolved on-host from SSM
  # - otherwise plaintext RDS_PASSWORD is embedded in transient payload
  #
  # Side effects:
  # - starts background dump on EC2
  # - records SSM command id
  local instance_id
  instance_id=$(awk -F= '/^DUMP_EC2_INSTANCE_ID=/{print $2}' "${STATE_FILE}" | tail -1)
  if [[ -z "${instance_id}" ]]; then
    log "ERROR: No dump host in state file. Run launch-dump-host first."
    exit 1
  fi

  local db_list
  db_list=$(awk -F= '/^SOURCE_DATABASE_LIST=/{print $2}' "${STATE_FILE}" | tail -1)
  if [[ -z "${db_list}" ]]; then
    log "SOURCE_DATABASE_LIST missing; collecting inventory now."
    inventory_source
    db_list=$(awk -F= '/^SOURCE_DATABASE_LIST=/{print $2}' "${STATE_FILE}" | tail -1)
  fi

  log "Sending dump command via SSM using --cli-input-json"

  local ssm_payload ssm_cmd_id
  ssm_payload="${RUN_DIR}/ssm-start-dump.json"

  local mysql_pwd_cmd
  if [[ -n "${RDS_PASSWORD_PARAM}" ]]; then
    mysql_pwd_cmd="export MYSQL_PWD=\$(aws ssm get-parameter --name '${RDS_PASSWORD_PARAM}' --with-decryption --query Parameter.Value --output text)"
  else
    log "WARNING: Using RDS_PASSWORD plaintext in transient SSM payload. Prefer RDS_PASSWORD_PARAM for safer secret handling."
    mysql_pwd_cmd="export MYSQL_PWD='${RDS_PASSWORD}'"
  fi

  cat > "${ssm_payload}" <<JSON
{
  "DocumentName": "AWS-RunShellScript",
  "Comment": "Start non-blocking mysqldump to S3",
  "InstanceIds": ["${instance_id}"],
  "Parameters": {
    "commands": [
      "set -euo pipefail",
      "sudo dnf install -y mysql pigz >/tmp/dump_pkg_install.log 2>&1",
      "cat > /tmp/run_dump.sh <<'EOS'",
      "#!/usr/bin/env bash",
        "set -euo pipefail",
        "${mysql_pwd_cmd}",
      "nohup bash -c \"mysqldump -h ${RDS_ENDPOINT} -P ${RDS_PORT} -u ${RDS_USER} --single-transaction --routines --triggers --events --databases ${db_list} | sed -E 's/DEFINER=[^*]*\*/\*/g; /SET @@GLOBAL.GTID_PURGED/d; /SET @@SESSION.SQL_LOG_BIN/d' | pigz -1 | aws s3 cp - s3://${S3_BUCKET}/${S3_KEY}\" > /var/log/auxdb_dump.log 2>&1 & disown",
      "echo STARTED > /tmp/dump_started.flag",
      "EOS",
      "chmod +x /tmp/run_dump.sh",
      "/tmp/run_dump.sh",
      "aws s3 ls s3://${S3_BUCKET}/ --human-readable --summarize || true"
    ]
  }
}
JSON

  chmod 600 "${ssm_payload}"

  ssm_cmd_id=$(aws_cmd ssm send-command --cli-input-json "file://${ssm_payload}" --query 'Command.CommandId' --output text)
  rm -f "${ssm_payload}"
  record_state "DUMP_SSM_COMMAND_ID" "${ssm_cmd_id}"

  log "Dump command submitted. CommandId=${ssm_cmd_id}"
  log "Monitor from EC2 logs with SSM or monitor S3 object growth: s3://${S3_BUCKET}/${S3_KEY}"
}

#######################################
# Stage 7: Transfer S3 -> GCS (stream)
#######################################
transfer_to_gcs() {
  # Stage purpose:
  # - stream completed dump from S3 to GCS (Cloud SQL import source)
  # - run as background helper script so it survives shell churn
  #
  # Side effects:
  # - writes transfer helper and transfer log
  # - records final GCS object URI for import stage
  log "Writing transfer helper script and launching with nohup"

  wait_for_s3_object_stable "${S3_BUCKET}" "${S3_KEY}" 3 60

  cat > "${TRANSFER_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
LOG_FILE="${RUN_DIR}/transfer_s3_to_gcs.log"
{
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting S3 -> GCS streaming transfer"
  aws --profile "${AWS_PROFILE}" --region "${AWS_REGION}" s3 cp "s3://${S3_BUCKET}/${S3_KEY}" - \
    | gcloud storage cp - "${GCS_BUCKET}/${GCS_OBJECT}"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Transfer complete"
} >> "${RUN_DIR}/transfer_s3_to_gcs.log" 2>&1
EOF

  chmod +x "${TRANSFER_SCRIPT}"
  nohup "${TRANSFER_SCRIPT}" >/dev/null 2>&1 &
  disown

  record_state "GCS_DUMP_URI" "${GCS_BUCKET}/${GCS_OBJECT}"
  log "Transfer started in background. Log: ${RUN_DIR}/transfer_s3_to_gcs.log"
}

#######################################
# Stage 8: Patch required DB flag
#######################################
patch_flag() {
  # Stage purpose:
  # - set required Cloud SQL flag BEFORE import
  #
  # Why this matters:
  # - log_bin_trust_function_creators=on is required for dumps that include
  #   stored routines/triggers lacking deterministic metadata.
  #
  # Side effects:
  # - patches Cloud SQL instance config
  # - waits for operation completion
  log "Patching Cloud SQL flag log_bin_trust_function_creators=on"

  local op_id
  op_id=$(gcloud_cmd sql instances patch "${CLOUDSQL_INSTANCE}" \
    --database-flags=log_bin_trust_function_creators=on \
    --quiet --format='value(name)')

  record_state "PATCH_OPERATION_ID" "${op_id}"

  log "Waiting for patch operation ${op_id}"
  gcloud_cmd sql operations wait "${op_id}" --timeout=3600

  log "Flag patch completed"
}

#######################################
# Stage 9: Start import + background poller
#######################################
start_import() {
  # Stage purpose:
  # - start Cloud SQL SQL import asynchronously
  # - create background poller that logs status every 5 minutes
  #
  # Side effects:
  # - starts server-side import operation
  # - records import operation id
  # - writes/launches import watcher script
  local gcs_uri
  gcs_uri=$(awk -F= '/^GCS_DUMP_URI=/{print $2}' "${STATE_FILE}" | tail -1)
  if [[ -z "${gcs_uri}" ]]; then
    gcs_uri="${GCS_BUCKET}/${GCS_OBJECT}"
  fi

  log "Starting Cloud SQL import (async): ${gcs_uri}"

  local op_id
  op_id=$(gcloud_cmd sql import sql "${CLOUDSQL_INSTANCE}" "${gcs_uri}" --async --format='value(name)')
  record_state "IMPORT_OPERATION_ID" "${op_id}"

  cat > "${IMPORT_WATCH_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
OP_ID="${op_id}"
while true; do
  ts=\$(date '+%Y-%m-%d %H:%M:%S')
  status=\$(gcloud --project "${GCP_PROJECT_ID}" sql operations describe "\${OP_ID}" --format='value(status)' 2>/dev/null || echo "UNKNOWN")
  echo "\${ts} import_op=\${OP_ID} status=\${status}" >> "${RUN_DIR}/import_watch.log"
  if [[ "\${status}" == "DONE" ]]; then
    gcloud --project "${GCP_PROJECT_ID}" sql operations describe "\${OP_ID}" --format=json >> "${RUN_DIR}/import_watch.log" 2>&1 || true
    break
  fi
  sleep 300
done
EOF

  chmod +x "${IMPORT_WATCH_SCRIPT}"
  nohup "${IMPORT_WATCH_SCRIPT}" >/dev/null 2>&1 &
  disown

  log "Import started. Background poller running at 5-minute intervals."
  log "Watch logs: ${RUN_DIR}/import_watch.log"
}

#######################################
# Stage 10: Create post-import user
#######################################
create_master_user() {
  # Stage purpose:
  # - create post-import application user master@%
  # - skip creation if user already exists (idempotent behavior)
  #
  # Note:
  # - Cloud SQL restricts SUPER privilege, so a companion SQL file is
  #   generated documenting broadest allowed grant pattern.
  log "Creating post-import user master@%"

  local source_pwd
  source_pwd="$(resolve_rds_password)"

  if gcloud_cmd sql users list --instance="${CLOUDSQL_INSTANCE}" --format='csv[no-heading](name,host)' | grep -E '^master,%$' >/dev/null 2>&1; then
    log "User master@% already exists; skipping create."
    return 0
  fi

  gcloud_cmd sql users create master \
    --instance="${CLOUDSQL_INSTANCE}" \
    --password="${source_pwd}" \
    --host='%'

  cat > "${RUN_DIR}/post_import_privileges.sql" <<'SQL'
-- Cloud SQL does not permit SUPER privilege.
-- Grant broad legal privileges within Cloud SQL constraints.
GRANT ALL PRIVILEGES ON *.* TO 'master'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL

  log "Created user. Privilege SQL saved to ${RUN_DIR}/post_import_privileges.sql"
  log "Run it after connecting to target if needed."
}

#######################################
# Stage 11: Verify
#######################################
verify() {
  # Stage purpose:
  # - generate a verification checklist for operator-driven validation
  # - include source/target database count comparisons and sampling guidance
  #
  # Side effects:
  # - writes verify_notes.txt in run directory
  local conn_name
  conn_name=$(gcloud_cmd sql instances describe "${CLOUDSQL_INSTANCE}" --format='value(connectionName)')
  record_state "CLOUDSQL_CONNECTION_NAME" "${conn_name}"

  cat > "${RUN_DIR}/verify_notes.txt" <<EOF
Verification checklist:
1) Start Cloud SQL Proxy with PSC:
   cloud-sql-proxy --psc ${conn_name}

2) Compare DB counts:
   Source:
   MYSQL_PWD='***' mysql -h ${RDS_ENDPOINT} -P ${RDS_PORT} -u ${RDS_USER} -N -e \
   "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','sys','information_schema','performance_schema','innodb','tmp');"

   Target (through proxy localhost:3306):
   MYSQL_PWD='***' mysql -h 127.0.0.1 -P 3306 -u root -N -e \
   "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','sys','information_schema','performance_schema','innodb','tmp');"

3) Compare table counts and sample row counts for largest tables.
EOF

  log "Verification checklist written to ${RUN_DIR}/verify_notes.txt"
}

#######################################
# Optional cleanup (requires confirmation)
#######################################
cleanup_prompt_only() {
  # Stage purpose:
  # - explicitly clean temporary migration resources after verification
  #
  # Destructive actions possible here:
  # - terminate dump EC2
  # - delete IAM role/profile artifacts
  # - delete dump objects from S3 and GCS
  #
  # Guardrails:
  # - two explicit confirmations are required before destructive actions
  log "Cleanup is destructive and intentionally requires explicit confirmation."
  log "This can terminate EC2, detach/delete IAM role+instance profile, and delete S3/GCS dump objects."
  confirm_or_exit "Proceed with cleanup now?"

  local instance_id role_name profile_name
  instance_id=$(awk -F= '/^DUMP_EC2_INSTANCE_ID=/{print $2}' "${STATE_FILE}" | tail -1)
  role_name=$(awk -F= '/^DUMP_EC2_ROLE=/{print $2}' "${STATE_FILE}" | tail -1)
  profile_name=$(awk -F= '/^DUMP_EC2_PROFILE=/{print $2}' "${STATE_FILE}" | tail -1)

  if [[ -n "${instance_id}" ]]; then
    aws_cmd ec2 terminate-instances --instance-ids "${instance_id}" >/dev/null || true
    log "Terminate requested for ${instance_id}"
  fi

  if [[ -n "${profile_name}" && -n "${role_name}" ]]; then
    aws_cmd iam remove-role-from-instance-profile --instance-profile-name "${profile_name}" --role-name "${role_name}" >/dev/null 2>&1 || true
    aws_cmd iam delete-instance-profile --instance-profile-name "${profile_name}" >/dev/null 2>&1 || true
    aws_cmd iam delete-role-policy --role-name "${role_name}" --policy-name auxdb-dump-s3-write-policy >/dev/null 2>&1 || true
    aws_cmd iam detach-role-policy --role-name "${role_name}" --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore >/dev/null 2>&1 || true
    aws_cmd iam delete-role --role-name "${role_name}" >/dev/null 2>&1 || true
    log "IAM role/profile cleanup attempted"
  fi

  confirm_or_exit "Delete dump objects from S3 and GCS?"
  aws_cmd s3 rm "s3://${S3_BUCKET}/${S3_KEY}" >/dev/null 2>&1 || true
  gcloud storage rm "${GCS_BUCKET}/${GCS_OBJECT}" >/dev/null 2>&1 || true
  log "Dump object cleanup attempted"
}

run_all() {
  # Convenience path that executes all build/migration stages except cleanup.
  # Import remains async; operator should monitor completion before verify/user.
  preflight
  inventory_source
  create_target
  stage_buckets
  launch_dump_host
  start_dump
  transfer_to_gcs
  patch_flag
  start_import
  log "run-all complete. Import runs asynchronously; monitor before create-master-user/verify."
}

usage() {
  # Keep stage names stable because operators/scripts may call them directly.
  cat <<'EOF'
Usage:
  aws_rds_mysql_to_cloudsql_psc_migration.sh <stage>

Stages:
  preflight
  inventory-source
  create-target
  stage-buckets
  launch-dump-host
  start-dump
  transfer-to-gcs
  patch-flag
  start-import
  create-master-user
  verify
  cleanup
  run-all
EOF
}

main() {
  local stage="${1:-}"
  case "${stage}" in
    preflight) preflight ;;
    inventory-source) inventory_source ;;
    create-target) create_target ;;
    stage-buckets) stage_buckets ;;
    launch-dump-host) launch_dump_host ;;
    start-dump) start_dump ;;
    transfer-to-gcs) transfer_to_gcs ;;
    patch-flag) patch_flag ;;
    start-import) start_import ;;
    create-master-user) create_master_user ;;
    verify) verify ;;
    cleanup) cleanup_prompt_only ;;
    run-all) run_all ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
