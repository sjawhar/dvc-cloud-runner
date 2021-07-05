#!/bin/bash
set -euf -o pipefail

export ACME_RUNNER_SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
export PATH="${PATH:-}:${ACME_RUNNER_SCRIPTS_DIR}"

BITBUCKET_ORG_NAME="acme"
REPOSITORY_NAME="${1}"
BRANCH_NAME="${2}"

echo "Configuring git..."
git config --global url."https://${BITBUCKET_AUTH}@bitbucket.org/".insteadOf "git@bitbucket.org:"
git config --global user.email "machine.account@acme.com"
git config --global user.name "Machine Account"

echo "Cloning ${REPOSITORY_NAME}..."
clone_dir="$(mktemp -d)"
git clone \
    --single-branch --branch "${BRANCH_NAME}" \
    "git@bitbucket.org:${BITBUCKET_ORG_NAME}/${REPOSITORY_NAME}" \
    "${clone_dir}"

echo "Configuring shared DVC cache..."
cache_dir="/dvc-cache/${REPOSITORY_NAME}"
mkdir -p "${cache_dir}"
dvc cache dir --global "${cache_dir}"
dvc config --global cache.shared group
dvc config --global cache.type reflink,hardlink,symlink

pushd "${clone_dir}"

if [[ -n "${ACME_RUN_COMMAND:-}" ]]
then
    exec ${ACME_RUN_COMMAND}
fi

# Use local job-run.sh if available, otherwise fall back to default
job_run_script="job-run.sh"
if [[ ! -x "${job_run_script}" ]]
then
    job_run_script="${ACME_RUNNER_SCRIPTS_DIR}/${job_run_script}"
fi

exec "${job_run_script}"
