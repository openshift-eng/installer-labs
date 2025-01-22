This lab demonstrates how to create an openshift cluster in existing subnets.

Executing the [main.sh](main.sh) script will:
    1. provision a VPC with subnets, as declared in [main.cfn.yaml](main.cfn.yaml)
    1. generate a install-config file with the provisioned subnet IDs, from the template [install-config.env.yaml](install-config.env.yaml)
    1. create a cluster with the generated install-config file, under `.cluster`
