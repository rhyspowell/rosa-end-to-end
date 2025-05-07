# Simple script to build HCP cluster

HCP requires you to have your VPC and subnets built to allow for installation. In this instance, we use terraform for that creation.

> As this is designed mostly for demo purposes and allowing people to get a cluster up and running quickly, we then use the ROSA and OC commands to build out the next steps, mostly to show how easy it can be, want to do it all in terraform, no worries, check out [here](https://docs.redhat.com/en/documentation/red_hat_openshift_service_on_aws/4/html/install_rosa_with_hcp_clusters/creating-a-rosa-cluster-using-terraform#sd-terraform-cluster-destroy_rosa-hcp-creating-a-cluster-quickly-terraform), it has everything you could need.

The script starts with a quick_export.sh file check, thats due to my workflow and the need to set certain settings to make the script run correctly. It is also a file where you can set password, region, cluster name and version. These can also be set, using the -p, -r, -c and -v options into the script. Other than password some defaults have been set in the script.


