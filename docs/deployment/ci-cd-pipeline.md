# CI/CD Pipeline Guide

This document outlines the continuous integration and continuous deployment (CI/CD) pipeline setup for AWS projects.

## Overview

The CI/CD pipeline automates the process of building, testing, and deploying your application to AWS environments. This automation helps ensure consistent deployments and reduces the risk of human error.

## Pipeline Architecture

This template's pipeline deploys and destroys a `dev` environment per branch, including `main` itself — `main` is treated as the parent dev/integration branch, not a hands-off one, so it gets its own environment that stays in sync with whatever's currently merged. It isn't a promotion pipeline, and there's no built-in path to `prod`. Three workflows make it up:

1. **`main.yml`**: pushing to any branch — `main` included — deploys (or updates) that branch's `dev` environment. When a feature branch's PR merges into `main`, two independent things happen: the push to `main` redeploys `main`'s own environment with the newly-merged code, and the `pull_request: closed` event separately destroys the feature branch's now-obsolete environment and deletes the branch. A manual dispatch with `action: deploy` re-runs a deploy for whichever branch it's run against; `action: cleanup` tears down that branch's environment on demand.
2. **`pull-request.yml`**: runs on every pull request to `main` — tests, lint, a Trivy security scan, and infrastructure template validation. It doesn't deploy anything.
3. **`manual-destroy.yml`**: a manually-triggered teardown, gated behind typing `DESTROY` to confirm, for either the `dev` or `prod` environment. It only destroys — there's no equivalent manual deploy-to-prod workflow.

Every deploy/destroy step branches on two independent settings read from `config/project-config.json` (written by `scripts/init.sh`):

- **`infraType`** — `cloudformation` or `terraform`. Chooses which IaC tool provisions the shared network-facing infrastructure (security group, website hosting via CloudFront/S3, the example Lambda + API Gateway behind it).
- **`applicationType`** — `serverless`, `container`, or `ec2` (optional). Chooses how the application workload itself gets deployed. Only `serverless` is automated today (via the Serverless Framework); `container` and `ec2` generate local scaffolding (`docker-compose.yml`, `scripts/user-data.sh`) but have no automated deploy/destroy step yet — the pipeline logs an explicit warning rather than silently skipping.

### Per-branch naming

Every branch's dev environment — `main`'s included — is named `<repo>-<branch>-<hash>` — computed once by `scripts/compute-deploy-name.sh` and used consistently as the CloudFormation stack name, the Terraform state key, the Serverless stage, and every named resource inside them (security group, S3 bucket, Lambda, API Gateway, and so on). `<repo>` is the GitHub repository name itself, not `config/project-config.json`'s free-text `projectName` — this keeps the deployment name tied to something stable and guaranteed-unique-per-repo rather than a value someone typed into `init.sh` that could drift or collide across projects. The name is deliberately short (24 characters), comfortably under the tightest naming limit any resource in this template currently hits (~64 characters, for Lambda function/IAM role names), leaving headroom for whatever's added later. A raw `<repo>-<branch>` concatenation would still blow past a tighter limit like the 32-character cap on an ALB name, if one's ever added back — and truncating alone isn't safe either: two branches with a long shared prefix (`feature/add-login-oauth` vs. `feature/add-login-saml`) would truncate to the same string and silently deploy over each other. The trailing 8-character hash is computed from the *full* branch name before truncation, so it stays unique regardless of how similar or long two branch names are.

Deploy and destroy each compute this name independently from the branch name available to them — they never look it up or pass it between runs. Destroy specifically needs the *feature* branch's name, and a plain push to `main` doesn't carry which branch was just merged into it — but a closed PR does (`github.event.pull_request.head.ref`). That's why the feature-branch teardown triggers on a **merged pull request** rather than push-to-main, even though the redeploy of `main` itself is a plain push trigger. A direct push to `main` that bypasses a PR still redeploys `main` as usual, but won't trigger the feature-branch cleanup or its branch deletion.

`prod` isn't part of this scheme — nothing in this template deploys it automatically (see Environment Configuration below), so `manual-destroy.yml`'s `prod` option targets a fixed `<repo>-prod` name instead of a branch-derived one.

## Implementation Options

### GitHub Actions (Default)

The template includes GitHub Actions workflows in the `.github/workflows` directory:

- `main.yml`: deploys on every push, including to `main`; separately destroys a feature branch (and deletes it) when its PR is merged to `main`; supports a manual `deploy`/`cleanup` dispatch for any branch
- `pull-request.yml`: runs on pull requests to `main` to test, lint, scan, and validate infrastructure — doesn't deploy
- `manual-destroy.yml`: manually-triggered teardown of the `dev` or `prod` environment, gated behind a typed confirmation

#### Setup Instructions

1. Configure AWS credentials as GitHub secrets:
   - `AWS_ACCESS_KEY_ID`
   - `AWS_SECRET_ACCESS_KEY`
   - `AWS_REGION`

2. Customize the workflow files as needed for your project

### AWS CodePipeline Alternative

For projects that prefer using AWS native services instead of GitHub Actions:

1. Create a CodePipeline with the following stages:
   - Source: CodeCommit or GitHub connection
   - Build: CodeBuild project
   - Test: CodeBuild project with test commands
   - Deploy: CloudFormation/Terraform deployment

This template doesn't include a starter CodePipeline/CodeBuild template — building this out means replacing the GitHub Actions workflows above from scratch, not layering on top of them.

## Environment Configuration

### Development Environment

- Deployed automatically on every push, including to `main` (`main`'s own environment redeploys with whatever was just merged into it), or via a manual `main.yml` dispatch
- A feature branch's environment is destroyed automatically when its PR is merged to `main` (and the branch itself deleted), or via a manual `main.yml` dispatch — `main`'s own environment is never destroyed by this automatic path, only ever redeployed
- Each branch gets its own isolated, consistently-named environment (see "Per-branch naming" above) — pushing to a second branch never affects another branch's resources
- Resources are tagged with `Environment: dev`

### Production Environment

- Not deployed by this pipeline — there is no automated or manual path to a `prod` deploy today
- `manual-destroy.yml` accepts `prod` as a destroy target, for tearing down `prod` resources created some other way, but nothing in this template creates them

## Deployment Strategies

Nothing below is implemented by the workflows in this template today. It's reference material for if you outgrow the simple deploy/destroy model above and want to add zero-downtime or gradual-rollout deploys yourself.

### Blue/Green Deployment

For zero-downtime deployments:

1. Create a new (green) environment identical to the current (blue) environment
2. Deploy the new version to the green environment
3. Test the green environment
4. Switch traffic from blue to green
5. Decommission the blue environment when no longer needed

### Canary Deployment

For gradual rollout:

1. Deploy the new version to a small percentage of the infrastructure
2. Monitor for any issues
3. Gradually increase the percentage until 100%
4. Roll back if issues are detected

## Rollback Procedures

In case of deployment failures:

1. Automatic rollback: The pipeline automatically reverts to the last successful deployment if tests fail
2. Manual rollback: Use the "Rollback" option in CloudFormation or run the deployment with the previous version

## Monitoring Deployments

Monitor deployments using:

1. CloudWatch Logs for application logs
2. CloudWatch Alarms for critical metrics
3. AWS X-Ray for tracing requests
4. CloudTrail for API activity

## Security Considerations

1. Use IAM roles with least privilege for the CI/CD pipeline
2. Scan code for vulnerabilities before deployment
3. Encrypt sensitive data in the pipeline using AWS Secrets Manager
4. Audit pipeline access and activities

## Best Practices

1. Keep the build and deployment scripts in the same repository as the application code
2. Use infrastructure as code for all environment provisioning
3. Make deployments idempotent and repeatable
4. Include rollback mechanisms in your deployment process
5. Test the deployment process itself regularly

## Troubleshooting

Common issues and solutions:

1. **Failed builds**: Check build logs for compilation errors or failed tests
2. **Deployment failures**: Verify IAM permissions and CloudFormation/Terraform templates
3. **Timeout issues**: Increase timeout settings for long-running deployments
4. **Resource conflicts**: Use logical IDs consistently to avoid duplicate resource creation