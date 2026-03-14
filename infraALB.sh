#!/bin/bash

VPC_CIDR="10.0.0.0/16"
REGION="us-east-1"
AZ1="us-east-1a"
AZ2="us-east-1b"
NAME_VPC="vpcCLI"
KEY_NAME="UbuntuKey"
AMI_ID="ami-084568db4383264d4"
DB_INDENTIFIER="bancoDB"
DB_NAME="meusite_db"
DB_USER="admin"
DB_PASS="SENHA-DO-DB"
DB_CLASS="db.t3.micro"
DB_ENGINE="mysql"
DB_VERSION="8.0.35"
DB_STORAGE="20"
DB_SUBNET_GROUP_NAME="rds-subnet-group"
REGION="us-east-1"


VPC_ID=$(aws ec2 create-vpc --cidr-block $VPC_CIDR --region $REGION --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=vpcCLI}]" --query 'Vpc.VpcId' --output text)

PUB_SUBNET1=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.1.0/24 --availability-zone $AZ1 --tag-specifications "ResourceType=subnet, Tags=[{Key=Name,Value=Subpub1a}]" --query 'Subnet.SubnetId' --output text)

PUB_SUBNET2=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.2.0/24 --availability-zone $AZ2 --tag-specifications "ResourceType=subnet, Tags=[{Key=Name,Value=Subpub1b}]" --query 'Subnet.SubnetId' --output text)

PRIV_SUBNET1=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.3.0/24 --availability-zone $AZ1 --tag-specifications "ResourceType=subnet, Tags=[{Key=Name,Value=Subpriv1a}]" --query 'Subnet.SubnetId' --output text)

PRIV_SUBNET2=$(aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.4.0/24 --availability-zone $AZ2 --tag-specifications "ResourceType=subnet, Tags=[{Key=Name,Value=Subpriv2b}]" --query 'Subnet.SubnetId' --output text)

export IGW_ID=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)

aws ec2 attach-internet-gateway --internet-gateway-id $IGW_ID --vpc-id $VPC_ID

export RTB_ID=$(aws ec2 create-route-table --vpc-id $VPC_ID --query 'RouteTable.RouteTableId' --output text)

aws ec2 associate-route-table --route-table-id $RTB_ID --subnet-id $PUB_SUBNET1
aws ec2 associate-route-table --route-table-id $RTB_ID --subnet-id $PUB_SUBNET2

aws ec2 create-route --route-table-id $RTB_ID --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW_ID

export SG_EC2=$(aws ec2 create-security-group --group-name sgCLI --description "Acesso SSH, HTTP e HTTPS" --vpc-id $VPC_ID --query 'GroupId' --output text)

export SG_RDS=$(aws ec2 create-security-group --group-name sgDB --description "Acesso DB " --vpc-id $VPC_ID --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress --group-id $SG_RDS --protocol tcp --port 3306 --source-group $SG_EC2 || true

aws ec2 authorize-security-group-ingress --group-id $SG_EC2 --protocol tcp --port 443 --cidr 0.0.0.0/0 || true

aws ec2 authorize-security-group-ingress --group-id $SG_EC2 --protocol tcp --port 80 --cidr 0.0.0.0/0 || true

aws ec2 authorize-security-group-ingress --group-id $SG_EC2 --protocol tcp --port 22 --cidr 0.0.0.0/0 || true

aws rds create-db-subnet-group --db-subnet-group-name $DB_SUBNET_GROUP_NAME --db-subnet-group-description "sitedb" --subnet-ids $PRIV_SUBNET1 $PRIV_SUBNET2 || true

aws rds create-db-instance --db-instance-identifier $DB_INDENTIFIER --db-name $DB_NAME --db-instance-class $DB_CLASS --engine $DB_ENGINE --engine-version $DB_VERSION --master-username $DB_USER --master-user-password $DB_PASS --allocated-storage $DB_STORAGE --vpc-security-group-ids $SG_RDS --db-subnet-group-name $DB_SUBNET_GROUP_NAME  --no-publicly-accessible --region $REGION || true

INSTANCE_ID=$(aws ec2 run-instances --image-id $AMI_ID --instance-type t2.micro --key-name $KEY_NAME --security-group-ids $SG_EC2 --subnet-id $PUB_SUBNET1 --associate-public-ip-address --user-data file://webserver.sh --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=WebServer}]" --query 'Instances[0].InstanceId' --output text)

aws ec2 wait instance-running --instance-ids $INSTANCE_ID

AMI_ID=$(aws ec2 create-image --instance-id $INSTANCE_ID --name imgwebserver --no-reboot --query 'ImageId' --output text)

aws ec2 wait image-available --image-ids $AMI_ID

cat > lt-data.json <<EOF
{
  "ImageId": "$AMI_ID",
  "InstanceType": "t2.micro",
  "UserData": "$USER_DATA_BASE64",
  "SecurityGroupIds": ["$SG_EC2"]
}
EOF

aws ec2 create-launch-template --launch-template-name imgwebserver --version-description version1 --launch-template-data file:// lt-data.json

TARGET_GROUP_ARN=$(aws elbv2 create-target-group --name tg-webserver --protocol HTTP --port 80 --vpc-id $VPC_ID --target-type instance --query 'TargetGroups[0].TargetGroupArn' --output text)

ALB_ARN=$(aws elbv2 create-load-balancer --name alb-web --subnets $PUB_SUBNET1 $PUB_SUBNET2 --security-groups $SG_EC2 --scheme internet-facing --type application --query 'LoadBalancers[0].LoadBalancerArn' --output text)

aws autoscaling create-auto-scaling-group --auto-scaling-group-name sg-webauto --launch-template LaunchTemplateName=imgwebserver,Version="1" --min-size 2 --max-size 4 --desired-capacity 2 --vpc-zone-identifier $PUB_SUBNET1,$PUB_SUBNET2 --target-group-arns $TARGET_GROUP_ARN
