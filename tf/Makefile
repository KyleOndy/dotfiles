TF_BIN=terraform
export AWS_ACCESS_KEY_ID = $(shell pass show aws.amazon.com/ondy-org/iam_users/admin | rg -e AWS_ACCESS_KEY_ID | cut -d'=' -f2)
export AWS_SECRET_ACCESS_KEY = $(shell pass show aws.amazon.com/ondy-org/iam_users/admin | rg -e AWS_SECRET_ACCESS_KEY | cut -d'=' -f2)

.PHONY: init plan

init:
	$(TF_BIN) init

plan: init
	$(TF_BIN) plan

apply: init
	$(TF_BIN) apply

.PHONY: env
env:
	printenv | rg AWS_ | sort

# Minted here rather than by an aws_iam_access_key resource, because
# terraform.tfstate is tracked in git and would carry the secret with it.
# IAM_USER rather than USER, which the shell already exports.
#   make access-key IAM_USER=svc.archive-push
.PHONY: access-key
access-key:
	aws iam create-access-key --user-name $(IAM_USER)
