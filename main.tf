terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region  = "ap-northeast-2"
  profile = "terraform-user"
}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name = "my-vpc"
  cidr = "10.0.0.0/16"

  azs                          = ["ap-northeast-2a", "ap-northeast-2c"]
  private_subnets              = ["10.0.1.0/24", "10.0.3.0/24"]
  public_subnets               = ["10.0.101.0/24", "10.0.103.0/24"]
  database_subnets             = ["10.0.201.0/24", "10.0.203.0/24"]
  create_database_subnet_group = true

  map_public_ip_on_launch = true

  tags = {
    Name = "my-vpc"
  }
}

resource "aws_route" "nat_route" {
  count                  = 2
  route_table_id         = module.vpc.private_route_table_ids[count.index]
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = module.nat_instance.primary_network_interface_id
}

module "bastion" {
  source = "terraform-aws-modules/ec2-instance/aws"

  name = "bastion-host"

  instance_type = "t3.micro"
  key_name      = "bastion-host-key"
  monitoring    = true
  subnet_id     = module.vpc.public_subnets[0]
  ami           = "ami-00e73adb2e2c80366"
  tags = {
    Name = "bastion-host"
  }

  vpc_security_group_ids = [module.bastion_sg.security_group_id]
}

module "bastion_sg" {
  # 22 허용
  source = "terraform-aws-modules/security-group/aws"

  name            = "bastion-sg"
  use_name_prefix = false
  description     = "bastion-host"
  vpc_id          = module.vpc.vpc_id

  ingress_with_cidr_blocks = [
    {
      rule        = "ssh-tcp"
      cidr_blocks = "${var.admin_ip}/32"
    },
  ]
  egress_with_cidr_blocks = [
    {
      rule        = "all-all"
      cidr_blocks = "0.0.0.0/0"
    },
  ]
}

module "nat_instance" {
  source = "terraform-aws-modules/ec2-instance/aws"

  name = "nat-instance"

  instance_type = "t3.micro"
  key_name      = "bastion-host-key"
  monitoring    = true
  subnet_id     = module.vpc.public_subnets[1]
  ami           = "ami-0eb63419e063fe627"
  tags = {
    Name = "nat-instance"
  }
  source_dest_check      = false
  vpc_security_group_ids = [module.nat_sg.security_group_id]
  user_data              = file("nat-setting.sh")
}

module "nat_sg" {
  # all 허용
  source = "terraform-aws-modules/security-group/aws"

  name            = "nat-sg"
  use_name_prefix = false
  description     = "nat-instance"
  vpc_id          = module.vpc.vpc_id

  # Ingress 규칙: 0.0.0.0/0 대신 'web_sg'에서 오는 트래픽만 허용
  ingress_with_source_security_group_id = [
    {
      rule                     = "all-all"
      source_security_group_id = module.web_sg.security_group_id
    }
  ]
  egress_with_cidr_blocks = [
    {
      rule        = "all-all"
      cidr_blocks = "0.0.0.0/0"
    },
  ]
}

module "web_ec2" {
  source = "terraform-aws-modules/ec2-instance/aws"
  count  = 2
  name   = "web-instance"

  instance_type = "t3.micro"
  key_name      = "web-server-key"
  monitoring    = true
  subnet_id     = module.vpc.private_subnets[count.index]
  ami           = "ami-00e73adb2e2c80366"
  tags = {
    Name = "web-instance"
  }

  vpc_security_group_ids = [module.web_sg.security_group_id]

  user_data = templatefile("${path.module}/tomcat-setting.sh.tpl", {
    DB_ADDRESS     = module.db.db_instance_address,
    DB_USERNAME    = var.db_username,
    DB_PASSWORD    = var.db_password,
    S3_BUCKET_NAME = module.S3.bucket_name
  })
  iam_instance_profile = module.IAM.iam_instance_profile
  depends_on           = [module.nat_instance]
}


module "web_sg" {
  # 22, 8080 허용
  source = "terraform-aws-modules/security-group/aws"

  name            = "web-sg"
  use_name_prefix = false
  description     = "Security group for http-8080-service with custom ports open within VPC"
  vpc_id          = module.vpc.vpc_id

  # Ingress 규칙: 0.0.0.0/0 대신 'elb_sg'와 'bastion_sg'에서만 허용
  ingress_with_source_security_group_id = [
    {
      # 8080 포트: 오직 ALB(elb_sg)에서만 접근 허용
      rule                     = "http-8080-tcp"
      source_security_group_id = module.elb_sg.security_group_id
    },
    {
      # 22 포트(SSH): 오직 Bastion Host(bastion_sg)에서만 접근 허용
      rule                     = "ssh-tcp"
      source_security_group_id = module.bastion_sg.security_group_id
    }
  ]
  egress_with_cidr_blocks = [
    {
      rule        = "all-all"
      cidr_blocks = "0.0.0.0/0"
    },
  ]
}

module "db" {
  source = "terraform-aws-modules/rds/aws"

  identifier = "database-1"

  engine            = "mariadb"
  engine_version    = "11.4"
  instance_class    = "db.t4g.micro"
  allocated_storage = 20

  db_name                     = "care"
  username                    = var.db_username
  password                    = var.db_password
  manage_master_user_password = false

  vpc_security_group_ids = [module.rds_sg.security_group_id]

  tags = {
    Name = "quiz-rds"
  }

  db_subnet_group_name      = module.vpc.database_subnet_group_name
  create_db_option_group    = false
  create_db_parameter_group = false

  # Database Deletion Protection
  deletion_protection = false
  skip_final_snapshot = true
  apply_immediately   = true
}


module "rds_sg" {
  # 3306 허용
  source = "terraform-aws-modules/security-group/aws"

  name            = "rds-sg"
  use_name_prefix = false
  description     = "mariadb"
  vpc_id          = module.vpc.vpc_id

  ingress_with_source_security_group_id = [
    {
      rule                     = "mysql-tcp"
      source_security_group_id = module.web_sg.security_group_id
    },
  ]
  egress_with_cidr_blocks = [
    {
      rule        = "all-all"
      cidr_blocks = "0.0.0.0/0"
    },
  ]
}

locals {
  env = "stage"
}

module "S3" {
  source = "./local_modules/s3"
  env    = local.env
}

module "IAM" {
  source      = "./local_modules/iam"
  env         = local.env
  bucket_name = module.S3.bucket_name
}

module "AMI" {
  source            = "./local_modules/ami"
  env               = local.env
  bastion_public_ip = module.bastion.public_ip
  web_instance      = module.web_ec2[0]
}

module "alb" {
  source = "terraform-aws-modules/alb/aws"

  name                       = "${local.env}-alb"
  vpc_id                     = module.vpc.vpc_id
  subnets                    = module.vpc.public_subnets
  enable_deletion_protection = false

  # Security Group
  security_group_ingress_rules = {
    all_http = {
      from_port   = 80
      to_port     = 80
      ip_protocol = "tcp"
      description = "HTTP web traffic"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }

  security_group_egress_rules = {
    all = {
      ip_protocol = "-1"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }

  listeners = {
    ex-http = {
      port     = 80
      protocol = "HTTP"
      forward = {
        target_group_key = "ex-instance"
      }
    }
  }

  target_groups = {
    ex-instance = {
      create_attachment = false # aws_lb_target_group_attachment 생성하지마
      protocol    = "HTTP"
      port        = 8080
      target_type = "instance"

      stickiness = {
        enabled = true
        type    = "lb_cookie"
      }

      health_check = {
        enabled  = true
        path     = "/boot/"
        protocol = "HTTP"
        port     = 8080
      }
    }

  }

  tags = {
    Name = "alb"
  }
}

module "asg" {
  source = "terraform-aws-modules/autoscaling/aws"

  # Autoscaling group
  name = "${local.env}-asg"

  min_size                  = 2
  max_size                  = 4
  desired_capacity          = 2
  wait_for_capacity_timeout = 0
  health_check_type         = "ELB"
  vpc_zone_identifier       = module.vpc.private_subnets

  # Launch template
  launch_template_name        = "${local.env}-asg"
  launch_template_description = "Launch template ${local.env}"
  launch_template_version     = "$Latest"

  image_id        = module.AMI.ami_instance_id
  instance_type   = "t3.micro"
  key_name        = "web-server-key"
  security_groups = [module.web_sg.security_group_id]

  traffic_source_attachments = {
    ex-alb = {
      traffic_source_identifier = module.alb.target_groups["ex-instance"].arn
      traffic_source_type       = "elbv2" # default
    }
  }

  scaling_policies = {
    my-policy = {
      policy_type = "TargetTrackingScaling"
      target_tracking_configuration = {
        predefined_metric_specification = {
          predefined_metric_type = "ASGAverageCPUUtilization"
          # resource_label         = "MyLabel"
        }
        target_value = 50.0
      }
    }
  }
}


# -----------------------------------------------------------------
# [추가] AWS WAF (Web Application Firewall) 생성
# -----------------------------------------------------------------
resource "aws_wafv2_web_acl" "waf_acl" {
  name  = "${local.env}-waf-acl"
  scope = "REGIONAL" # ALB에 적용할 WAF는 "REGIONAL" 스코프를 사용합니다.

  default_action {
    allow {} # 규칙에 일치하지 않는 트래픽은 기본적으로 허용합니다.
  }

  # 규칙 1: AWS 관리형 - 공통 규칙 세트 (SQLi, XSS, LFI 등 포함)
  rule {
    name     = "AWS-Managed-Common-Rule-Set"
    priority = 10 # 규칙 실행 우선순위 (낮을수록 먼저 실행)

    override_action {
      none {} # 규칙 세트 내부의 기본 동작(Block)을 그대로 따릅니다.
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        # AWS가 제공하는 가장 일반적이고 권장되는 규칙 모음입니다.
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = false
      metric_name                = "friendly-rule-metric-name"
      sampled_requests_enabled   = false
    }
  }

  # 규칙 2: AWS 관리형 - SQL Injection 전용 규칙 세트 (보안 강화)
  rule {
    name     = "AWS-Managed-SQLi-Rule-Set"
    priority = 20

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        # SQL Injection 공격을 탐지하는 데 특화된 규칙 모음입니다.
        name        = "AWSManagedRulesSQLiRuleSet"
      }
    }
    
    visibility_config {
      cloudwatch_metrics_enabled = false
      metric_name                = "friendly-rule-metric-name"
      sampled_requests_enabled   = false
    }
  
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "waf-acl-metrics-${local.env}"
    sampled_requests_enabled   = true # 디버깅을 위해 샘플 요청을 기록합니다.
  }

  tags = {
    Env  = local.env
    Name = "${local.env}-waf-acl"
  }
}

# -----------------------------------------------------------------
# [추가] 생성한 WAF를 'module "ELB"' (ALB)에 연결
# -----------------------------------------------------------------
resource "aws_wafv2_web_acl_association" "waf_alb_association" {
  # 'module "ELB"'의 ARN(고유 식별자)을 참조하여 연결합니다.
  resource_arn = module.ELB.lb_arn 

  # 위에서 생성한 'aws_wafv2_web_acl' 리소스의 ARN을 참조합니다.
  web_acl_arn  = aws_wafv2_web_acl.waf_acl.arn
}


# -----------------------------------------------------------------
# [추가] AWS CloudTrail (감사 로그)
# -----------------------------------------------------------------

# 현재 AWS 계정 ID를 가져오기 (S3 정책 생성 시 필요)
data "aws_caller_identity" "current" {}

# 1. CloudTrail 로그를 저장할 S3 버킷 (Private)
resource "aws_s3_bucket" "cloudtrail_log_bucket" {
  # 버킷 이름은 전 세계적으로 고유해야 하므로, 계정 ID와 환경 이름을 조합합니다.
  bucket        = "${local.env}-trail-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # (주의) terraform destroy 시 버킷을 강제 삭제 (실습용)

  tags = {
    Env  = local.env
    Name = "${local.env}-cloudtrail-log-bucket"
  }
}

# 2. S3 버킷이 Private이도록 Public Access 차단
resource "aws_s3_bucket_public_access_block" "cloudtrail_bucket_pab" {
  bucket = aws_s3_bucket.cloudtrail_log_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 3. CloudTrail 서비스가 S3 버킷에 로그를 쓸 수 있도록 허용하는 정책
resource "aws_s3_bucket_policy" "cloudtrail_bucket_policy" {
  bucket = aws_s3_bucket.cloudtrail_log_bucket.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid    = "AWSCloudTrailAclCheck",
        Effect = "Allow",
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        },
        Action   = "s3:GetBucketAcl",
        Resource = aws_s3_bucket.cloudtrail_log_bucket.arn
      },
      {
        Sid    = "AWSCloudTrailWrite",
        Effect = "Allow",
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        },
        Action   = "s3:PutObject",
        Resource = "${aws_s3_bucket.cloudtrail_log_bucket.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*",
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.cloudtrail_bucket_pab]
}

# 4. CloudWatch Logs로 로그를 보낼 IAM Role
resource "aws_iam_role" "cloudtrail_cw_role" {
  name = "${local.env}-cloudtrail-cw-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
      }
    ]
  })
}

# 5. CloudWatch Logs에 로그를 생성할 수 있는 권한 정책
resource "aws_iam_role_policy" "cloudtrail_cw_policy" {
  name = "${local.env}-cloudtrail-cw-policy"
  role = aws_iam_role.cloudtrail_cw_role.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Effect   = "Allow",
        Resource = "${aws_cloudwatch_log_group.cloudtrail_log_group.arn}:*"
      }
    ]
  })
}

# 6. CloudTrail 로그를 수신할 CloudWatch Log Group
resource "aws_cloudwatch_log_group" "cloudtrail_log_group" {
  name              = "/aws/cloudtrail/${local.env}-trail"
  retention_in_days = 7 # 로그 보관 기간 (프로젝트 실습용 7일)

  tags = {
    Env = local.env
  }
}

# 7. CloudTrail (Trail) 본체 생성
resource "aws_cloudtrail" "main_trail" {
  name                          = "${local.env}-main-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail_log_bucket.id
  
  # 모든 리전의 활동을 기록 (필수)
  is_multi_region_trail         = true
  # IAM 등 글로벌 서비스의 활동도 기록 (필수)
  include_global_service_events = true
  enable_logging                = true

  # CloudWatch Logs 연동 설정
  cloud_watch_logs_group_arn = aws_cloudwatch_log_group.cloudtrail_log_group.arn
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail_cw_role.arn

  # S3 정책과 IAM 역할이 먼저 생성되도록 의존성 설정
  depends_on = [
    aws_s3_bucket_policy.cloudtrail_bucket_policy,
    aws_iam_role_policy.cloudtrail_cw_policy
  ]

  tags = {
    Env = local.env
  }
}


# -----------------------------------------------------------------
# [추가] Amazon GuardDuty (지능형 위협 탐지)
# -----------------------------------------------------------------
resource "aws_guardduty_detector" "default" {
  # 'enable = true'로 설정하는 것만으로 GuardDuty가 활성화됩니다.
  enable = true

  tags = {
    Env  = local.env
    Name = "${local.env}-guardduty-detector"
  }
}


# -----------------------------------------------------------------
# [추가] AWS Config (리소스 설정 변경 추적 및 규정 준수)
# -----------------------------------------------------------------

# 1. Config 데이터(변경 이력)를 저장할 S3 버킷 (Private)
resource "aws_s3_bucket" "config_log_bucket" {
  # 버킷 이름은 전 세계적으로 고유해야 함
  bucket        = "${local.env}-config-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # (주의) terraform destroy 시 버킷을 강제 삭제 (실습용)

  tags = {
    Env  = local.env
    Name = "${local.env}-config-log-bucket"
  }
}

# 2. S3 버킷 Public Access 차단
resource "aws_s3_bucket_public_access_block" "config_bucket_pab" {
  bucket = aws_s3_bucket.config_log_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 3. Config 서비스가 S3 버킷에 데이터를 쓸 수 있도록 허용하는 정책
resource "aws_s3_bucket_policy" "config_bucket_policy" {
  bucket = aws_s3_bucket.config_log_bucket.id
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid    = "AWSConfigBucketVerification",
        Effect = "Allow",
        Principal = {
          Service = "config.amazonaws.com"
        },
        Action   = "s3:GetBucketAcl",
        Resource = aws_s3_bucket.config_log_bucket.arn
      },
      {
        Sid    = "AWSConfigBucketDelivery",
        Effect = "Allow",
        Principal = {
          Service = "config.amazonaws.com"
        },
        Action   = "s3:PutObject",
        Resource = "${aws_s3_bucket.config_log_bucket.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/Config/*"
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.config_bucket_pab]
}

# 4. Config 서비스가 리소스 설정을 읽을 수 있도록 허용하는 IAM Role
resource "aws_iam_role" "config_role" {
  name = "${local.env}-config-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "config.amazonaws.com"
        }
      }
    ]
  })
}

# 5. Config Role에 AWS 관리형 정책(읽기 권한) 연결
resource "aws_iam_role_policy_attachment" "config_role_attachment" {
  role       = aws_iam_role.config_role.name
  # AWSConfigRole: AWS 리소스 구성을 읽을 수 있는 기본 권한 제공
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

# 6. Config Recorder (어떤 리소스를 모니터링할지 정의)
resource "aws_config_configuration_recorder" "default" {
  name     = "${local.env}-recorder"
  role_arn = aws_iam_role.config_role.arn

  recording_group {
    # 모든 리전의 모든 리소스 유형을 모니터링
    all_supported                 = true
    include_global_resource_types = true
  }

  depends_on = [aws_iam_role_policy_attachment.config_role_attachment]
}

# 7. Delivery Channel (모니터링 결과를 어디로 보낼지 정의)
resource "aws_config_delivery_channel" "default" {
  name           = "${local.env}-delivery-channel"
  s3_bucket_name = aws_s3_bucket.config_log_bucket.id

  depends_on = [
    aws_config_configuration_recorder.default,
    aws_s3_bucket_policy.config_bucket_policy
  ]
}

# 8. [핵심] Config 규칙 (보안 규정 정의)
# 규칙 1: S3 버킷이 Public Read를 허용하는지 검사 (사용자 요청)
resource "aws_config_config_rule" "s3_public_read_prohibited" {
  name = "s3-bucket-public-read-prohibited"
  
  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_PUBLIC_READ_PROHIBITED" # AWS 관리형 규칙 이름
  }

  depends_on = [aws_config_delivery_channel.default]
}

# 규칙 2: SSH(22번 포트)가 0.0.0.0/0에 열려 있는지 검사
resource "aws_config_config_rule" "ssh_restricted" {
  name = "restricted-ssh"
  
  source {
    owner             = "AWS"
    source_identifier = "RESTRICTED_SSH" # AWS 관리형 규칙 이름
  }

  depends_on = [aws_config_delivery_channel.default]
}

# 규칙 3: MFA가 활성화되었는지 검사 (Root 계정)
resource "aws_config_config_rule" "root_account_mfa" {
  name = "root-account-mfa-enabled"
  
  source {
    owner             = "AWS"
    source_identifier = "ROOT_ACCOUNT_MFA_ENABLED" # AWS 관리형 규칙 이름
  }

  depends_on = [aws_config_delivery_channel.default]
}
# PS C:\terraform\workspace\26_quiz> $env:TF_VAR_db_username = "admin"
# PS C:\terraform\workspace\26_quiz> $env:TF_VAR_db_password = "mariaPassw0rd"
# PS C:\terraform\workspace\26_quiz> terraform init