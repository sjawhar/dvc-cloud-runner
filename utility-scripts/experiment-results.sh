#!/bin/bash
set -euf -o pipefail

starting_branch="$(git rev-parse --abbrev-ref HEAD)"
experiment_base="experiment/$(git rev-parse HEAD | cut -c 1-7)-"

git fetch --prune
while read branch_name
do
    [[ -n "$(git branch --list ${branch_name})" ]] && git branch -D "${branch_name}"
    echo "Checking out ${branch_name}"
    git checkout ${branch_name}
done <<<$(git branch --list --remote "origin/${experiment_base}*" | sed 's|origin/||')

echo "Pulling all DVC cache..."
dvc pull --all-branches

local_branches="$(git branch --list \
        --format='%(refname:short)' \
        "${experiment_base}*" \
    | sed 's|experiment/||')"
pushd .dvc/experiments
git fetch --prune
while read branch_name
do
    echo "Copying ${branch_name} to experiments..."
    [[ -n "$(git branch --list ${branch_name})" ]] && git branch -D "${branch_name}"
    git checkout -b ${branch_name} origin/experiment/${branch_name}
    expriment_id="$(echo ${branch_name} | awk -F '-' '{print $(NF)}')"

    stash_hash="$(echo ${branch_name} | awk -F '-' '{print $(NF)}')"
    [[ -z "$(git stash list)" ]] && continue

    stash_position=$(git reflog show --format='%H %gD' stash \
        | grep "${stash_hash}" \
        | awk '{print $2}' \
        || echo '')
    [[ -z "${stash_position}" ]] && continue

    echo "Dropping stash commit ${stash_hash}..."
    git stash drop "${stash_position}"
done <<<"${local_branches}"
popd

echo "Cleaning up..."
git checkout "${starting_branch}"
dvc checkout
git branch --list --format='%(refname:short)' "${experiment_base}*" | xargs git branch -D

pushd .dvc/experiments
git fetch --prune
popd
