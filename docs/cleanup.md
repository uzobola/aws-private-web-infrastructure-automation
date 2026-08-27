# Cleanup and Teardown

## Purpose

Cleanup is part of the project resource lifecycle.

The teardown process removes AWS infrastructure, validates removal of billable resources, records teardown evidence, and reviews local project-specific authentication configuration.

The deploy procedure is in [installation.md](installation.md).

---

## Before Teardown

Do not destroy the environment until final submission evidence has been captured.

Confirm that the final evidence set includes the required application, infrastructure, Ansible, and security proof.

Check Terraform state:

```bash
cd terraform
terraform state list
```

Record the deployed outputs needed for post-destroy checks:

```bash
terraform output
```

Useful values include:

- `alb_dns_name`
- `vpc_id`
- `web_bucket_name`

---

## Capture a Destroy Plan

From Git Bash:

```bash
cd terraform

aws-vault exec terraform -- \
  terraform plan -destroy -out=destroy.tfplan
```

Review the plan.

The destroy plan should contain the Terraform-managed Challenge 3 resources.

Do not proceed if unrelated AWS resources appear in the destroy plan.

---

## Destroy the Environment

Apply the reviewed destroy plan:

```bash
aws-vault exec terraform -- \
  terraform apply destroy.tfplan
```

Using the saved destroy plan keeps teardown aligned with the reviewed resource set.

---

## Validate Terraform State

After successful destruction:

```bash
terraform state list
```

The expected result is no managed resources.

Capture this terminal result as teardown evidence.

Suggested path: `docs/evidence/teardown/terraform-state-empty.png`

---

## Verify EC2 Removal

```bash
aws-vault exec terraform -- \
  aws ec2 describe-instances \
    --filters \
      "Name=tag:Project,Values=challenge3" \
      "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text
```

No active Challenge 3 EC2 instances should be returned.

---

## Verify Load Balancer Removal

```bash
aws-vault exec terraform -- \
  aws elbv2 describe-load-balancers \
    --query "LoadBalancers[?contains(LoadBalancerName, 'challenge3')].[LoadBalancerName,DNSName]" \
    --output table
```

No Challenge 3 load balancer should remain.

---

## Verify NAT Gateway Removal

```bash
aws-vault exec terraform -- \
  aws ec2 describe-nat-gateways \
    --filter "Name=tag:Project,Values=challenge3" \
    --query 'NatGateways[?State!=`deleted`].[NatGatewayId,State]' \
    --output table
```

No non-deleted Challenge 3 NAT Gateway should remain.

NAT Gateway removal is worth checking since it is a billable resource.

---

## Verify Elastic IP Cleanup

```bash
aws-vault exec terraform -- \
  aws ec2 describe-addresses \
    --filters "Name=tag:Project,Values=challenge3" \
    --query 'Addresses[].{AllocationId:AllocationId,PublicIp:PublicIp}' \
    --output table
```

No Challenge 3 Elastic IP should remain allocated.

---

## Verify S3 Transfer Bucket Removal

If the bucket name was recorded before destroy:

```bash
aws-vault exec terraform -- \
  aws s3api head-bucket \
    --bucket <recorded-bucket-name>
```

The bucket should no longer exist.

The Terraform resource uses `force_destroy`, so temporary transfer objects do not block bucket deletion.

---

## Verify IAM Role Removal

Check the project-specific Ansible role:

```bash
aws-vault exec terraform -- \
  aws iam get-role \
    --role-name challenge3-ansible-execution-role
```

The expected result after teardown is `NoSuchEntity`.

Check the EC2 workload role using the deployed Terraform role name if needed.

Do not remove the shared Terraform execution role if it predates this project and is used outside of the project.

---

## Verify VPC Removal

Use the recorded VPC ID:

```bash
aws-vault exec terraform -- \
  aws ec2 describe-vpcs \
    --vpc-ids <recorded-vpc-id>
```

The project VPC should no longer exist.

---

## Local Authentication Cleanup

The local AWS profile `challenge3-ansible` exists only to assume the Terraform-managed Challenge 3 Ansible role.

After the AWS role is destroyed, review the local AWS configuration and remove that profile if it is no longer needed.

Do not remove these profiles solely as part of this project's teardown:

- `grc-engineer`
- `terraform`
- `ansible`

Those profiles have separate purposes.

---

## Temporary AWS Sessions

AWS Vault sessions are temporary.

Exit project WSL shells after teardown.

AWS Vault session state can be reviewed from Git Bash:

```bash
aws-vault list
```

No long-lived project credential is stored on the EC2 instances.

---

## Local Terraform State

Terraform state is excluded from Git.

After teardown has succeeded and removal checks are complete, the local state files may be archived securely or deleted.

Do not delete Terraform state before teardown.

---

## Teardown Evidence

Keep teardown evidence small.

Recommended final evidence:

```text
docs/evidence/teardown/
├── terraform-destroy-success.png
└── terraform-state-empty.png
```

A single screenshot should prove one meaningful cleanup claim.

---

## Cleanup Completion Criteria

Teardown is complete when:

- Terraform reports successful destruction
- Terraform state contains no managed Challenge 3 resources
- EC2 instances are gone
- ALB is gone
- NAT Gateway is gone
- Elastic IP is released
- transfer bucket is gone
- project IAM roles are gone
- VPC is gone
- local project-specific AWS profile has been reviewed

The project is not considered fully closed until billable AWS resources and obsolete machine identities have been removed.
