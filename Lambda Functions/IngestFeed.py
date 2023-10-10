import requests
import pymongo
import json
import os

def lambda_handler(event, context):
    params = {'query':'get_recent','selector':'time'}    #Define parameters for MalwareBazaar API query
    r = requests.post('https://mb-api.abuse.ch/api/v1/', data=params).text    #Make POST request to MalwareBazaar API, retrieving metadata of all samples uploaded to the repository in the past hour
    data = json.loads(r)    #Convert retrieved JSON string into Python Dictionary format
    #Retrieve additional feeds here
                  
    r = requests.get('https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem')    #Retrieve contents of TLS certificate bundle for all AWS Regions, required to establish a TLS-encrypted connection to DocumentDB
    caCert = open('/tmp/global-bundle.pem', 'wb')
    caCert.write(r.content)    #Write TLS certificate bundle contents to /tmp/global-bundle.pem
    caCert.close()
                  
    client = pymongo.MongoClient('mongodb://'+os.environ['USERNAME']+':'+os.environ['PASSWORD']+'@'+os.environ['CLUSTER']+':27017/?tls=true&tlsCAFile=/tmp/global-bundle.pem&replicaSet=rs0&readPreference=secondaryPreferred&retryWrites=true')    #Configure DocumentDB cluster connection string
    db = client.tip    #Define DocumentDB database
    collection = db.tip_collection    #Define DocumentDB database collection
    collection.insert_one(data)    #Ingest retrieved data into DocumentDB
    #Create other collections for ingestion of additional feeds here
    client.close()
