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
KUBECTL := kubectl --context kind-orderlab
.PHONY: k8s-cluster k8s-image k8s-secret k8s-deploy k8s-smoke k8s-down
k8s-cluster:
	kind get clusters | grep -qx orderlab || kind create cluster --config platform/k8s/kind.yaml
	$(KUBECTL) apply --server-side -k platform/k8s/cluster
	$(KUBECTL) -n kube-system rollout status deployment/metrics-server --timeout=120s
k8s-image: k8s-cluster
	docker build -t orderlab:local .
	kind load docker-image orderlab:local --name orderlab
# Secret from the local .env (lab.py init); piped through stdin so values never hit argv.
k8s-secret: k8s-cluster
	kubectl create namespace $(K8S_NS) --dry-run=client -o yaml | kubectl apply -f -
	grep -E '^(POSTGRES_PASSWORD|LAB_ADMIN_TOKEN)=' .env | kubectl -n $(K8S_NS) create secret generic orderlab-secrets \
		--from-env-file=/dev/stdin --dry-run=client -o yaml | kubectl apply -f -
k8s-deploy: k8s-image k8s-secret
	kubectl apply -k platform/k8s/overlays/$(ENV)
	kubectl -n $(K8S_NS) rollout status statefulset/postgres --timeout=180s
	kubectl -n $(K8S_NS) rollout status deployment/payments --timeout=180s
	kubectl -n $(K8S_NS) rollout status deployment/api --timeout=180s
k8s-smoke:
	@kubectl -n $(K8S_NS) port-forward svc/api 18000:8000 >/dev/null & pf=$$!; trap "kill $$pf" EXIT; sleep 2; \
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
	@kubectl -n $(K8S_NS) delete pod k6 --ignore-not-found >/dev/null
	@kubectl -n $(K8S_NS) run k6 -i --restart=Never --image=$(K6_IMAGE) --env=BASE_URL=http://api:8000 --env=DURATION=90s \
		-- run --quiet - < platform/k8s/tests/orders-load.js & k6=$$!; \
	for i in $$(seq 120); do kubectl -n $(K8S_NS) get pod k6 2>/dev/null | grep -q Running && break; sleep 1; done; \
	kubectl -n $(K8S_NS) get pod k6 2>/dev/null | grep -q Running || { kill $$k6 2>/dev/null; echo 'k6 did not start'; exit 1; }; sleep 10; \
	echo ">>> replacing every api pod under load"; kubectl -n $(K8S_NS) rollout restart deployment/api; \
	wait $$k6; status=$$?; kubectl -n $(K8S_NS) delete pod k6 --ignore-not-found >/dev/null; exit $$status
# Simulates a 60 s slow startup on a rolling update, then reports restarts.
k8s-slow-start-test:
	kubectl -n $(K8S_NS) set env deployment/api STARTUP_DELAY_SECONDS=60
	kubectl -n $(K8S_NS) rollout status deployment/api --timeout=300s || true
	kubectl -n $(K8S_NS) get pods -l app.kubernetes.io/name=api -o custom-columns=POD:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount
	kubectl -n $(K8S_NS) set env deployment/api STARTUP_DELAY_SECONDS-
# Payments down for 60 s: api pods must stay Ready (readiness checks only the DB) and never restart.
k8s-dependency-test:
	kubectl -n $(K8S_NS) scale deployment/payments --replicas=0
	sleep 60
	kubectl -n $(K8S_NS) get pods -l app.kubernetes.io/name=api -o custom-columns=POD:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount
	kubectl -n $(K8S_NS) scale deployment/payments --replicas=1
	kubectl -n $(K8S_NS) rollout status deployment/payments --timeout=120s

.PHONY: k8s-capacity
k8s-capacity:
	platform/k8s/tests/capacity.sh $(K8S_NS) 25 50 75 100 150
