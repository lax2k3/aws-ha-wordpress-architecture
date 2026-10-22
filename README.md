# AWS HA WordPress Architecture

Enterprise-grade, fault-tolerant multi-tier web architecture deployed on AWS using EC2 Auto Scaling, Application Load Balancer, Amazon EFS shared storage, and Amazon Aurora MySQL Multi-AZ clustering.

## Overview

This architecture is designed for high availability, fault tolerance, and dynamic scalability in a single AWS Region. It separates the stateless web tier from shared media storage and a managed relational database cluster across multiple Availability Zones, eliminating common single points of failure.

## Architecture Overview

<p align="center">
  <img src="docs/architecture-diagram.png" alt="AWS HA WordPress architecture diagram" width="100%" />
</p>

### Key Architectural Tenets

- High Availability & Fault Tolerance: Multi-AZ deployment across compute, storage, and database layers.
- Stateless Compute Layer: Amazon EC2 instances managed by an Auto Scaling Group (ASG) run behind an Application Load Balancer (ALB)[cite: 11, 16].
- Decoupled Distributed Storage: Centralized Amazon Elastic File System (EFS) provides concurrent, multi-AZ NFS storage for application assets[cite: 11, 14, 16].
- Managed Relational Database: Amazon Aurora MySQL-compatible cluster configured with an active Writer node and an automated failover Reader replica[cite: 11, 13, 16].
- Defense-in-Depth Network Isolation: Public subnets host only the ALB and NAT gateways; application compute and databases are isolated in private subnets[cite: 11, 12, 16].

---

## Technology Stack & Services

| Service | Category | Function in Architecture |
| :--- | :--- | :--- |
| Amazon VPC | Networking | Custom network with 2 public, 2 private app, and 2 private DB subnets[cite: 11, 12, 16] |
| AWS CloudFormation | IaC | Declarative templates for core network resources and launch templates |
| Amazon Aurora (MySQL) | Database | Multi-AZ database cluster with primary Writer and standby Reader replica[cite: 11, 13, 16] |
| Amazon EFS | Storage | Multi-AZ, POSIX-compliant shared file storage mounted via NFS[cite: 11, 14, 16] |
| Application Load Balancer | Load Balancing | Layer 7 traffic routing, health checks, and connection distribution[cite: 11, 15, 16] |
| EC2 Auto Scaling | Compute / Scaling | Dynamic horizontal scaling with Target Tracking on CPU utilization |
| AWS Systems Manager | Management | Operational orchestration and automated configuration management |

---

## Repository Layout

```text
├── .gitignore
├── LICENSE
├── README.md
├── docs/
│   ├── architecture-diagram.png            # Complete end-state multi-tier diagram
│   └── wordpress-login.png                 # Validation screenshot of active deployment
├── scripts/
│   └── userdata.sh                         # Bootstrap script for Apache, EFS, and DB config
└── templates/
    ├── 01-networking-infrastructure.yaml   # VPC, subnets, route tables, NAT gateways
    └── 02-launch-template.yaml             # CloudFormation launch template specification
```

---

## Step-by-Step Implementation Guide

### Task 1: Network Foundation (CloudFormation)

The underlying virtual network is provisioned across two Availability Zones (us-east-1a and us-east-1b)[cite: 12].

Deploy `templates/01-networking-infrastructure.yaml` via CloudFormation to create:

- Amazon VPC: `LabVPC`[cite: 12]
- Subnets: `PublicSubnet1`, `PublicSubnet2`, `AppSubnet1`, `AppSubnet2`, `DBSubnet1`, and `DBSubnet2`[cite: 12]
- Gateways & Routing: 1 Internet Gateway, 2 NAT Gateways (with dedicated Elastic IPs), and route tables isolating private traffic through NAT[cite: 12]
- Security Groups: pre-configured security groups for ALB ingress, EC2 instance access, EFS mount points, and Aurora database communication

### Task 2: Multi-AZ Amazon Aurora Database

Deploy a fully managed, fault-tolerant relational database cluster:

1. Navigate to Amazon RDS > Create database
2. Creation Method: Standard create
3. Engine: Aurora (MySQL Compatible), Template: Production
4. Settings:
   - DB cluster identifier: `MyDBCluster`
   - Master username: `admin`
   - Database name: `WPDatabase`
   - Instance class: `db.t3.medium`
   - Availability & Durability: create an Aurora Reader node in a different AZ for Multi-AZ deployment
5. Connectivity:
   - VPC: `LabVPC`
   - Subnet group: `labdbsubnetgroup` (database subnets only)
   - Public access: No
   - VPC security group: attach `RDSSecurityGroup` and remove the default security group
6. Record the generated Writer Endpoint when the cluster is available

### Task 3: Amazon Elastic File System (EFS)

Provision shared storage across both application subnets:

1. Navigate to EFS > Create file system > choose Customize
2. General Configuration:
   - Name: `myWPEFS`
   - Performance Mode: General Purpose
   - Throughput Mode: Bursting
3. Network Access (LabVPC):
   - AZ-a: Subnet `AppSubnet1` | Security Group: `EFSMountTargetSecurityGroup`[cite: 14]
   - AZ-b: Subnet `AppSubnet2` | Security Group: `EFSMountTargetSecurityGroup`[cite: 14]
4. Remove default security groups on the mount targets
5. Save the generated File System ID (`fs-xxxxxxxx`)

### Task 4: Application Load Balancer & Target Group

Configure Layer 7 load balancing for incoming web requests:

- Target Group: `myWPTargetGroup`
  - Target type: `Instances`[cite: 10, 16]
  - Protocol/Port: `HTTP:80`[cite: 10, 16]
  - VPC: `LabVPC`[cite: 10]
  - Health Checks: Path `/wp-login.php`, Healthy threshold 2, Unhealthy threshold 10, Timeout 50s, Interval 60s[cite: 10]
- Application Load Balancer: `myWPAppALB`
  - Scheme: Internet-facing, IPv4[cite: 11, 15, 16]
  - Subnets: `PublicSubnet1` and `PublicSubnet2`[cite: 11, 15, 16]
  - Security Group: `AppInstanceSecurityGroup` (Port 80 Inbound)[cite: 15]
  - Listener: Forward HTTP Port 80 to `myWPTargetGroup`[cite: 10]
- Copy the ALB DNS name

### Task 5: Launch Template Configuration (CloudFormation)

Deploy `templates/02-launch-template.yaml` using CloudFormation to configure `LabLaunchTemplate`:

- DB Name: `WPDatabase`
- Database Endpoint: Aurora Writer Endpoint
- Database Username: `admin`
- Instance Type: `t3.medium`
- ALBDnsName: ALB DNS Name
- WPElasticFileSystemID: EFS File System ID

#### User Data Script (`scripts/userdata.sh`)

```bash
#!/bin/bash
set -e

# Update operating system and install dependencies
yum update -y
yum install -y httpd php php-mysqlnd php-gd php-xml php-mbstring amazon-efs-utils

# Enable and start Apache web server
systemctl start httpd
systemctl enable httpd

# Mount shared Amazon EFS volume
mkdir -p /var/www/html
mount -t efs -o tls ${WPElasticFileSystemID}:/ /var/www/html
echo "${WPElasticFileSystemID}:/ /var/www/html efs _netdev,tls 0 0" >> /etc/fstab

# Retrieve and configure WordPress on shared storage
if [ ! -f /var/www/html/wp-config.php ]; then
  cd /var/www/html
  wget https://wordpress.org/latest.tar.gz
  tar -xzf latest.tar.gz --strip-components=1
  rm -f latest.tar.gz

  cp wp-config-sample.php wp-config.php
  sed -i "s/database_name_here/${DBName}/" wp-config.php
  sed -i "s/username_here/${DBUser}/" wp-config.php
  sed -i "s/password_here/${DBPassword}/" wp-config.php
  sed -i "s/localhost/${DBEndpoint}/" wp-config.php

  chown -R apache:apache /var/www/html
fi

systemctl restart httpd
```

### Task 6: EC2 Auto Scaling Group & Scaling Policies

In the EC2 Console, create an Auto Scaling Group:

- Name: `WP-ASG`
- Launch Template: `LabLaunchTemplate` (Version: Latest (2))
- VPC & Subnets: `LabVPC` > `AppSubnet1` and `AppSubnet2`
- Attach to existing load balancer target group: `myWPTargetGroup`[cite: 10, 16]
- Enable Elastic Load Balancing health checks
- Health check grace period: `300 seconds`
- Enable group metrics collection in CloudWatch
- Group sizing:
  - Desired: `2`
  - Minimum: `2`
  - Maximum: `4`
- Scaling policy: Target tracking based on average CPU utilization at `50%`[cite: 9]
- Tags: Key `Name`, Value `wp-ha-app`[cite: 11, 16]

---

## Verification & Testing

### 1. Target Health Validation

Navigate to EC2 > Target Groups > `myWPTargetGroup` > Targets tab[cite: 10, 16]. Both registered instances should pass health checks and display green checkmarks indicating a Healthy status[cite: 10].

### 2. Live Application Access

Open the following URL in a browser:

```text
http://<ALB-DNS-NAME>/wp-login.php
```

<p align="center">
  <img src="docs/wordpress-login.png" alt="WordPress login page in AWS HA deployment" width="100%" />
</p>

Log in using the `wpadmin` account and the administrator password to access the WordPress administrative dashboard.

---

## Summary

This repository demonstrates how to design and deploy a resilient multi-tier WordPress architecture on AWS using VPC isolation, load-balanced stateless web servers, shared EFS storage, and an Aurora MySQL cluster with Multi-AZ failover. The solution is fully aligned with enterprise cloud architecture best practices for high availability, scalability, and operational resilience.
