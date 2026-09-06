# AWS Project Template

A comprehensive template repository to help developers quickly start new AWS projects with best practices built-in.

## Features

- Infrastructure as Code (IaC) using AWS CloudFormation or Terraform
- CI/CD pipeline configuration
- Security best practices
- Logging and monitoring setup
- Cost optimization guidelines
- Project structure for common application types

## Getting Started

1. Click the "Use this template" button on GitHub to create a new repository based on this template
2. Clone your new repository
3. Run the initialization script: `./scripts/init.sh`
4. Follow the prompts to customize your project
5. Start building your application!

`init.sh` asks for two independent settings:

- **Infrastructure type** (`CF`/`TF`) — which IaC tool provisions your infrastructure. **Picking one deletes the `infrastructure/` subdirectory for the other** (choosing `CF` removes `infrastructure/terraform`, and vice versa), so make sure you've settled on one before running it.
- **Application type** (`serverless`/`container`/`ec2`, optional) — how your application workload deploys. Only `serverless` has an automated deploy/destroy path today; `container` and `ec2` just generate local scaffolding (`docker-compose.yml`, `scripts/user-data.sh`) for you to build out yourself.

Both are written to `config/project-config.json`, which every workflow reads to decide what to deploy or destroy — commit it once `init.sh` has run.

`init.sh` also prompts for the AWS region, VPC ID, and subnet IDs to deploy into. These default to the corporate dev account's values in `scripts/org-defaults.env` — press Enter to accept them, or type something else if a project genuinely needs a different VPC. Project name and infrastructure type have no default and must be entered.

If you picked Terraform, there's one more one-time step: run `./scripts/setup-terraform-backend.sh` to create the S3 bucket and DynamoDB lock table Terraform state lives in, then commit the `infrastructure/terraform/backend.hcl` it generates. Deploys will fail without it — Terraform has nowhere to store or lock state otherwise.

## CI/CD

`main` is treated as the parent dev/integration branch, not a hands-off branch — merging a feature branch into it redeploys `main`'s own environment with the newly-merged code, right alongside tearing down the feature branch's environment.

- `main.yml` deploys a `dev` environment on every push, including to `main`, and destroys the *feature branch's* environment (and deletes the branch itself) when its PR is merged to `main` — deploy and destroy fire independently and target different environments, so they don't conflict on the same merge
- `pull-request.yml` runs tests/lint/security-scan/infrastructure validation on pull requests to `main`
- `manual-destroy.yml` is a manually-triggered teardown of the `dev` or `prod` environment, gated behind typing `DESTROY` to confirm

Deployment happens exclusively through these workflows — there's no local deploy script. Use `main.yml`'s manual dispatch (`action: deploy`) if you need to trigger a deploy outside of a push.

Every branch — `main` included — gets its own isolated environment, named `<repo>-<branch>-<hash>` (see `scripts/compute-deploy-name.sh`; `<repo>` is the GitHub repository name, not the free-text project name from `init.sh`) — short enough to fit AWS's tightest resource-name limits, and collision-safe even when two branch names are long and nearly identical. This one computed name is used consistently for the CloudFormation stack, the Terraform state file, the Serverless stage, and every named resource within them (security group, S3 bucket, Lambda, API Gateway, ...), so a branch's resources are easy to find and never collide with another branch's.

Destroy still needs the merged branch's name specifically (a plain push to `main` doesn't carry which branch was just merged into it, but a closed PR does), so the destroy-and-delete-branch side triggers on a **merged pull request** rather than push-to-main. A direct push to `main` that bypasses a PR redeploys `main` as usual, but won't trigger the feature-branch cleanup — enable branch protection requiring PRs into `main` if you want that guaranteed.

See `docs/deployment/ci-cd-pipeline.md` for the full picture.

## Directory Structure

- `/infrastructure` - CloudFormation/Terraform templates (`init.sh` removes whichever one you don't pick)
- `/src` - Application source code
- `/tests` - Test files — a starting point, empty until you add your own
- `/scripts` - Utility scripts
- `/docs` - Documentation
- `/config` - Configuration files, created by `init.sh`
- `/.github` - GitHub Actions workflows

## Documentation

See the `/docs` directory for detailed documentation on:
- Architecture patterns
- Deployment procedures
- Security guidelines
- Cost optimization
- Troubleshooting