
resource "aws_vpc" "genome_vpc" {
  cidr_block           = "10.1.0.0/24"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name    = "genome-demo-vpc"
    project = "genome-demo"
  }
}

data "aws_availability_zones" "azs" {
  state = "available"
}

resource "aws_subnet" "private" {
  count                   = 2
  vpc_id                  = aws_vpc.genome_vpc.id
  cidr_block              = element(["10.1.0.0/26", "10.1.0.64/26"], count.index)
  availability_zone       = data.aws_availability_zones.azs.names[count.index]
  map_public_ip_on_launch = false
  tags = {
    Name    = "genome-demo-subnet-${count.index + 1}"
    project = "genome-demo"
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.genome_vpc.id
  tags = {
    Name    = "private-route-table"
    project = "genome-demo"
  }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id

}

resource "aws_security_group" "batch_sg" {
  name        = "genome-batch-sg"
  description = "Allow outbound HTTPS (for S3 endpoint)"
  vpc_id      = aws_vpc.genome_vpc.id

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "genome-batch-sg"
  project = "genome-demo" }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.genome_vpc.id
  service_name      = "com.amazonaws.us-east-1.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  tags = {
    Name    = "genome-s3-endpoint"
    project = "genome-demo"
  }
}


# resource "aws_vpc_endpoint" "s3" {
#   vpc_id            = aws_vpc.genome_vpc.id
#   service_name      = "com.amazonaws.us-east-1.s3"
#   vpc_endpoint_type = "Gateway"

#   # Attach to the private subnets’ route tables:
#   # If you have explicit route tables, list them here instead.
#   route_table_ids = [
#     aws_subnet.private[0].id,
#     aws_subnet.private[1].id
#   ]

#   tags = { Name = "s3-gateway-endpoint" }
# }

resource "aws_security_group" "endpoint_sg" {
  name        = "endpoint-sg"
  description = "Allow inbound 443 from batch-sg for ECR endpoints"
  vpc_id      = aws_vpc.genome_vpc.id

  # Ingress: allow HTTPS from batch_sg
  ingress {
    description     = "Allow Fargate tasks to talk to ECR endpoints"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.batch_sg.id]
  }

  # Egress: allow all outbound (so endpoint ENIs can reach AWS services, though usually not needed)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "endpoint-sg" }
}


resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = aws_vpc.genome_vpc.id
  service_name        = "com.amazonaws.us-east-1.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoint_sg.id]
  private_dns_enabled = true

  tags = { Name = "ecr-api-endpoint" }
}

resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = aws_vpc.genome_vpc.id
  service_name        = "com.amazonaws.us-east-1.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoint_sg.id]
  private_dns_enabled = true

  tags = { Name = "ecr-dkr-endpoint" }
}

resource "aws_vpc_endpoint" "cloudwatch_logs" {
  vpc_id              = aws_vpc.genome_vpc.id
  service_name        = "com.amazonaws.us-east-1.logs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoint_sg.id]
  private_dns_enabled = true

  tags = {
    Name = "logs-endpoint"
  }
}

resource "aws_vpc_endpoint" "cloudwatch" {
  vpc_id              = aws_vpc.genome_vpc.id
  service_name        = "com.amazonaws.us-east-1.monitoring"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoint_sg.id]
  private_dns_enabled = true

  tags = {
    Name = "cloudwatch-endpoint"
  }
}
