# Local workflow (GitHub Codespaces or any Ubuntu/Debian machine).
#   make emulator   # install + start AWS Emulator
#   make deploy     # terraform apply against the emulator
#   make lint       # JavaScript syntax + Ruff on the Python tests
#   make test       # unit + end-to-end tests
#   make destroy
SHELL := /bin/bash
ENV := set -a; source .emulator.env; set +a;
# Python tools (pytest, Ruff) live in a project venv, not in the system Python.
VENV := .venv
VENV_OK := $(VENV)/.requirements-installed

.PHONY: emulator deploy lint unit e2e test destroy clean

emulator:
	bash scripts/start-emulator.sh

deploy:
	$(ENV) terraform -chdir=infra init -input=false && terraform -chdir=infra apply -auto-approve

# Dependencies are reinstalled only when a requirements file changes.
$(VENV_OK): tests/requirements.txt tests/requirements-dev.txt
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install -q -r tests/requirements.txt -r tests/requirements-dev.txt
	touch $@

lint: $(VENV_OK)
	cd app && npm run lint
	$(VENV)/bin/ruff check tests
	$(VENV)/bin/ruff format --check tests

unit:
	cd app && npm ci && npm test

e2e: $(VENV_OK)
	$(ENV) $(VENV)/bin/pytest tests/integration -v

test: unit e2e

destroy:
	$(ENV) terraform -chdir=infra destroy -auto-approve

clean:
	pkill aws-emulator || true
	rm -rf infra/.terraform infra/terraform.tfstate* infra/build .emulator.env
