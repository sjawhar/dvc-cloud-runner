import json
import os
import re

import boto3

batch = boto3.client("batch")
secretsmanager = boto3.client("secretsmanager")

ALLOWED_HOOK_UUIDS = None
PARAM_BRANCH_NAME = "branchName"
PARAM_REPOSITORY_NAME = "repositoryName"

KEYWORD_RUN_EXP = "ACME_RUN_EXP"
KEYWORD_RUN_JOB = "ACME_RUN"

KEYWORD_MEMORY = "ACME_MEMORY"
KEYWORD_VCPUS = "ACME_VCPUS"
KEYWORD_GPUS = "ACME_GPUS"

ENV_JOB_ARGS = "ACME_RUN_ARGS"


def load_allowed_hook_uuids():
    global ALLOWED_HOOK_UUIDS
    response = secretsmanager.get_secret_value(
        SecretId=os.environ["ALLOWED_WEBHOOK_UUIDS_SECRET_ID"]
    )
    ALLOWED_HOOK_UUIDS = json.loads(response["SecretString"])


def authenticate_request(event):
    hook_uuid = event["headers"].get("x-hook-uuid", None)
    if ALLOWED_HOOK_UUIDS is None:
        load_allowed_hook_uuids()

    return hook_uuid in ALLOWED_HOOK_UUIDS


def _capture_keyword(keyword, message, fallback=None):
    match = re.search(f"^:{keyword}:(.*?)$", message, re.MULTILINE)
    if not match:
        return None

    capture = match.group(1).strip()
    if fallback is None:
        return capture
    elif capture == "":
        return fallback
    return capture


def get_job_overrides(message):
    overrides = {}
    for override, keyword in [
        ("memory", KEYWORD_MEMORY),
        ("vcpus", KEYWORD_VCPUS),
    ]:
        capture = _capture_keyword(keyword, message)
        if not capture:
            continue
        overrides[override] = int(capture)

    gpus = _capture_keyword(KEYWORD_GPUS, message, fallback="1")
    if gpus:
        overrides["resourceRequirements"] = [{"type": "GPU", "value": gpus}]

    environment = {}
    job_args = _capture_keyword(KEYWORD_RUN_JOB, message)
    if job_args:
        environment[ENV_JOB_ARGS] = job_args
    if _capture_keyword(KEYWORD_RUN_EXP, message) is not None:
        environment[KEYWORD_RUN_EXP] = "1"
    if environment:
        overrides["environment"] = [
            {"name": k, "value": v} for k, v in environment.items()
        ]

    return overrides


def get_job_branches(body):
    branches = []
    for change in body["push"]["changes"]:
        change = change.get("new", None)
        if not change:
            continue
        branch = change.get("name", None)
        commit = change.get("target", {})
        commit_hash = commit.get("hash", None)
        commit_message = commit.get("message", "")
        if not branch or not commit_hash or not KEYWORD_RUN_JOB in commit_message:
            continue
        branches.append((branch, commit_hash, get_job_overrides(commit_message)))

    return branches


def submit_jobs(repository, branches):
    for branch, commit_hash, overrides in branches:
        job_params = {
            "jobDefinition": f'{os.environ["JOB_DEFINITION_NAME_PREFIX"]}-{repository}',
            "jobName": "-".join(
                [os.environ["JOB_NAME_PREFIX"], repository, commit_hash[:7]]
            ),
            "jobQueue": os.environ["JOB_QUEUE_ARN"],
            "parameters": {
                PARAM_BRANCH_NAME: branch,
                PARAM_REPOSITORY_NAME: repository,
            },
        }
        if overrides:
            job_params["containerOverrides"] = overrides

        batch.submit_job(**job_params)


def handler(event, _):
    try:
        if not authenticate_request(event):
            return {"statusCode": 401}

        body = json.loads(event["body"])
        branches = get_job_branches(body)
        submit_jobs(body["repository"]["name"], branches)
        return {"statusCode": 204}
    except Exception as e:
        print(e)
        return {
            "statusCode": 500,
            "body": json.dumps(
                {
                    "errorMessage": getattr(e, "message", str(e)),
                    "errorType": type(e).__name__,
                }
            ),
        }
