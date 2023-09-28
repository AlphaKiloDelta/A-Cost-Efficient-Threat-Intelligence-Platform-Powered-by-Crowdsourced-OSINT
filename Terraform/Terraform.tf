#MIT License

#Copyright (c) 2023 AlphaKiloDelta (GitHub account holder)

#Permission is hereby granted, free of charge, to any person obtaining a copy
#of this software and associated documentation files (the "Software"), to deal
#in the Software without restriction, including without limitation the rights
#to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#copies of the Software, and to permit persons to whom the Software is
#furnished to do so, subject to the following conditions:

#The above copyright notice and this permission notice shall be included in all
#copies or substantial portions of the Software.

#THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
#OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
#SOFTWARE.





data "aws_caller_identity" "current" {}

resource "aws_vpc" "vpc" {
  cidr_block = "10.0.0.0/16"
  enable_dns_support = true
  enable_dns_hostnames = true
  tags = {
    Name = "TIP-VPC"
  }
}

resource "aws_internet_gateway" "internet_gateway" {
  tags = {
    Name = "TIP-IGW"
  }
}

resource "aws_internet_gateway_attachment" "internet_gateway_attachment" {
  vpc_id = aws_vpc.vpc.id
  internet_gateway_id = aws_internet_gateway.internet_gateway.id
}

resource "aws_lambda_function" "ingest_feed" {
  function_name = "TIP-IngestFeed"
  description = "Retrieves and ingests intel feeds into TIP-DocDBCluster, triggered hourly by TIP-HourlyInvoke"
  environment {
    variables = {
      CLUSTER = aws_docdb_cluster.doc_db_cluster.endpoint
      USERNAME = jsondecode(data.aws_secretsmanager_secret_version.doc_db_credentials.secret_string)["username"]
      PASSWORD = jsondecode(data.aws_secretsmanager_secret_version.doc_db_credentials.secret_string)["password"]
    }
  }
  filename = "IngestFeed.zip"
  runtime = "python3.10"
  handler = "index.lambda_handler"
  role = aws_iam_role.ingest_feed_role.arn
  timeout = 120
  layers = [
    aws_lambda_layer_version.lambda_layer.arn
  ]
  vpc_config {
    security_group_ids = [aws_security_group.ingest_feed_sg.id]
    subnet_ids = [
      aws_subnet.private_subnet_a.id,
      aws_subnet.private_subnet_b.id,
      aws_subnet.private_subnet_c.id
    ]
  }
}

resource "aws_scheduler_schedule" "hourly_invoke" {
  name = "TIP-HourlyInvoke"
  description = "Invokes the TIP-IngestFeed Lambda function each hour"
  schedule_expression = "rate(1 hour)"
  state = "ENABLED"
  target {
    arn = aws_lambda_function.ingest_feed.arn
    role_arn = aws_iam_role.hourly_invoke_role.arn
  }
  flexible_time_window {
    mode = "OFF"
  }
  
  depends_on = [
	aws_internet_gateway_attachment.internet_gateway_attachment,
	aws_route.private_route_to_internet_a,
	aws_route.private_route_to_internet_b,
	aws_route.private_route_to_internet_c,
	aws_docdb_cluster_instance.doc_db_instance_a
  ]
}

resource "aws_iam_role" "hourly_invoke_role" {
  name = "TIP-HourlyInvokeRole"
  description = "Grants the TIP-HourlyInvoke schedule permission to invoke the \"TIP-IngestFeed\" Lambda function"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
    {
      Effect = "Allow"
      Principal = {
        Service = [
          "scheduler.amazonaws.com"
        ]
      }
      Action = [
        "sts:AssumeRole"
      ]
    }
    ]
  })
  inline_policy {
      name = "TIP-InvokeIngestFeed"
      policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Effect = "Allow"
            Action = "lambda:InvokeFunction"
            Resource = aws_lambda_function.ingest_feed.arn
          }
        ]
      })
    }
}

resource "aws_iam_role" "ingest_feed_role" {
  name = "TIP-IngestFeedRole"
  description = "Grants the TIP-IngestFeed Lambda function permission to send logs to CloudWatch, and to manage network interfaces for connectivity"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
    {
      Effect = "Allow"
      Principal = {
        Service = [
          "lambda.amazonaws.com"
        ]
      }
      Action = [
        "sts:AssumeRole"
      ]
    }
    ]
  })
  path = "/"
  inline_policy {
    name = "TIP-AppendToLogs,EnableConnectivity"
    policy = jsonencode({
	  Version = "2012-10-17"
      Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface"
        ]
        Resource = "*"
      }
      ]
    })
  }
}

resource "aws_lambda_layer_version" "lambda_layer" {
  layer_name = "TIP-LambdaLayer"
  compatible_runtimes = ["python3.10"]
  filename = "LambdaLayer.zip"
  description = "Layer for the TIP-IngestFeed Lambda function, contains requests and pymongo"
}

resource "aws_security_group" "ingest_feed_sg" {
  name = "TIP-IngestFeedSg"
  description = "Allows the TIP-IngestFeed function to make API requests to intel repositories via HTTPS, and to ingest feed data into TIP-DocDBCluster"
  vpc_id = aws_vpc.vpc.id
  egress {
    protocol = "tcp"
	from_port = 443
	to_port = 443
	cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
	protocol = "tcp"
	from_port = 27017
	to_port = 27017
	cidr_blocks = ["10.0.0.0/16"]
  }
}

resource "aws_security_group" "ssh_tunnel_sg" {
  name = "TIP-SshTunnelSg"
  description = "Allows TIP-SshTunnelServer to receive external SSH connections, and to connect to TIP-DocDBCluster"
  vpc_id = aws_vpc.vpc.id
  ingress {
      protocol = "tcp"
      from_port = 22
      to_port = 22
      cidr_blocks = ["0.0.0.0/0"]
    }
  egress {
      protocol = "tcp"
      from_port = 27017
      to_port = 27017
      cidr_blocks = ["10.0.0.0/16"]
    }
}

resource "aws_launch_template" "ssh_tunnel_launch_template" {
  name = "SshTunnelLaunchTemplate"
  network_interfaces {
    device_index = 0
    associate_public_ip_address = true
    delete_on_termination = true
    security_groups = [aws_security_group.ssh_tunnel_sg.id]
  }
  image_id = "ami-0e603d96bf395bc01"
  instance_type = "t2.micro"
  key_name = aws_key_pair.ssh_tunnel_key.id
  tag_specifications {
    resource_type = "instance"
    tags = {
      Name: "TIP-SshTunnelServer"
    }
  }
}

resource "aws_autoscaling_group" "ssh_tunnel_asg" {
  launch_template {
    id = aws_launch_template.ssh_tunnel_launch_template.id
    version = aws_launch_template.ssh_tunnel_launch_template.latest_version
  }
  max_size = 1
  min_size = 1
  vpc_zone_identifier = [
    aws_subnet.public_subnet_a.id,
    aws_subnet.public_subnet_b.id,
    aws_subnet.public_subnet_c.id
  ]
  
  depends_on = [
	aws_internet_gateway_attachment.internet_gateway_attachment
  ]
}

resource "aws_key_pair" "ssh_tunnel_key" {
  key_name = "TIP-SshTunnelKey"
  public_key = tls_private_key.ssh_tunnel_key.public_key_openssh
}

resource "tls_private_key" "ssh_tunnel_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_file" "ssh_tunnel_key" {
  content  = tls_private_key.ssh_tunnel_key.private_key_pem
  filename = "SshTunnelKey"
}

resource "aws_kms_key" "doc_db_key" {
  description = "Encryption key for TIP-DocDBCluster"
  enable_key_rotation = true
  policy = jsonencode({
    Version = "2012-10-17"
    Id = "TIP-DocDBKeyPolicy"
    Statement = [
    {
      Sid = "Enable IAM User Permissions"
      Effect = "Allow"
      Principal = {
        AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
      }
      Action = "kms:*"
      Resource = "*"
    }
    ]
  })
}

resource "aws_kms_alias" "doc_db_key_alias" {
  name = "alias/TIP-DocDBKey"
  target_key_id = aws_kms_key.doc_db_key.arn
}

resource "aws_secretsmanager_secret" "doc_db_credentials" {
  name = "TIP-DocDBCredentials"
  description = "Username and password for TIP-DocDBCluster"
}

data "aws_secretsmanager_random_password" "doc_db_credentials" {
  password_length = 99
  exclude_punctuation = true
}

resource "aws_secretsmanager_secret_version" "doc_db_credentials" {
  secret_id = aws_secretsmanager_secret.doc_db_credentials.id
  secret_string = jsonencode({
    "username": "tipdbadmin",
    "password": data.aws_secretsmanager_random_password.doc_db_credentials.random_password
  })
}

data "aws_secretsmanager_secret" "doc_db_credentials" {
  name = "TIP-DocDBCredentials"
  
  depends_on = [
	aws_secretsmanager_secret_version.doc_db_credentials
  ]
}

data "aws_secretsmanager_secret_version" "doc_db_credentials" {
  secret_id = data.aws_secretsmanager_secret.doc_db_credentials.id
}

resource "aws_docdb_cluster" "doc_db_cluster" {
  backup_retention_period = 7
  cluster_identifier = "tip-docdbcluster"
  db_cluster_parameter_group_name = aws_docdb_cluster_parameter_group.doc_db_parameter_group.id
  db_subnet_group_name = aws_db_subnet_group.doc_db_subnet_group.id
  deletion_protection = true
  enabled_cloudwatch_logs_exports = [
    "audit"
  ]
  master_username = jsondecode(data.aws_secretsmanager_secret_version.doc_db_credentials.secret_string)["username"]
  master_password = jsondecode(data.aws_secretsmanager_secret_version.doc_db_credentials.secret_string)["password"]
  vpc_security_group_ids = [
    aws_security_group.doc_db_sg.id
  ]
  storage_encrypted = true
  kms_key_id = aws_kms_key.doc_db_key.arn
  
  depends_on = [
	aws_secretsmanager_secret_version.doc_db_credentials
  ]
}

resource "aws_db_subnet_group" "doc_db_subnet_group" {
  name = "tip-docdbsubnetgroup"
  description = "Subnet group for TIP-DocDBCluster"
  subnet_ids = [
    aws_subnet.private_subnet_a.id,
    aws_subnet.private_subnet_b.id,
    aws_subnet.private_subnet_c.id
  ]
}

resource "aws_docdb_cluster_parameter_group" "doc_db_parameter_group" {
  name = "tip-docdbparameterroup"
  description = "Enables TLS and audit logging for TIP-DocDBCluster"
  family = "docdb5.0"
  parameter {
	name  = "tls"
    value = "enabled"
  }
  parameter {
	name = "audit_logs"
	value = "all"
  }
}

resource "aws_security_group" "doc_db_sg" {
  name = "TIP-DocDBSg"
  description = "Allows inbound connections from TIP-VPC to TIP-DocDBCluster"
  vpc_id = aws_vpc.vpc.id
  ingress {
      protocol = "tcp"
      from_port = 27017
      to_port = 27017
      cidr_blocks = ["10.0.0.0/16"]
    }
}

resource "aws_docdb_cluster_instance" "doc_db_instance_a" {
  availability_zone = "eu-west-2a"
  cluster_identifier = aws_docdb_cluster.doc_db_cluster.id
  instance_class = "db.t3.medium"
  identifier = "tip-docdbinstancea"
}

resource "aws_docdb_cluster_instance" "doc_db_instance_b" {
  availability_zone = "eu-west-2b"
  cluster_identifier = aws_docdb_cluster.doc_db_cluster.id
  instance_class = "db.t3.medium"
  identifier = "tip-docdbinstanceb"
  
  depends_on = [
	aws_docdb_cluster_instance.doc_db_instance_a
  ]
}

resource "aws_docdb_cluster_instance" "doc_db_instance_c" {
  availability_zone = "eu-west-2c"
  cluster_identifier = aws_docdb_cluster.doc_db_cluster.id
  instance_class = "db.t3.medium"
  identifier = "tip-docdbinstancec"
  
  depends_on = [
	aws_docdb_cluster_instance.doc_db_instance_b
  ]
}

resource "aws_subnet" "private_subnet_a" {
  vpc_id = aws_vpc.vpc.id
  availability_zone = "eu-west-2a"
  cidr_block = "10.0.0.0/24"
  tags = {
    Name = "TIP-PrivateSubnetA"
  }
}

resource "aws_subnet" "private_subnet_b" {
  vpc_id = aws_vpc.vpc.id
  availability_zone = "eu-west-2b"
  cidr_block = "10.0.10.0/24"
  tags = {
    Name = "TIP-PrivateSubnetB"
  }
}

resource "aws_subnet" "private_subnet_c" {
  vpc_id = aws_vpc.vpc.id
  availability_zone = "eu-west-2c"
  cidr_block = "10.0.20.0/24"
  tags = {
    Name = "TIP-PrivateSubnetC"
  }
}

resource "aws_subnet" "public_subnet_a" {
  vpc_id = aws_vpc.vpc.id
  availability_zone = "eu-west-2a"
  cidr_block = "10.0.1.0/24"
  map_public_ip_on_launch = true
  tags = {
    Name = "TIP-PublicSubnetA"
  }
}

resource "aws_subnet" "public_subnet_b" {
  vpc_id = aws_vpc.vpc.id
  availability_zone = "eu-west-2b"
  cidr_block = "10.0.11.0/24"
  map_public_ip_on_launch = true
  tags = {
    Name = "TIP-PublicSubnetB"
  }
}

resource "aws_subnet" "public_subnet_c" {
  vpc_id = aws_vpc.vpc.id
  availability_zone = "eu-west-2c"
  cidr_block = "10.0.21.0/24"
  map_public_ip_on_launch = true
  tags = {
    Name = "TIP-PublicSubnetC"
  }
}

resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.vpc.id
  tags = {
    Name = "TIP-PublicRouteTable"
  }
}

resource "aws_route" "public_route" {
  route_table_id = aws_route_table.public_route_table.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id = aws_internet_gateway.internet_gateway.id
}

resource "aws_route_table_association" "public_subnet_route_table_association_a" {
  subnet_id = aws_subnet.public_subnet_a.id
  route_table_id = aws_route_table.public_route_table.id
}

resource "aws_route_table_association" "public_subnet_route_table_association_b" {
  subnet_id = aws_subnet.public_subnet_b.id
  route_table_id = aws_route_table.public_route_table.id
}

resource "aws_route_table_association" "public_subnet_route_table_association_c" {
  subnet_id = aws_subnet.public_subnet_c.id
  route_table_id = aws_route_table.public_route_table.id
}

resource "aws_eip" "nat_gateway_elastic_ipa" {
  domain = "vpc"
  tags = {
    Name = "TIP-NATGatewayEIPA"
  }
}

resource "aws_eip" "nat_gateway_elastic_ipb" {
  domain = "vpc"
  tags = {
    Name = "TIP-NATGatewayEIPB"
  }
}

resource "aws_eip" "nat_gateway_elastic_ipc" {
  domain = "vpc"
  tags = {
    Name = "TIP-NATGatewayEIPC"
  }
}

resource "aws_nat_gateway" "nat_gateway_a" {
  allocation_id = aws_eip.nat_gateway_elastic_ipa.id
  subnet_id = aws_subnet.public_subnet_a.id
  tags = {
    Name = "TIP-NATGatewayA"
  }
}

resource "aws_nat_gateway" "nat_gateway_b" {
  allocation_id = aws_eip.nat_gateway_elastic_ipb.id
  subnet_id = aws_subnet.public_subnet_b.id
  tags = {
    Name = "TIP-NATGatewayB"
  }
}

resource "aws_nat_gateway" "nat_gateway_c" {
  allocation_id = aws_eip.nat_gateway_elastic_ipc.id
  subnet_id = aws_subnet.public_subnet_c.id
  tags = {
    Name = "TIP-NATGatewayC"
  }
}

resource "aws_route_table" "private_route_table_a" {
  vpc_id = aws_vpc.vpc.id
  tags = {
    Name = "TIP-PrivateRouteTableA"
  }
}

resource "aws_route_table" "private_route_table_b" {
  vpc_id = aws_vpc.vpc.id
  tags = {
    Name = "TIP-PrivateRouteTableB"
  }
}

resource "aws_route_table" "private_route_table_c" {
  vpc_id = aws_vpc.vpc.id
  tags = {
    Name = "TIP-PrivateRouteTableC"
  }
}

resource "aws_route" "private_route_to_internet_a" {
  route_table_id = aws_route_table.private_route_table_a.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id = aws_nat_gateway.nat_gateway_a.id
}

resource "aws_route" "private_route_to_internet_b" {
  route_table_id = aws_route_table.private_route_table_b.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id = aws_nat_gateway.nat_gateway_b.id
}

resource "aws_route" "private_route_to_internet_c" {
  route_table_id = aws_route_table.private_route_table_c.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id = aws_nat_gateway.nat_gateway_c.id
}

resource "aws_route_table_association" "private_subnet_route_table_association_a" {
  subnet_id = aws_subnet.private_subnet_a.id
  route_table_id = aws_route_table.private_route_table_a.id
}

resource "aws_route_table_association" "private_subnet_route_table_association_b" {
  subnet_id = aws_subnet.private_subnet_b.id
  route_table_id = aws_route_table.private_route_table_b.id
}

resource "aws_route_table_association" "private_subnet_route_table_association_c" {
  subnet_id = aws_subnet.private_subnet_c.id
  route_table_id = aws_route_table.private_route_table_c.id
}

resource "aws_network_acl" "public_subnet_nacl" {
  vpc_id = aws_vpc.vpc.id
  tags = {
    Name = "TIP-PublicSubnetNACL"
  }
}

resource "aws_network_acl_rule" "public_nacl_inbound_https" {
  network_acl_id = aws_network_acl.public_subnet_nacl.id
  rule_number = 100
  protocol = 6
  rule_action = "allow"
  cidr_block = "10.0.0.0/16"
  from_port = 443
  to_port = 443
}

resource "aws_network_acl_rule" "public_nacl_inbound_ssh" {
  network_acl_id = aws_network_acl.public_subnet_nacl.id
  rule_number = 200
  protocol = 6
  rule_action = "allow"
  cidr_block = "0.0.0.0/0"
  from_port = 22
  to_port = 22
}

resource "aws_network_acl_rule" "public_nacl_inbound_ephemeral" {
  network_acl_id = aws_network_acl.public_subnet_nacl.id
  rule_number = 300
  protocol = 6
  rule_action = "allow"
  cidr_block = "0.0.0.0/0"
  from_port = 1024
  to_port = 65535
}

resource "aws_network_acl_rule" "public_nacl_outbound_https" {
  network_acl_id = aws_network_acl.public_subnet_nacl.id
  rule_number = 100
  protocol = 6
  egress = true
  rule_action = "allow"
  cidr_block = "0.0.0.0/0"
  from_port = 443
  to_port = 443
}

resource "aws_network_acl_rule" "public_nacl_outbound_ephemeral" {
  network_acl_id = aws_network_acl.public_subnet_nacl.id
  rule_number = 200
  protocol = 6
  egress = true
  rule_action = "allow"
  cidr_block = "0.0.0.0/0"
  from_port = 1024
  to_port = 65535
}

resource "aws_network_acl_association" "public_subnet_anacl_association" {
  subnet_id = aws_subnet.public_subnet_a.id
  network_acl_id = aws_network_acl.public_subnet_nacl.id
}

resource "aws_network_acl_association" "public_subnet_bnacl_association" {
  subnet_id = aws_subnet.public_subnet_b.id
  network_acl_id = aws_network_acl.public_subnet_nacl.id
}

resource "aws_network_acl_association" "public_subnet_cnacl_association" {
  subnet_id = aws_subnet.public_subnet_c.id
  network_acl_id = aws_network_acl.public_subnet_nacl.id
}

resource "aws_network_acl" "private_subnet_nacl" {
  vpc_id = aws_vpc.vpc.id
  tags = {
    Name = "TIP-PrivateSubnetNACL"
  }
}

resource "aws_network_acl_rule" "private_nacl_inbound_doc_db" {
  network_acl_id = aws_network_acl.private_subnet_nacl.id
  rule_number = 100
  protocol = 6
  rule_action = "allow"
  cidr_block = "10.0.0.0/16"
  from_port = 27017
  to_port = 27017
}

resource "aws_network_acl_rule" "private_nacl_inbound_ephemeral" {
  network_acl_id = aws_network_acl.private_subnet_nacl.id
  rule_number = 200
  protocol = 6
  rule_action = "allow"
  cidr_block = "0.0.0.0/0"
  from_port = 1024
  to_port = 65535
}

resource "aws_network_acl_rule" "private_nacl_outbound_ephemeral" {
  network_acl_id = aws_network_acl.private_subnet_nacl.id
  rule_number = 100
  protocol = 6
  egress = true
  rule_action = "allow"
  cidr_block = "10.0.0.0/16"
  from_port = 1024
  to_port = 65535
}

resource "aws_network_acl_rule" "private_nacl_outbound_https" {
  network_acl_id = aws_network_acl.private_subnet_nacl.id
  rule_number = 200
  protocol = 6
  egress = true
  rule_action = "allow"
  cidr_block = "0.0.0.0/0"
  from_port = 443
  to_port = 443
}

resource "aws_network_acl_association" "private_subnet_anacl_association" {
  subnet_id = aws_subnet.private_subnet_a.id
  network_acl_id = aws_network_acl.private_subnet_nacl.id
}

resource "aws_network_acl_association" "private_subnet_bnacl_association" {
  subnet_id = aws_subnet.private_subnet_b.id
  network_acl_id = aws_network_acl.private_subnet_nacl.id
}

resource "aws_network_acl_association" "private_subnet_cnacl_association" {
  subnet_id = aws_subnet.private_subnet_c.id
  network_acl_id = aws_network_acl.private_subnet_nacl.id
}
