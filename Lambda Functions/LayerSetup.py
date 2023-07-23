import subprocess
import shutil
import boto3
import cfnresponse
import os

s3 = boto3.resource('s3')

def lambda_handler(event, context):
    subprocess.call('pip install requests -t /tmp/python/ --no-cache-dir'.split())    #Install "requests" Python package to /tmp/python
    subprocess.call('pip install pymongo -t /tmp/python/ --no-cache-dir'.split())    #Install "pymongo" Python package to /tmp/python
    shutil.make_archive('/tmp/layer', 'zip', '/tmp/', 'python')    #Zip /tmp/python to layer.zip
    s3.Bucket(os.environ['BUCKET']).upload_file('/tmp/layer'+'.zip', 'layer.zip')    #Upload layer.zip to tip-layerbucket
    cfnresponse.send(event, context, cfnresponse.SUCCESS, {})    #CloudFormation custom resource response