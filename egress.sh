VPC_NAME=test-vpc
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$VPC_NAME" --query "Vpcs[0].VpcId" --output text)

# store the private subnet IDs and CIDR ranges together so each IP can be reserved in the right subnet
PRIVATE_SUBNETS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag:Name,Values=*private*" --query "Subnets[].[SubnetId,CidrBlock]" --output text)
PRIVATE_SUBNET_IDS=$(awk '{print $1}' <<< "$PRIVATE_SUBNETS")
PRIVATE_SUBNET_CIDRS=$(awk '{print $2}' <<< "$PRIVATE_SUBNETS")
echo "Private subnet IDs: $PRIVATE_SUBNET_IDS"
echo "Private subnet CIDRs: $PRIVATE_SUBNET_CIDRS"

# reuse the web server security group if it already exists, otherwise create it
SG_NAME=test-web-server-sg
SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' \
  --output text \
  --no-cli-pager)
if [ -z "$SECURITY_GROUP_ID" ] || [ "$SECURITY_GROUP_ID" = "None" ]; then
  echo "Creating security group $SG_NAME"
  SECURITY_GROUP_ID=$(aws ec2 create-security-group \
    --group-name "$SG_NAME" \
    --description "Security group for test web server" \
    --vpc-id "$VPC_ID" \
    --query 'GroupId' \
    --output text \
    --no-cli-pager)
else
  echo "Using existing security group $SECURITY_GROUP_ID"
fi

echo "Waiting for security group $SECURITY_GROUP_ID to exist..."
aws ec2 wait security-group-exists --group-ids "$SECURITY_GROUP_ID" --no-cli-pager
echo "Security group $SECURITY_GROUP_ID is ready"

HAS_8080=$(aws ec2 describe-security-groups --group-ids "$SECURITY_GROUP_ID" --no-cli-pager \
  --query 'length(SecurityGroups[0].IpPermissions[?FromPort==`8080` && ToPort==`8080` && IpProtocol==`tcp` && IpRanges[?CidrIp==`0.0.0.0/0`]])' \
  --output text)
if [ "${HAS_8080:-0}" -eq 0 ]; then
  echo "Allowing TCP 8080 from 0.0.0.0/0 on $SECURITY_GROUP_ID"
  aws ec2 authorize-security-group-ingress \
    --group-id "$SECURITY_GROUP_ID" \
    --protocol tcp --port 8080 --cidr 0.0.0.0/0 \
    --no-cli-pager
else
  echo "TCP 8080 from 0.0.0.0/0 already allowed on $SECURITY_GROUP_ID"
fi

# create a small instance with web server that will be used to test the egress IP assignment
WEB_SUBNET_ID=$(awk '{print $1; exit}' <<< "$PRIVATE_SUBNET_IDS")
USER_DATA=$(cat <<'EOF'
#!/bin/bash
set -euxo pipefail

sudo dnf install -y https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_arm64/amazon-ssm-agent.rpm
sudo systemctl start amazon-ssm-agent
sudo systemctl enable amazon-ssm-agent

sudo dnf install -y go-toolset
/usr/bin/go install github.com/jmalloc/echo-server/cmd/echo-server@latest
PORT=8080 go/bin/echo-server &
EOF
)

# copy the VPC tags onto the instance, keeping a distinct Name so we can find it later
VPC_TAGS=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --query 'Vpcs[0].Tags' --output json --no-cli-pager)
TAG_SPEC=$(jq -c '
  (. // [])
  | map(select(.Key != "Name"))
  + [{"Key":"Name","Value":"test-web-server"}]
  | [{ResourceType:"instance",Tags:.}]
' <<< "$VPC_TAGS")

# AMI: https://eu-west-2.console.aws.amazon.com/ec2/home?region=eu-west-2#LaunchInstances:ami=ami-058603bce5b4ce304
SSM_ROLE_NAME=test-web-server-ssm-role
SSM_PROFILE_NAME=test-web-server-ssm

if aws iam get-role --role-name "$SSM_ROLE_NAME" --no-cli-pager >/dev/null 2>&1; then
  echo "Using existing IAM role $SSM_ROLE_NAME"
else
  echo "Creating IAM role $SSM_ROLE_NAME"
  aws iam create-role \
    --role-name "$SSM_ROLE_NAME" \
    --assume-role-policy-document '{
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Principal": {"Service": "ec2.amazonaws.com"},
        "Action": "sts:AssumeRole"
      }]
    }' \
    --no-cli-pager >/dev/null
fi

SSM_POLICY_ATTACHED=$(aws iam list-attached-role-policies --role-name "$SSM_ROLE_NAME" --no-cli-pager \
  --query "AttachedPolicies[?PolicyName=='AmazonSSMManagedInstanceCore'].PolicyName" --output text)
if [ -z "$SSM_POLICY_ATTACHED" ]; then
  echo "Attaching AmazonSSMManagedInstanceCore to $SSM_ROLE_NAME"
  aws iam attach-role-policy \
    --role-name "$SSM_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore \
    --no-cli-pager
fi

if aws iam get-instance-profile --instance-profile-name "$SSM_PROFILE_NAME" --no-cli-pager >/dev/null 2>&1; then
  echo "Using existing instance profile $SSM_PROFILE_NAME"
else
  echo "Creating instance profile $SSM_PROFILE_NAME"
  aws iam create-instance-profile --instance-profile-name "$SSM_PROFILE_NAME" --no-cli-pager >/dev/null
fi

PROFILE_ROLE=$(aws iam get-instance-profile --instance-profile-name "$SSM_PROFILE_NAME" --no-cli-pager \
  --query 'InstanceProfile.Roles[0].RoleName' --output text)
if [ -z "$PROFILE_ROLE" ] || [ "$PROFILE_ROLE" = "None" ]; then
  echo "Adding $SSM_ROLE_NAME to instance profile $SSM_PROFILE_NAME"
  aws iam add-role-to-instance-profile \
    --instance-profile-name "$SSM_PROFILE_NAME" \
    --role-name "$SSM_ROLE_NAME" \
    --no-cli-pager
fi

echo "Waiting for instance profile $SSM_PROFILE_NAME..."
aws iam wait instance-profile-exists --instance-profile-name "$SSM_PROFILE_NAME"

INSTANCE_ID=$(aws ec2 describe-instances \
  --filters \
    "Name=tag:Name,Values=test-web-server" \
    "Name=vpc-id,Values=$VPC_ID" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text \
  --no-cli-pager)

if [ -n "$INSTANCE_ID" ] && [ "$INSTANCE_ID" != "None" ]; then
  echo "Using existing web server instance $INSTANCE_ID"
  INSTANCE_STATE=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].State.Name' --output text --no-cli-pager)
  if [ "$INSTANCE_STATE" = "stopped" ] || [ "$INSTANCE_STATE" = "stopping" ]; then
    echo "Starting stopped instance $INSTANCE_ID"
    aws ec2 start-instances --instance-ids "$INSTANCE_ID" --no-cli-pager >/dev/null
  fi
else
  echo "Launching web server instance"
  # IAM can take a few seconds to be usable by EC2
  sleep 15
  INSTANCE_ID=$(aws ec2 run-instances \
    --image-id ami-058603bce5b4ce304 \
    --instance-type t4g.micro \
    --subnet-id "$WEB_SUBNET_ID" \
    --security-group-ids "$SECURITY_GROUP_ID" \
    --iam-instance-profile Name="$SSM_PROFILE_NAME" \
    --user-data "$USER_DATA" \
    --tag-specifications "$TAG_SPEC" \
    --query 'Instances[0].InstanceId' \
    --output text \
    --no-cli-pager)
fi

echo "Waiting for the web server to be ready..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --no-cli-pager
echo "Waiting for instance status checks to pass on $INSTANCE_ID..."
aws ec2 wait instance-status-ok --instance-ids "$INSTANCE_ID" --no-cli-pager
echo "Web server $INSTANCE_ID is ready"

WEB_SERVER_PRIVATE_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text --no-cli-pager)
echo "Web server private IP: $WEB_SERVER_PRIVATE_IP"

# take the highest address in each CIDR, subtract 12, and reserve that IP in AWS
EGRESS_IPS=()
while read -r subnet_id cidr; do
  [ -z "$subnet_id" ] && continue
  egress_ip=$(python3 -c "import ipaddress; print(ipaddress.ip_address(int(ipaddress.ip_network('$cidr').broadcast_address) - 12))")
  EGRESS_IPS+=("$egress_ip")
  echo "Reserving $egress_ip in $subnet_id"
  reservation_id=$(aws ec2 create-subnet-cidr-reservation \
    --subnet-id "$subnet_id" \
    --reservation-type prefix \
    --cidr "${egress_ip}/32" \
    --no-cli-pager \
    --query 'SubnetCidrReservation.SubnetCidrReservationId' \
    --output text)
  echo "Completed reservation of $egress_ip in $subnet_id ($reservation_id)"
done <<< "$PRIVATE_SUBNETS"
EGRESS_IPS_YAML=$(printf '    - %s\n' "${EGRESS_IPS[@]}")
echo "Egress IPs: ${EGRESS_IPS[*]}"


EGRESS_POOL_REPLICAS=1
rosa create machinepool --name egresslock-pool \
  --cluster="${ROSA_CLUSTER_NAME}" \
  --labels "k8s.ovn.org/egress-assignable=" \
  --replicas $EGRESS_POOL_REPLICAS \
  --instance-type m5.xlarge

echo "Waiting for $EGRESS_POOL_REPLICAS egress-assignable node(s) to become Ready..."
for _ in $(seq 1 120); do
  ready=$(oc get nodes -l 'k8s.ovn.org/egress-assignable=' -o json 2>/dev/null | jq '[.items[] | select(.status.conditions[] | select(.type=="Ready" and .status=="True"))] | length')
  echo "Ready egress-assignable nodes: ${ready:-0}/$EGRESS_POOL_REPLICAS"
  if [ "${ready:-0}" -ge "$EGRESS_POOL_REPLICAS" ]; then
    break
  fi
  sleep 10
done
if [ "${ready:-0}" -lt "$EGRESS_POOL_REPLICAS" ]; then
  echo "Timed out waiting for egress-assignable nodes"
  exit 1
fi
echo "All egress-assignable nodes are Ready"

oc new-project demo-egress-ns

oc new-project locked-egress-ns

# set the egress IPs in each private subnet
echo "Setting egress IPs in each private subnet"
cat <<EOF | oc apply -f -
apiVersion: k8s.ovn.org/v1
kind: EgressIP
metadata:
  name: locked-egress-ns
spec:
  egressIPs:
$EGRESS_IPS_YAML
  namespaceSelector:
    matchLabels:
      kubernetes.io/metadata.name: locked-egress-ns
EOF

echo
echo "Connect to the web instance with SSM Session Manager."
echo "Instance ID: $INSTANCE_ID"
echo "In that session, run:"
echo "  python -m http.server 8080"
echo "Leave that command running, return to this terminal, and press any key."
echo "Then go back to the SSM console to watch the requests."
read -n 1 -s -r -p "Press any key to continue..."
echo

echo "Creating a pod in the demo-egress-ns namespace that will use the load balancer hostname to connect to the service"
echo "This pod will not be assigned to an egress-assignable node"

oc delete pod demo-any-egress-ns -n demo-egress-ns --ignore-not-found
oc run \
  demo-any-egress-ns \
  --namespace=demo-egress-ns \
  --env=WEB_SERVER_PRIVATE_IP=$WEB_SERVER_PRIVATE_IP \
  --image=registry.access.redhat.com/ubi9/ubi \
  --overrides='{"spec":{"affinity":{"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"k8s.ovn.org/egress-assignable","operator":"DoesNotExist"}]}]}}}}}' -- \
  sleep 64000

echo "Waiting for the pod to be ready"
oc wait --for=condition=Ready pod/demo-any-egress-ns -n demo-egress-ns --timeout=300s

echo "Connecting to the pod and curling the service"
for i in {1..10}; do
  oc debug -n demo-egress-ns demo-any-egress-ns -- curl -s http://$WEB_SERVER_PRIVATE_IP:8080
done

echo "Creating a pod in the locked-egress-ns namespace that will use the load balancer hostname to connect to the service"
echo "This pod will be assigned to an egress-assignable node"

oc delete pod demo-locked-egress-ns -n locked-egress-ns --ignore-not-found
oc run \
  demo-locked-egress-ns \
  --namespace=locked-egress-ns \
  --env=WEB_SERVER_PRIVATE_IP=$WEB_SERVER_PRIVATE_IP \
  --image=registry.access.redhat.com/ubi9/ubi \
  --overrides='{"spec":{"affinity":{"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"k8s.ovn.org/egress-assignable","operator":"Exists"}]}]}}}}}' -- \
  sleep 64000

echo "Waiting for the pod to be ready"
oc wait --for=condition=Ready pod/demo-locked-egress-ns -n locked-egress-ns --timeout=300s

echo "Connecting to the pod and curling the service"
for i in {1..10}; do
  oc debug -n locked-egress-ns demo-locked-egress-ns -- curl -s http://$WEB_SERVER_PRIVATE_IP:8080
done