terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.27"
    }
  }
  required_version = ">= 0.14.9"
}

// Environment variables
variable "aws_region" {
  default     = "us-west-2"
  description = "AWS deployment region"
  type        = string
}

variable "env_name" {
  default     = "Event-Driven-Go"
  description = "Terraform environment name"
  type        = string
}

// Build the lambda file
resource "null_resource" "build_lambda_exec" {
  // run this when the main.go changes
  triggers = {
    source_code_hash = "${filebase64sha256("${path.module}/lambda/main.go")}"
  }
  provisioner "local-exec" {
    command     = "${path.module}/build.sh"
    working_dir = path.module
  }
}

// Lambda Zip file
data "archive_file" "s3_copy_lambda_function" {
  source_dir  = "${path.module}/lambda/"
  output_path = "${path.module}/lambda.zip"
  type        = "zip"
}

provider "aws" {
  profile = "default"
  region  = var.aws_region
}

// policy for the lambda
resource "aws_iam_policy" "lambda_policy" {
  name = "iam_for_${var.env_name}_lambda"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
  {
      "Action": [
        "s3:ListBucket",
        "s3:GetObject",
        "s3:CopyObject",
        "s3:HeadObject"
      ],
      "Effect": "Allow",
      "Resource" : [
        "arn:aws:s3:::${aws_s3_bucket.my_producer.id}",
        "arn:aws:s3:::${aws_s3_bucket.my_producer.id}/*"
      ]
  },
   {
      "Action": [
        "s3:ListBucket",
        "s3:PutObject",
        "s3:PutObjectAcl",
        "s3:CopyObject",
        "s3:HeadObject"
      ],
      "Effect": "Allow",
      "Resource": [
        "arn:aws:s3:::${aws_s3_bucket.my_consumer.id}",
        "arn:aws:s3:::${aws_s3_bucket.my_consumer.id}/*"
      ]
    },
    {
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Effect": "Allow",
      "Resource": "*"
    }
  ]
}
EOF
}

// AWS IAM Role for the lambda
resource "aws_iam_role" "s3_copy_function" {
  name = "app-${var.env_name}-lambda"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow"
    }
  ]
}
EOF
}

// Attach the policy to the role
resource "aws_iam_role_policy_attachment" "terraform_lambda_iam_policy_basic_execution" {
  role       = aws_iam_role.s3_copy_function.id
  policy_arn = aws_iam_policy.lambda_policy.arn
}

// Resources
resource "random_string" "unique_name" {
  length  = 8
  special = false
  upper   = false
  lower   = true
  number  = false
}
// Bucket Producer of events to lambda
resource "aws_s3_bucket" "my_producer" {
  bucket = "${random_string.unique_name.id}-my-producer"
}

// Bucket Consumer of data from lambda
resource "aws_s3_bucket" "my_consumer" {
  bucket = "${random_string.unique_name.id}-my-consumer"
  acl    = "private"
}

// allow bucket to notify lambda of events
resource "aws_lambda_permission" "allow_bucket" {
  statement_id  = "AllowExecutionFromS3Bucket"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.s3_copy_lambda_function.arn
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.my_producer.arn // which bucket is going to call our lambda
}

// Lambda function
resource "aws_lambda_function" "s3_copy_lambda_function" {
  filename      = "lambda.zip"
  function_name = "example_lambda_name"
  role          = aws_iam_role.s3_copy_function.arn
  handler       = "s3_lambda"
  runtime       = "go1.x"
  // Set environment variables for the lambda code
  environment {
    variables = {
      DST_BUCKET = aws_s3_bucket.my_consumer.id
      REGION     = "${var.aws_region}"
    }
  }
}


resource "aws_s3_bucket_notification" "bucket_notification" {
  // bucket that sends the notification
  bucket = aws_s3_bucket.my_producer.id

  // The lambda function that will be notified
  lambda_function {
    lambda_function_arn = aws_lambda_function.s3_copy_lambda_function.arn
    events              = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_lambda_permission.allow_bucket]
}
