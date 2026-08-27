# Private Multi-AZ AWS Web Infrastructure Automation

Public ALB, private EC2, Terraform, Ansible, and SSM instead of SSH.

Provisioning, configuration, workload, and AWS service identities are separate. Least privilege is proven with allowed operations and deliberate denies.

## At a Glance

- **Built:** A two-AZ private EC2/nginx web tier behind a public Application Load Balancer, provisioned with Terraform and configured with Ansible.
- **Private by design:** EC2 instances have no public IP addresses and no inbound SSH rule; the ALB is the only public application entry point.
- **Terraform owns:** VPC, subnets, routing, NAT, ALB, EC2, IAM, S3, VPC endpoints, security groups, and baseline logging/security controls.
- **Ansible owns:** Dynamic EC2 discovery, nginx and host configuration, template rendering, and service state.
- **Management plane:** Ansible manages the private instances through AWS Systems Manager rather than direct SSH connectivity.
- **Identity separation:** Terraform, Ansible, EC2, and VPC Flow Logs use distinct AWS identities with different responsibilities.
- **Least privilege:** The EC2 workload role has SSM managed-node permissions but no application S3 permission; the Ansible execution role has only the discovery, SSM, and transfer-bucket authority its workflow requires.
- **Validation:** Multi-AZ traffic distribution, Ansible idempotence, denied IAM actions, VPC Flow Logs, and Checkov results are captured under `docs/evidence/`.

```text
TerraformExecutionRole
        -> provisions and destroys AWS infrastructure

challenge3-ansible-execution-role
        -> discovers EC2, starts approved SSM sessions,
           and operates the scoped S3 transfer bucket

challenge3-web-instance-role
        -> registers EC2 as an SSM managed node
           no application S3 authority

VPC Flow Logs service role
        -> publishes network-flow records to CloudWatch Logs
```

---

## Architecture

A fuller write-up is in [docs/architecture.md](docs/architecture.md). Identity and IAM are in [docs/security-model.md](docs/security-model.md). The documentation index is [docs/README.md](docs/README.md).

![Architecture diagram](docs/evidence/infrastructure/architecture-diagram.png)

### Management / configuration path

```text
AWS Vault + MFA
       |
       v
Ansible Execution Role
       |
       +--> EC2 dynamic inventory
       |
       +--> Systems Manager session
       |
       +--> S3 temporary transfer bucket
       |
       v
Private EC2 instances
```

### Infrastructure path

```text
AWS Vault + MFA
       |
       v
Terraform Execution Role
       |
       v
Terraform
       |
       v
AWS infrastructure
```

### Traffic flow

```text
User
 |
 v
Internet Gateway
 |
 v
Application Load Balancer
 |
 v
EC2 security group
 |
 v
nginx on private EC2
```

The EC2 instances have no public IPv4 addresses.

Outbound traffic from the private subnets uses a NAT Gateway. The project uses one NAT Gateway as a deliberate lab cost tradeoff, so the application serving tier spans two AZs but outbound management traffic retains a single-NAT dependency.

---

## Technology Stack

| Area                     | Technology                                    |
| ------------------------ | --------------------------------------------- |
| Infrastructure as Code   | Terraform                                     |
| Configuration Management | Ansible                                       |
| Cloud                    | AWS                                           |
| Compute                  | EC2                                           |
| Load Balancing           | Application Load Balancer                     |
| Networking               | VPC, public/private subnets, IGW, NAT Gateway |
| Remote Management        | AWS Systems Manager                           |
| Transfer Storage         | Amazon S3                                     |
| Identity                 | IAM roles, STS, AWS Vault, MFA                |
| Web Server               | nginx                                         |
| Network Logging          | VPC Flow Logs + CloudWatch Logs               |
| IaC Security             | Checkov                                       |

---

## Repository Structure

```text
.
├── README.md
├── ansible/
│   ├── ansible.cfg
│   ├── aws_ec2.yml
│   ├── group_vars/
│   │   └── all.yml
│   ├── playbook.yml
│   ├── requirements.txt
│   ├── requirements.yml
│   └── templates/
│       └── index.html.j2
├── terraform/
│   ├── alb.tf
│   ├── ec2.tf
│   ├── endpoints.tf
│   ├── iam.tf
│   ├── outputs.tf
│   ├── provider.tf
│   ├── s3.tf
│   ├── security-baseline.tf
│   ├── security-group.tf
│   ├── variables.tf
│   └── vpc.tf
├── scripts/
│   └── init-ansible-env.sh
└── docs/
    ├── README.md
    ├── architecture.md
    ├── security-model.md
    ├── installation.md
    ├── cleanup.md
    └── evidence/
        ├── ansible/
        ├── application/
        ├── infrastructure/
        │   └── architecture-diagram.png
        └── security/
```

## Code Map

### Terraform

| File | Responsibility |
| --- | --- |
| `terraform/provider.tf` | AWS provider, version constraints, and default tags (`Project`, `ManagedBy`, `Environment`) |
| `terraform/variables.tf` | Region, project name, VPC CIDR, and environment |
| `terraform/vpc.tf` | VPC, public/private subnets, Internet Gateway, single NAT Gateway, and route tables |
| `terraform/security-group.tf` | ALB public HTTP ingress; EC2 HTTP only from the ALB SG; scoped egress |
| `terraform/alb.tf` | Internet-facing ALB, target group, listener, and health checks |
| `terraform/ec2.tf` | Two private instances, IMDSv2, encrypted root volumes, detailed monitoring, and no public IPs |
| `terraform/iam.tf` | EC2 instance role/profile for SSM and Ansible execution role trust + permissions |
| `terraform/s3.tf` | Private Ansible/SSM transfer bucket: encryption, public-access block, and lifecycle cleanup |
| `terraform/endpoints.tf` | S3 Gateway VPC endpoint associated with the private route table |
| `terraform/security-baseline.tf` | VPC Flow Logs, Flow Logs IAM role, CloudWatch log group, and default-SG deny-all |
| `terraform/outputs.tf` | `alb_dns_name`, `web_bucket_name`, VPC ID, and subnet IDs |

The Terraform **execution identity** (`TerraformExecutionRole`) is not provisioned by this repository. It is a pre-existing role assumed from the workstation through AWS Vault and MFA.

### Ansible

| File | Responsibility |
| --- | --- |
| `ansible/ansible.cfg` | Inventory configuration, SSM connection defaults, and Python interpreter settings |
| `ansible/aws_ec2.yml` | Dynamic inventory by `Project` tag and SSM connection |
| `ansible/group_vars/all.yml` | SSM region and transfer-bucket settings |
| `ansible/playbook.yml` | Idempotent nginx installation, template rendering, and service state |
| `ansible/templates/index.html.j2` | Per-host page showing server number, Availability Zone, and instance ID |
| `ansible/requirements.yml` | Pinned `amazon.aws` collection |
| `ansible/requirements.txt` | Pinned `boto3` and `botocore` dependencies |

### Scripts and Documentation

| File | Responsibility |
| --- | --- |
| `scripts/init-ansible-env.sh` | WSL helper that verifies the Ansible AWS identity and loads deployment values from Terraform state |
| `docs/architecture.md` | Traffic paths, Availability Zone layout, tool ownership boundaries, and architectural tradeoffs |
| `docs/security-model.md` | IAM identities, trust boundaries, least privilege, negative tests, and Checkov decisions |
| `docs/installation.md` | Reproducible Git Bash, AWS Vault, WSL, Terraform, and Ansible deployment procedure |
| `docs/cleanup.md` | Terraform teardown, billable-resource checks, and project identity cleanup |

---

## Terraform Responsibilities

Terraform owns the AWS infrastructure lifecycle.

It provisions:

- VPC
- Internet Gateway
- two public subnets
- two private subnets
- route tables
- NAT Gateway
- S3 Gateway VPC endpoint
- Application Load Balancer
- target group and listener
- two EC2 instances
- IAM roles and instance profile
- security groups
- S3 transfer bucket
- VPC Flow Logs
- CloudWatch log group
- locked-down default security group

The EC2 instances require IMDSv2, use encrypted root volumes, have detailed monitoring enabled, and receive no public IP addresses.

---

## Ansible Responsibilities

Ansible owns operating-system and application configuration.

The playbook:

- discovers the Terraform-created EC2 instances using AWS dynamic inventory
- connects through AWS Systems Manager rather than SSH
- gathers EC2 metadata
- derives each server number from its AWS tag
- installs nginx
- renders `index.html.j2`
- starts and enables nginx

No EC2 IP addresses or instance IDs are hardcoded into the inventory. Discovery is by the `Project` tag (`challenge3`).

```text
Terraform
   |
   | creates + tags EC2
   v
AWS EC2
   ^
   | dynamic tag discovery
   |
Ansible
```

---

## Identity and Access Model

The project deliberately separates infrastructure provisioning from configuration management.

### Terraform execution identity

```text
grc-engineer01
      |
      | MFA + STS
      v
TerraformExecutionRole
      |
      v
Terraform-managed infrastructure
```

### Ansible execution identity

```text
grc-engineer01
      |
      | MFA + STS
      v
challenge3-ansible-execution-role
      |
      +--> discover EC2
      +--> start approved SSM sessions
      +--> use S3 transfer bucket
```

### EC2 workload identity

```text
EC2
 |
 v
challenge3-web-instance-role
 |
 +--> Systems Manager managed-node permissions
 X--> no application S3 permission
```

The nginx application does not need S3 or other application-data AWS APIs. The instance role carries only Systems Manager managed-node permissions.

A negative-permission test confirmed that both EC2 instances receive `AccessDenied` when attempting account-level S3 enumeration.

This is intentional: running inside AWS does not automatically justify AWS permissions.

---

## Why S3 Exists

S3 is not the source of the webpage.

The bucket exists for the `amazon.aws.aws_ssm` connection path used by Ansible.

```text
Ansible controller
       |
       | temporary module/file transfer
       v
S3 transfer bucket
       |
       v
SSM-managed EC2
```

The bucket is configured with:

- Block Public Access
- Bucket Owner Enforced ownership
- SSE-S3 encryption
- versioning suspended
- one-day object expiration
- one-day incomplete multipart-upload cleanup
- Terraform `force_destroy` for lab teardown

Versioning is intentionally suspended. Temporary Ansible payloads should not survive deletion as historical object versions.

---

## Network Security

### Public boundary

The Application Load Balancer is the only public application entry point.

```text
Internet
   |
   | TCP/80
   v
ALB security group
```

### Private compute boundary

The EC2 security group accepts HTTP only from the ALB security group.

```text
ALB SG
   |
   | TCP/80
   v
EC2 SG
```

There is:

- no SSH ingress
- no port 22 rule
- no bastion host
- no EC2 public IP
- no application-level S3 access

Administration uses Systems Manager.

---

## Logging and Visibility

VPC Flow Logs capture all VPC traffic and publish to CloudWatch Logs.

The Flow Logs service role trust policy restricts assumption with:

- `aws:SourceAccount`
- `aws:SourceArn`

The default VPC security group is explicitly locked down.

---

## Security Validation

Security validation included both successful and denied operations.

### Positive tests

The project proved:

- Terraform can provision the complete environment
- both EC2 instances register with Systems Manager
- Ansible dynamic inventory discovers both instances
- Ansible connects without SSH
- nginx is installed on both servers
- the ALB reaches both targets
- requests are distributed across both Availability Zones
- a second Ansible run completes with `changed=0`
- the application remains reachable after security hardening

### Negative tests

The project proved:

- the EC2 workload identity cannot enumerate S3 buckets
- the Ansible execution role cannot perform unrelated IAM administration
- broad AWS authority is not required for configuration management

See [`docs/evidence/`](docs/evidence/) for captured validation evidence.

---

## Checkov Security Scan

Terraform was assessed with Checkov.

**Final scan:** 132 passed, 17 failed, 0 skipped.

The remaining findings were reviewed individually and classified as accepted lab risk, intentional design, tool/context mismatch, or not applicable. Several earlier findings led directly to infrastructure hardening, including VPC Flow Logs, default-security-group lockdown, restricted egress, EC2 detailed monitoring, ALB invalid-header handling, and S3 transfer lifecycle controls.

See [`docs/security-model.md`](docs/security-model.md) for the full findings register and decision rationale. Final scan evidence: [`docs/evidence/security/checkov-final-scan.png`](docs/evidence/security/checkov-final-scan.png).

---

## Deployment

The full Windows/WSL procedure is in [docs/installation.md](docs/installation.md).

Summary:

1. From Git Bash, apply Terraform with `aws-vault exec terraform`.
2. After the Ansible role exists, add the local `challenge3-ansible` profile.
3. Launch a **new** WSL shell through AWS Vault so STS variables reach WSL.
4. In WSL, `source scripts/init-ansible-env.sh`, then inventory, ping, and the playbook.

```bash
# Git Bash — infrastructure
cd terraform
aws-vault exec terraform -- terraform init
aws-vault exec terraform -- terraform plan -out=tfplan
aws-vault exec terraform -- terraform apply tfplan

# Git Bash — open WSL with Ansible-role credentials
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=us-east-1
export WSLENV="AWS_ACCESS_KEY_ID/u:AWS_SECRET_ACCESS_KEY/u:AWS_SESSION_TOKEN/u:AWS_REGION/u:AWS_DEFAULT_REGION/u"
aws-vault exec challenge3-ansible -- wsl.exe bash -lc 'exec bash -i'
```

```bash
# WSL — configuration
source scripts/init-ansible-env.sh
cd ansible
ansible-inventory --graph
ansible all -m ping
ansible-playbook playbook.yml
```

A second playbook run should converge with `changed=0` and `failed=0`.

---

## Application Validation

After `source scripts/init-ansible-env.sh`, the helper exports `ALB_DNS`:

```bash
curl -I "http://${ALB_DNS}"
```

Repeated requests show traffic reaching both EC2 instances across both Availability Zones.

See [docs/installation.md](docs/installation.md) for the full validation loop.

See:

- [`docs/evidence/infrastructure/alb-multiaz-distribution.png`](docs/evidence/infrastructure/alb-multiaz-distribution.png)
- [`docs/evidence/application/live-web-application.png`](docs/evidence/application/live-web-application.png)

---

## Teardown

The full teardown procedure is in [docs/cleanup.md](docs/cleanup.md).

```bash
cd terraform

aws-vault exec terraform -- terraform plan -destroy -out=destroy.tfplan
aws-vault exec terraform -- terraform apply destroy.tfplan
```

Then confirm billable resources are gone (EC2, ALB, NAT, Elastic IP, transfer bucket, project IAM roles, VPC). Review and remove the local `challenge3-ansible` profile if it is no longer needed. Do not remove the shared `grc-engineer`, `terraform`, or `ansible` profiles.

Teardown evidence belongs in [`docs/evidence/teardown/`](docs/evidence/teardown/).

---

## Key Engineering Decisions

This project deliberately favors:

- private compute over directly exposed EC2
- SSM over SSH
- temporary role credentials over stored workload keys
- separate Terraform and Ansible identities
- exact authority over broad managed access
- dynamic inventory over hardcoded hosts
- negative permission tests alongside success tests
- documented scanner exceptions over scanner-driven architecture
- reproducible teardown as part of the resource lifecycle

