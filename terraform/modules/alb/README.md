# ALB module

![Terraform](https://img.shields.io/badge/Terraform-844FBA?style=for-the-badge&logo=terraform&logoColor=white)
![Application Load Balancer](https://img.shields.io/badge/Application%20Load%20Balancer-8C4FFF?style=for-the-badge)
![ACM](https://img.shields.io/badge/ACM-DD344C?style=for-the-badge)
![Route 53](https://img.shields.io/badge/Route%2053-8C4FFF?style=for-the-badge)

The single public entry point for the stack: an internet-facing Application Load
Balancer with a wildcard certificate, routing HTTPS requests by hostname to
target groups that the `ec2` module's Auto Scaling groups register with.

By design it publishes only Boundary. Every other service is reached through a
Boundary session.

## What it creates

- An internet-facing ALB and its security group, open on 80 and 443 to
  `allowed_client_cidrs` only
- A wildcard ACM certificate for `*.<public_zone_name>`, validated through DNS
- An HTTP listener that redirects to HTTPS, and an HTTPS listener that returns
  404 for unknown hostnames
- One target group, listener rule and Route 53 alias record per service

The public hosted zone is looked up, not created.

## Usage

```hcl
module "alb" {
  source = "./modules/alb"

  project_name      = var.project_name
  vpc_id            = module.vpc.vpc_id
  vpc_cidr          = module.vpc.vpc_cidr
  public_subnet_ids = module.vpc.public_subnet_ids

  public_zone_name     = var.public_zone_name
  allowed_client_cidrs = var.allowed_client_cidrs

  services = {
    boundary = {
      hostname    = "boundary"
      node_group  = "boundary"
      port        = module.ec2.ports.boundary.api
      health_port = module.ec2.ports.boundary.ops
      health_path = "/health"
    }
  }
}
```

This module and `ec2` reference each other: `alb` reads port numbers from `ec2`,
and `ec2` reads target group ARNs from `alb`. That works because the references
are to individual values. Do not add a module-level `depends_on` between them.

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `project_name` | `string` | required | Resource name prefix. |
| `tags` | `map(string)` | `{}` | Tags merged onto every resource. |
| `vpc_id` | `string` | required | VPC for the ALB and target groups. |
| `vpc_cidr` | `string` | required | The only destination the ALB may send traffic to. |
| `public_subnet_ids` | `list(string)` | required | Public subnets in at least two availability zones. |
| `public_zone_name` | `string` | required | Existing Route 53 public hosted zone. |
| `services` | `map(object)` | required | Hostname, node group, port and health check per service. |
| `allowed_client_cidrs` | `list(string)` | required | CIDRs allowed to reach the ALB. |
| `deregistration_delay` | `number` | `30` | Seconds a target drains before deregistering. |
| `enable_deletion_protection` | `bool` | `false` | Deletion protection on the ALB. |

## Outputs

| Name | Description |
|---|---|
| `target_group_arns` | Target group ARNs keyed by node group. |
| `service_urls` | HTTPS URL per published service. |
| `https_listener_arn` | HTTPS listener, for adding application rules. |
| `security_group_id` | Security group attached to the ALB. |
| `dns_name` | The ALB's own DNS name. |
| `zone_id` | The ALB's hosted zone ID, for alias records. |

## Notes

- **Why no NLB:** the account cannot create Network Load Balancers. The Boundary
  worker's proxy port is not HTTP, so it is exposed through the instance's own
  public IP instead of this load balancer.
- **Health checks** for Boundary use its ops listener on a separate port, not
  the API port.
- **Adding an application later:** attach a rule to `https_listener_arn`, or add
  an entry to `services`.

## Requirements

| Name | Version |
|---|---|
| Terraform | >= 1.3 |
| AWS provider | ~> 6.0 |