data "aws_secretsmanager_secret_version" "tailscale_relay_key" {
  secret_id = "${var.environment}/gateway-legacy/tailscale"
}

resource "aws_security_group" "tailscale" {
  name = "tailscale-sg"
  description = "Allow tailscale relay vpc inbound traffic"
  vpc_id = aws_vpc.default.id

  ingress {
    description = "Allow all secure web traffic"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow all secure web traffic"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow all non-secure web traffic temporarily"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow SSH from local network."
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.default.cidr_block]
  }

  # Allow egress to the internet
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "tailscale-relay-${var.environment}"
  }
}

resource "aws_instance" "tailscale-relay" {
  ami = var.ami_ubuntu_latest
  instance_type = "t4g.micro"

  # Refer to the security group we just created
  vpc_security_group_ids = [aws_security_group.tailscale.id]
  subnet_id = aws_subnet.public[0].id

  user_data = templatefile("tailscale-relay-init.sh.tftpl", {
    subnets_to_advertise = join(",", aws_subnet.private[*].cidr_block)

    tailscale_auth_key = data.aws_secretsmanager_secret_version.tailscale_relay_key.secret_string
    vpc_ip_cidr = aws_subnet.public[0].cidr_block
    internal_domain = "internal.${var.domain_name}"
  })

  lifecycle {
    create_before_destroy = true
  }

  /*
    In case you need to manually ssh for recovery, you will need to enable a key for ssh access.
    Normally we are running the instance without any key since we don't need ssh access

    Uncomment key_name to apply a key if needed
    key_name = <your key>
  */

  tags = {
    Name = "tailscale-relay"
  }
}
