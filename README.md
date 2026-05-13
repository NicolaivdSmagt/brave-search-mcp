# Brave Search MCP Server on AWS Bedrock AgentCore

Deploys [Brave Search](https://brave.com/search/api/) as a remote MCP server on Amazon Bedrock AgentCore Runtime. Clients like Claude Code and OpenCode connect over HTTPS with automatic OAuth authentication -- no local processes, no API keys in client configs.

## Architecture

```
                         ┌──────────────┐
                         │   OIDC IdP   │
                         │   (Auth0,    │
                         │    Okta,     │
                         │    EntraID)  │
                         └──────┬───────┘
                             ▲  │
              DCR, login,    │  │ JWKS
              token exchange │  │
                             │  ▼
┌───────────┐  MCP over  ┌──┴──────────────────────────────────┐
│           │  HTTPS +   │  Amazon Bedrock AgentCore            │
│  Claude   │  Bearer JWT│                                      │
│  Code     ├───────────►│  Runtime         JWT Authorizer      │
│           │            │  (serverless,    (validates tokens   │
│  (MCP +   │◄───────────┤   multi-AZ)      against IdP)       │
│   OAuth   │  MCP tools │       │                              │
│   client) │  responses │       │  Workload Identity           │
│           │            │       │  (auto-managed)              │
└───────────┘            └───────┼──────────────────────────────┘
                                 │
                                 │ HTTPS + API key
                                 ▼
                         ┌──────────────┐
                         │ Brave Search │
                         │ API          │
                         └──────────────┘
```

**OAuth flow (first connection):**
1. Claude Code connects to the Runtime MCP endpoint
2. Runtime returns 401 with `/.well-known/oauth-protected-resource` metadata
3. Claude Code discovers the OIDC provider, registers via Dynamic Client Registration
4. User logs in via the IdP in the browser
5. Claude Code exchanges the auth code for a JWT
6. Runtime validates the JWT against the IdP's JWKS, allows MCP access
7. Subsequent sessions reuse cached tokens automatically

**Components:**

| Component | Role |
|---|---|
| **AgentCore Runtime** | Serverless container hosting for the Brave Search MCP server. Multi-AZ, auto-scaling. |
| **JWT Authorizer** (built into Runtime) | Validates Bearer tokens via OIDC discovery. Serves OAuth protected resource metadata. |
| **Workload Identity** (auto-created) | Runtime identity within AgentCore Identity service. No manual setup. |
| **OIDC Identity Provider** | Any OIDC-compliant provider (Auth0, Okta, Microsoft Entra ID, Amazon Cognito, etc.). Handles DCR, user login, and JWT issuance. |
| **Brave Search API** | External search API, called by the MCP server using `BRAVE_API_KEY` env var. |

## Prerequisites

- AWS account with AgentCore access in a [supported region](https://aws.amazon.com/bedrock/agentcore/faqs/)
- AWS CLI configured with appropriate credentials
- Terraform >= 1.3 with hashicorp/aws provider >= 6.34.0
- Docker (to pull and push the container image)
- A Brave Search API key ([get one free](https://brave.com/search/api/))
- An OIDC identity provider with Dynamic Client Registration (DCR) support

## Setup

### 1. Configure your OIDC identity provider

You need an OIDC-compliant identity provider that supports:
- **OpenID Connect discovery** (`/.well-known/openid-configuration`)
- **Dynamic Client Registration** (DCR, [RFC 7591](https://datatracker.ietf.org/doc/html/rfc7591)) -- required for Claude Code's automatic OAuth flow
- **Authorization Code grant** with JWT access tokens

Configure your IdP with:
- A custom API / resource server (defines the `audience` for JWT tokens)
- A default audience so tokens include the correct `aud` claim
- A login connection (database, social, or enterprise) enabled for dynamically registered clients
- At least one test user

<details>
<summary><strong>Example: Auth0 setup</strong></summary>

This example was built with Auth0 (free tier). Install the Auth0 CLI and run:

```bash
# Create a custom API (defines the JWT audience)
auth0 apis create \
  --name "Brave Search MCP" \
  --identifier "https://brave-search-mcp.example.com" \
  --scopes "search:web"

# Enable Dynamic Client Registration
auth0 api patch "tenants/settings" \
  --data '{"flags":{"enable_dynamic_client_registration":true}}'

# Set default audience (so all tokens include the correct aud claim)
auth0 api patch "tenants/settings" \
  --data '{"default_audience":"https://brave-search-mcp.example.com"}'

# Enable the database connection for all clients (including DCR-created ones)
CONNECTION_ID=$(auth0 api get "connections" | python3 -c "
import json, sys
for c in json.load(sys.stdin):
    if c['strategy'] == 'auth0':
        print(c['id'])
")
auth0 api patch "connections/$CONNECTION_ID" \
  --data '{"is_domain_connection":true}'

# Create a test user
auth0 users create \
  -c "Username-Password-Authentication" \
  -e "you@example.com" \
  -p "YourPassword123!" \
  -n "Your Name"
```

Your OIDC discovery URL will be:
`https://your-tenant.eu.auth0.com/.well-known/openid-configuration`

</details>

<details>
<summary><strong>Notes for other IdPs</strong></summary>

- **Okta**: Create an Authorization Server and OIDC application. Okta supports DCR via its `/oauth2/v1/clients` endpoint. Set the default audience on the authorization server.
- **Microsoft Entra ID**: Register an application and configure API permissions. Note that Entra ID does not support DCR natively -- you may need to pre-register the Claude Code client using `--client-id` (see step 5).
- **Amazon Cognito**: Create a User Pool with an app client. Note that Cognito does not support DCR -- use pre-configured OAuth credentials with `--client-id` and `--client-secret` in the Claude Code config (see step 5).

</details>

### 2. Push the Brave Search MCP image to ECR

AgentCore Runtime requires container images from ECR. Pull from Docker Hub and push to your private ECR:

```bash
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGION=eu-west-1

# Create ECR repository
aws ecr create-repository --repository-name brave-search-mcp --region $REGION

# Login to ECR
aws ecr get-login-password --region $REGION | \
  docker login --username AWS --password-stdin $AWS_ACCOUNT.dkr.ecr.$REGION.amazonaws.com

# Pull, tag, push
docker pull mcp/brave-search:latest
docker tag mcp/brave-search:latest $AWS_ACCOUNT.dkr.ecr.$REGION.amazonaws.com/brave-search-mcp:latest
docker push $AWS_ACCOUNT.dkr.ecr.$REGION.amazonaws.com/brave-search-mcp:latest
```

### 3. Configure Terraform variables

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
brave_mcp_api_key       = "YOUR_BRAVE_API_KEY"
brave_mcp_container_uri = "123456789012.dkr.ecr.eu-west-1.amazonaws.com/brave-search-mcp:latest"

brave_mcp_oidc_discovery_url     = "https://your-idp.example.com/.well-known/openid-configuration"
brave_mcp_oidc_allowed_audiences = ["https://brave-search-mcp.example.com"]
```

If your AWS CLI uses a named profile, update the `profile` in `main.tf` or remove it to use the default profile.

### 4. Deploy

```bash
terraform init
terraform apply
```

This creates 3 resources:
- IAM role + policy (CloudWatch logs, ECR pull)
- AgentCore Runtime (Brave Search MCP container with OIDC auth)

Deployment takes about 20 seconds. Terraform outputs the MCP endpoint URL.

### 5. Configure Claude Code

Add the MCP server to your Claude Code config (user scope so it's available in all projects):

```bash
# For IdPs that support DCR (Auth0, Okta):
claude mcp add-json brave_search \
  "{\"type\":\"http\",\"url\":\"$(terraform output -raw brave_mcp_endpoint)\",\"oauth\":{\"authServerMetadataUrl\":\"https://your-idp.example.com/.well-known/oauth-authorization-server\"}}" \
  --scope user

# For IdPs without DCR (Cognito, Entra ID) -- pre-register a client and provide its ID:
claude mcp add-json brave_search \
  "{\"type\":\"http\",\"url\":\"$(terraform output -raw brave_mcp_endpoint)\",\"oauth\":{\"clientId\":\"your-client-id\",\"authServerMetadataUrl\":\"https://your-idp.example.com/.well-known/oauth-authorization-server\"}}" \
  --scope user --client-secret
```

No API keys or tokens in the config. Claude Code handles OAuth automatically:
1. Connects to the endpoint, receives a 401 with OAuth protected resource metadata
2. Discovers the OIDC provider as the authorization server
3. Registers itself via DCR (or uses pre-configured client credentials)
4. Opens your browser for login
5. Exchanges the authorization code for a JWT
6. Connects to the MCP server with the Bearer token
7. Subsequent sessions reuse cached tokens automatically

### 6. Verify

Start Claude Code and run `/mcp` to check the `brave_search` server status.

Or test from the command line:

```bash
# Should return 401 with WWW-Authenticate header (auth is enforced)
curl -s -o /dev/null -w "%{http_code}" \
  "$(terraform output -raw brave_mcp_endpoint)" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":1}'
# Expected: 401
```

## Available tools

The Brave Search MCP server exposes 6 tools:

| Tool | Description |
|---|---|
| `brave_web_search` | General web search with rich metadata |
| `brave_local_search` | Local business and location search |
| `brave_image_search` | Image search |
| `brave_video_search` | Video search |
| `brave_news_search` | News article search |
| `brave_summarizer` | AI-generated summaries of search results |

## Tear down

```bash
terraform destroy
```

To also remove the ECR repository:

```bash
aws ecr delete-repository --repository-name brave-search-mcp --region eu-west-1 --force
```

## Cost

- **AgentCore Runtime**: Pay per session + invocation. See [pricing](https://aws.amazon.com/bedrock/agentcore/pricing/).
- **Brave Search API**: $5 CPM ($0.005/request). $5 free credits/month.
