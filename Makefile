.PHONY: init up down test verify load reset-faults
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
	terraform -chdir=platform/terraform/bootstrap fmt -check
	terraform -chdir=platform/terraform/modules/ecr fmt -check
	terraform -chdir=platform/terraform/modules/iam fmt -check
	terraform -chdir=platform/terraform/modules/secrets fmt -check
	terraform -chdir=platform/terraform/environments/shared fmt -check
	terraform -chdir=platform/terraform/environments/staging fmt -check
	terraform -chdir=platform/terraform/environments/production fmt -check
tf-validate:
	terraform -chdir=platform/terraform/bootstrap validate
	terraform -chdir=platform/terraform/modules/ecr validate
	terraform -chdir=platform/terraform/modules/iam validate
	terraform -chdir=platform/terraform/modules/secrets validate
	terraform -chdir=platform/terraform/environments/shared validate
	terraform -chdir=platform/terraform/environments/staging validate
	terraform -chdir=platform/terraform/environments/production validate
