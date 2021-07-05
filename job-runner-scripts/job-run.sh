#!/bin/bash
set -euf -o pipefail

AWS_ACCOUNT_ID="000000000000"
JOB_BASE_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
JOB_BASE_REV="$(git rev-parse HEAD)"
JOB_IS_EXPERIMENT="${ACME_RUN_EXP:-0}"
JOB_RESULTS_BRANCH="${JOB_BASE_BRANCH}"
JOB_RUN_ARGS="${ACME_RUN_ARGS:-}"

echo "Pulling from DVC remote..."
dvc pull --run-cache
dvc checkout

if [[ -n "${WANDB_SWEEP_ID:-}" ]]
then
    echo "Setting up for wandb sweep..."
    JOB_IS_EXPERIMENT="1"
    JOB_RESULTS_BRANCH="sweep/${WANDB_SWEEP_ID}/${WANDB_RUN_ID}"

    # Convert params to comma-separated
    params="$(IFS=,; echo "$*")"
    JOB_RUN_ARGS="--params ${params}"
fi

if [[ "${JOB_IS_EXPERIMENT}" != "0" ]]
then
    dvc config --global core.experiments true
    dvc config --global feature.parametrization true

    echo "Running experiment..."
    dvc exp run --pull ${JOB_RUN_ARGS}

    # TODO: Replace with `dvc exp list` once DVC 2.0 is released
    exp_ref_info="$(git show-ref | grep refs/exps | grep -v stash)"
    dvc exp apply "$(echo ${exp_ref_info} | awk '{print $1}')"

    # Delete the experiment ref
    # TODO: Replace with `dvc exp gc` once DVC 2.0 is released
    git update-ref -d "$(echo ${exp_ref_info} | awk '{print $NF}')"

    if [[ "${JOB_RESULTS_BRANCH}" == "${JOB_BASE_BRANCH}" ]]
    then
        JOB_RESULTS_BRANCH="experiment/${JOB_BASE_REV:0:7}-$(echo ${exp_ref_info} | awk -F '-' '{print $NF}')"
    fi
    git checkout -b "${JOB_RESULTS_BRANCH}"

    # Drop whitespace changes from params.yaml
    git diff -b --no-color params.yaml | git apply --cached --ignore-space-change
    git checkout -- params.yaml
else
    echo "Running repro..."
    dvc repro ${JOB_RUN_ARGS}
fi

echo "Pushing DVC assets..."
dvc push --run-cache

git add .
if ! git diff --quiet HEAD
then
    echo "Committing changes to ${JOB_RESULTS_BRANCH}..."

    commit_message="$( printf "Cloud run job\n\nBased on ${JOB_BASE_BRANCH} at commit ${JOB_BASE_REV}")"

    if [[ -n "${JOB_RUN_ARGS}" ]]
    then
        commit_message="$( printf "${commit_message}\nRan with arguments: ${JOB_RUN_ARGS}")"
    fi

    if [[ -n "${ECS_CONTAINER_METADATA_URI_V4:-}" ]]
    then
        log_stream_arn=$(curl --silent ${ECS_CONTAINER_METADATA_URI_V4} \
            | jq -r '.LogOptions | [
                "arn:aws:logs",
                ."awslogs-region",
                "'$AWS_ACCOUNT_ID':log-group",
                ."awslogs-group",
                "log-stream",
                ."awslogs-stream"
            ] | join(":")')
        commit_message="$( printf "${commit_message}\nLog stream ARN: ${log_stream_arn}")"
    fi
    git commit -m "${commit_message}"
fi

git push origin "${JOB_RESULTS_BRANCH}"

# Use local diff-report script if available, otherwise fall back to default
diff_report_script="diff-report.sh"
if [[ ! -x "${diff_report_script}" ]]
then
    diff_report_script="${ACME_RUNNER_SCRIPTS_DIR}/${diff_report_script}"
fi

if [[ -x "${diff_report_script}" ]] && [[ -n "${BITBUCKET_AUTH:-}" ]]
then
    echo "Generating diff report..."
    comment_file="$(mktemp)"
    comment_raw="$("${diff_report_script}" ${JOB_BASE_REV} ${JOB_RESULTS_BRANCH} --all | grep -v 'test.')"
    echo '{}' | jq -rc --arg raw "${comment_raw}" '{"content": {"raw": $raw}}' > "${comment_file}"

    echo "Posting diff report as comment..."
    repo_name="$(git remote get-url origin | grep -oP '(?<=\.(org|com)[:/]).*')"
    repo_api_url="https://api.bitbucket.org/2.0/repositories/${repo_name}"
    curl \
        --data-binary "@${comment_file}" \
        --fail \
        --header 'Content-Type: application/json' \
        --output /dev/null \
        --request POST \
        --silent \
        --user "${BITBUCKET_AUTH}" \
        --write-out '%{http_code}' \
        "${repo_api_url}/commit/$(git rev-parse HEAD)/comments"
fi

tracking_stage="experiment"
if [[ "${JOB_IS_EXPERIMENT}" -eq "1" ]] && dvc unfreeze "${tracking_stage}" 2> /dev/null
then
    echo "Tracking experiment results..."
    dvc repro "${tracking_stage}"
fi

echo "Resetting repo to original state..."
git checkout --force "${JOB_BASE_BRANCH}"
git reset --hard "${JOB_BASE_REV}"
dvc checkout

echo "Done!"
