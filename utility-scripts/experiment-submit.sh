#!/bin/bash
set -euf -o pipefail

starting_branch="$(git rev-parse --abbrev-ref HEAD)"
short_hash="$(git rev-parse --short HEAD)"
branches=""
check=N
while read experiment_id
do
    git checkout "${short_hash}"
    rm -f .dvc/tmp/repro.dat
    dvc experiments checkout "${experiment_id}"
    git add .

    git diff --quiet HEAD && continue

    branch_name="experiment/${short_hash}-${experiment_id}"
    git checkout -b "${branch_name}"
    git commit -m "Experiment ${experiment_id}

    :ACME_RUN:"

    if [[ "${check}" == "y" ]]
    then
        branches="${branches} ${branch_name}"
        continue
    fi

    echo "Pushing first branch..."
    git push --set-upstream origin "${branch_name}"
    read -p "Submit remaining jobs? (y/N) " check </dev/tty
    [[ "${check}" == "y" ]] || break
done <<<$(dvc exp show --show-json \
    | jq -rc 'to_entries
        | map(select(.key | test("workspace") | not))[0].value
        | with_entries(select(.value.queued)) | keys | .[]')

git push --set-upstream origin $branches
git checkout "${starting_branch}"
