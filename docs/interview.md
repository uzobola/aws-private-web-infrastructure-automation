# Interview Guide

Use these as talking beats, not a script.

Deeper write-ups: [architecture.md](architecture.md), [security-model.md](security-model.md), [installation.md](installation.md).

## Project Summary

This project is a two-AZ AWS web architecture provisioned with Terraform and configured with Ansible.

The application runs on private EC2 instances behind an internet-facing Application Load Balancer. The instances have no public IP addresses and expose no SSH access.

Terraform owns infrastructure lifecycle.

Ansible discovers the EC2 instances dynamically and configures nginx through AWS Systems Manager.

The project separates Terraform, Ansible, EC2 workload, and AWS service identities rather than using one broad AWS identity for every operation.

---

## 60-Second Project Explanation

I built a two-AZ AWS web architecture using Terraform and Ansible.

Terraform provisions the VPC, public and private subnets, Application Load Balancer, two private EC2 instances, NAT Gateway, IAM roles, security groups, S3 transfer bucket, VPC Flow Logs, and CloudWatch logging. The instance role has SSM managed-node access and no SSH path.

Ansible handles host configuration. It discovers the EC2 instances dynamically through AWS tags, connects through Systems Manager rather than SSH, installs nginx, and renders a host-specific page using live EC2 metadata.

I separated Terraform and Ansible execution roles so configuration management does not inherit infrastructure-provisioning authority. The EC2 workload role has Systems Manager permissions but no application S3 permission.

I tested permitted operations, denied operations, multi-AZ traffic distribution, Ansible idempotence, and Checkov findings. I documented security exceptions where a scanner recommendation did not fit the lab architecture.

---

## Terraform vs Ansible

### How do Terraform and Ansible work together?

Terraform provisions infrastructure.

Ansible configures the operating system and application running on that infrastructure.

In this project:

```text
Terraform
   |
   +--> VPC
   +--> subnets
   +--> ALB
   +--> EC2
   +--> IAM
   +--> S3
   +--> logging

Ansible
   |
   +--> discover EC2
   +--> install nginx
   +--> render application page
   +--> manage nginx service
```

Terraform tags the EC2 instances.

Ansible dynamic inventory queries AWS and discovers those instances through the tags.

This avoids hardcoded instance IDs or IP addresses.

Tags are the discovery scope. SSM `StartSession` is authorized on the exact Terraform-created EC2 instance ARNs, not on the tag alone.

### Why not use Terraform provisioners to install nginx?

Terraform is strongest when it manages infrastructure state.

Host configuration is a separate lifecycle.

Using Ansible keeps package installation, service configuration, templates, and idempotent host management outside Terraform state.

That separation makes failures easier to isolate:

```text
Infrastructure problem
        |
        v
Terraform / AWS

Host configuration problem
        |
        v
Ansible / OS
```

### What is dynamic inventory?

Static inventory explicitly lists hosts.

Example:

```text
10.0.1.20
10.0.2.31
```

Dynamic inventory queries a source at runtime.

This project queries AWS EC2 and selects running instances with the Challenge 3 project tag.

That fits cloud infrastructure since instances may be destroyed and recreated with different IDs or IP addresses.

### What do the main Ansible files do?

```text
ansible.cfg
    |
    v
How Ansible operates

aws_ec2.yml
    |
    v
Which machines Ansible discovers

playbook.yml
    |
    v
What state those machines should reach

templates/index.html.j2
    |
    v
What application content gets rendered

group_vars/all.yml
    |
    v
Shared SSM connection values
```

### What is idempotence?

Idempotence means repeated execution reaches the same desired state without making unnecessary changes once the target state has converged.

I validated this directly.

The second Ansible run completed on both EC2 instances with:

```text
changed=0
unreachable=0
failed=0
```

That gave me runtime proof rather than relying only on the playbook syntax.

---

## IAM

### What is the difference between a trust policy and a permission policy?

A trust policy answers: who may assume this role?

A permission policy answers: what may the role do after it is assumed?

In this project, the Ansible execution-role trust policy permits the verified human IAM principal to assume the role with MFA.

The Ansible permission policy grants only its configuration-management operations.

### What is the difference between an IAM role and an EC2 instance profile?

The IAM role is the AWS identity.

It contains the trust relationship and receives permissions.

The instance profile is the container EC2 uses to receive that role.

```text
IAM Role
    |
    v
Instance Profile
    |
    v
EC2
```

The web instances receive `challenge3-web-instance-role` through an instance profile.

### Why separate Terraform and Ansible execution roles?

Terraform has infrastructure-lifecycle responsibilities.

It may need authority to create or remove VPC resources, EC2 instances, IAM resources, load-balancer resources, and other infrastructure.

Ansible needs much less:

- EC2 discovery
- SSM session access
- S3 transfer-bucket access

Using the Terraform role for Ansible would give configuration management infrastructure authority it does not need.

The separate role reduces blast radius and permission accumulation.

### Why doesn't the EC2 role have S3 application permissions?

The original design granted the EC2 role `s3:GetObject` for a webpage stored in S3.

After tracing the real application path, I found that Ansible renders the Jinja template directly onto the EC2 filesystem.

The EC2 workload therefore had no application reason to read the S3 object.

I removed the permission.

The S3 bucket remains in the architecture for Ansible's SSM transfer path.

The security principle is: a narrowly scoped unnecessary permission is still unnecessary permission.

### Does EC2 need S3 IAM access for Ansible's SSM transfer path?

No direct application-level S3 permission is required on the EC2 workload role for this implementation.

The Ansible controller uses the transfer bucket as part of the SSM connection path.

I confirmed that the web-instance role could still be managed through Ansible and SSM after removing its application S3 permission.

I then ran an S3 enumeration command from the EC2 instances and confirmed `AccessDenied`.

### How did you test least privilege?

I tested both allowed and denied operations.

Allowed examples:

- Ansible dynamic EC2 discovery
- SSM connectivity
- S3 transfer operations needed by Ansible

Denied examples:

- EC2 workload → account-wide S3 enumeration
- Ansible role → unrelated IAM administration
- Ansible role → account-wide S3 enumeration

This matters since a policy that works does not prove it is narrow.

---

## Systems Manager

### Why use Systems Manager instead of SSH?

The EC2 instances have:

- no public IP
- no inbound port 22
- no SSH key pair requirement
- no bastion host

Systems Manager gives the management path without introducing an inbound SSH path.

Ansible uses the `amazon.aws.aws_ssm` connection plugin.

### What identities participate in the SSM path?

There are no SSM interface VPC endpoints. The agent reaches Systems Manager outbound through the NAT Gateway.

```text
Ansible controller
      |
      v
challenge3-ansible-execution-role
      |
      v
Systems Manager
      ^
      |
SSM Agent on EC2
      |
      | outbound via NAT
      v
NAT Gateway

challenge3-web-instance-role
      |
      v
SSM Agent (managed-node permissions)
```

The controller identity and managed-node identity have different responsibilities.

---

## Networking

### What makes a subnet public?

The route table.

A public subnet has a route such as:

```text
0.0.0.0/0 -> Internet Gateway
```

Automatic public-IP assignment is a separate setting.

I disabled `map_public_ip_on_launch` on the public subnets. The subnets remain public through their Internet Gateway route.

That reduces the chance that a future EC2 instance launched into those subnets receives a public address automatically.

### Why are the EC2 instances private?

The Application Load Balancer is the public application boundary.

The EC2 instances:

- have no public IP
- run in private subnets
- accept HTTP only from the ALB security group

The user reaches:

```text
Internet
   |
   v
ALB
   |
   v
private EC2
```

rather than connecting directly to the compute tier.

### Is the architecture fully independent across two Availability Zones?

No.

The application-serving tier spans two Availability Zones:

- ALB
- two private subnets
- two EC2 instances

The architecture uses one NAT Gateway to control lab cost.

That creates a single dependency for outbound private-subnet traffic.

For a production architecture requiring independent AZ egress, I would deploy one NAT Gateway per AZ and route each private subnet to its local NAT Gateway.

---

## S3

### What is the S3 bucket used for?

It is a dedicated Ansible/SSM transfer bucket.

It is not the source of the webpage.

Controls include:

- Block Public Access
- Bucket Owner Enforced
- SSE-S3
- versioning suspended
- one-day object expiration
- one-day incomplete multipart-upload cleanup
- `force_destroy` for lab teardown

### Why is versioning suspended?

Versioning is often useful for durable data.

This bucket carries temporary Ansible transfer payloads.

Retaining deleted temporary payloads as historical object versions would work against the intended short-lived data lifecycle.

The control was selected based on the workload rather than applying a generic S3 rule mechanically.

---

## Security Scanning

### How did you use Checkov?

I used Checkov as a control-assessment tool.

I did not treat every finding as an instruction to modify infrastructure.

Each finding was classified as one of:

- remediate
- accepted risk
- tool/context mismatch
- not applicable

Examples of controls I remediated include:

- automatic subnet public-IP assignment
- ALB invalid-header handling
- EC2 detailed monitoring
- security-group egress
- S3 transfer cleanup
- VPC Flow Logs
- default security-group lockdown

Examples I accepted or classified by context include:

- WAF for a temporary static lab
- cross-region replication for transient transfer data
- one-year retention for lab Flow Logs
- customer-managed KMS for short-lived lab resources

### Tell me about a scanner finding you rejected.

Checkov flagged the EC2 instances for explicit EBS optimization.

I initially considered setting `ebs_optimized = true`.

The Terraform plan then showed that both EC2 instances would be replaced.

AWS documents the T3 family as EBS-optimized by default.

So the proposed change created infrastructure churn without improving the effective runtime state.

I removed the explicit setting and documented the finding as a scanner-context mismatch.

The lesson was to examine the control objective, provider behavior, and operational impact before applying scanner recommendations.

---

## Terraform State and Recovery

### What happened during the partial Terraform apply?

The first deployment created many AWS resources successfully, then failed when Terraform attempted to create the Ansible execution role.

The role trust policy referenced an IAM user called `grc-engineer`.

AWS rejected it as an invalid principal.

I used STS to inspect the actual source identity and discovered:

```text
local AWS Vault profile: grc-engineer
actual IAM user:         grc-engineer01
```

The trust policy was corrected.

Terraform had already written successfully created resources into state.

A fresh plan then proposed:

```text
2 to add
0 to change
0 to destroy
```

I applied only the two resources that had failed rather than rebuilding the environment.

### What did that teach you about Terraform state?

Terraform does not wait until the entire apply succeeds before recording all successful work.

Resources that complete can be written into state before a later resource fails.

After a partial apply, I should:

- inspect the failure
- inspect state
- fix the configuration
- create a fresh plan
- review the new plan
- continue from state

I should not blindly rerun an old saved plan or tear everything down.

---

## AWS Authentication

### What is the difference between an AWS profile and AWS identity?

A local profile is workstation configuration.

It may contain settings such as:

- source profile
- role ARN
- region
- MFA serial

The effective AWS identity is what AWS sees after authentication and role assumption.

I use `aws sts get-caller-identity` to verify the actual principal.

This caught the difference between the local `grc-engineer` profile name and the real IAM user `grc-engineer01`.

### How did temporary credential expiration present itself?

An expired AWS Vault STS session caused `RequestExpired` during Ansible EC2 inventory discovery.

That was an authentication/session-lifetime problem.

It was not an IAM authorization problem.

The correct fix was to refresh the temporary session, not loosen IAM permissions.

---

## VPC Flow Logs

### How did you protect the Flow Logs role trust policy?

The role trusts `vpc-flow-logs.amazonaws.com`.

The trust policy adds:

- `aws:SourceAccount`
- `aws:SourceArn`

to constrain the service-assumption context and reduce confused-deputy exposure.

### Why does one CloudWatch Logs permission use Resource = "*"?

Some AWS API operations do not support resource-level ARN restriction.

`logs:DescribeLogGroups` is one such operation.

For actions that support resource scoping, the policy uses the project log-group ARN.

Least privilege means using the narrowest authority AWS actually supports, not mechanically removing every wildcard.

---

## Failure Troubleshooting Model

When Ansible fails, I separate the path into layers.

1. Identity — `aws sts get-caller-identity`
2. Inventory — `ansible-inventory --graph`
3. Connectivity — `ansible all -m ping`
4. Configuration — `ansible-playbook playbook.yml`
5. Application — `curl` the ALB
6. Load balancing — repeated requests across both hosts

Examples:

| Symptom | Layer |
| --- | --- |
| `RequestExpired` | credential lifetime |
| No inventory parsed | inventory / AWS query failure |
| SSM connection failure | identity, transfer bucket, SSM, or managed node |
| nginx task failure | playbook / OS problem |
| HTTP failure after successful Ansible | application, target health, SG, or ALB problem |

This prevents changing unrelated infrastructure when the failure belongs to a different layer.

---

## Strong Interview Stories

### Story 1 — Partial Terraform apply

**Situation:** Terraform successfully created most infrastructure but failed on an IAM role trust policy.

**Action:** I used STS to verify the source principal, corrected the trust policy, inspected Terraform state, generated a fresh plan, and confirmed only two resources remained.

**Result:** The deployment recovered without rebuilding successful infrastructure.

### Story 2 — Removing unnecessary AWS authority

**Situation:** The EC2 role had a narrowly scoped S3 permission to read one webpage object.

**Action:** I traced the real configuration flow and confirmed Ansible wrote the webpage directly to nginx. The S3 permission served no workload requirement.

**Result:** I removed the permission and later proved the EC2 workload received `AccessDenied` for S3 enumeration while Ansible management still worked.

### Story 3 — Scanner recommendation vs runtime reality

**Situation:** Checkov flagged missing explicit EBS optimization.

**Action:** I added the setting and reviewed the Terraform plan before applying it. Terraform showed both servers would be replaced. I checked AWS behavior and confirmed T3 instances are EBS-optimized by default.

**Result:** I rejected the unnecessary replacement and recorded the finding as a tool/context mismatch.

### Story 4 — Authentication vs authorization

**Situation:** Ansible inventory began failing after previously working.

**Action:** The error was `RequestExpired`. I identified that the temporary STS session had expired.

**Result:** I renewed the AWS Vault session rather than changing IAM permissions.

### Story 5 — Proving idempotence

**Situation:** The Ansible configuration worked successfully.

**Action:** I ran the playbook again after convergence.

**Result:** Both hosts returned `changed=0`, `unreachable=0`, and `failed=0`. That provided direct evidence that the configuration did not keep modifying already-correct systems.

---

## Senior-Level Design Summary

If asked what I would change for production, I would discuss:

- HTTPS with ACM and a registered domain
- WAF based on application threat model
- one NAT Gateway per AZ where independent egress is required
- remote Terraform state with locking
- CI-based Terraform execution using federation
- CI-based Ansible execution with federated identity
- ALB access logging
- longer monitoring/log retention based on policy
- customer-managed KMS where data classification requires it
- autoscaling if workload demand requires it

Those are production extensions, not requirements for the current project.

The project intentionally stays small enough that every component has a defendable purpose.
