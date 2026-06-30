resource "aws_security_group" "alb" {
  name_prefix = "${local.name_prefix}-alb-"
  description = "Security group for ALB"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-alb-sg"
  })
}

resource "aws_security_group" "app" {
  name_prefix = "${local.name_prefix}-app-"
  description = "Security group for application EC2 instances"
  vpc_id      = aws_vpc.main.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-app-sg"
  })
}

# Internet -> ALB : HTTP
resource "aws_vpc_security_group_ingress_rule" "alb_http_ipv4" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow HTTP from the internet"

  ip_protocol = "tcp"
  from_port   = 80
  to_port     = 80
  cidr_ipv4   = "0.0.0.0/0"
}

# ALB -> Internet : outbound
resource "aws_vpc_security_group_egress_rule" "alb_all_outbound_ipv4" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow all outbound traffic from ALB"

  ip_protocol = "-1"
  cidr_ipv4   = "0.0.0.0/0"
}

# ALB -> EC2 : application port
resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id = aws_security_group.app.id
  description       = "Allow application traffic from ALB"

  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
  referenced_security_group_id = aws_security_group.alb.id
}

# EC2 -> Internet : outbound
resource "aws_vpc_security_group_egress_rule" "app_all_outbound_ipv4" {
  security_group_id = aws_security_group.app.id
  description       = "Allow all outbound traffic from application instances"

  ip_protocol = "-1"
  cidr_ipv4   = "0.0.0.0/0"
}