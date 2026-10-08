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
