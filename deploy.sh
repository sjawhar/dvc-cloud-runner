#!/bin/bash
set -euf -o pipefail

ENVIRONMENT="${1:-}"

if [ -z "${ENVIRONMENT}" ]
then
  echo 'Usage: ./deploy.sh $ENVIRONMENT [--region $REGION]'
  exit 1
fi

S3_BUCKET="acme-${ENVIRONMENT}-ml"

aws s3 sync --delete job-runner-scripts "s3://${S3_BUCKET}/job-runner-scripts"

OUTPUT_TEMPLATE="cloudformation-generated.yml"

echo "Packaging..."
aws cloudformation package \
  --template-file "cloudformation.yml" \
  --output-template-file $OUTPUT_TEMPLATE \
  --s3-bucket $S3_BUCKET \
  --s3-prefix "cloudformation-artifacts"

echo "Deploying..."
aws cloudformation deploy \
  --template-file $OUTPUT_TEMPLATE \
  --stack-name "acme-${ENVIRONMENT}-ml" \
  --capabilities \
        CAPABILITY_AUTO_EXPAND \
        CAPABILITY_NAMED_IAM \
  --parameter-overrides "Environment=${ENVIRONMENT}" \
  "${@:2}"

rm -f $OUTPUT_TEMPLATE
