module "acm" {
  source  = "terraform-aws-modules/acm/aws"
  version = "~> 3.0"

  domain_name  = var.domain_name
  zone_id      = aws_route53_zone.default.id

  subject_alternative_names = [
    "*.${var.domain_name}"
  ]

  wait_for_validation = true

  tags = {
    Name = var.domain_name
  }
}


resource "aws_lb" "gateway_legacy_alb" {
  name               = "gateway-legacy-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.web.id]
  subnets            = aws_subnet.public[*].id
}

resource "aws_lb_target_group" "gateway_legacy_tg" {
  name        = "gateway-legacy-tg"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.default.id
  target_type = "ip"
  health_check {
    enabled = true
    path    = "/health"
  }
  depends_on = [aws_lb.gateway_legacy_alb]
}

resource "aws_lb_listener" "gateway_legacy_lb_http" {
  load_balancer_arn = aws_lb.gateway_legacy_alb.arn
  port              = "80"
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

resource "aws_lb_listener" "gateway_legacy_lb_https" {
  certificate_arn   = module.acm.acm_certificate_arn
  load_balancer_arn = aws_lb.gateway_legacy_alb.arn
  port              = "443"
  protocol          = "HTTPS"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.gateway_legacy_tg.arn
  }
}
