#!/bin/bash
set -euf -o pipefail

exitCode=0
for template in $(find . \
  -type f -name '*generated*' -prune \
  -o -type f -name 'cloudformation.*yml' \
  -exec grep -il AWSTemplateFormatVersion {} \;
)
do
    echo "Validating ${template}..."
    aws cloudformation validate-template --template-body "file://${template}" || exitCode=1
    echo ""
done

exit $exitCode
