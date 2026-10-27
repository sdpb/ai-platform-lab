.PHONY: init up down test verify load reset-faults tf-fmt tf-validate tf-test
init:
	python3 scripts/lab.py init
up:
	python3 scripts/lab.py up
down:
	python3 scripts/lab.py down
test:
	python3 scripts/lab.py test
verify:
	python3 scripts/verify.py
load:
	python3 scripts/load.py --output evidence/baseline.json
reset-faults:
	python3 scripts/lab.py reset-faults
tf-fmt:
	terraform fmt -check -recursive platform/terraform missions
TF_DIRS := bootstrap modules/ecr modules/iam modules/secrets environments/shared environments/staging environments/production
tf-validate:
	@set -e; for d in $(TF_DIRS); do \
		terraform -chdir=platform/terraform/$$d init -backend=false -input=false >/dev/null; \
		terraform -chdir=platform/terraform/$$d validate; \
	done
TF_MODULES := ecr iam secrets
tf-test:
	@set -e; for m in $(TF_MODULES); do \
		terraform -chdir=platform/terraform/modules/$$m init -backend=false -input=false >/dev/null; \
		terraform -chdir=platform/terraform/modules/$$m test; \
	done
