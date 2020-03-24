#!/usr/bin/bash

# gcp-vpn.sh
# Author: Nils Knieling - https://github.com/Cyclenerd/google-cloud-gcp-pfsense

# Create a Classic VPN tunnel between your pfSense and GCP

################################################################################


################################################################################
# Usage
################################################################################

function usage {
    MY_RETURN_CODE="$1"
    echo -e "Usage: $ME OPTION:
    OPTION is one of the following:
        ip       Show my external IPv4 address
        list     List VPN tunnels and routes in GCP project
        create   Create VPN tunnel and route in GCP project
        delete   Delete route and VPN tunnel in GCP project
        pfsense  Update my identifier (myid_data) to current IPv4 and apply
        refresh  1. Delete route and VPN tunnel in GCP project
                 2. Create new VPN tunnel and route in GCP project
                 3. Update my identifier (myid_data) in pfSense
                 4. Apply new IPsec VPN
        help     Displays help (this message)"
    exit "$MY_RETURN_CODE"
}

################################################################################
# Check Commands
################################################################################

function check_commands {
    command -v ssh >/dev/null 2>&1    || { echo >&2 "ERROR: SSH client it's not installed. Aborting."; exit 1; }
    command -v curl >/dev/null 2>&1   || { echo >&2 "ERROR: curl it's not installed. Aborting."; exit 1; }
    command -v gcloud >/dev/null 2>&1 || { echo >&2 "ERROR: Google Cloud SDK CLI it's not installed. Aborting."; exit 1; }
}

################################################################################
# Load and check config
################################################################################

function check_config {
    if [ -e "$MY_GCP_VPN_CONFIG" ]; then
        echo "Using config from file: '$MY_GCP_VPN_CONFIG'"
        # ignore SC1090
        # shellcheck source=/dev/null
        source "$MY_GCP_VPN_CONFIG"
    else
        echo "!!! ERROR !!! Could not load config file: '$MY_GCP_VPN_CONFIG'"
        exit 9
    fi
    if [ -z "$MY_IP_RANGE" ]; then
        echo "ERROR: MY_IP_RANGE in config missing"
        exit 2
    fi
    if [ -z "$MY_SHARED_SECRET" ]; then
        echo "ERROR: MY_SHARED_SECRET in config missing"
        exit 2
    fi
    if [ -z "$MY_REGION" ]; then
        echo "ERROR: MY_REGION in config missing"
        exit 2
    fi
    if [ -z "$MY_PROJECT_ID" ]; then
        echo "ERROR: MY_PROJECT_ID in config missing"
        exit 2
    fi
    if [ -z "$MY_VPC_NETWORK" ]; then
        echo "ERROR: MY_VPC_NETWORK in config missing"
        exit 2
    fi
    if [ -z "$MY_TUNNEL_NAME" ]; then
        echo "ERROR: MY_TUNNEL_NAME in config missing"
        exit 2
    fi
    if [ -z "$MY_ROUTE_NAME" ]; then
        echo "ERROR: MY_ROUTE_NAME in config missing"
        exit 2
    fi
    if [ -z "$MY_VPN_GATEWAY_NAME" ]; then
        echo "ERROR: MY_VPN_GATEWAY_NAME in config missing"
        exit 2
    fi
    if [ -z "$MY_PFSENSE_IP" ]; then
        echo "ERROR: MY_PFSENSE_IP in config missing"
        exit 2
    fi
    if [ -z "$MY_PFSENSE_USER" ]; then
        echo "ERROR: MY_PFSENSE_USER in config missing"
        exit 2
    fi
    if [ -z "$MY_GET_IP_URL" ]; then
        echo "ERROR: MY_GET_IP_URL in config missing"
        exit 2
    fi
}

################################################################################
# MY EXTERNAL IPv4
################################################################################

MY_EXTERNAL_IP="" # Public IP address of your own network's VPN gateway
function externalIp {
    MY_EXTERNAL_IP=$(curl -4 --silent "$MY_GET_IP_URL")
    if [ -z "$MY_EXTERNAL_IP" ]; then
        echo "!!! ERROR !!! Could not discover current external IPv4 address"
        exit 9
    else
        echo "$MY_EXTERNAL_IP"
    fi
}

################################################################################
# CREATE
################################################################################

function createVpn {
    gcloud compute vpn-tunnels create "$MY_TUNNEL_NAME" \
        --peer-address "$MY_EXTERNAL_IP" \
        --shared-secret "$MY_SHARED_SECRET" \
        --local-traffic-selector=0.0.0.0/0 \
        --remote-traffic-selector=0.0.0.0/0 \
        --target-vpn-gateway "$MY_VPN_GATEWAY_NAME" \
        --region "$MY_REGION" \
        --project "$MY_PROJECT_ID" \
        --quiet \
    && gcloud compute routes create "$MY_ROUTE_NAME" \
        --destination-range "$MY_IP_RANGE" \
        --next-hop-vpn-tunnel "$MY_TUNNEL_NAME" \
        --network "$MY_VPC_NETWORK" \
        --next-hop-vpn-tunnel-region "$MY_REGION" \
        --project "$MY_PROJECT_ID" \
        --quiet
}

################################################################################
# PFSENSE
################################################################################

function pfsenseIpsec {
    {
        echo '! echo "Update my identifier (myid_data) to current IPv4 and apply"'
        echo 'require_once("config.inc");'
        echo 'require_once("filter.inc");'
        echo 'require_once("auth.inc");'
        echo 'require_once("vpn.inc");'
        echo "\$config['ipsec']['phase1'][0]['myid_data'] = '$MY_EXTERNAL_IP';"
        echo "write_config();"
        echo "vpn_ipsec_configure(true);"
    } | ssh -l "$MY_PFSENSE_USER" "$MY_PFSENSE_IP" \
        "cat > /etc/phpshellsessions/editipsecmyid && pfSsh.php playback editipsecmyid" || exit 9
}

################################################################################
# DELETE
################################################################################

function deleteVpn {
    gcloud compute routes delete "$MY_ROUTE_NAME" \
        --project "$MY_PROJECT_ID" \
        --quiet \
    && gcloud compute vpn-tunnels delete "$MY_TUNNEL_NAME" \
        --region "$MY_REGION" \
        --project "$MY_PROJECT_ID" \
        --quiet
}

################################################################################
# LIST
################################################################################

function listVpn {
    echo
    gcloud compute vpn-tunnels list \
        --project "$MY_PROJECT_ID" \
        --format="table[box,title=VPNs](name:sort=1, peerIp)"
    echo
    gcloud compute routes list \
        --project "$MY_PROJECT_ID" \
        --format="table[box,title=Routes](name:sort=1, destRange)"
    echo
}

################################################################################
# MAIN
################################################################################

ME=$(basename "$0")
# TODO: Resolv symlinks https://stackoverflow.com/questions/59895
BASE_PATH=$(dirname "$0")

# If a config file has been specified with MY_GCP_VPN_CONFIG=myfile use this one,
# otherwise default to config
if [[ -z "$MY_GCP_VPN_CONFIG" ]]; then
    MY_GCP_VPN_CONFIG="$BASE_PATH/config"
fi

case "$1" in
"")
    # called without arguments
    usage 1
    ;;
"ip")
    check_commands
    check_config
    externalIp
    ;;
"create")
    check_commands
    check_config
    externalIp
    createVpn
    ;;
"pfsense")
    check_commands
    check_config
    externalIp
    pfsenseIpsec
    ;;
"delete")
    check_commands
    check_config
    deleteVpn
    ;;
"refresh")
    check_commands
    check_config
    deleteVpn
    externalIp
    createVpn
    pfsenseIpsec
    ;;
"list")
    check_commands
    check_config
    listVpn
    ;;
"h" | "help" | "-h" | "-help" | "-?" | *)
    usage 0
    ;;
esac