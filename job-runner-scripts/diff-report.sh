#!/bin/bash
set -euf -o pipefail

DIFF_BASE="${1}"
DIFF_HEAD="${2:-workspace}"
METRICS_PARAMS="${@:3}"

clean_diff_text()
{
  diff_text="${1}"
  [ -z "$(echo "${diff_text}" | tail -n+3)" ] && diff_text="No changes"
  echo "${diff_text}"
}

echo "# Change Report"
echo "Comparing changes from ${DIFF_BASE} to ${DIFF_HEAD}"

echo "## Performance Changes"
clean_diff_text "$(dvc metrics diff \
    --show-md \
    ${METRICS_PARAMS} \
    ${DIFF_BASE} ${DIFF_HEAD})"
echo ""

echo "## Parameter Changes"
clean_diff_text "$(dvc params diff --show-md --no-path ${DIFF_BASE} ${DIFF_HEAD})"
echo ""
