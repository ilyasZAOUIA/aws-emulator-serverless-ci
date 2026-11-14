# Local workflow (GitHub Codespaces or any Ubuntu/Debian machine).
#   make emulator   # install + start AWS Emulator
#   make deploy     # terraform apply against the emulator
#   make test       # unit + end-to-end tests
#   make destroy
SHELL := /bin/bash
ENV := set -a; source .emulator.env; set +a;

.PHONY: emulator deploy unit e2e test destroy clean

emulator:
	bash scripts/start-emulator.sh

deploy:
	$(ENV) terraform -chdir=infra init -input=false && terraform -chdir=infra apply -auto-approve

unit:
	cd app && npm ci && npm test

e2e:
	pip install -q -r tests/requirements.txt
	$(ENV) pytest tests/integration -v

test: unit e2e

destroy:
	$(ENV) terraform -chdir=infra destroy -auto-approve

clean:
	pkill aws-emulator || true
	rm -rf infra/.terraform infra/terraform.tfstate* infra/build .emulator.env
