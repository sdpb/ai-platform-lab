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

# Local kind cluster (Week 3). ENV=staging|production picks the overlay/namespace.
ENV ?= staging
K8S_NS := orderlab-$(ENV)
# Never act on whatever kubectl context happens to be current.
KUBECTL := kubectl --context kind-orderlab
API_RESTARTS = $(KUBECTL) -n $(K8S_NS) get pods -l app.kubernetes.io/name=api -o custom-columns=POD:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount
# Pass criterion of the slow-start and dependency tests: no api container restarted.
NO_RESTARTS = test "$$($(KUBECTL) -n $(K8S_NS) get pods -l app.kubernetes.io/name=api -o jsonpath='{.items[*].status.containerStatuses[0].restartCount}' | tr ' ' '\n' | awk '{s+=$$1} END {print s+0}')" = 0
API_RESTART = if $(KUBECTL) -n $(K8S_NS) get rollout api >/dev/null 2>&1; then kubectl argo rollouts --context kind-orderlab -n $(K8S_NS) restart api; else $(KUBECTL) -n $(K8S_NS) rollout restart deployment/api; fi
API_WAIT = if $(KUBECTL) -n $(K8S_NS) get rollout api >/dev/null 2>&1; then kubectl argo rollouts --context kind-orderlab -n $(K8S_NS) status api --timeout=300s; else $(KUBECTL) -n $(K8S_NS) rollout status deployment/api --timeout=300s; fi
.PHONY: k8s-cluster k8s-image k8s-deploy k8s-smoke k8s-down
k8s-cluster:
	kind get clusters | grep -qx orderlab || kind create cluster --config platform/k8s/kind.yaml
	$(KUBECTL) apply --server-side -k platform/k8s/cluster
	$(KUBECTL) -n kube-system rollout status deployment/metrics-server --timeout=120s
	@if $(KUBECTL) -n argo-rollouts get deployment/argo-rollouts >/dev/null 2>&1; then $(KUBECTL) -n argo-rollouts rollout status deployment/argo-rollouts --timeout=180s; fi
	@if $(KUBECTL) -n monitoring get deployment/prometheus >/dev/null 2>&1; then $(KUBECTL) -n monitoring rollout status deployment/prometheus --timeout=120s; fi
k8s-image: k8s-cluster
	docker build -t orderlab:local .
	kind load docker-image orderlab:local --name orderlab
k8s-deploy: k8s-image
	scripts/kind-deploy.sh $(ENV)
k8s-smoke:
	@$(KUBECTL) -n $(K8S_NS) port-forward svc/api 18000:8000 >/dev/null & pf=$$!; trap "kill $$pf" EXIT; sleep 2; \
	curl -fsS localhost:18000/health/ready && echo && \
	curl -fsS localhost:18000/orders -H 'Content-Type: application/json' -H "Idempotency-Key: smoke-$$(date +%s)" \
		-d '{"customer_id":"smoke","sku":"widget","quantity":1,"unit_price_cents":100}' && echo
k8s-down:
	kind delete cluster --name orderlab

# Week 3 runtime checks. Load runs in-cluster (k6 pod -> Service), not through a port-forward.
# The shutdown test restarts every api pod (each one is terminated) while k6 sends 20 orders/s.
K6_IMAGE := grafana/k6:2.3.0
.PHONY: k8s-shutdown-test k8s-slow-start-test k8s-dependency-test
k8s-shutdown-test:
	@$(KUBECTL) -n $(K8S_NS) delete pod k6 --ignore-not-found >/dev/null
	@$(KUBECTL) -n $(K8S_NS) run k6 -i --restart=Never --image=$(K6_IMAGE) --env=BASE_URL=http://api:8000 --env=DURATION=180s \
		-- run --quiet - < platform/k8s/tests/orders-load.js & k6=$$!; \
	for i in $$(seq 120); do $(KUBECTL) -n $(K8S_NS) get pod k6 2>/dev/null | grep -q Running && break; sleep 1; done; \
	$(KUBECTL) -n $(K8S_NS) get pod k6 2>/dev/null | grep -q Running || { kill $$k6 2>/dev/null; echo 'k6 did not start'; exit 1; }; sleep 10; \
	echo ">>> replacing every api pod under load"; $(API_RESTART); \
	wait $$k6; status=$$?; $(KUBECTL) -n $(K8S_NS) delete pod k6 --ignore-not-found >/dev/null; \
	$(API_WAIT) || status=1; \
	$(API_RESTARTS) || status=1; \
	$(NO_RESTARTS) || { echo 'FAIL: an api container restarted during the shutdown test'; status=1; }; \
	exit $$status
# Simulates a 60 s slow startup on a rolling update, then reports restarts.
k8s-slow-start-test:
	@if $(KUBECTL) -n $(K8S_NS) get rollout api >/dev/null 2>&1; then \
		platform/k8s/tests/slow-start.sh $(K8S_NS); \
	else \
		$(KUBECTL) -n $(K8S_NS) set env deployment/api STARTUP_DELAY_SECONDS=60; \
		$(KUBECTL) -n $(K8S_NS) rollout status deployment/api --timeout=300s || true; \
		$(API_RESTARTS); $(NO_RESTARTS) || { $(KUBECTL) -n $(K8S_NS) set env deployment/api STARTUP_DELAY_SECONDS-; echo 'FAIL: api restarted during slow start'; exit 1; }; \
		$(KUBECTL) -n $(K8S_NS) set env deployment/api STARTUP_DELAY_SECONDS-; \
		$(KUBECTL) -n $(K8S_NS) rollout status deployment/api --timeout=300s; \
	fi
# Payments down for 60 s: api pods must stay Ready (readiness checks only the DB) and never restart.
k8s-dependency-test:
	$(KUBECTL) -n $(K8S_NS) scale deployment/payments --replicas=0
	sleep 60
	$(API_RESTARTS)
	@$(NO_RESTARTS) && ok=1 || ok=0; \
	$(KUBECTL) -n $(K8S_NS) scale deployment/payments --replicas=1; \
	$(KUBECTL) -n $(K8S_NS) rollout status deployment/payments --timeout=120s; \
	[ $$ok = 1 ] || { echo 'FAIL: api restarted while payments was down'; exit 1; }

.PHONY: k8s-capacity k8s-rollout-gate k8s-argo-canary-test
k8s-capacity:
	platform/k8s/tests/capacity.sh $(K8S_NS) 25 50 75 100 150
k8s-rollout-gate:
	scripts/rollout-gate-demo.sh $(K8S_NS)
k8s-argo-canary-test:
	platform/k8s/tests/argo-canary.sh $(K8S_NS)
