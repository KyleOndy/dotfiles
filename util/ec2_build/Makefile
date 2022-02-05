.PHONY: build
build:
	terraform init
	terraform apply -auto-approve
	./ssh_to_remote

.PHONY: destroy
destroy:
	terraform apply -destroy -auto-approve
