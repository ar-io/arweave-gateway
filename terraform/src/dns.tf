resource "aws_route53_zone" "default" {
  name = var.domain_name

  tags = {
    Environment = var.environment
  }
}


resource "aws_route53_record" "ar_prod_base_a_record" {
  count    = var.environment == "prod" ? 1 : 0

  zone_id = aws_route53_zone.default.id

  name    = "ar-prod.io"
  type    = "A"

  alias {
    name                   = aws_lb.gateway_legacy_alb.dns_name
    zone_id                = aws_lb.gateway_legacy_alb.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "ar_prod_base_aaaa_record" {
  count    = var.environment == "prod" ? 1 : 0

  zone_id = aws_route53_zone.default.id

  name    = "ar-prod.io"
  type    = "AAAA"

  alias {
    name                   = aws_lb.gateway_legacy_alb.dns_name
    zone_id                = aws_lb.gateway_legacy_alb.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "ar_prod_a_www_record" {
  count    = var.environment == "prod" ? 1 : 0

  zone_id = aws_route53_zone.default.id

  name    = "www.ar-prod.io"
  type    = "A"

  alias {
    name                   = aws_lb.gateway_legacy_alb.dns_name
    zone_id                = aws_lb.gateway_legacy_alb.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "ar_prod_aaaa_www_record" {
  count    = var.environment == "prod" ? 1 : 0

  zone_id = aws_route53_zone.default.id

  name    = "www.ar-prod.io"
  type    = "AAAA"

  alias {
    name                   = aws_lb.gateway_legacy_alb.dns_name
    zone_id                = aws_lb.gateway_legacy_alb.zone_id
    evaluate_target_health = true
  }
}
