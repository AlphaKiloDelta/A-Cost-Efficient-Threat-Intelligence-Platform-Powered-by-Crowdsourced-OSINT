# Lambda Functions
This folder contains the two Python scripts used in the CloudFormation template's Lambda functions: "LayerSetup" and "IngestFeed". These scripts cannot be run as is, they require environment variables specified in the template and are designed to be executed as Lambda functions. They are provided here with comments, separate from the rest of the CloudFormation template, purely for ease of viewing.

## LayerSetup
This function is invoked by the "LayerSetupInvoke" custom resource when the stack is created. It creates a .zip archive containing the "requests" and "pymongo" Python packages, required by "IngestFeed", and uploads it to "LayerBucket" for use in "LambdaLayer".

Environment variables:
- BUCKET: A reference to "LayerBucket".

## LayerSetup
This function is invoked by the "HourlyInvoke" EventBridge schedule once each hour. It retrieves, formats, and ingests OSINT data into "DocDBCluster". This script should be modified to include additional intelligence feeds the user desires to ingest.

Environment variables:
- CLUSTER: The "DocDBCluster" endpoint.
- USERNAME: The "DocDBCluster" master username, retrieved from Secrets Manager.
- PASSWORD: The "DocDBCluster" master user password, retrieved from Secrets Manager.
