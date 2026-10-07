# VPC module

![Terraform](https://img.shields.io/badge/Terraform-844FBA?style=for-the-badge&logo=terraform&logoColor=white)
![Amazon VPC](https://img.shields.io/badge/Amazon%20VPC-8C4FFF?style=for-the-badge)
![NAT Gateway](https://img.shields.io/badge/NAT%20Gateway-8C4FFF?style=for-the-badge)
![Route 53](https://img.shields.io/badge/Route%2053-8C4FFF?style=for-the-badge)


The network for the HashiCorp stack: a three-tier VPC across three availability
zones, with internet and NAT gateways, a private hosted zone, and optional IPv6.

## Layout

The VPC is divided into sixteen equal blocks (the VPC prefix plus 4 bits). Each
availability zone gets four consecutive blocks, one per tier, and the last four
blocks are left free. With the default `10.16.0.0/16`:

| Tier | Purpose | AZ a | AZ b | AZ c |
|---|---|---|---|---|
| reserved | Held back for future use; no subnet created | `10.16.0.0/20` | `10.16.64.0/20` | `10.16.128.0/20` |
| db | RDS | `10.16.16.0/20` | `10.16.80.0/20` | `10.16.144.0/20` |
| app | Consul, Nomad and Vault nodes | `10.16.32.0/20` | `10.16.96.0/20` | `10.16.160.0/20` |
| web | ALB and the Boundary node | `10.16.48.0/20` | `10.16.112.0/20` | `10.16.176.0/20` |

`10.16.192.0/18` is unallocated.

The predictable layout means a subnet's tier and zone can be read straight from
an IP address, which helps when reading logs and security group rules.

## What it creates

- A VPC with DNS support and DNS hostnames enabled
- Nine subnets: web, app and db in each of the first three availability zones
  that need no opt-in
- An internet gateway, and a public route table for the web tier
- A regional NAT gateway serving all zones, and one private route table shared
  by the app and db tiers
- A DHCP option set that puts the private zone on every instance's DNS search
  path (optional)
- A Route 53 private hosted zone attached to the VPC, with optional records
- With `ipv6_enabled`: an Amazon-provided /56, a /64 per subnet mirroring the
  IPv4 layout, and an egress-only internet gateway for the private tiers

## Design decisions

- **Web tier does not auto-assign public IPs.** Anything that needs one asks for
  it explicitly, as the Boundary node does in its launch template.
- **One NAT gateway, one private route table.** A regional gateway covers every
  zone without a gateway and route table per zone, and this module manages no
  Elastic IP for it.
- **Fixed at three zones.** Raft clusters want three failure domains, so the
  zone count is not configurable.
- **Private zone changes to VPC associations are ignored.** Another VPC, such as
  the disaster-recovery region's, can be associated with the zone outside this
  module without Terraform removing it.
- **Service discovery uses Consul DNS, not this zone.** The private zone is for
  names that should not depend on Consul, such as a stable database alias, and
  for a future internal load balancer.

## Usage

```hcl
module "vpc" {
  source = "./modules/vpc"

  project_name      = var.project_name
  vpc_cidr          = "10.16.0.0/16"
  private_zone_name = "hashicorp-stack.internal"
}
```

Adding a record at the root level:

```hcl
  records = {
    database = {
      name    = "boundary-db"
      type    = "CNAME"
      records = [module.rds.endpoint_address]
    }
  }
```

## Inputs

| Name | Type | Default | Description |
|---|---|---|---|
| `project_name` | `string` | required | Name prefix and `Project` tag for every resource. |
| `vpc_cidr` | `string` | `"10.16.0.0/16"` | IPv4 CIDR of the VPC. |
| `private_zone_name` | `string` | required | Fully qualified private zone name. Must not end in `.local`. |
| `records` | `map(object)` | `{}` | Records to create in the private zone. Each sets either `records` or `alias`. |
| `records_force_destroy` | `bool` | `false` | Delete all records when the zone is destroyed. |
| `enable_dns_hostnames` | `bool` | `true` | Give instances DNS hostnames. |
| `enable_dns_support` | `bool` | `true` | Enable the Amazon-provided DNS resolver. |
| `enable_dhcp_options` | `bool` | `true` | Add the private zone to the instance DNS search path. |
| `map_public_ip_on_launch` | `bool` | `false` | Auto-assign public IPv4 addresses in the web tier. |
| `ipv6_enabled` | `bool` | `false` | Assign IPv6 ranges to the VPC and every subnet. |
| `tags` | `map(string)` | `{}` | Tags merged onto every resource. |

## Outputs

| Name | Description |
|---|---|
| `vpc-id` | ID of the VPC. |
| `vpc-arn` | ARN of the VPC. |
| `vpc-cidr_block` | IPv4 CIDR block of the VPC. |
| `ipv6_cidr_block` | IPv6 CIDR block of the VPC, when enabled. |
| `public_route_table_id` | Route table used by the web tier. |
| `private_route_table_id` | Route table used by the app and db tiers. |
| `web_subnet_ids` | Web tier subnet IDs. |
| `app_subnet_ids` | App tier subnet IDs. |
| `db_subnet_ids` | Database tier subnet IDs. |
| `zone_id` | Private hosted zone ID. |
| `zone_arn` | Private hosted zone ARN. |
| `zone_name` | Private zone name without the trailing dot. |
| `record_fqdns` | Fully qualified name of each record created through `records`. |

## Notes

- **Second region:** give it a CIDR that does not overlap this one, for example
  `10.17.0.0/16`, or the two VPCs cannot be peered.
- **Running cost:** the NAT gateway is the only resource here with a meaningful
  hourly charge. Everything in the app and db tiers depends on it to reach AWS
  APIs and pull images.
- **Other VPC sizes:** subnets are always the VPC prefix plus 4 bits, so a `/16`
  gives `/20` subnets and a `/20` gives `/24`.

## Requirements

| Name | Version |
|---|---|
| Terraform | >= 1.3 |
| AWS provider | ~> 6.0 |