# Security module
#
# The security groups. Together they form a chain, and each link allows only
# the one thing the next link needs:
#
#   internet --80--> load balancer --8080--> app tasks
#
#   Jenkins: nothing may connect in. It only calls out.
#
# Security groups are stateful allow-lists: anything not allowed is denied, and
# replies to allowed traffic are let through automatically.
#
# Outbound rules are restricted too, not left open. Open outbound access is how
# stolen access sends data out or downloads tools. Each group may only call out
# on the ports it really needs.
#
# Rules are separate resources, not inline blocks. The load balancer group
# refers to the app group and the app group refers to the load balancer group,
# and inline rules would make that a circular dependency.

# --- Load balancer: the only public door ----------------------------------

resource "aws_security_group" "alb" {
  name_prefix = "${var.project}-alb-"
  description = "Load balancer: HTTP in from the internet, app port out to the tasks"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.project}-alb"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each = toset(var.alb_ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "Web traffic from ${each.value}"
  ip_protocol       = "tcp"
  from_port         = var.alb_port
  to_port           = var.alb_port
  cidr_ipv4         = each.value
}

# The load balancer can only talk to the app tasks, on the app port. If it were
# ever compromised, it still could not reach anything else.
resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "Forward requests and health checks to the app tasks"
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port
  referenced_security_group_id = aws_security_group.app.id
}

# --- App tasks: reachable only from the load balancer ----------------------

resource "aws_security_group" "app" {
  name_prefix = "${var.project}-app-"
  description = "App tasks: app port in from the load balancer only, HTTPS out"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.project}-app"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# The source is the load balancer group itself, not an IP range. Only the load
# balancer can connect, and it keeps working when its IP addresses change.
resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "App port from the load balancer only"
  ip_protocol                  = "tcp"
  from_port                    = var.app_port
  to_port                      = var.app_port
  referenced_security_group_id = aws_security_group.alb.id
}

# HTTPS only. Tasks pull their image from ECR and send logs to CloudWatch, and
# both use port 443. The game itself never calls anything, so port 80 stays shut.
resource "aws_vpc_security_group_egress_rule" "app_https" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS to AWS services (ECR image pull, CloudWatch Logs)"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# --- Jenkins: nothing in, only HTTPS and HTTP out -------------------------

resource "aws_security_group" "jenkins" {
  name_prefix = "${var.project}-jenkins-"
  description = "Jenkins: no inbound rules at all, HTTPS and HTTP out"
  vpc_id      = var.vpc_id

  tags = {
    Name = "${var.project}-jenkins"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# There is deliberately no ingress rule for Jenkins. Nobody connects to it, not
# even you: admin access goes through SSM Session Manager, which works over an
# outbound connection the server opens itself. Port 22 stays closed.

resource "aws_vpc_security_group_egress_rule" "jenkins_https" {
  security_group_id = aws_security_group.jenkins.id
  description       = "HTTPS: GitHub, ECR, AWS APIs, SSM, Docker Hub, package sources"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# Needed only for the smoke test, which checks the public site on port 80.
resource "aws_vpc_security_group_egress_rule" "jenkins_http" {
  security_group_id = aws_security_group.jenkins.id
  description       = "HTTP: the pipeline smoke test calls the public load balancer"
  ip_protocol       = "tcp"
  from_port         = var.alb_port
  to_port           = var.alb_port
  cidr_ipv4         = "0.0.0.0/0"
}
