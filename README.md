# Challenge 3: Two-AZ Private Web Architecture on AWS

> A web page served by nginx on a **private** EC2 instance, behind an Application Load Balancer, across **two Availability Zones**. Provisioned with Terraform, configured with Ansible over AWS Systems Manager (no SSH). 

**Tech stack:** Terraform · Ansible · AWS (VPC, EC2, ALB, S3, IAM, NAT, SSM) · nginx

---

## The problem this solves

**Business problem.** A company needs an application the public can reach, while four things stay true at once: it must be *reachable* but its servers must not be *exposed*; it must *survive the loss of a data center*; it must be *reproducible and auditable* rather than hand-built; and it must be *provably secure before it ships*. Each of those failing is a business cost: a breach, an outage, an unrecoverable snowflake, or a failed audit.

**Technical problem.** Translate those requirements into infrastructure:

| Requirement | Solution |
| --- | --- |
| Reachable but not exposed | Private EC2 behind a public Application Load Balancer |
| Survive a data-center failure | Resources spread across two Availability Zones |
| Reproducible and auditable | All infrastructure as Terraform; all configuration as Ansible |
| No standing credentials on servers | EC2 reads S3 through a scoped IAM role, never a stored key |
| Administered without new attack surface | Access via SSM Session Manager (no SSH, no port 22, no bastion) |

---

## Architecture

```
Internet
   |
Internet Gateway
   |
+---------------------- VPC (10.0.0.0/16) ----------------------+
|                                                               |
|  PUBLIC subnets   (AZ-a, AZ-b)                                |
|    - Application Load Balancer  (only public entry point)     |
|    - NAT Gateway                                              |
|                                                               |
|  PRIVATE subnets  (AZ-a, AZ-b)                                |
|    - EC2 running nginx   (no public IP)                       |
|                                                               |
+---------------------------------------------------------------+
```

- **Request flow:** visitor → Internet Gateway → ALB (public subnet) → EC2 (private subnet) on port 80
- **Outbound:** EC2 → NAT Gateway → internet, for package installation only
- **S3 access:** EC2 → S3 Gateway VPC Endpoint → bucket, without traversing the NAT

<!-- Before final submission: replace this ASCII diagram with an exported image. -->

---

# Part 1 — Required documentation

## 1. Setting up the environment

### Tools

| Tool | Where it runs | Purpose |
| --- | --- | --- |
| AWS CLI v2 | Windows and Linux | AWS API access |
| Terraform >= 1.5 | Any Windows terminal (or Linux/macOS) | Provision infrastructure |
| aws-vault (v7.x) | Same terminal as Terraform | Short-lived credentials for Terraform |
| Ansible | Any Linux shell (WSL on Windows) | Configure the instances |
| session-manager-plugin | Same shell as Ansible | Agentless SSM connection |

### Two shells, on purpose

Terraform has a native Windows binary and runs from any terminal. Ansible is Linux-native and does not run on Windows at all; it runs from a Linux shell.

- **On Windows:** run Terraform from **any terminal** (Git Bash, PowerShell, or Windows Terminal), with aws-vault providing credentials. Run Ansible from **WSL or any Linux shell**.
- **On macOS or Linux:** run both directly in your terminal.

The real requirement is not a specific shell but the split itself: Terraform needs aws-vault for credentials; Ansible needs a Linux environment. 


### AWS authentication

Terraform never holds a long-lived key. A scoped IAM user is allowed only to assume a Terraform execution role, and only with MFA. The full, reproducible credential setup is documented separately:

> **See [`aws-role-assumption-setup-guide.md`](./aws-role-assumption-setup-guide.md)** for the complete IAM role, MFA, and aws-vault configuration.

### Installing the Linux toolchain (Ansible)

Run once, from WSL or a native Linux/macOS terminal:

```bash
sudo apt update
sudo apt install -y ansible python3-pip unzip

# AWS CLI v2 (Linux copy)
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -q awscliv2.zip && sudo ./aws/install && rm -rf awscliv2.zip aws/

# SSM Session Manager plugin
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o "smp.deb"
sudo dpkg -i smp.deb && rm smp.deb

# Ansible AWS collections and Python SDK
ansible-galaxy collection install community.aws amazon.aws
pip3 install boto3 botocore --break-system-packages
```

---

## 2. Deploying the infrastructure and configuration

Deployment is two stages: Terraform provisions, then Ansible configures.

### Stage 1 — Provision (Terraform)

From the `terraform/` directory, using aws-vault (which handles the assume-role and MFA prompt):

```bash
cd terraform
aws-vault exec terraform -- terraform init
aws-vault exec terraform -- terraform plan
aws-vault exec terraform -- terraform apply
```

`apply` prints the outputs, including `alb_dns_name`, the site's URL.

> **Cost note:** the NAT Gateway and ALB bill hourly from `apply`. 

### Stage 2 — Configure (Ansible)

From the `ansible/` directory, in a Linux shell (WSL or native):

```bash
cd ansible

# On the Windows mount only: the directory is world-writable, so point Ansible at the config explicitly
export ANSIBLE_CONFIG=$(pwd)/ansible.cfg

# Load short-lived credentials into the shell (Ansible cannot answer the MFA prompt itself)
aws sts get-caller-identity --profile terraform
eval $(aws configure export-credentials --profile terraform --format env)

# Confirm discovery and connectivity, then configure
ansible-inventory --graph        # lists both instances under server_1 / server_2
ansible all -m ping              # returns "pong" from each instance over SSM
ansible-playbook playbook.yml    # installs nginx, renders the page, starts the service
```

Once nginx serves HTTP 200, the ALB health check passes and the site goes live.

### Accessing the page

The live URL is the `alb_dns_name` output (HTTP only). The ALB DNS name is regenerated on every rebuild, so the URL submitted for grading is taken from the final `apply` before submission.

Each server reports its real Availability Zone and instance ID, so the load balancer distributing traffic across both AZs is visible live:

```bash
for i in $(seq 1 10); do curl -s http://<alb_dns_name> | grep -E "Server|Zone"; echo "---"; done
```

### Teardown

```bash
aws-vault exec terraform -- terraform destroy
```

Everything is Terraform-managed, so teardown is clean. `index.html` is re-uploaded from the local `files/` directory on the next `apply`; the repository, not the running bucket, is the source of truth.

---

## 3. Explanation of the code

### Repository structure

```
.
├── terraform/
│   ├── provider.tf          # provider, version constraints, default tags
│   ├── variables.tf         # region, project name, VPC CIDR, environment
│   ├── vpc.tf               # VPC, subnets, IGW, NAT, route tables
│   ├── s3.tf                # bucket + hardening + web object
│   ├── iam.tf               # instance role, profile, SSM policy
│   ├── security-group.tf    # ALB and instance security groups
│   ├── endpoints.tf         # S3 gateway VPC endpoint
│   ├── alb.tf               # load balancer, target group, listener
│   ├── ec2.tf               # two private instances (one per AZ)
│   ├── security-baseline.tf # flow logs + default-SG lockdown (staged, see scanning)
│   ├── outputs.tf
│   └── files/index.html
└── ansible/
    ├── ansible.cfg          # inventory plugin + SSM defaults
    ├── aws_ec2.yml          # dynamic inventory (discover by tag)
    ├── playbook.yml         # install nginx, render page, start service
    └── templates/index.html.j2
```

### Terraform

| File | What it provisions |
| --- | --- |
| `vpc.tf` | A /16 VPC, two public and two private subnets across two AZs, IGW, a single NAT Gateway, and route tables. Route tables are what actually enforce the public/private split. |
| `s3.tf` | A uniquely named bucket (account-ID suffix for global uniqueness), hardened (see security notes), holding `index.html`. |
| `iam.tf` | The instance role and profile, scoped to read a single S3 object, plus the managed SSM policy. Trust policy (who may assume) and permission policy (what it may do) are separate. |
| `security-group.tf` | The ALB SG (public on 80) and the instance SG, which trusts only the ALB SG. |
| `endpoints.tf` | An S3 Gateway VPC endpoint on the private route table, keeping S3 traffic off the NAT and off the internet. |
| `alb.tf` | Internet-facing ALB across both public subnets, a target group with an HTTP health check, and a listener forwarding port 80. |
| `ec2.tf` | Two instances (one per private subnet, so one per AZ), each with the instance profile, no public IP, IMDSv2 required, and an encrypted root volume. The AMI is looked up (latest Amazon Linux 2023), not hardcoded. |

### Ansible

| File | What it does |
| --- | --- |
| `aws_ec2.yml` | Dynamic inventory: the `amazon.aws.aws_ec2` plugin discovers instances by `tag:Project`, connects over `aws_ssm`, and builds `server_1` / `server_2` groups from the `Server` tag. Nothing is hardcoded, so it survives rebuilds. |
| `playbook.yml` | Gathers each instance's metadata, derives its server number from its tag, installs nginx via `dnf`, renders the page template per host, and starts the service. |
| `templates/index.html.j2` | Shared branding plus each host's real AZ and instance ID, pulled from live metadata so the values cannot be faked. |

---

# Part 2 — Additions

Everything below is engineering added on top of the stated requirements: the security posture, the verifiable guarantees, and the infrastructure-as-code security scan. This is where the design choices are justified.

## Design decisions and security posture

Each choice is a deliberate tradeoff, not a default.

### Why two instances

The brief asked for a single EC2 instance. This deployment runs two, one in each Availability Zone, as a deliberate application of the AWS Well-Architected Framework:

- **Reliability (primary):** a single instance in a single AZ is a single point of failure. Two instances across two AZs keep the site serving through a full AZ outage. High availability is the main reason for the second instance.
- **Performance Efficiency (secondary):** the ALB distributes requests across both instances rather than concentrating load on one.
- **Operational Excellence (secondary):** with two instances, the load balancer's health checking and cross-AZ distribution are observable and testable. The page reports each server's real AZ, making the HA behavior visible rather than assumed.
- **Cost Optimization (the tradeoff):** two instances cost more than one. This is a conscious trade of marginal cost for reliability, which is itself how Well-Architected decisions are meant to be made, balancing pillars rather than maximizing one.

### The web server is private; the URL is the load balancer

The brief asks for "the URL of the web page hosted on the EC2 instance." The instance is deliberately placed in a private subnet with no public IP and cannot be reached directly. Public traffic terminates at the ALB, which routes to the instance internally. The URL provided for grading is therefore the load balancer's DNS name. This is an intentional deviation from the literal wording in favor of the production-correct pattern: never expose compute directly.

## Security Considerations

### S3 bucket hardening

- **Block Public Access (all four controls):** the bucket cannot be made public through ACLs or policy, on current or future grants.
- **Ownership BucketOwnerEnforced:** ACLs disabled entirely, removing a legacy misconfiguration vector.
- **Versioning enabled:** protects against accidental overwrite or deletion and preserves object history.
- **Server-side encryption (AES256):** declared explicitly to document intent and satisfy scanners.

### IAM instance role (least privilege)

The instances read from S3 through an IAM role attached as an instance profile, never a stored key. The permission policy grants `s3:GetObject` on a *single object ARN*, not the bucket, not all objects, not all buckets. A fully compromised instance can read one HTML file and nothing else. The role also carries the AWS-managed `AmazonSSMManagedInstanceCore` policy for Session Manager access, a deliberate, documented use of a managed policy.

### Security group chain

- The **ALB SG** allows inbound 80 from `0.0.0.0/0`; the load balancer is meant to be public.
- The **instance SG** allows inbound 80 *only from the ALB's security group* (a reference, not an IP range). Nothing else in the VPC, and nothing on the internet, has a path to the instances.

### What this architecture makes impossible

Each statement is verifiable in one or two commands:

> - The web server has no public IP and cannot be reached directly from the internet.
> - The S3 bucket cannot be made public; public access is blocked at the account-override level.
> - The EC2 instances hold no static AWS credentials; they read S3 through a scoped role.
> - No access keys appear anywhere in the Terraform code.
> - No port 22 is open anywhere; there is no SSH and no key pair. Access is via SSM only.
> - The instances enforce IMDSv2, closing the metadata-service credential-theft vector.

---

## IaC security scanning

The Terraform was scanned with **Checkov** (policy-as-code against CIS, NIST, and other frameworks). The goal is not a clean scan; on infrastructure this size, zero findings usually means the tool is not looking hard enough. The goal is documented judgment: every finding is triaged.

```bash
python3 -m checkov -d terraform/ --compact --quiet
```

**Result: 76 passed, 24 failed.** The 76 passes independently confirm the hardening built into this project (public-access block, encryption, IMDSv2, scoped IAM, the SG chain, encrypted volumes). The Ansible scan passed with no failures.

### Findings triage

| Finding(s) | Decision | Rationale |
| --- | --- | --- |
| `CKV2_AWS_11` VPC flow logs | **Fix (staged)** | Network audit/IR record. Terraform written in `security-baseline.tf`, not yet applied. |
| `CKV2_AWS_12` default SG not restricted | **Fix (staged)** | Lock the unused default SG to deny-all. |
| `CKV_AWS_91`, `CKV_AWS_18` access logging | **Fix (staged)** | ALB and S3 access logs; needs a logging bucket. |
| `CKV_AWS_2`, `_103`, `_131`, `_378`, `CKV2_AWS_20` (HTTPS/TLS) | **Accept** | HTTP-only: no registered domain in a lab. Production terminates TLS at the ALB with an ACM cert. |
| `CKV_AWS_145` S3 KMS encryption | **Accept** | SSE-S3 used; customer-managed KMS deferred as a cost tradeoff. |
| `CKV_AWS_150` ALB deletion protection | **Accept** | Off intentionally; the lab is destroyed nightly and this would block teardown. |
| `CKV_AWS_260` ingress 0.0.0.0/0 to 80 | **Accept** | Fires on the ALB SG, the intended public entry point. |
| `CKV_AWS_130` public IP on subnets | **Accept** | Fires on public subnets, which need it for the ALB/NAT. Private subnets do not. |
| `CKV_AWS_382` egress 0.0.0.0/0 | **Accept** | Instances need outbound for package installation via NAT. |
| `CKV_AWS_144`, `CKV2_AWS_62`, `CKV2_AWS_61`, `CKV_AWS_126`, `CKV_AWS_135`, `CKV2_AWS_28` | **Accept** | Enterprise-scale controls (cross-region replication, event notifications, lifecycle, detailed monitoring, EBS optimization, WAF) beyond a single-region lab. |

This triage, 76 controls validated and 24 findings sorted into fix-now versus accept-with-rationale, is the governance record for the infrastructure: risk is either remediated or consciously accepted with a documented reason, never silently ignored.

---

## Cost and tradeoffs

| Choice | Tradeoff |
| --- | --- |
| Single NAT Gateway | Cost vs. availability; production runs one per AZ. |
| AES256 (SSE-S3) not KMS | Cost vs. key control. |
| Versioning without lifecycle expiry | Fine for a lab; production adds an expiry rule. |
| HTTP only, no TLS | No registered domain; production terminates HTTPS at the ALB. |
| Some scanner findings staged, not applied | Flow logs, default-SG lockdown, access logging queued for a follow-up. |
