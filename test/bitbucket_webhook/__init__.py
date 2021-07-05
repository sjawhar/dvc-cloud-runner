import os

os.environ["ALLOWED_WEBHOOK_UUIDS_SECRET_ID"] = "allowed-hooks"
os.environ["JOB_DEFINITION_NAME_PREFIX"] = "test-job-definition"
os.environ["JOB_NAME_PREFIX"] = "test-job-name"
os.environ["JOB_QUEUE_ARN"] = "test-job-queue"
