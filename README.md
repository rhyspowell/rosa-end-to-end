# Simple script to build HCP cluster

HCP requires you to have your VPC and subnets built to allow for installation. In this instance, we use terraform for that creation.

> As this is designed mostly for demo purposes and allowing people to get a cluster up and running quickly, we then use the ROSA and OC commands to build out the next steps, mostly to show how easy it can be, want to do it all in terraform, no worries, check out [here](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/install_rosa_with_hcp_clusters/creating-a-rosa-cluster-using-terraform#sd-terraform-cluster-destroy_rosa-hcp-creating-a-cluster-quickly-terraform), it has everything you could need.

The script starts with a quick_export.sh file check, thats due to my workflow and the need to set certain settings to make the script run correctly. It is also a file where you can set password, region, cluster name and version. These can also be set, using the -p, -r, -c and -v options into the script. Other than password some defaults have been set in the script.

For the terraform build variables.tf contains whats required with some sensible generic defaults. ```terraform.tfvars``` is an easy way to override anything you would want to customise in this area.

### Destroy Script

This will allow you to clean up the cluster build. Should the build script fail its recommended that this be run to make sure everything is deployed in a clean fashion.

### ArgoCD - The power of the platform

ArgoCD bring the power to the cluster, this is key to the multi/hybrid cloud environment and is the key to removing many of the issues that are normally associated with DR. The option to deploy it here comes with the ```-a```. This example is really just that, nothing complex, just here to give yo uan idea of how the cluster can be built out in a controlled manner, using code.
