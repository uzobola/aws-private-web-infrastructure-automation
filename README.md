# Challenge 3: Reproducible, Least-Exposure Web Architecture with Terraform and Ansible

A "Hello, World!" page is served by nginx on a private EC2 instance, behind an Application Load Balancer, across two Availability Zones. The application is trivial on purpose. The delivery pattern is the point: reproducible infrastructure as code, least exposure by default, and no standing credentials anywhere in the path.

## Architecture

```
Internet
   |
Internet Gateway
   |
+---------------------- VPC (10.0.0.0/16) ----------------------+
|  PUBLIC subnets  (AZ-a, AZ-b)                                 |
|    - Application Load Balancer                                |
|    - NAT Gateway                                              |
|                                                              |
|  PRIVATE subnets (AZ-a, AZ-b)                                 |
|    - EC2 running nginx  (no public IP)                        |
+--------------------------------------------------------------+
```

Request flow: visitor -> Internet Gateway -> ALB (public subnet) -> EC2 (private subnet) on port 80.
Outbound from the instance: EC2 -> NAT Gateway -> internet, for package installation only.
S3 access: EC2 -> S3 Gateway VPC Endpoint -> bucket, without traversing the NAT.

<!-- TODO: replace ASCII with an exported diagram image before submission -->

## Design decisions and security posture

This section is the reason the architecture looks the way it does. Each choice is a deliberate tradeoff, not a default.

### The web server is private, and the URL is the load balancer

The challenge asks for "the URL of the web page hosted on the EC2 instance." The instance is deliberately placed in a private subnet with no public IP address. It cannot be reached directly from the internet. Public traffic terminates at the Application Load Balancer, which routes to the instance over the VPC's internal network.

The URL provided for evaluation is therefore the load balancer's DNS name, not the instance's. This is an intentional deviation from the literal wording, in favor of the production-correct pattern: never expose compute directly. The page is served by the instance and reached through the load balancer.

### What this architecture makes impossible

Verifiable statements, each testable in one or two commands:

- The web server has no public IP and cannot be reached directly from the internet.
- The S3 bucket cannot be made public; public access is blocked at the account-override level.
- The EC2 instance holds no static AWS credentials; it reads S3 through a scoped instance role.
- No access keys appear anywhere in the Terraform code.
- Terraform authenticates with short-lived, MFA-gated credentials obtained by assuming a role.
- No port 22 is open anywhere; there is no SSH and no key pair. Administrative and configuration access is via AWS Systems Manager Session Manager only.
- The instances enforce IMDSv2 (`http_tokens = "required"`), closing the metadata-service credential-theft vector.
- The instance security group accepts traffic only from the load balancer's security group, not from any IP range, so there is no network path to the instances except through the ALB.

### S3 bucket hardening

The bucket that holds the web content is hardened rather than merely created:

- **Block Public Access (all four controls):** the bucket cannot be made public through ACLs or bucket policy, on current or future grants. It serves the instance through an IAM role, never the public.
- **Ownership set to BucketOwnerEnforced:** ACLs are disabled entirely, removing a legacy misconfiguration vector. Access is governed only by IAM and bucket policy.
- **Versioning enabled:** protects against accidental overwrite or deletion and preserves a provable object history. (Production would add a lifecycle rule to expire old versions; omitted here as a documented tradeoff.)
- **Server-side encryption at rest (AES256 / SSE-S3):** declared explicitly to document intent and satisfy scanners, even though S3 encrypts by default. (A customer-managed KMS key would add key rotation, a key access policy, and CloudTrail on decrypt, at ~1 USD/month; deferred as a documented tradeoff.)

### Credential handling

Terraform never holds long-lived credentials. A scoped IAM user (`grc-engineer01`) is permitted only to assume a dedicated execution role, and only with MFA present, enforced by an `aws:MultiFactorAuthPresent` condition in the role's trust policy. `aws-vault` stores the source key in the OS credential manager (not a plaintext file) and mints short-lived session credentials per command. The Terraform provider block contains no `access_key` or `secret_key`.

Full setup steps are in [aws-role-assumption-setup-guide.md](./aws-role-assumption-setup-guide.md).

### IAM instance role (least privilege)

The instances read the web content from S3 through an IAM role attached as an instance profile, never through a stored access key. The role's permission policy grants `s3:GetObject` on a single object ARN (`<bucket>/index.html`), not the bucket, not all objects, not all buckets. If an instance were fully compromised, the identity it carries can read one HTML file and nothing else. This is non-human identity governance expressed in infrastructure: a scoped role, no standing secret, minimal access. The role additionally carries the AWS-managed `AmazonSSMManagedInstanceCore` policy so the instance can be managed over Session Manager. That managed policy is a deliberate, documented exception to hand-scoping, since it is AWS's own minimal SSM policy.

### Security group chain

Two security groups enforce least exposure as a pair:

- The ALB security group allows inbound port 80 from `0.0.0.0/0`. This is intentional; the load balancer is the one component meant to be public.
- The instance security group allows inbound port 80 only from the ALB's security group (a security-group reference, not an IP range). Nothing else in the VPC, and nothing on the internet, has a network path to the instances. The exposure lives entirely at the ALB by design.

## Prerequisites

Tools required on the workstation:

- AWS CLI v2
- Terraform >= 1.5
- aws-vault (maintained fork, v7.x) for running Terraform on short-lived credentials

### Two shells, on purpose

Terraform has a native Windows binary and is run from a Windows shell (Git Bash) via aws-vault. Ansible is a Linux-native tool and does not run natively on Windows at all. It runs from a Linux control node.

- On **Windows**: run the Ansible steps from **WSL** (Windows Subsystem for Linux), not Git Bash. Git Bash cannot run Ansible.
- On **macOS or Linux**: run the Ansible steps directly in your terminal.

This split is the portable, reproducible setup: "run Ansible from a Linux shell" is correct on every operating system.

### Setting up the Linux control node (Ansible)

From WSL (or a native Linux/macOS terminal), install the toolchain:

```
sudo apt update
sudo apt install -y ansible python3-pip unzip

# AWS CLI v2 (Linux copy, separate from any Windows install)
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -q awscliv2.zip && sudo ./aws/install && rm -rf awscliv2.zip aws/

# SSM Session Manager plugin (for the agentless SSM connection)
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o "session-manager-plugin.deb"
sudo dpkg -i session-manager-plugin.deb && rm session-manager-plugin.deb

# Ansible AWS collections and Python SDK
ansible-galaxy collection install community.aws amazon.aws
pip3 install boto3 botocore --break-system-packages
```

### AWS authentication

- An IAM user scoped to assume a Terraform execution role, with MFA enforced in the role's trust policy (see the setup guide above).
- The `terraform` profile configured in `~/.aws/config`. On Windows this is used by aws-vault; in WSL the same profile is configured natively so Ansible's dynamic inventory can authenticate. Full details are in the credential setup guide.

## Repository structure

```
challenge-3-terraform-ansible/
├── README.md
├── .gitignore
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
│   ├── outputs.tf
│   └── files/index.html
└── ansible/
    ├── ansible.cfg          # inventory plugin + SSM defaults
    ├── aws_ec2.yml          # dynamic inventory (discover by tag)
    ├── playbook.yml         # install nginx, render page, start service
    └── templates/index.html.j2
```

## Deploying the infrastructure

All Terraform commands run through aws-vault, which handles the assume-role and MFA prompt:

```
cd terraform
aws-vault exec terraform -- terraform init
aws-vault exec terraform -- terraform plan
aws-vault exec terraform -- terraform apply
```

`apply` prints the outputs, including the load balancer DNS name used to reach the site.

Note: the NAT Gateway and ALB begin billing on `apply` and run hourly. This project is destroyed between work sessions and rebuilt with a single `apply`, so nothing accrues overnight.

## Configuring the instance

Ansible runs from the Linux control node (WSL on Windows). It connects to the instances over AWS Systems Manager Session Manager, not SSH: no bastion, no key pair, no open port 22. The instances are discovered dynamically by tag, so nothing is hardcoded and the same commands work after any rebuild.

Load short-lived credentials into the shell (Ansible cannot answer the MFA prompt itself, so the session is obtained once and exported):

```
cd ansible
export ANSIBLE_CONFIG=$(pwd)/ansible.cfg   # only needed on the Windows mount (world-writable dir)
aws sts get-caller-identity --profile terraform
eval $(aws configure export-credentials --profile terraform --format env)
```

Confirm discovery and connectivity, then run the playbook:

```
ansible-inventory --graph      # should list both instances under server_1 and server_2
ansible all -m ping            # should return "pong" from each instance over SSM
ansible-playbook playbook.yml
```

The playbook installs nginx, renders the page from a Jinja2 template, and starts the service. Once nginx serves HTTP 200, the ALB health check passes and traffic flows.

## Accessing the web page

The live URL is the ALB DNS name, printed as the `alb_dns_name` output after `terraform apply`:

```
Live URL:  http://<alb_dns_name>          (http only; see HTTPS note in scanning triage)
```

Note: the ALB DNS name is regenerated on every rebuild, so the URL changes each time the stack is destroyed and re-applied. The URL submitted for evaluation is taken from the final `apply` performed immediately before submission.

The page reports each server's real Availability Zone and instance ID, read from live instance metadata, so refreshing across requests demonstrates the load balancer distributing traffic across both AZs. To observe the distribution reliably (browsers reuse connections and appear to stick to one server), use fresh connections:

```
for i in $(seq 1 10); do curl -s http://<alb_dns_name> | grep -E "Server|Zone"; echo "---"; done
```

## Explanation of the code

### Terraform

- **Networking (`vpc.tf`):** a /16 VPC with two public and two private subnets across two AZs. Public subnets route to the Internet Gateway; private subnets route outbound through a single NAT Gateway. Route tables are what actually enforce the public/private distinction.
- **Storage (`s3.tf`):** a uniquely named bucket (suffixed with the account ID for global uniqueness), hardened as described above, holding `index.html`.
- **Identity (`iam.tf`):** the instance role and profile, scoped to read a single S3 object, plus the managed SSM policy. Trust policy and permission policy are separate concerns (who may assume vs. what the role may do).
- **Security groups (`security-group.tf`):** the ALB SG (public on 80) and the instance SG (trusts only the ALB SG). The one-directional reference avoids a Terraform dependency cycle.
- **Endpoint (`endpoints.tf`):** an S3 Gateway VPC endpoint associated with the private route table, so S3 traffic stays on the AWS network and does not traverse the NAT.
- **Load balancer (`alb.tf`):** the internet-facing ALB across both public subnets, a target group with an HTTP health check on `/`, and a listener forwarding port 80 to the group.
- **Compute (`ec2.tf`):** two instances (`count = 2`), one per private subnet so one per AZ, each with the instance profile, no public IP, IMDSv2 required, and an encrypted root volume. The AMI is looked up (latest Amazon Linux 2023) rather than hardcoded. Both register into the ALB target group.

### Ansible

- **Dynamic inventory (`aws_ec2.yml`):** the `amazon.aws.aws_ec2` plugin queries EC2 at runtime, filtering on `tag:Project = challenge3` and running state, so instances are discovered by tag rather than by hardcoded IP. The `compose` block sets each host to connect via the `aws_ssm` connection, and `keyed_groups` builds `server_1` / `server_2` groups from the `Server` tag.
- **Playbook (`playbook.yml`):** gathers each instance's EC2 metadata, derives the server number from its tag (stored in a clean variable to avoid Ansible's reserved `tags` name), installs nginx via `dnf`, renders `templates/index.html.j2` per host, and enables and starts the service.
- **Template (`templates/index.html.j2`):** shared branding plus each host's real Availability Zone and instance ID, pulled from live metadata so the values cannot be faked. Shared content is common; per-host identity is injected by configuration management.

## IaC security scanning

The Terraform was scanned with Checkov, a policy-as-code tool that checks infrastructure against CIS, NIST, and other frameworks. The point of the exercise is not a clean scan (a zero-findings result on infrastructure this size usually means the tool is not looking hard enough) but documented judgment: every finding is triaged into fix-worthy or accept-with-rationale.

```
python3 -m checkov -d terraform/ --compact --quiet
```

**Result: 76 passed, 24 failed.** The 76 passes independently confirm the hardening built into this project: the S3 public-access block, encryption, IMDSv2 enforcement, the scoped instance role, the security-group chain, and encrypted volumes are all detected and validated. The Ansible scan passed with no failures.

The 24 failures are triaged below.

### Fix-worthy (remediation staged)

These are legitimate gaps worth closing. The Terraform for them is staged for a follow-up commit and not yet applied at the time of this submission.

- `CKV2_AWS_11` VPC Flow Logs not enabled. The highest-value finding: flow logs are the network audit and incident-response record. Remediation: a CloudWatch log group, a scoped flow-logs IAM role, and an `aws_flow_log` capturing ALL traffic.
- `CKV2_AWS_12` default security group not restricted. Remediation: adopt the VPC's default SG in Terraform and strip it to deny-all.
- `CKV_AWS_91` / `CKV_AWS_18` ALB and S3 access logging not enabled. Remediation: a logging bucket plus access-log configuration on both.

### Accepted: deliberate lab tradeoffs (documented)

- `CKV_AWS_2`, `CKV_AWS_103`, `CKV2_AWS_20`, `CKV_AWS_378`, `CKV_AWS_131` (ALB should use HTTPS / TLS 1.2 / redirect HTTP / drop HTTP headers): all downstream of serving HTTP only. HTTPS requires a registered domain and a TLS certificate, out of scope for this lab. Production terminates TLS at the ALB with an ACM certificate.
- `CKV_AWS_145` S3 not encrypted with a KMS key: SSE-S3 (AES256) is used instead. A customer-managed KMS key adds rotation, a key policy, and CloudTrail on decrypt, deferred as a cost tradeoff.
- `CKV_AWS_150` ALB deletion protection disabled: intentionally off, because the lab is destroyed and rebuilt between sessions and deletion protection would block teardown. Production would enable it.

### Accepted: fires on intended design

- `CKV_AWS_260` ingress from `0.0.0.0/0` to port 80: fires on the ALB security group, which is the intended public entry point. The instances behind it are not internet-reachable.
- `CKV_AWS_130` subnets assign public IP by default: fires on the public subnets, which legitimately need this for the ALB and NAT. Private subnets, where the workloads run, do not assign public IPs.
- `CKV_AWS_382` egress to `0.0.0.0/0`: the instances need outbound access for package installation via the NAT.

### Accepted: enterprise-scale controls beyond this lab's scope

- `CKV_AWS_144` S3 cross-region replication (DR for critical data), `CKV2_AWS_62` S3 event notifications, `CKV2_AWS_61` S3 lifecycle policy, `CKV_AWS_126` EC2 detailed monitoring, `CKV_AWS_135` EBS optimization, `CKV2_AWS_28` WAF on the ALB. Each is a real production control but unnecessary or cost-adding for a single-region Hello World lab. Production would revisit WAF and lifecycle in particular.

This triage (76 controls validated, 24 findings sorted into fix-now versus accept-with-rationale) is the governance record for the infrastructure, analogous to an exception register: risk is either remediated or consciously accepted with a documented reason, never silently ignored.

## Teardown

To avoid ongoing charges (the NAT Gateway and ALB bill hourly):

```
aws-vault exec terraform -- terraform destroy
```

All resources are Terraform-managed, so `destroy` removes everything cleanly, including the S3 bucket and its object. The `index.html` is re-uploaded from the local `files/` directory on the next `apply`, so the source of truth is the repository, not the running bucket.

## Cost and tradeoffs

- Single NAT Gateway rather than one per AZ: a cost-versus-availability tradeoff; production would run one per AZ.
- AES256 encryption rather than a customer-managed KMS key: a cost-versus-control tradeoff.
- S3 versioning without a lifecycle expiry rule: acceptable for a lab, would be added in production.
- HTTP only (no TLS): the lab has no registered domain; production terminates HTTPS at the ALB with an ACM certificate.
- Several fix-worthy scanner findings (flow logs, default SG lockdown, access logging) are staged for a follow-up rather than applied at submission time.
