# Security Model

Paths, subnets, and Terraform/Ansible ownership are in [architecture.md](architecture.md). This document covers identities, IAM boundaries, and scanner decisions.

## Security Objectives

The project applies a small set of security goals:

- keep EC2 application hosts private
- avoid SSH exposure
- use temporary AWS credentials
- separate provisioning authority from configuration authority
- grant workloads only the AWS authority they need
- protect the S3 transfer bucket from public access
- log VPC network activity
- test denied actions alongside permitted actions
- record scanner findings that are consciously accepted

---

## Identity Inventory

| Identity | Type | Purpose |
| --- | --- | --- |
| `grc-engineer01` | Human IAM principal | Starting AWS identity |
| `TerraformExecutionRole` | Automation execution role | Terraform infrastructure lifecycle |
| `challenge3-ansible-execution-role` | Automation execution role | Ansible discovery and SSM configuration |
| `challenge3-web-instance-role` | EC2 workload role | Systems Manager managed-node access |
| Flow Logs IAM role | AWS service role | Publish VPC Flow Logs to CloudWatch |
| nginx | Application process | Serve HTTP; no AWS API authority |

---

## Human Authentication Path

AWS Vault stores the source credential outside the repository.

Role assumption requires MFA.

```text
AWS Vault
    |
    v
grc-engineer01
    |
    | MFA
    | STS AssumeRole
    v
Temporary role credentials
```

Long-lived AWS credentials are not stored in Terraform, Ansible, or application configuration.

---

## Terraform Execution Identity

```text
grc-engineer01
      |
      | MFA + STS
      v
TerraformExecutionRole
      |
      v
AWS infrastructure lifecycle
```

Terraform requires broader AWS authority than Ansible since it creates and destroys cloud infrastructure.

The Terraform identity is kept separate from the Ansible identity.

---

## Ansible Execution Identity

```text
grc-engineer01
      |
      | MFA + STS
      v
challenge3-ansible-execution-role
```

The role is scoped to the operations required by the configuration path.

It can:

- discover EC2 instances
- start approved SSM sessions to the Terraform-created Challenge 3 instances
- operate its S3 transfer path
- clean up its SSM sessions

It cannot perform general infrastructure administration.

Negative tests confirmed denied unrelated actions.

Evidence: [docs/evidence/security/ansible-role-least-privilege-deny.png](evidence/security/ansible-role-least-privilege-deny.png)

---

## Ansible Role Trust Policy

The Ansible role trusts the verified IAM user `grc-engineer01`.

MFA is required by the role trust policy.

This moves the MFA requirement into an AWS-enforced trust control rather than relying only on workstation configuration.

The local AWS Vault profile is named `grc-engineer`.

The local profile name is configuration metadata, not the AWS IAM username.

STS `GetCallerIdentity` was used to verify the real source principal before the trust policy was corrected.

---

## Ansible Authorization Boundary

Dynamic inventory uses tags for host discovery.

IAM uses the exact Terraform-created EC2 instance ARNs for SSM authorization.

```text
AWS tags
    |
    v
Discovery scope

Exact EC2 ARNs
    |
    v
Authorization scope
```

This avoids relying on mutable tags as the sole SSM authorization boundary.

---

## EC2 Workload Identity

Each web server receives `challenge3-web-instance-role` through an EC2 instance profile.

The role trusts the EC2 service and carries the Systems Manager managed-node permissions required by the SSM Agent.

The EC2 workload does not receive application-level S3 access.

```text
EC2
 |
 v
challenge3-web-instance-role
 |
 +--> Systems Manager access
 X--> account-wide S3 access
```

A negative test ran `aws s3api list-buckets` from both EC2 instances.

Both requests returned `AccessDenied`.

Evidence: [docs/evidence/security/web-instance-s3-denied.png](evidence/security/web-instance-s3-denied.png)

---

## Why nginx Has No AWS Identity

nginx serves a static page from the EC2 filesystem.

It does not:

- call AWS APIs
- read application data from S3
- access Secrets Manager
- access DynamoDB
- assume AWS roles

The application runs in AWS without requiring application AWS authority.

This reduces the workload's IAM attack surface.

---

## S3 Transfer Bucket

The S3 bucket exists for Ansible's SSM transfer mechanism.

It is not an application-content bucket.

Security controls include:

- Block Public Access
- Bucket Owner Enforced ownership
- SSE-S3
- versioning suspended
- one-day object expiration
- one-day incomplete multipart-upload cleanup
- Terraform `force_destroy`

The Ansible controller has the required object-transfer actions for this bucket.

The EC2 workload role does not receive direct application S3 permissions.

Ansible transfer cleanup was validated after configuration runs.

Evidence: [docs/evidence/security/ansible-transfer-bucket-clean.png](evidence/security/ansible-transfer-bucket-clean.png)

---

## SSH Elimination

The architecture exposes no SSH listener.

There is:

- no inbound port 22 security-group rule
- no bastion host
- no application EC2 public IP
- no SSH key pair required for Ansible

Configuration management uses Systems Manager.

This removes an inbound administration path from the VPC design.

---

## EC2 Metadata Protection

EC2 requires IMDSv2.

This limits access to instance metadata through session-oriented metadata tokens rather than permitting IMDSv1 requests.

The root EBS volume is encrypted.

Detailed EC2 monitoring is enabled.

---

## Network Boundary

The Application Load Balancer is the public application boundary.

The EC2 instances accept port 80 only from the ALB security group.

```text
Internet
   |
   v
ALB SG
   |
   v
EC2 SG
   |
   v
nginx
```

Private EC2 instances do not receive public IPv4 addresses.

---

## VPC Flow Logs

VPC Flow Logs capture all traffic and publish to CloudWatch Logs.

The service-role trust policy limits assumption with:

- `aws:SourceAccount`
- `aws:SourceArn`

The CloudWatch permission policy separates API operations that support resource-level scoping from operations that require `Resource = "*"`.

This keeps the IAM policy aligned with AWS API authorization behavior.

---

## Default Security Group

The default VPC security group is explicitly managed with no ingress or egress rules.

Application traffic uses dedicated security groups.

This prevents accidental future use of the permissive default security-group behavior.

---

## Security Validation

Validation included positive tests and negative tests.

### Positive tests

Verified:

- Terraform infrastructure provisioning
- SSM registration
- Ansible dynamic inventory
- SSM connectivity
- nginx configuration
- ALB application reachability
- multi-AZ traffic distribution
- VPC Flow Logs
- Ansible idempotence

### Negative tests

Verified:

- EC2 workload cannot enumerate S3 buckets
- Ansible controller cannot perform unrelated IAM administration
- Ansible controller cannot enumerate account-wide S3 buckets

A security model is incomplete when it proves only successful permissions.

---

## Checkov Assessment

Terraform was scanned with Checkov.

Scanner findings were treated as control-review inputs rather than automatic implementation requirements.

Controls were placed into four categories:

- remediated
- accepted risk
- tool/context mismatch
- not applicable

Final scan evidence: [docs/evidence/security/checkov-final-scan.png](evidence/security/checkov-final-scan.png)

## Checkov Findings Register

Final scan:

- **132 passed**
- **17 failed**
- **0 skipped**
- **16 distinct remaining controls**

17 failed checks map to 16 distinct controls; `CKV_AWS_135` fires once per instance.

The remaining findings were reviewed against the deployed architecture rather than treated as automatic remediation requirements.

| Finding | Status | Decision |
| --- | --- | --- |
| `CKV_AWS_91` ALB access logging | Accepted for lab | ALB access logging would require a dedicated logging bucket and extra configuration beyond this short-lived lab |
| `CKV_AWS_150` ALB deletion protection | Accepted for lab | Disabled intentionally so the environment can be destroyed cleanly |
| `CKV_AWS_2` ALB listener not HTTPS | Accepted for lab | No registered domain or ACM certificate; production would terminate TLS at the ALB |
| `CKV_AWS_135` EC2 EBS optimization | Tool/context mismatch | Both `t3.micro` instances are EBS-optimized by default; explicitly setting the property caused Terraform to propose instance replacement without changing effective runtime behavior |
| `CKV_AWS_158` CloudWatch Logs KMS encryption | Accepted for lab | AWS-managed encryption selected for short-lived lab logs rather than a customer-managed KMS key |
| `CKV_AWS_338` CloudWatch retention below one year | Accepted for lab | 14-day retention fits the temporary environment and avoids retaining lab network telemetry unnecessarily |
| `CKV_AWS_260` public ingress to port 80 | Intended design | Applies to the internet-facing ALB security group; EC2 instances remain private and accept HTTP only from the ALB security group |
| `CKV_AWS_145` S3 KMS encryption | Accepted for lab | SSE-S3 selected for temporary Ansible transfer data |
| `CKV2_AWS_20` ALB does not redirect HTTP to HTTPS | Accepted for lab | HTTPS is not configured in this domain-less lab |
| `CKV_AWS_378` ALB-to-target HTTP | Accepted for lab | Backend HTTP is restricted to the ALB-to-EC2 security-group path |
| `CKV_AWS_103` TLS policy | Accepted for lab | No HTTPS listener exists in the current lab architecture |
| `CKV_AWS_18` S3 access logging | Accepted for lab | Transfer bucket contains short-lived automation artifacts; separate S3 access-logging infrastructure was not added |
| `CKV_AWS_21` S3 versioning | Intentional exception | Versioning is suspended so deleted temporary Ansible payloads do not remain as historical object versions |
| `CKV2_AWS_62` S3 event notifications | Not applicable | The transfer bucket has no event-driven consumer |
| `CKV_AWS_144` S3 cross-region replication | Not applicable | Bucket contains transient automation-transfer data rather than durable application data |
| `CKV2_AWS_28` WAF on public ALB | Accepted for lab | Static short-lived application; WAF would be considered for a production internet-facing workload |

### Remediations completed before the final scan

The final architecture already incorporated several Checkov-driven hardening changes:

- VPC Flow Logs enabled
- default VPC security group locked down
- ALB invalid-header dropping enabled
- EC2 detailed monitoring enabled
- public-subnet automatic public-IP assignment disabled
- ALB and EC2 egress narrowed
- S3 lifecycle expiration added
- incomplete multipart uploads cleaned after one day

---

## Scanner Finding Example: EBS Optimization

Checkov flagged explicit EBS optimization.

A Terraform plan showed:

```text
aws_instance.web[0] must be replaced
aws_instance.web[1] must be replaced
```

AWS documents T3 instances as EBS-optimized by default.

The explicit setting was rejected rather than replacing two healthy EC2 instances solely to satisfy scanner syntax.

This demonstrates the difference between scanner output and effective platform behavior.

---

## Partial Apply and IAM Trust Failure

The first Terraform deployment partially succeeded before creation of the Ansible role failed.

The trust policy referenced `grc-engineer` as an IAM username.

STS showed that the real IAM principal was `grc-engineer01`.

Terraform had already recorded the successful resources in state.

The trust principal was corrected, a fresh plan was created, and Terraform proposed only:

```text
2 to add
0 to change
0 to destroy
```

The deployment continued without rebuilding the successful infrastructure.

---

## Credential Expiration

AWS Vault provides temporary STS credentials.

An expired session caused `RequestExpired` during EC2 inventory discovery.

The fix was session renewal rather than IAM-policy modification.

This distinction separates authentication/session-lifetime failures from authorization failures.
