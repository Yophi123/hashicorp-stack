data "aws_route53_zone" "public" {
  name         = var.public_zone_name
  private_zone = false
}

locals {
  tags      = merge(var.tags, { Project = var.project_name })
  zone_name = trimsuffix(data.aws_route53_zone.public.name, ".")
  fqdns     = { for k, s in var.services : k => "${s.hostname}.${local.zone_name}" }
}

## Security group
resource "aws_security_group" "alb" {
  name_prefix = "${var.project_name}-alb-"
  description = "Internet-facing ALB"
  vpc_id      = var.vpc_id

  tags = merge(local.tags, { Name = "${var.project_name}-alb-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "clients" {
  for_each = {
    for pair in setproduct([80, 443], var.allowed_client_cidrs) :
    "${pair[0]}-${pair[1]}" => { port = pair[0], cidr = pair[1] }
  }

  security_group_id = aws_security_group.alb.id
  description       = "Port ${each.value.port} from ${each.value.cidr}"
  cidr_ipv4         = each.value.cidr
  from_port         = each.value.port
  to_port           = each.value.port
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "to_vpc" {
  security_group_id = aws_security_group.alb.id
  description       = "ALB to targets inside the VPC"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "-1"
}

## Certificate
resource "aws_acm_certificate" "this" {
  domain_name       = "*.${local.zone_name}"
  validation_method = "DNS"

  tags = merge(local.tags, { Name = "${var.project_name}-alb-cert" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for o in aws_acm_certificate.this.domain_validation_options : o.domain_name => o
  }

  zone_id         = data.aws_route53_zone.public.zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  certificate_arn         = aws_acm_certificate.this.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

## Load balancer
resource "aws_lb" "this" {
  name               = "${var.project_name}-alb"
  internal           = false
  load_balancer_type = "application"
  subnets            = var.public_subnet_ids
  security_groups    = [aws_security_group.alb.id]

  drop_invalid_header_fields = true
  enable_deletion_protection = var.enable_deletion_protection

  tags = merge(local.tags, { Name = "${var.project_name}-alb" })
}

resource "aws_lb_target_group" "service" {
  for_each = var.services

  name_prefix          = substr("${each.key}-", 0, 6)
  vpc_id               = var.vpc_id
  port                 = each.value.port
  protocol             = "HTTP"
  target_type          = "instance"
  deregistration_delay = var.deregistration_delay

  health_check {
    protocol            = "HTTP"
    port                = tostring(coalesce(each.value.health_port, each.value.port))
    path                = each.value.health_path
    matcher             = each.value.health_matcher
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
    timeout             = 5
  }

  tags = merge(local.tags, { Name = "${var.project_name}-${each.key}-tg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.this.certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not found"
      status_code  = "404"
    }
  }
}

resource "aws_lb_listener_rule" "service" {
  for_each = var.services

  listener_arn = aws_lb_listener.https.arn

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.service[each.key].arn
  }

  condition {
    host_header {
      values = [local.fqdns[each.key]]
    }
  }
}

## DNS
resource "aws_route53_record" "service" {
  for_each = var.services

  zone_id = data.aws_route53_zone.public.zone_id
  name    = local.fqdns[each.key]
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}
