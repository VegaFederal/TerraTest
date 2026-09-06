#!/bin/bash

# Colors for better output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}=========================================${NC}"
echo -e "${GREEN}AWS Project Initialization Script${NC}"
echo -e "${BLUE}=========================================${NC}"

# Corporate region/VPC/subnet defaults — see scripts/org-defaults.env.
# shellcheck source=org-defaults.env
source "$(dirname "$0")/org-defaults.env"

# Get project information
echo -e "${YELLOW}Please provide the following information:${NC}"
read -p "Project name: " PROJECT_NAME
read -p "Project description: " PROJECT_DESCRIPTION
read -p "Infrastructure type (CF/TF): " INFRA_TYPE
read -p "Application type (serverless/container/ec2): " APP_TYPE
read -p "AWS Region [$DEFAULT_AWS_REGION]: " AWS_REGION
AWS_REGION="${AWS_REGION:-$DEFAULT_AWS_REGION}"
read -p "Company VPC ID [$DEFAULT_VPC_ID]: " VPC_ID
VPC_ID="${VPC_ID:-$DEFAULT_VPC_ID}"
read -p "Subnet IDs (comma-separated) [$DEFAULT_SUBNET_IDS]: " SUBNET_IDS
SUBNET_IDS="${SUBNET_IDS:-$DEFAULT_SUBNET_IDS}"
read -p "GitHub repository URL: " GITHUB_REPO

# Validate inputs. AWS region/VPC ID/Subnet IDs fall back to
# scripts/org-defaults.env and so should never actually be blank.
if [ -z "$PROJECT_NAME" ] || [ -z "$INFRA_TYPE" ]; then
    echo -e "${YELLOW}Error: Project name and infrastructure type are required.${NC}"
    exit 1
fi
if [ -z "$AWS_REGION" ] || [ -z "$VPC_ID" ] || [ -z "$SUBNET_IDS" ]; then
    echo -e "${YELLOW}Error: AWS region, VPC ID, and Subnet IDs are required and have no default — check that scripts/org-defaults.env exists and is populated.${NC}"
    exit 1
fi

# Convert to lowercase for consistency
INFRA_TYPE=$(echo "$INFRA_TYPE" | tr '[:upper:]' '[:lower:]')
APP_TYPE=$(echo "$APP_TYPE" | tr '[:upper:]' '[:lower:]')

# Normalize to the values the GitHub Actions workflows expect
case "$INFRA_TYPE" in
  cf|cloudformation) INFRA_TYPE="cloudformation" ;;
  tf|terraform) INFRA_TYPE="terraform" ;;
  *)
    echo -e "${YELLOW}Error: Infrastructure type must be one of CF, TF.${NC}"
    exit 1
    ;;
esac

# Application type is optional (leave blank for infra-only projects).
case "$APP_TYPE" in
  ""|serverless|container|ec2) ;;
  *)
    echo -e "${YELLOW}Error: Application type must be blank or one of serverless, container, ec2.${NC}"
    exit 1
    ;;
esac

# Update README with project info
sed "s/# AWS Project Template/# $PROJECT_NAME/g" README.md > README.md.tmp && mv README.md.tmp README.md
sed "s/A comprehensive template repository to help developers quickly start new AWS projects with best practices built-in./$PROJECT_DESCRIPTION/g" README.md > README.md.tmp && mv README.md.tmp README.md

# Create project config file
mkdir -p config
cat > config/project-config.json << EOL
{
  "projectName": "$PROJECT_NAME",
  "description": "$PROJECT_DESCRIPTION",
  "infraType": "$INFRA_TYPE",
  "applicationType": "$APP_TYPE",
  "awsRegion": "$AWS_REGION",
  "vpcId": "$VPC_ID",
  "subnetIds": "$SUBNET_IDS",
  "githubRepo": "$GITHUB_REPO",
  "createdAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOL

# Clean up unused infrastructure directories
if [ "$INFRA_TYPE" != "cloudformation" ]; then
    rm -rf infrastructure/cloudformation
fi

if [ "$INFRA_TYPE" != "terraform" ]; then
    rm -rf infrastructure/terraform
fi

# Set up infrastructure files based on selection. CloudFormation needs
# nothing generated here — the templates already committed in
# infrastructure/cloudformation/ are the real, working, parameterized ones
# (VpcId/SubnetIds deliberately have no Default: baked in; main.yml supplies
# them fresh from config/project-config.json on every deploy). Generating a
# fresh, minimal main-template.yaml here used to silently overwrite that
# working template with a broken one (an empty Outputs: section parses as
# `Outputs: null` in YAML, which CloudFormation's API rejects outright) and
# orphan static-website.yaml/api.yaml, which the minimal version never
# referenced.
if [ "$INFRA_TYPE" == "terraform" ]; then
    # Create Terraform variables file with VPC info
    cat > infrastructure/terraform/terraform.tfvars << EOL
project_name = "$PROJECT_NAME"
environment = "dev"
aws_region = "$AWS_REGION"
vpc_id = "$VPC_ID"
subnet_ids = [$(echo $SUBNET_IDS | sed 's/,/","/g' | sed 's/^/"/' | sed 's/$/"/')] 
EOL
fi

# Set up application structure based on type
if [ "$APP_TYPE" == "serverless" ]; then
    # Create serverless.yml for serverless framework
    cat > serverless.yml << EOL
service: $PROJECT_NAME

frameworkVersion: '3'

provider:
  name: aws
  runtime: nodejs22.x
  region: $AWS_REGION
  stage: \${opt:stage, 'dev'}
  vpc:
    securityGroupIds:
      - !Ref ServerlessSecurityGroup
    subnetIds: $(echo $SUBNET_IDS | sed 's/,/\n      - /g' | sed '1s/^/\n      - /')

functions:
  hello:
    handler: src/lambda/example-function/index.handler
    events:
      - httpApi:
          path: /hello
          method: get

resources:
  Resources:
    ServerlessSecurityGroup:
      Type: AWS::EC2::SecurityGroup
      Properties:
        GroupDescription: Security group for serverless functions
        VpcId: $VPC_ID
        SecurityGroupEgress:
        - IpProtocol: "-1"
          CidrIp: 0.0.0.0/0
EOL

elif [ "$APP_TYPE" == "container" ]; then
    # Create docker-compose.yml with VPC info as environment variables
    cat > docker-compose.yml << EOL
version: '3'
services:
  app:
    build: .
    ports:
      - "8080:8080"
    environment:
      - NODE_ENV=development
      - VPC_ID=$VPC_ID
      - SUBNET_IDS=$SUBNET_IDS
EOL

elif [ "$APP_TYPE" == "ec2" ]; then
    # Create user-data script for EC2 with VPC info
    cat > scripts/user-data.sh << EOL
#!/bin/bash
yum update -y
yum install -y httpd
systemctl start httpd
systemctl enable httpd
echo "<h1>Hello from $PROJECT_NAME!</h1>" > /var/www/html/index.html
echo "<p>Running in VPC: $VPC_ID</p>" >> /var/www/html/index.html
EOL
    chmod +x scripts/user-data.sh
fi

# Create VPC documentation
cat > docs/architecture/vpc-integration.md << EOL
# VPC Integration Guide

## Overview

This project is designed to deploy into the company's existing VPC infrastructure. All resources that require VPC connectivity will be deployed into the pre-configured VPC and subnets managed by the company administrators.

## VPC Details

- **VPC ID**: \`$VPC_ID\`
- **Subnet IDs**: \`$SUBNET_IDS\`

## Integration Points

### Network Resources

All network-dependent resources in this project will be deployed into the existing VPC infrastructure. This includes:

- EC2 instances
- RDS databases
- Lambda functions (when VPC access is required)
- Load balancers
- ECS tasks

### Security Groups

Security groups will be created within the existing VPC but managed by this project. Ensure that any security group rules comply with company network policies.

### Connectivity

For resources that need to communicate with external services:

1. Ensure the subnet has appropriate route tables configured
2. Check that security groups allow the necessary outbound traffic
3. Verify that network ACLs permit the required traffic

## Deployment Considerations

1. **Subnet Selection**: Choose appropriate subnets based on the resource requirements:
   - Public subnets for internet-facing resources
   - Private subnets for internal resources

2. **Availability Zones**: Distribute resources across multiple AZs for high availability

3. **IP Address Management**: Be mindful of IP address consumption in the shared VPC

## Troubleshooting

If you encounter connectivity issues:

1. Verify subnet configurations
2. Check security group rules
3. Validate network ACL settings
4. Ensure route tables are properly configured
5. Contact the network administrator if issues persist
EOL

echo -e "${GREEN}Project initialization complete!${NC}"
echo -e "${BLUE}Next steps:${NC}"
echo -e "1. Review and customize the generated files"
echo -e "2. Commit and push to your repository"
echo -e "3. Start building your application"
echo -e "${BLUE}=========================================${NC}"