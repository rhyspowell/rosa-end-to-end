variable "vpc_name" {
  type        = string
  description = "The Name of the VPC as applied to AWS"
  default     = "test-vpc"
}

variable "vpc_cidr_block" {
  type        = string
  description = "Value of the CIDR block to use for the VPC"
  default     = "10.0.0.0/16"
}

variable "aws_region" {
  type        = string
  description = "THe region you want all of this to run in"
  default     = "eu-west-2"
}
variable "availability_zones" {
  type        = list(any)
  description = "The specific availability zones that you want to use"
  default     = ["eu-west-2a", "eu-west-2b", "eu-west-2c"]
}

variable "private_subnet_cidrs" {
  type        = list(any)
  description = "VPC privatge subnets"
  default     = ["10.0.0.0/24", "10.0.1.0/24", "10.0.2.0/24"]
}

variable "public_subnet_cidrs" {
  type        = list(any)
  description = "VPC public subnets"
  default     = ["10.0.10.0/24", "10.0.11.0/24", "10.0.12.0/24"]
}
variable "single_nat_gateway" {
  type        = bool
  description = "Do you want a gateway for each subnet"
  default     = false
}

variable "additional_tags" {
  type        = map(string)
  description = "Additional tags for AWS resources as required"
  default = {
    "Owner" = "test"
  }
}
