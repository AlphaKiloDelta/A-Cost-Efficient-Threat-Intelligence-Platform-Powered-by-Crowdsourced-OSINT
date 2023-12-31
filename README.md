# A Cost-Efficient Threat Intelligence Platform Powered by Crowdsourced OSINT
## Overview
The paper's "Conclusion and Future Work" section refers to the development of a well-architected Threat Intelligence Platform (TIP), a resilient one with high availability. The below diagram illustrates such an architecture, with a decoupled design.

![AWS Diagram](https://github.com/AlphaKiloDelta/A-Cost-Efficient-Threat-Intelligence-Platform-Powered-by-Crowdsourced-OSINT/assets/68220964/4e479341-8d33-46e7-8014-0ccf0d47c047)

This TIP is available as both a CloudFormation template ([CloudFormation.yaml](https://github.com/AlphaKiloDelta/A-Cost-Efficient-Threat-Intelligence-Platform-Powered-by-Crowdsourced-OSINT/blob/main/CloudFormation.yaml)) and a Terraform file ([Terraform.tf](https://github.com/AlphaKiloDelta/A-Cost-Efficient-Threat-Intelligence-Platform-Powered-by-Crowdsourced-OSINT/blob/main/Terraform/Terraform.tf)) in this repository. Unlike the simple model TIP presented as a proof of concept in the paper, this TIP conforms to the AWS Well-Architected Framework and is suitable for a production deployment.

## Process
Following the callouts in the above diagram:
1) An EventBridge schedule "HourlyInvoke" invokes the "IngestFeed" Lambda function (a Python script) once each hour.
2) The "IngestFeed" Lambda function pulls all data uploaded to the defined OSINT repositories in the past hour, through each of their respective APIs. Because it is a VPC-attached function in a private subnet, a NAT Gateway is required for it to reach the internet.
3) The "IngestFeed" Lambda function retrieves the DocumentDB cluster credentials from Secrets Manager.
4) The retrieved OSINT data is ingested into the DocumentDB cluster.
5) Using a compatible data analytics tool (Power BI is recommended), the analyst will remotely connect to the DocumentDB cluster to retrieve all ingested data. As the cluster is distributed across private subnets, the analyst connects via an SSH tunnel in a public subnet.

## Availability, Elasticity, and Resilience
- The TIP is hosted across three Availability Zones to ensure high availability.
- DocumentDB automatically promotes a replica instance (read-only) to a primary instance (writable) if the current primary instance fails.
- DocumentDB storage automatically scales with the cluster volume's data. The cluster can be vertically scaled by modifying its instances' classes, and horizontally scaled by adding or removing instances.
- The SSH tunnel server is in an EC2 Auto Scaling group which spins up another pre-configured tunnel server from a launch template as soon as the tunnel fails.
- The "IngestFeed" Lambda function is configured to deploy in any of the three Availability Zones' private subnets. To support this, a NAT Gateway is present in the public subnet of each Availability Zone.
- Automated backups of DocumentDB are retained for seven days.

## Security
- All data is encrypted both in transit and at rest.
  - Data in Transit: Encrypted by TLS using the AWS certificate bundle.
  - Data at Rest: Encrypted by an AES-256 customer-managed key in KMS (alias: "TIP-DocDBKey") with automatic key rotation enabled.
- The DocumentDB cluster credentials are stored in Secrets Manager and the password is referenced implicitly in the template.
- The DocumentDB password is a randomly-generated 99-character string consisting of upper/lower case letters and numbers.
- The SSH tunnel server requires an SSH key to connect, found in the Parameter Store in Systems Manager.
- The DocumentDB cluster, SSH tunnel server, and "IngestFeed" Lambda function have security groups applied to them which allow inbound/outbound traffic to only the ports and IP ranges they require.
- All public and private subnets have network ACLs applied to them which allow inbound/outbound traffic to only the ports and IP ranges they require.
- DocumentDB audit logs and Lambda logs are sent to CloudWatch.
- Deletion protection is enabled on the DocumentDB cluster.

## Cost Analysis
The table below breaks down the daily cost of operating the template as is.

![Cost Analysis](https://github.com/AlphaKiloDelta/A-Cost-Efficient-Threat-Intelligence-Platform-Powered-by-Crowdsourced-OSINT/assets/68220964/4069852f-af84-4c36-a6ee-22c09d53d9e8)

The data is sourced from Cost Explorer and representative of service usage in the eu-west-2 region in July 2023.

## Notes
The template is ready-to-deploy with no configuration required. The stack is built in little over 20 minutes, and automatically begins ingesting data from MalwareBazaar once the DocumentDB primary instance is created. Resource names are prepended with "TIP-" for easy identification in AWS after the stack is built, to help distinguish from other resources owned by the account.

If required, the template can be easily configured to suit the user's specific requirements. For example:
- MalwareBazaar is used as a proof of concept, as explained in the paper. Additional intelligence feeds can (and should) be integrated by adding them to the "IngestFeed" Lambda function.
- The TIP is deployed to eu-west-2, however the region can be changed to any other which supports all services/features used in the template.
- The TIP is deployed to three Availability Zones, however this can be increased or decreased if desired depending on how many zones are available in the chosen region. A minimum of two Availability Zones is recommended for a highly available deployment.
- If data-at-rest encryption is not desired, simply remove the "StorageEncrypted" and "KmsKeyId" properties from the "DocDBCluster" resource. In this case, also remove the "DocDBKey" and "DocDBKeyAlias" resources from the template.
- The automated backup retention period for DocumentDB is seven days, however this can be increased or decreased if desired.
- The number of DocumentDB replicas can be increased or decreased, depending on expected demand.
- The SSH tunnel server Auto Scaling group has a maximum and minimum capacity of 1, this can be increased if the user desires more than one SSH tunnel server available at a time.
- For inbound SSH traffic, "SshTunnelSg" and "PublicNACLInboundSsh" can be modified to permit the user's specific public IP range instead of permitting all addresses via 0.0.0.0/0. 

These are simply some examples of changes which may be made to the template, it can be customised in any way to suit the needs of the user. Removal of security components is not recommended, however.

## How to Connect
Power BI is the recommended data analytics tool. Information on how to configure the DocumentDB custom connector can be found [here](https://docs.aws.amazon.com/documentdb/latest/developerguide/connect-odbc-power-bi.html).

Upon successful configuration, Power BI will be able to establish a connection to the DocumentDB cluster and retrieve all stored data. Visualisations can then be produced.

Note: In the template, the password is generate without symbols/punctuation. It is recommended to be left this way, containing only letters and numbers, as [symbols are known to cause connectivity issues with the ODBC driver](https://github.com/aws/amazon-documentdb-odbc-driver/issues/193).

## CloudFormation Diagram

![CloudFormation Diagram](https://github.com/AlphaKiloDelta/A-Cost-Efficient-Threat-Intelligence-Platform-Powered-by-Crowdsourced-OSINT/assets/68220964/72654883-2999-4c35-8039-e67ac918322c)
