#!/usr/bin/env bash
set -ueo pipefail
set +x

SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

# setup tmpdir for testfiles and cleanup
TMP=$(mktemp -d -t tmp.XXXXXXXXXX)
cleanup(){
	rm -rf "$TMP"
}
trap cleanup EXIT
# mirroring install-sim from the Makefile since it won't work on private Jenkins
install_sim(){
    local bin_dir="${TMP}/bin"
    mkdir -p ${bin_dir}

    go build -race -v -o ${bin_dir}/storagenode ./cmd/storagenode >/dev/null 2>&1
    go build -race -v -o ${bin_dir}/satellite ./cmd/satellite >/dev/null 2>&1
    go build -race -v -o ${bin_dir}/storj-sim ./cmd/storj-sim >/dev/null 2>&1
    go build -race -v -o ${bin_dir}/versioncontrol ./cmd/versioncontrol >/dev/null 2>&1

    go build -race -v -o ${bin_dir}/uplink ./cmd/uplink >/dev/null 2>&1
    go build -race -v -o ${bin_dir}/identity ./cmd/identity >/dev/null 2>&1
    go build -race -v -o ${bin_dir}/certificates ./cmd/certificates >/dev/null 2>&1

    rm -rf .build/gateway-tmp
    mkdir -p .build/gateway-tmp
    pushd .build/gateway-tmp
        go mod init gatewaybuild && GOBIN=${bin_dir} GO111MODULE=on go get storj.io/gateway@latest
    popd
}

pushd $SCRIPTDIR
    echo "Running test-sim"
    echo "Running $SCRIPTDIR"
    ls -al
    pwd
    id
    
    if [ -d "$SCRIPTDIR/storj" ]; then 
      rm -Rf $SCRIPTDIR/storj; 
    fi
    
    git clone https://github.com/storj/storj.git -b yz/enable-quic --depth 1

    pushd ./storj
        git status
        install_sim
    popd
popd

export PATH=$TMP/bin:$PATH
#echo "Running test-sim"
#make -C "$SCRIPTDIR"/.. install-sim

export STORJ_NETWORK_DIR=$TMP

STORJ_NETWORK_HOST4=${STORJ_NETWORK_HOST4:-127.0.0.1}
STORJ_SIM_POSTGRES=${STORJ_SIM_POSTGRES:-""}
STORJ_SIM_REDIS=${STORJ_SIM_REDIS:-""}
# STORJ_CONSOLE_payments_stripe-coin-payments_coinpayments-private-key="5366b14A7Dc5A1b0FCc3C8845c5d903E8c6b6360de5f3667AD8B58f5E8cC017c"
# setup the network
# if postgres connection string is set as STORJ_SIM_POSTGRES then use that for testing
if [ -z ${STORJ_SIM_POSTGRES} ]; then
	storj-sim -x --satellites 1 --host $STORJ_NETWORK_HOST4 network setup --host="192.168.195.99" #--storage-nodes 1 --identities 1 
else
	storj-sim -x --satellites 1 --host $STORJ_NETWORK_HOST4 network --postgres=$STORJ_SIM_POSTGRES setup --host="192.168.195.99" #--storage-nodes 1 --identities 1 
fi

#cat $TMP/satellite/0/config.yaml

echo "metainfo.rate-limiter.enabled: false" >> $TMP/satellite/0/config.yaml
echo "metainfo.rs: 1/1/1/1-256 B" >> $TMP/satellite/0/config.yaml

cat $TMP/satellite/0/config.yaml

#storj-sim -x --satellites 1 --storage-nodes 1 --host $STORJ_NETWORK_HOST4 network run &
storj-sim -x --satellites 1 --host $STORJ_NETWORK_HOST4 network run &

sleep 20

head -c 50M </dev/urandom > 64M

#uplink --config-dir=$TMP/uplink import $(storj-sim network env GATEWAY_0_ACCESS --storage-nodes 1)
uplink --config-dir=$TMP/uplink import $(storj-sim network env GATEWAY_0_ACCESS)
storj-sim network env GATEWAY_0_ACCESS #--storage-nodes 1
uplink --config-dir=$TMP/uplink access inspect 

uplink --config-dir=$TMP/uplink access inspect >> /tmp/access.txt

#wget https://github.com/storj/storj/releases/download/v0.29.3/uplink_linux_amd64.zip
#unzip ./uplink_linux_amd64.zip

echo "Set uplink config"
echo "advanced: true" >> $TMP/uplink/config.yaml
echo "log.caller: true" >> $TMP/uplink/config.yaml
echo "log.development: true" >> $TMP/uplink/config.yaml
echo "log.level: debug" >> $TMP/uplink/config.yaml
echo "log.stack: true" >> $TMP/uplink/config.yaml

apt-get -y install tcpdump

echo "create Bucket"
uplink --config-dir=$TMP/uplink mb sj://test 

echo "start upload"

ip a

# TCP Run
tcpdump -i any -s 65535 -w tcp.cap port not 22 &
sleep 2.5
uplink --config-dir=$TMP/uplink cp ./64M sj://test 

pid=$(ps -e | pgrep tcpdump)
echo $pid

#interrupt it:
sleep 2.5
kill -2 $pid


# QUIC Run
tcpdump -i any -s 65535 -w quic.cap port not 22 &
sleep 2.5
uplink --config-dir=$TMP/uplink cp --client.enable-quic ./64M sj://test 

pid=$(ps -e | pgrep tcpdump)
echo $pid

#interrupt it:
sleep 2.5
kill -2 $pid

uplink --config-dir=$TMP/uplink ls

storj-sim -x --satellites 1 --host $STORJ_NETWORK_HOST4 network destroy
