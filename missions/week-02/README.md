# Week 2 Mission: Secrets and Drift Lab

Throwaway lab. Local state only, all under the `lab-w2` prefix.
`01-leak/` is intentionally insecure and is excluded from CI scanning (CI scans `platform/terraform/` only).

Prereqs: `terraform >= 1.11`, `pip install checkov`, valid AWS credentials for account 986608278121.

## 1. Leak

```bash
cd missions/week-02/01-leak
terraform init && terraform apply -auto-approve
terraform state pull | grep -E 'result|secret_string|AKIA'      # BEFORE evidence: plaintext
```

## 2. Detect

```bash
checkov -d . --check CKV_SECRET_2,CKV2_AWS_34 --compact
```
Expect: `CKV_SECRET_2` (hardcoded AWS key, main.tf:28) and `CKV2_AWS_34` (unencrypted SSM param).

## 3. Remediate

```bash
terraform destroy -auto-approve
cd ../02-remediated
export TF_VAR_api_key="lab-only-$(openssl rand -hex 8)"
terraform init && terraform apply -auto-approve
terraform state pull | grep -E 'result|secret_string|api_key' || echo "no secrets in state"   # AFTER
checkov -d . --check CKV_SECRET_2,CKV2_AWS_34 --compact
terraform destroy -auto-approve
```

Why it works: `ephemeral "random_password"` and `ephemeral = true` variables exist only in memory;
`secret_string_wo` / `value_wo` are write-only, so the provider sends them but never records them.
Trade-off: Terraform can't diff a value it doesn't store, so rotation = bump `*_wo_version`.

## 4. Drift: Restore

```bash
cd ../03-drift
terraform init && terraform apply -auto-approve
aws ssm put-parameter --name /lab-w2/drift/managed --type String --value "hacked-by-hand" --overwrite
terraform plan -detailed-exitcode ; echo "exit=$?"     # exit 2, shows value change
terraform apply -auto-approve                          # restores code intent
terraform plan -detailed-exitcode ; echo "exit=$?"     # exit 0
```

## 5. Drift: Adopt

```bash
aws ssm put-parameter --name /lab-w2/drift/manual --type String --value "created-by-hand"
mv adopt.tf.disabled adopt.tf
terraform plan        # "1 to import"
terraform apply -auto-approve
terraform plan -detailed-exitcode ; echo "exit=$?"     # exit 0
```

## Cleanup

```bash
terraform destroy -auto-approve
aws secretsmanager list-secrets --query "SecretList[?starts_with(Name,'lab-w2')].Name"   # expect []
aws ssm describe-parameters --parameter-filters Key=Name,Option=BeginsWith,Values=/lab-w2 # expect none
```
