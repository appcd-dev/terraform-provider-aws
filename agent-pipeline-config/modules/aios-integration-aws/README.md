# AIOS Integration — AWS

Provisions an AWS cloud integration with JIT credentials via Vault IAM role assumption.

## Usage

```hcl
module "aws_integration" {
  source = "github.com/appcd-dev/solutions//modules/aios-integration-aws"

  aws_role_arn = "arn:aws:iam::123456789012:role/SREReadOnly"
  aws_region   = "us-west-2"
}
```

## What It Creates

| Resource | Description |
|----------|-------------|
| `sg_secret` | Vault secret storing the AWS role ARN and region |
| `sg_guild_integration` | Containerized AWS CLI MCP integration |

## Outputs

| Name | Description |
|------|-------------|
| `integration_name` | Name to pass to agent modules |
| `integration_id` | Integration resource ID |
| `secret_id` | Vault secret ID |
