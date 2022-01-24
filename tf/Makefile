TF_BIN=terraform

.PHONY: init plan

init:
	$(TF_BIN) init

plan: init
	$(TF_BIN) plan

apply: init
	$(TF_BIN) apply
