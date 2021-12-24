

#------------------------------------------------
# Create S3 Bucket

terraform {
  backend "s3" {
    # Поменяйте это на имя своего бакета!
    bucket = "terraform-my-testing-state"
    key    = "stage/services/webserver-cluster/terraform.tfstate"
    region = "us-east-1"
    # Замените это именем своей таблицы DynamoDB!
    dynamodb_table = "terraform-up-and-running-locks"
    encrypt        = true
  }
}

#-------------------------------------------------
# Make Remote State for Data-Store MySql
data "terraform_remote_state" "db" {
  backend = "s3"
  config = {
    bucket = var.db_remote_state_bucket
    #key    = "stage/data-stores/mysql/terraform.tfstate"
    key    = var.db_remote_state_key
    region = "us-east-1"
  }
}

#------------------------------------------------
# Create Local Variables
locals {
  http_port    = 80
  any_port     = 0
  any_protocol = "-1"
  tcp_protocol = "tcp"
  all_ips      = ["0.0.0.0/0"]
}

#-----------------------------------------------
# Create Security Group
resource "aws_security_group" "instance" {
  name = "${var.cluster_name}-instance"
  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Create Security Group for ALB
resource "aws_security_group" "alb" {
  name = "${var.cluster_name}-alb"
  /*
  # Разрешаем все входящие HTTP-запросы
  ingress {
    from_port   = local.http_port
    to_port     = local.http_port
    protocol    = local.tcp_protocol
    cidr_blocks = local.all_ips
  }
  # Разрешаем все исходящие запросы
  egress {
    from_port   = local.any_port
    to_port     = local.any_port
    protocol    = local.any_protocol
    cidr_blocks = local.all_ips
  }
  */
}

# Create Rule for Security Group
resource "aws_security_group_rule" "allow_http_inbound" {
  type              = "ingress"
  security_group_id = aws_security_group.alb.id
  from_port         = local.http_port
  to_port           = local.http_port
  protocol          = local.tcp_protocol
  cidr_blocks       = local.all_ips
}

resource "aws_security_group_rule" "allow_all_outbound" {
  type              = "egress"
  security_group_id = aws_security_group.alb.id
  from_port         = local.any_port
  to_port           = local.any_port
  protocol          = local.any_protocol
  cidr_blocks       = local.all_ips
}





#--------------------------------------
# Create Launch Configuration
resource "aws_launch_configuration" "example" {
  image_id        = "ami-083654bd07b5da81d" // Ubuntu Server 20.04 Server
  instance_type   = var.instance_type
  security_groups = [aws_security_group.instance.id]
  user_data       = data.template_file.user_data.rendered

  lifecycle {
    create_before_destroy = true
  }
}

# Get user_data
data "template_file" "user_data" {
  template = file("${path.module}/user_data.sh") // add path ${path.module} for working in prod/sstage
  vars = {
    server_port = var.server_port
    db_address  = data.terraform_remote_state.db.outputs.address
    db_port     = data.terraform_remote_state.db.outputs.port
  }
}


# Create Auto Scaling Group (ASG)
resource "aws_autoscaling_group" "example" {
  launch_configuration = aws_launch_configuration.example.name
  vpc_zone_identifier  = data.aws_subnet_ids.default.ids
  target_group_arns    = [aws_lb_target_group.asg.arn] // use Target Groupe
  health_check_type    = "ELB"
  min_size             = var.min_size
  max_size             = var.max_size

  tag {
    key                 = "Name"
    value               = "${var.cluster_name}-asg-example"
    propagate_at_launch = true
  }
}

# Get default DATA
data "aws_vpc" "default" {
  default = true
}

data "aws_subnet_ids" "default" {
  vpc_id = data.aws_vpc.default.id
}

# Create Application Load Balancer (ALB)
resource "aws_lb" "example" {
  name               = "${var.cluster_name}-asg-example"
  load_balancer_type = "application"
  subnets            = data.aws_subnet_ids.default.ids
  security_groups    = [aws_security_group.alb.id] // use SG for ALB
}

# Create ALB Listener:
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.example.arn
  port              = local.http_port
  protocol          = "HTTP"
  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "404: page not found"
      status_code  = 404
    }
  }
}

# Create Target Group for ASG
resource "aws_lb_target_group" "asg" {
  name     = "${var.cluster_name}-asg-example"
  port     = var.server_port
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id
  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 3
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# Make full
# Create Listener Rule:
resource "aws_lb_listener_rule" "asg" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100
  condition {
    path_pattern {
      values = ["*"]
    }
  }
  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.asg.arn
  }
}
