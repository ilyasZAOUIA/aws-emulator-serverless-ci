locals {
  # AWS Emulator does not inject an endpoint or credentials into the Lambda
  # runtime, so the function has to be told where "AWS" is. On real AWS this
  # map is empty and the function uses its IAM role as usual.
  emulator_env = var.emulator_dir == "" ? {} : {
    AWS_ENDPOINT_URL            = var.emulator_endpoint
    AWS_SHARED_CREDENTIALS_FILE = "${var.emulator_dir}/emulator_credentials"
    AWS_CONFIG_FILE             = "${var.emulator_dir}/config"
    NODE_EXTRA_CA_CERTS         = "${var.emulator_dir}/ca.pem"
  }
}

# ---------------------------------------------------------------- DynamoDB --

resource "aws_dynamodb_table" "links" {
  name         = "${var.project}-links"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "code"

  attribute {
    name = "code"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }
}

# --------------------------------------------------------------------- IAM --

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.project}-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

# Least privilege: only the three DynamoDB actions the code uses, on one table.
data "aws_iam_policy_document" "lambda_dynamodb" {
  statement {
    actions   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.links.arn]
  }
}

resource "aws_iam_role_policy" "lambda_dynamodb" {
  name   = "dynamodb-links"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_dynamodb.json
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ------------------------------------------------------------------ Lambda --

data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/../app/src"
  output_path = "${path.module}/build/lambda.zip"
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.project}-api"
  retention_in_days = 14
}

resource "aws_lambda_function" "api" {
  function_name    = "${var.project}-api"
  role             = aws_iam_role.lambda.arn
  runtime          = "nodejs22.x"
  handler          = "index.handler"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 10
  memory_size      = 128

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = merge({ TABLE_NAME = aws_dynamodb_table.links.name }, local.emulator_env)
  }

  depends_on = [aws_cloudwatch_log_group.lambda, aws_iam_role_policy_attachment.lambda_logs]
}

# ------------------------------------------------------------- API Gateway --
#   POST /links         -> create a short link
#   GET  /links/{code}  -> redirect

resource "aws_api_gateway_rest_api" "api" {
  name = "${var.project}-api"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_resource" "links" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "links"
}

resource "aws_api_gateway_resource" "code" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_resource.links.id
  path_part   = "{code}"
}

resource "aws_api_gateway_method" "create" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.links.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_method" "resolve" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.code.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "create" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.links.id
  http_method             = aws_api_gateway_method.create.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.api.invoke_arn
}

resource "aws_api_gateway_integration" "resolve" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.code.id
  http_method             = aws_api_gateway_method.resolve.http_method
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = aws_lambda_function.api.invoke_arn
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api.execution_arn}/*/*"
}

resource "aws_api_gateway_deployment" "api" {
  rest_api_id = aws_api_gateway_rest_api.api.id

  # Redeploy whenever a route or integration changes.
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.links.id,
      aws_api_gateway_resource.code.id,
      aws_api_gateway_method.create.id,
      aws_api_gateway_method.resolve.id,
      aws_api_gateway_integration.create.id,
      aws_api_gateway_integration.resolve.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [aws_api_gateway_integration.create, aws_api_gateway_integration.resolve]
}

resource "aws_api_gateway_stage" "api" {
  rest_api_id          = aws_api_gateway_rest_api.api.id
  deployment_id        = aws_api_gateway_deployment.api.id
  stage_name           = var.stage_name
  xray_tracing_enabled = true
}
