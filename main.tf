# ABOUTME: Deploys Brave Search as an MCP server on Amazon Bedrock AgentCore Runtime.
# ABOUTME: Clients connect directly to the Runtime's MCP Streamable HTTP endpoint with a Bearer token.

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------

variable "brave_mcp_name_prefix" {
  description = "Name prefix for all Brave Search MCP resources"
  type        = string
  default     = "brave-search-mcp"
}

variable "brave_mcp_aws_region" {
  description = "AWS region for AgentCore deployment (AgentCore GA regions include us-east-1, us-east-2, us-west-2, eu-west-1, eu-central-1, and others)"
  type        = string
  default     = "eu-west-1"
}

variable "brave_mcp_api_key" {
  description = "Brave Search API key (get one at https://brave.com/search/api/)"
  type        = string
  sensitive   = true
}

variable "brave_mcp_container_uri" {
  description = "ECR container URI for the Brave Search MCP server image"
  type        = string
}

# --- OIDC configuration (inbound auth for MCP clients) ---

variable "brave_mcp_oidc_discovery_url" {
  description = "OIDC discovery URL (e.g. https://your-tenant.eu.auth0.com/.well-known/openid-configuration)"
  type        = string
}

variable "brave_mcp_oidc_allowed_audiences" {
  description = "List of allowed JWT audiences"
  type        = list(string)
}

# -----------------------------------------------------------------------------
# Provider
# -----------------------------------------------------------------------------

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.34.0"
    }
  }
}

provider "aws" {
  region = var.brave_mcp_aws_region
}

# -----------------------------------------------------------------------------
# IAM -- execution role for AgentCore Runtime
# -----------------------------------------------------------------------------

resource "aws_iam_role" "brave_mcp_agentcore" {
  name = "${var.brave_mcp_name_prefix}-agentcore-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "bedrock-agentcore.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "brave_mcp_agentcore" {
  name = "${var.brave_mcp_name_prefix}-agentcore-policy"
  role = aws_iam_role.brave_mcp_agentcore.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:${var.brave_mcp_aws_region}:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:GetAuthorizationToken",
          "ecr:BatchCheckLayerAvailability"
        ]
        Resource = "*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# AgentCore Runtime -- hosts the Brave Search MCP server container
#
# The Runtime is serverless and managed by AWS. It handles scaling,
# availability, and infrastructure automatically. The container serves
# MCP Streamable HTTP -- clients connect directly to the Runtime endpoint.
# -----------------------------------------------------------------------------

resource "aws_bedrockagentcore_agent_runtime" "brave_mcp" {
  agent_runtime_name = replace("${var.brave_mcp_name_prefix}_runtime", "-", "_")
  description        = "Brave Search MCP server on AgentCore Runtime"
  role_arn           = aws_iam_role.brave_mcp_agentcore.arn

  network_configuration {
    network_mode = "PUBLIC"
  }

  environment_variables = {
    BRAVE_API_KEY       = var.brave_mcp_api_key
    BRAVE_MCP_TRANSPORT = "http"
    BRAVE_MCP_STATELESS = "true"
    BRAVE_MCP_PORT      = "8000"
    BRAVE_MCP_HOST      = "0.0.0.0"
  }

  protocol_configuration {
    server_protocol = "MCP"
  }

  authorizer_configuration {
    custom_jwt_authorizer {
      discovery_url    = var.brave_mcp_oidc_discovery_url
      allowed_audience = var.brave_mcp_oidc_allowed_audiences
    }
  }

  agent_runtime_artifact {
    container_configuration {
      container_uri = var.brave_mcp_container_uri
    }
  }
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

locals {
  # URL-encode the Runtime ARN for the endpoint URL
  encoded_arn = replace(replace(
    aws_bedrockagentcore_agent_runtime.brave_mcp.agent_runtime_arn,
    ":", "%3A"
  ), "/", "%2F")

  mcp_endpoint = "https://bedrock-agentcore.${var.brave_mcp_aws_region}.amazonaws.com/runtimes/${local.encoded_arn}/invocations?qualifier=DEFAULT"
}

output "brave_mcp_runtime_arn" {
  description = "ARN of the AgentCore Runtime hosting Brave Search"
  value       = aws_bedrockagentcore_agent_runtime.brave_mcp.agent_runtime_arn
}

output "brave_mcp_endpoint" {
  description = "MCP Streamable HTTP endpoint URL (use with Authorization: Bearer <token> header)"
  value       = local.mcp_endpoint
}

output "brave_mcp_client_config" {
  description = "Example MCP client configuration for Claude Code / OpenCode"
  value       = <<-EOT
    # MCP endpoint (Streamable HTTP):
    ${local.mcp_endpoint}

    # Claude Code -- add to ~/.claude/.mcp.json or use: claude mcp add --transport http braveSearch <url>
    # Auth is handled automatically via OAuth (no manual token needed).
    {
      "braveSearch": {
        "type": "http",
        "url": "${local.mcp_endpoint}"
      }
    }
  EOT
}
