import json
import os

from botocore import stub
import pytest

from src.functions.bitbucket_webhook.index import handler, batch, secretsmanager

HOOK_SECRET_ID = os.environ["ALLOWED_WEBHOOK_UUIDS_SECRET_ID"]
JOB_DEFINITION_NAME_PREFIX = os.environ["JOB_DEFINITION_NAME_PREFIX"]
JOB_NAME_PREFIX = os.environ["JOB_NAME_PREFIX"]
JOB_QUEUE_ARN = os.environ["JOB_QUEUE_ARN"]

JOB_RUN_KEYWORD = ":ACME_RUN:"

AUTHORIZED_WEBHOOK = "super-secret"
REPOSITORY_NAME = "test-repo"


@pytest.fixture(name="get_event")
def fixture_get_event():
    def _get_event(
        changes=None, repository=REPOSITORY_NAME, webhook_uuid=AUTHORIZED_WEBHOOK
    ):
        return {
            "headers": {"x-hook-uuid": webhook_uuid},
            "body": json.dumps(
                {
                    "repository": {"name": repository},
                    "push": {"changes": changes},
                }
            ),
        }

    return _get_event


@pytest.fixture(name="stub_secrets", scope="module")
def fixture_stub_secrets():
    stub_secrets = stub.Stubber(secretsmanager)
    stub_secrets.add_response(
        "get_secret_value",
        {"SecretString": json.dumps([AUTHORIZED_WEBHOOK])},
        {"SecretId": HOOK_SECRET_ID},
    )
    stub_secrets.activate()

    yield stub_secrets

    stub_secrets.deactivate()


@pytest.fixture(name="check_submitted_jobs")
def fixture_check_submitted_jobs(get_event, stub_secrets):
    def _check_submitted_jobs(
        changes=None,
        container_overrides=None,
        expected_jobs=None,
        message=None,
    ):
        if message and not changes:
            changes = [
                {
                    "new": {
                        "name": "new-branch",
                        "target": {"hash": "1234567", "message": message},
                    }
                }
            ]

        if container_overrides and not expected_jobs:
            expected_jobs = [
                {
                    "jobName": f"{JOB_NAME_PREFIX}-{REPOSITORY_NAME}-1234567",
                    "jobQueue": JOB_QUEUE_ARN,
                    "jobDefinition": f"{JOB_DEFINITION_NAME_PREFIX}-{REPOSITORY_NAME}",
                    "parameters": {
                        "repositoryName": REPOSITORY_NAME,
                        "branchName": "new-branch",
                    },
                    "containerOverrides": container_overrides,
                }
            ]
        elif expected_jobs is None:
            expected_jobs = []

        stub_batch = stub.Stubber(batch)
        for job in expected_jobs:
            stub_batch.add_response(
                "submit_job", {"jobId": "foo", "jobName": "bar"}, job
            )

        with stub_batch, stub_secrets:
            response = handler(get_event(changes=changes), None)
            stub_batch.assert_no_pending_responses()

        return response

    return _check_submitted_jobs


def test_unknown_hook_uuid_returns_401(stub_secrets, get_event):
    response = handler(get_event(webhook_uuid="not-correct"), None)
    stub_secrets.assert_no_pending_responses()

    assert response["statusCode"] == 401


@pytest.mark.parametrize(
    "changes, expected_jobs",
    [
        [[], None],
        [[{"new": None}], None],
        [
            [
                {
                    "new": {
                        "name": "new-branch",
                        "target": {
                            "hash": "1234567",
                            "message": "Missing the code",
                        },
                    }
                }
            ],
            None,
        ],
        [
            [
                {
                    "new": {
                        "name": "new-branch",
                        "target": {
                            "hash": "123456789",
                            "message": f"Commit mesage\n{JOB_RUN_KEYWORD}",
                        },
                    }
                }
            ],
            [
                {
                    "jobName": f"{JOB_NAME_PREFIX}-{REPOSITORY_NAME}-1234567",
                    "jobQueue": JOB_QUEUE_ARN,
                    "jobDefinition": f"{JOB_DEFINITION_NAME_PREFIX}-{REPOSITORY_NAME}",
                    "parameters": {
                        "repositoryName": REPOSITORY_NAME,
                        "branchName": "new-branch",
                    },
                }
            ],
        ],
        [
            [
                {
                    "new": {
                        "name": "new-branch",
                        "target": {
                            "hash": "123456789",
                            "message": f"Commit mesage\n{JOB_RUN_KEYWORD}",
                        },
                    }
                },
                {
                    "new": {
                        "name": "new-branch",
                        "target": {
                            "hash": "abcdefghijk",
                            "message": f"No code",
                        },
                    }
                },
                {
                    "new": {
                        "name": "other-branch",
                        "target": {
                            "hash": "thisisatest",
                            "message": JOB_RUN_KEYWORD,
                        },
                    }
                },
            ],
            [
                {
                    "jobName": f"{JOB_NAME_PREFIX}-{REPOSITORY_NAME}-1234567",
                    "jobQueue": JOB_QUEUE_ARN,
                    "jobDefinition": f"{JOB_DEFINITION_NAME_PREFIX}-{REPOSITORY_NAME}",
                    "parameters": {
                        "repositoryName": REPOSITORY_NAME,
                        "branchName": "new-branch",
                    },
                },
                {
                    "jobName": f"{JOB_NAME_PREFIX}-{REPOSITORY_NAME}-thisisa",
                    "jobQueue": JOB_QUEUE_ARN,
                    "jobDefinition": f"{JOB_DEFINITION_NAME_PREFIX}-{REPOSITORY_NAME}",
                    "parameters": {
                        "repositoryName": REPOSITORY_NAME,
                        "branchName": "other-branch",
                    },
                },
            ],
        ],
    ],
)
def test_jobs_submission(check_submitted_jobs, changes, expected_jobs):
    response = check_submitted_jobs(changes=changes, expected_jobs=expected_jobs)
    assert response == {"statusCode": 204}


@pytest.mark.parametrize(
    "message, expected_env",
    [
        [":ACME_RUN:", None],
        [":ACME_RUN: train", {"ACME_RUN_ARGS": "train"}],
        [":ACME_RUN:train ", {"ACME_RUN_ARGS": "train"}],
        [" :ACME_RUN:train", None],
        [
            ':ACME_RUN: --params var1=2,var2={"foo":"bar"} train\n:ACME_RUN_EXP:',
            {
                "ACME_RUN_ARGS": '--params var1=2,var2={"foo":"bar"} train',
                "ACME_RUN_EXP": "1",
            },
        ],
        [":ACME_RUN:\n :ACME_RUN_EXP:", None],
    ],
)
def test_job_environment(check_submitted_jobs, message, expected_env):
    container_overrides = (
        None
        if not expected_env
        else {
            "environment": [{"name": k, "value": v} for k, v in expected_env.items()],
        }
    )
    check_submitted_jobs(message=message, container_overrides=container_overrides)


@pytest.mark.parametrize(
    "message, expected_overrides, expected_resources",
    [
        [":ACME_GPUS:", None, {"GPU": "1"}],
        [":ACME_GPUS: 0", None, {"GPU": "0"}],
        [":ACME_VCPUS:", None, None],
        [":ACME_VCPUS: 4", {"vcpus": 4}, None],
        [":ACME_MEMORY:", None, None],
        [":ACME_MEMORY: 4096", {"memory": 4096}, None],
        [":ACME_GPUS: 0\n:ACME_MEMORY: 8192", {"memory": 8192}, {"GPU": "0"}],
    ],
)
def test_job_resources(
    check_submitted_jobs, message, expected_overrides, expected_resources
):
    container_overrides = {} if expected_overrides is None else expected_overrides
    if expected_resources:
        container_overrides["resourceRequirements"] = [
            {"type": k, "value": v} for k, v in expected_resources.items()
        ]
    check_submitted_jobs(
        message=f":ACME_RUN:\n{message}", container_overrides=container_overrides
    )


@pytest.mark.usefixtures("stub_secrets")
def test_job_submission_failure_returns_500(get_event):
    with stub.Stubber(batch) as stub_batch:
        stub_batch.add_client_error("submit_job")
        response = handler(
            get_event(
                changes=[
                    {
                        "new": {
                            "name": "new-branch",
                            "target": {
                                "hash": "123456789",
                                "message": JOB_RUN_KEYWORD,
                            },
                        }
                    }
                ]
            ),
            None,
        )
        stub_batch.assert_no_pending_responses()

    assert response["statusCode"] == 500
    response_body = json.loads(response["body"])
    assert "SubmitJob" in response_body["errorMessage"]
    assert response_body["errorType"] == "ClientError"
