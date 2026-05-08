#!/bin/bash

set -e

# Define the age threshold in hours
AGE=5
THRESHOLD_DATE=$(date -u -d "${AGE} hours ago" +"%Y-%m-%dT%H:%M:%SZ")

AGE_S3=24
THRESHOLD_DATE_S3=$(date -u -d "${AGE_S3} hours ago" +"%Y-%m-%dT%H:%M:%SZ")

command -v aws > /dev/null || { echo "Error: Install aws"; exit 1; }
command -v jq > /dev/null || { echo "Error: Install jq"; exit 1; }
command -v xargs > /dev/null || { echo "Error: Install xargs"; exit 1; }

filter_instances() {
    local json=$1

    jq -r --arg threshold "$THRESHOLD_DATE" '
        .Reservations[]?.Instances[]?
        | select(.LaunchTime <= $threshold)
        | select(.Tags // [] | any(.Key == "createdBy" and .Value == "gh-openshift-ci"))
        | .InstanceId
    ' <<< "$json"
}

filter_volumes() {
    local json=$1

    jq -r --arg threshold "$THRESHOLD_DATE" '
        .Volumes[]?
        | select(.CreateTime <= $threshold)
        | select(.State == "available")
        | select(.Tags // [] | any(
            .Key == "createdBy" and .Value == "gh-openshift-ci" or
            .Key == "kubernetes.io/created-for/pvc/namespace" and .Value == "openshift-storage" or
            .Key == "kubernetes.io/created-for/pvc/namespace" and .Value == "openshift-monitoring"
        ))
        | .VolumeId
    ' <<< "$json"
}

filter_nat_gateways() {
    local json=$1

    jq -r --arg threshold "$THRESHOLD_DATE" '
        .NatGateways[]?
        | select(.CreateTime <= $threshold)
        | select(.State == "available")
        | select(.Tags // [] | any(.Key == "createdBy" and .Value == "gh-openshift-ci"))
        | .NatGatewayId
    ' <<< "$json"
}

filter_network_interfaces() {
    local json=$1

    jq -r '
        .NetworkInterfaces[]?
        | select(.Status == "available")
        | select(.TagSet // [] | any(.Key == "createdBy" and .Value == "gh-openshift-ci"))
        | .NetworkInterfaceId
    ' <<< "$json"
}

filter_s3_buckets() {
    local json=$1

    jq -r --arg threshold "$THRESHOLD_DATE_S3" '
        .Buckets[]?
        | select(.CreationDate <= $threshold)
        | select(.Name | startswith("nb"))
        | .Name
    ' <<< "$json"
}

filter_load_balancers() {
    local json_age=$1
    local json_tags=$2

    local arns_age=$(jq -c --arg threshold "$THRESHOLD_DATE" '
        [
            .LoadBalancers[]?
            | select(.CreatedTime <= $threshold)
            | .LoadBalancerArn
        ]
    ' <<< "$json_age")

    local arns_tags=$(jq -c '
        [
            .ResourceTagMappingList[]?
            | select(.Tags // [] | any(.Key == "createdBy" and .Value == "gh-openshift-ci"))
            | .ResourceARN
        ]
    ' <<< "$json_tags")

    # Filter common
    jq -n -r --argjson arr1 "$arns_age" --argjson arr2 "$arns_tags" '
        ($arr1 - ($arr1 - $arr2))[]
    '
}

for region in us-east-1 us-east-2 us-west-1 us-west-2; do

    echo List and Filter instances in $region
    instances=$(aws ec2 describe-instances --region "$region" --output json)
    filtered_instances=$(filter_instances "$instances")
    echo "$filtered_instances"
    echo "$filtered_instances" | xargs -I {} aws ec2 terminate-instances --region "$region" --instance-ids {}

    echo List and Filter volumes in $region
    volumes=$(aws ec2 describe-volumes --region "$region" --output json)
    filtered_volumes=$(filter_volumes "$volumes")
    echo "$filtered_volumes"
    echo "$filtered_volumes" | xargs -I {} aws ec2 delete-volume --region "$region" --volume-id {}

    echo List and Filter nat gateways in $region
    nat_gateways=$(aws ec2 describe-nat-gateways --region "$region" --output json)
    filtered_nat_gateways=$(filter_nat_gateways "$nat_gateways")
    echo "$filtered_nat_gateways"
    echo "$filtered_nat_gateways" | xargs -I {} aws ec2 delete-nat-gateway --region "$region" --nat-gateway-id {}

    echo List and Filter network interfaces in $region
    network_interfaces=$(aws ec2 describe-network-interfaces --region "$region" --output json)
    filtered_network_interfaces=$(filter_network_interfaces "$network_interfaces")
    echo "$filtered_network_interfaces"
    echo "$filtered_network_interfaces" | xargs -I {} aws ec2 delete-network-interface --region "$region" --network-interface-id {}

    echo List and Filter load balancers in $region
    load_balancers=$(aws elbv2 describe-load-balancers --region "$region" --output json)
    load_balancers_tags=$(aws resourcegroupstaggingapi get-resources --resource-type-filters elasticloadbalancing:loadbalancer --region "$region" --output json)
    filtered_load_balancers=$(filter_load_balancers "$load_balancers" "$load_balancers_tags")
    echo "$filtered_load_balancers"
    echo "$filtered_load_balancers" | xargs -I {} aws elbv2 delete-load-balancer --region "$region" --load-balancer-arn {}

done

echo List and Filter s3 buckets in $region
s3_buckets=$(aws s3api list-buckets --output json)
filtered_s3_buckets=$(filter_s3_buckets "$s3_buckets")
echo "$filtered_s3_buckets"
echo "$filtered_s3_buckets" | xargs -I {} aws s3 rb s3://{} --force
