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
