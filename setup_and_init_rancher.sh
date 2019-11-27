#!/bin/bash -x
curlimage="appropriate/curl"
jqimage="stedolan/jq"

RANCHER_IP=127.0.0.1
RANCHER_HTTPS_PORT=8443
RANCHER_HTTP_PORT=8440
CATALOG_URL="http://127.0.0.1/chartrepo/edge-cloud/"
RANCHER_USER=admin
RANCHER_PASSWORD=admin
RANCHER_LOGIN_TOKEN=""
RANCHER_API_TOKEN=""

for image in $curlimage $jqimage; do
  until docker inspect $image > /dev/null 2>&1; do
    docker pull $image
    sleep 2
  done
done


# Create password,not use openssl
#RANCHER_PASSWORD=$(openssl rand -base64 12)

echo $RANCHER_PASSWORD > ./rancher_password

until docker inspect rancher/rancher:latest > /dev/null 2>&1; do
  docker pull rancher/rancher:latest
  sleep 2
done

echo "install rancher"
docker stop rancher-server
docker rm rancher-server
docker run --restart=unless-stopped --name rancher-server -d -p $RANCHER_HTTP_PORT:80 -p $RANCHER_HTTPS_PORT:443 rancher/rancher:latest

while true; do
  docker run --rm --net=host $curlimage -slk --connect-timeout 5 --max-time 5 https://127.0.0.1:8443/ping && break
  # check if Rancher is not in restarting mode
  if [ $(docker inspect $(docker ps -q --filter ancestor=rancher/rancher:latest) --format='{{.State.Restarting}}') == "true" ]; then docker rm -f $(docker ps -q --filter ancestor=rancher/rancher:latest); docker run --restart=unless-stopped --name rancher-server -d -p $RANCHER_HTTP_PORT:80 -p $RANCHER_HTTPS_PORT:443 rancher/rancher:latest; fi
  sleep 5
done

# Login
while true; do

    LOGINRESPONSE=$(docker run \
        --rm \
        --net=host \
        $curlimage \
        -s "https://127.0.0.1:8443/v3-public/localProviders/local?action=login" -H 'content-type: application/json' --data-binary '{"username":"admin","password":"admin"}' --insecure)
    LOGINTOKEN=$(echo $LOGINRESPONSE | docker run --rm -i $jqimage -r .token)
    if [ "$LOGINTOKEN" != "null" ]; then
        break
    else
        sleep 5
    fi
done

# Change password
docker run --rm --net=host $curlimage -s 'https://127.0.0.1:8443/v3/users?action=changepassword' -H 'content-type: application/json' -H "Authorization: Bearer $LOGINTOKEN" --data-binary '{"currentPassword":"admin","newPassword":"'"${RANCHER_PASSWORD}"'"}' --insecure

# Create API key
APIRESPONSE=$(docker run --rm --net=host $curlimage -s 'https://127.0.0.1:8443/v3/token' -H 'content-type: application/json' -H "Authorization: Bearer $LOGINTOKEN" --data-binary '{"type":"token","description":"edge-cloud"}' --insecure)

# Extract and store token
APITOKEN=`echo $APIRESPONSE | docker run --rm -i $jqimage -r .token`

# Configure server-url
RANCHER_SERVER="https://${RANCHER_IP}:${RANCHER_HTTPS_PORT}"
docker run --rm --net=host $curlimage -s 'https://127.0.0.1:8443/v3/settings/server-url' -H 'content-type: application/json' -H "Authorization: Bearer $APITOKEN" -X PUT --data-binary '{"name":"server-url","value":"'"${RANCHER_SERVER}"'"}' --insecure

# Create import cluster
CLUSTERRESPONSE=$(docker run --rm --net=host $curlimage -s 'https://127.0.0.1:8443/v3/cluster' -H 'content-type: application/json' -H "Authorization: Bearer $APITOKEN" -X POST --data-binary '{"dockerRootDir":"/var/lib/docker","enableNetworkPolicy":false,"type":"cluster","name":"edge-node"}' --insecure)

# Extract import command
CLUSTERID=`echo $CLUSTERRESPONSE | docker run --rm -i $jqimage -r .id`

# Generate registrationtoken
docker run --rm --net=host $curlimage -s 'https://127.0.0.1:8443/v3/clusterregistrationtoken' -H 'content-type: application/json' -H "Authorization: Bearer $APITOKEN" --data-binary '{"type":"clusterRegistrationToken","clusterId":"'"$CLUSTERID"'"}' --insecure

IMPORTCMD=$(docker run \
    --rm \
    --net=host \
    $curlimage \
        -s \
        -H "Authorization: Bearer $APITOKEN" \
        "https://127.0.0.1:8443/v3/clusterregistrationtoken?clusterId=$CLUSTERID" --insecure | docker run --rm -i $jqimage -r '.data[].insecureCommand' | head -1)

echo $IMPORTCMD > ./importcmd
echo $IMPORTCMD | /bin/sh

# 
while true; do

    CLUSTERRESPONSE=$(docker run \
        --rm \
        --net=host \
        $curlimage \
        -s "https://127.0.0.1:8443/v3/clusters?limit=-1&sort=name" -H 'content-type: application/json' -H "Authorization: Bearer $APITOKEN" --insecure)
    CLUSTERRESTATES=`echo $CLUSTERRESPONSE | docker run --rm -i $jqimage -r '.data[] |select(.name=="edge-node")'.state`
    if [ "$CLUSTERRESTATES" == "active" ]; then
        break
    else
        sleep 5
    fi
done

echo "Rancher is ready"

# add catalog
docker run --rm --net=host $curlimage -s 'https://127.0.0.1:8443/v3/catalog' -H 'content-type: application/json' -H "Authorization: Bearer $APITOKEN" --data-binary '{"branch":"master","kind":"helm","name":"edge-cloud","type":"edge-cloud","url":"'"$CATALOG_URL"'"}' --insecure

# move namespace
# get projects 
PROJECTSRESPONSE=$(docker run --rm --net=host $curlimage -s 'https://127.0.0.1:8443/v3/projects?limit=-1&sort=name' -H "Authorization: Bearer $APITOKEN"  --insecure)

# get default project id
DEFAULT_PROJECTID=`echo $PROJECTSRESPONSE | docker run --rm -i $jqimage -r '.data[] |select(.name=="Default")'.id`

# move
docker run --rm --net=host $curlimage -s "https://127.0.0.1:8443/v3/cluster/$CLUSTERID/namespaces/default?action=move" -H 'content-type: application/json' -H "Authorization: Bearer $APITOKEN" --data-binary '{"projectId":"'"$DEFAULT_PROJECTID"'"}' --insecure

# enable prometheus
docker run --rm --net=host $curlimage -s "https://127.0.0.1:8443/v3/clusters/$CLUSTERID?action=enableMonitoring" -H 'content-type: application/json' -H "Authorization: Bearer $APITOKEN" --data-binary '{"answers":{"operator-init.enabled":"true","exporter-node.enabled":"true","exporter-node.ports.metrics.port":"9796","exporter-kubelets.https":"true","exporter-node.resources.limits.cpu":"200m","exporter-node.resources.limits.memory":"200Mi","operator.resources.limits.memory":"500Mi","prometheus.retention":"12h","grafana.persistence.enabled":"false","prometheus.persistence.enabled":"false","prometheus.persistence.storageClass":"default","grafana.persistence.storageClass":"default","grafana.persistence.size":"10Gi","prometheus.persistence.size":"50Gi","prometheus.resources.core.requests.cpu":"750m","prometheus.resources.core.limits.cpu":"1000m","prometheus.resources.core.requests.memory":"750Mi","prometheus.resources.core.limits.memory":"1000Mi","prometheus.persistent.useReleaseName":"true"},"version":"0.0.5"}' --insecure

echo "Login to Rancher: $RANCHER_SERVER"
echo "Api token: $APITOKEN"
echo "Username: admin"
echo "Password: $(cat ./rancher_password)"
