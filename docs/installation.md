# Installation and Deployment

## Purpose

This document describes the deployment procedure used for this project.

The development workstation uses:

- Windows
- Git Bash for Terraform and AWS Vault
- WSL Ubuntu for Ansible
- AWS Vault for source-credential storage
- MFA and STS role assumption for AWS access

Terraform and Ansible use separate AWS execution roles.

Architecture is in [architecture.md](architecture.md). Identity and IAM are in [security-model.md](security-model.md). Teardown is in [cleanup.md](cleanup.md).

---

## Authentication Model

The local AWS profile named `grc-engineer` maps to the IAM user `grc-engineer01`.

The local profile name and IAM username are separate concepts.

STS `GetCallerIdentity` is used to verify the active AWS principal.

### Terraform authentication

```text
grc-engineer
      |
      | MFA
      | STS AssumeRole
      v
TerraformExecutionRole
```

Example AWS CLI configuration:

```ini
[profile grc-engineer]
region = us-east-1
output = json

[profile terraform]
source_profile = grc-engineer
role_arn = arn:aws:iam::<ACCOUNT_ID>:role/TerraformExecutionRole
mfa_serial = arn:aws:iam::<ACCOUNT_ID>:mfa/grc-engineer01
region = us-east-1
```

The source credential for `grc-engineer` is stored through AWS Vault rather than committed to the repository.

Verify:

```bash
aws-vault exec terraform -- aws sts get-caller-identity
```

Expected role: `assumed-role/TerraformExecutionRole`

---

## Terraform Tooling

Terraform runs from Git Bash on Windows.

Check:

```bash
terraform version
aws-vault --version
aws --version
```

---

## Deploy Infrastructure

From the repository root:

```bash
cd terraform

aws-vault exec terraform -- terraform init
aws-vault exec terraform -- terraform fmt -check
aws-vault exec terraform -- terraform validate
aws-vault exec terraform -- terraform plan -out=tfplan
```

Review the plan before applying it.

Apply the saved plan:

```bash
aws-vault exec terraform -- terraform apply tfplan
```

Inspect outputs (reads local state; AWS credentials are not required):

```bash
terraform output
```

Expected outputs include:

- `alb_dns_name`
- `web_bucket_name`
- `vpc_id`

---

## Validate Terraform Identity

```bash
aws-vault exec terraform -- aws sts get-caller-identity
```

The ARN should contain `assumed-role/TerraformExecutionRole`.

---

## Ansible Authentication

Terraform creates the project-specific Ansible execution role `challenge3-ansible-execution-role`.

Add a local AWS profile after Terraform creates that role:

```ini
[profile challenge3-ansible]
source_profile = grc-engineer
role_arn = arn:aws:iam::<ACCOUNT_ID>:role/challenge3-ansible-execution-role
mfa_serial = arn:aws:iam::<ACCOUNT_ID>:mfa/grc-engineer01
region = us-east-1
output = json
```

The pre-existing profile named `ansible` belongs to a different project and is not reused.

Test from Git Bash:

```bash
aws-vault exec challenge3-ansible -- aws sts get-caller-identity
```

Expected ARN: `assumed-role/challenge3-ansible-execution-role`

---

## WSL Tooling

Ansible runs inside WSL.

Required tools:

- Python 3
- Ansible
- AWS CLI
- AWS Session Manager plugin
- boto3
- botocore
- `amazon.aws` Ansible collection

Check:

```bash
python3 --version
ansible --version
aws --version
session-manager-plugin --version
```

---

## Install Project Ansible Dependencies

The tested project dependencies are recorded in `ansible/requirements.yml` and `ansible/requirements.txt`.

From WSL:

```bash
cd ansible

python3 -m pip install -r requirements.txt
ansible-galaxy collection install -r requirements.yml
```

The tested AWS collection is pinned in `requirements.yml`.

Verify:

```bash
ansible-galaxy collection list amazon.aws
```

---

## Pass Temporary AWS Credentials into WSL

AWS Vault runs on the Windows side.

WSL receives the temporary STS credential variables when the WSL process starts.

From Git Bash:

```bash
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1

export WSLENV="AWS_ACCESS_KEY_ID/u:AWS_SECRET_ACCESS_KEY/u:AWS_SESSION_TOKEN/u:AWS_REGION/u:AWS_DEFAULT_REGION/u"

aws-vault exec challenge3-ansible -- \
  wsl.exe bash -lc 'exec bash -i'
```

Do not expect an already-open WSL terminal to receive newly created temporary credentials.

AWS Vault does not need to be installed inside WSL.

---

## Initialize the Ansible Environment

From the repository root inside the newly opened WSL session:

```bash
source scripts/init-ansible-env.sh
```

The helper validates:

- AWS CLI availability
- Ansible availability
- Session Manager plugin availability
- Terraform state availability
- active AWS identity
- Ansible execution-role identity
- S3 transfer-bucket value
- ALB DNS value
- Ansible configuration path

The script reads non-secret deployment outputs from the local Terraform state.

It does not print temporary AWS credentials.

Expected output includes:

```text
Challenge 3 Ansible environment loaded.

AWS identity : arn:aws:sts::...:assumed-role/challenge3-ansible-execution-role/...
AWS region   : us-east-1
SSM bucket   : challenge3-...
ALB DNS      : challenge3-alb-...
Ansible cfg  : .../ansible/ansible.cfg
```

---

## Validate Dynamic Inventory

From the `ansible/` directory:

```bash
ansible-inventory --graph
```

Illustrative structure (Ansible also shows plugin groups such as `@aws_ec2`):

```text
@server_1
  └── EC2 instance ID

@server_2
  └── EC2 instance ID
```

Inventory is discovered from AWS rather than hardcoded instance IDs.

---

## Validate SSM Connectivity

```bash
ansible all -m ping
```

Both EC2 hosts should return `SUCCESS` with `ping: pong`.

No SSH connection is used.

---

## Configure the Web Servers

```bash
ansible-playbook playbook.yml
```

The playbook:

- gathers host facts
- gathers EC2 metadata
- determines the server number
- installs nginx
- renders the Jinja template
- enables and starts nginx

Successful execution should end with `unreachable=0` and `failed=0`.

---

## Validate Idempotence

Run the playbook a second time:

```bash
ansible-playbook playbook.yml
```

After convergence, both hosts should report:

- `changed=0`
- `unreachable=0`
- `failed=0`

Evidence: [docs/evidence/ansible/idempotence-final.png](evidence/ansible/idempotence-final.png)

---

## Validate the Application

The environment helper exports `ALB_DNS`.

```bash
curl -I "http://${ALB_DNS}"
```

Expected response: `HTTP/1.1 200 OK`

Repeated requests can verify both backend instances:

```bash
for i in $(seq 1 12); do
  curl -s "http://${ALB_DNS}" |
    grep -E "Availability Zone|Instance ID"
  echo "-----"
done
```

Evidence:

- [docs/evidence/application/live-web-application.png](evidence/application/live-web-application.png)
- [docs/evidence/infrastructure/alb-multiaz-distribution.png](evidence/infrastructure/alb-multiaz-distribution.png)

---

## Temporary Credential Expiration

AWS Vault supplies temporary STS credentials.

An expired session may produce `RequestExpired` during dynamic inventory or other AWS API calls.

Do not modify IAM permissions in response to an expired credential.

Exit the WSL session and launch a fresh session through:

```bash
aws-vault exec challenge3-ansible -- \
  wsl.exe bash -lc 'exec bash -i'
```

Then source again:

```bash
source scripts/init-ansible-env.sh
```

---

## Common Failure: Empty S3 Transfer Bucket

The Ansible SSM connection requires `ANSIBLE_SSM_BUCKET`.

If it is empty, the connection plugin can fail with an invalid bucket-name error.

```bash
source scripts/init-ansible-env.sh
```

The helper reads the actual bucket name from Terraform state and rejects an empty result.

---

## Common Failure: Wrong AWS Identity

```bash
aws sts get-caller-identity
```

For Ansible work, the ARN must contain `assumed-role/challenge3-ansible-execution-role`.

For Terraform work, the ARN must contain `assumed-role/TerraformExecutionRole`.

Do not rely on the local profile name alone to determine the effective AWS identity.

---

## Source-of-Truth Boundaries

- Terraform owns cloud infrastructure.
- Ansible owns host and nginx configuration.
- Terraform state remains local and is excluded from Git.
- Ansible dependencies are pinned in the repository.
- The S3 transfer bucket is not the web-content source.

The Jinja template is the application-page source: `ansible/templates/index.html.j2`.
