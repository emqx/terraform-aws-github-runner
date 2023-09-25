# Action runners deployment for emqx organization

Steps for the full setup, such as creating a GitHub app can be found in the root module's [README](../README.md).

- Uses a prebuilt AMI based on Ubuntu 22.04.
- Configured to run with org level runners.
- GitHub runner binary syncer is not deployed.
- Runners are ephemeral and will be used for one job only.

## Usage

All commands are run from the root repository directory.

### Build lambdas

```bash
.ci/build.sh
```

### Build AMI

```bash
cd images/emqx-amd64
packer init .
packer validate .
packer build github_agent.ubuntu.pkr.hcl
```

### Deploy

```bash
cd emqx
terraform init
terraform apply
```

You can receive the webhook details by running:

```bash
terraform output -raw webhook_endpoint
terraform output -raw webhook_secret
```
