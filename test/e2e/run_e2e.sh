#!/bin/bash
set -euo pipefail

create_cluster=false
e2e=false
loadtest_e2e=false
stackset_e2e=false
decommission_cluster=false
COMMAND="${1:-"all"}" # all, create-cluster, e2e, stackset-e2e, decommission-cluster

case "$COMMAND" in
    all)
        create_cluster=true
        e2e=true
        loadtest_e2e=true
        stackset_e2e=true
        decommission_cluster=true
        ;;
    create-cluster)
        create_cluster=true
        ;;
    e2e)
        e2e=true
        ;;
    loadtest-e2e)
        loadtest_e2e=true
        ;;
    stackset-e2e)
        stackset_e2e=true
        ;;
    decommission-cluster)
        decommission_cluster=true
        ;;
    *)
        echo "Unknown command: $COMMAND"
        exit 1
esac

E2E_SKIP_CLUSTER_UPDATE="${E2E_SKIP_CLUSTER_UPDATE:-"false"}"

# variables set for making it possible to run script locally
CDP_BUILD_VERSION="${CDP_BUILD_VERSION:-"local-1"}"
CDP_TARGET_REPOSITORY="${CDP_TARGET_REPOSITORY:-"github.com/zalando-incubator/kubernetes-on-aws"}"
CDP_TARGET_COMMIT_ID="${CDP_TARGET_COMMIT_ID:-"dev"}"
CDP_HEAD_COMMIT_ID="${CDP_HEAD_COMMIT_ID:-"$(git describe --tags --always)"}"
RESULT_BUCKET="${RESULT_BUCKET:-""}"

export CLUSTER_ALIAS="${CLUSTER_ALIAS:-"e2e-${CDP_BUILD_VERSION}"}"
export LOCAL_ID="${LOCAL_ID:-"e2e-${CDP_BUILD_VERSION}"}"
export API_SERVER_URL="https://${LOCAL_ID}.${HOSTED_ZONE}"
export INFRASTRUCTURE_ACCOUNT="aws:${AWS_ACCOUNT}"
export CLUSTER_ID="${INFRASTRUCTURE_ACCOUNT}:${REGION}:${LOCAL_ID}"

# create kubeconfig
cat >kubeconfig <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: ${API_SERVER_URL}
  name: e2e-cluster
contexts:
- context:
    cluster: e2e-cluster
    namespace: default
    user: e2e-bot
  name: e2e-cluster
current-context: e2e-cluster
preferences: {}
users:
- name: e2e-bot
  user:
    token: ${CLUSTER_ADMIN_TOKEN}
EOF

KUBECONFIG="$(pwd)/kubeconfig"
export KUBECONFIG="$KUBECONFIG"

if [ "$create_cluster" = true ]; then
    echo "Creating cluster ${CLUSTER_ID}: ${API_SERVER_URL}"

    # TODO drop later
    export MASTER_PROFILE="master"
    export WORKER_PROFILE="worker"

    # if E2E_SKIP_CLUSTER_UPDATE is true, don't create a cluster from base first
    if [ "$E2E_SKIP_CLUSTER_UPDATE" != "true" ]; then
        BASE_CFG_PATH="base_config"

        # get head cluster config channel
        if [ -d "$BASE_CFG_PATH" ]; then
            rm -rf "$BASE_CFG_PATH"
        fi
        git clone "https://$CDP_TARGET_REPOSITORY" "$BASE_CFG_PATH"
        git -C "$BASE_CFG_PATH" reset --hard "${CDP_TARGET_COMMIT_ID}"

        # generate cluster.yaml
        # call the cluster_config.sh from base git checkout if possible
        if [ -f "$BASE_CFG_PATH/test/e2e/cluster_config.sh" ]; then
            "./$BASE_CFG_PATH/test/e2e/cluster_config.sh" "${CDP_TARGET_COMMIT_ID}" "requested" > base_cluster.yaml
        else
            "./cluster_config.sh" "${CDP_TARGET_COMMIT_ID}" "requested" > base_cluster.yaml
        fi

        # generate the cluster certificates
        aws-account-creator refresh-certificates --registry-file base_cluster.yaml --create-ca

        # Create cluster
        clm provision \
            --token="${CLUSTER_ADMIN_TOKEN}" \
            --directory="$(pwd)/$BASE_CFG_PATH" \
            --debug \
            --registry=base_cluster.yaml \
            --manage-etcd-stack

        # Wait for the resources to be ready
        ./wait-for-update.py --timeout 1200

        # provision and start load test
        echo "provision and start load test"
        ./start-load-test.sh --zone "$HOSTED_ZONE" --target "$(date +%s)" -v --timeout 900 --wait 30
    fi

    # generate updated clusters.yaml
    "./cluster_config.sh" "${CDP_HEAD_COMMIT_ID}" "ready" > head_cluster.yaml

    # either copy the certificates from the already created cluster or regenerate them from scratch
    if [ -f base_cluster.yaml ]; then
      ./copy-certificates.py base_cluster.yaml head_cluster.yaml
    else
      aws-account-creator refresh-certificates --registry-file head_cluster.yaml --create-ca
    fi

    # Update cluster
    echo "Updating cluster ${CLUSTER_ID}: ${API_SERVER_URL}"

    clm provision \
        --token="${CLUSTER_ADMIN_TOKEN}" \
        --directory="$(pwd)/../.." \
        --debug \
        --registry=head_cluster.yaml \
        --manage-etcd-stack

    # Wait for the resources to be ready after the update
    # TODO: make a feature of CLM --wait-for-kube-system
    ./wait-for-update.py --timeout 1200
fi

if [ "$e2e" = true ]; then
    echo "Running e2e against cluster ${CLUSTER_ID}: ${API_SERVER_URL}"
    # disable cluster downscaling before running e2e
    ./toggle-scaledown.py disable

    export S3_AWS_IAM_BUCKET="zalando-e2e-test-${AWS_ACCOUNT}-${LOCAL_ID}"
    export AWS_IAM_ROLE="${LOCAL_ID}-e2e-aws-iam-test"

    # Run e2e tests
    # * conformance tests
    # * statefulset tests
    # * custom 'zalando' tests
    #
    # Disable DNS tests covering DNS names of format: <name>.<namespace>.svc which
    # we don't support with the ndots:2 configuration:
    #
    # * "should resolve DNS of partial qualified names for the cluster [DNS] [Conformance]"
    #   https://github.com/kubernetes/kubernetes/blob/66049e3b21efe110454d67df4fa62b08ea79a19b/test/e2e/network/dns.go#L71-L98
    #
    # * "should resolve DNS of partial qualified names for services [LinuxOnly]"
    #   https://github.com/kubernetes/kubernetes/blob/06ad960bfd03b39c8310aaf92d1e7c12ce618213/test/e2e/network/dns.go#L181-L234

    # Disable Tests for setups which we don't support
    #
    # These are disabled because they assume nodePorts are reachable via the public
    # IP of the node, we don't currently support that.
    #
    # * "[Fail] [sig-network] Services [It] should be able to change the type from ExternalName to NodePort [Conformance]"
    #   https://github.com/kubernetes/kubernetes/blob/224be7bdce5a9dd0c2fd0d46b83865648e2fe0ba/test/e2e/network/service.go#L1037
    # * "[Fail] [sig-network] Services [It] should be able to create a functioning NodePort service [Conformance]"
    #   https://github.com/kubernetes/kubernetes/blob/224be7bdce5a9dd0c2fd0d46b83865648e2fe0ba/test/e2e/network/service.go#L551
    # * "[Fail] [sig-network] Services [It] should have session affinity work for NodePort service [LinuxOnly] [Conformance]"
    #   https://github.com/kubernetes/kubernetes/blob/v1.19.2/test/e2e/network/service.go#L1813
    # * "[Fail] [sig-network] Services [It] should have session affinity timeout work for NodePort service [LinuxOnly] [Conformance]"
    #   https://github.com/kubernetes/kubernetes/blob/v1.19.2/test/e2e/network/service.go#L2522
    # * "[Fail] [sig-network] Services [It] should be able to switch session affinity for NodePort service [LinuxOnly] [Conformance]"
    #   https://github.com/kubernetes/kubernetes/blob/v1.19.2/test/e2e/network/service.go#L2538
    #
    # These are disabled because the hostPort are not supported in our
    # clusters yet. Currently there's no need to support them and
    # portMapping is not enabled in the Flannel CNI configmap.
    # * "[Fail] [sig-network] HostPort [It] validates that there is no conflict between pods with same hostPort but different hostIP and protocol [LinuxOnly] [Conformance]"
    #   https://github.com/kubernetes/kubernetes/blob/v1.21.5/test/e2e/network/hostport.go#L61
    set +e

    # TODO(linki): re-introduce the broken DNS record test after ExternalDNS handles it better
    #
    # # introduce a broken DNS record to mess with ExternalDNS
    # cat broken-dns-record.yaml | kubectl apply -f -

    mkdir -p junit_reports
    ginkgo -nodes=25 -flakeAttempts=2 \
        -focus="(\[Conformance\]|\[StatefulSetBasic\]|\[Feature:StatefulSet\]\s\[Slow\].*mysql|\[Zalando\])" \
        -skip="(should.resolve.DNS.of.partial.qualified.names.for.the.cluster|should.resolve.DNS.of.partial.qualified.names.for.services|should.be.able.to.change.the.type.from.ExternalName.to.NodePort|should.be.able.to.create.a.functioning.NodePort.service|should.have.session.affinity.work.for.NodePort.service|should.have.session.affinity.timeout.work.for.NodePort.service|should.be.able.to.switch.session.affinity.for.NodePort.service|validates.that.there.is.no.conflict.between.pods.with.same.hostPort.but.different.hostIP.and.protocol|\[Serial\]|Should.create.gradual.traffic.routes|Should.create.blue-green.routes)" \
        "e2e.test" -- \
        -delete-namespace-on-failure=false \
        -non-blocking-taints=node.kubernetes.io/role,nvidia.com/gpu,dedicated \
        -report-dir=junit_reports
    TEST_RESULT="$?"

    set -e

    if [[ -n "$RESULT_BUCKET" ]]; then
        # Prepare metadata.json
        jq --arg targetBranch "$CDP_TARGET_BRANCH" \
           --arg head "$CDP_HEAD_COMMIT_ID" \
           --arg buildVersion "$CDP_BUILD_VERSION" \
           --argjson prNumber "$CDP_PULL_REQUEST_NUMBER" \
           --arg author "$CDP_PULL_REQUEST_AUTHOR" \
           --argjson exitStatus "$TEST_RESULT" \
           -n \
           '{timestamp: now | todate, success: ($exitStatus == 0), targetBranch: $targetBranch, author: $author, prNumber: $prNumber, head: $head, version: $buildVersion }' \
           > junit_reports/metadata.json

        TARGET_DIR="$(printf "junit-reports/%04d-%02d/%s" "$(date +%Y)" "$(date +%-V)" "$LOCAL_ID")"
        echo "Uploading test results to S3 ($TARGET_DIR)"
        aws s3 cp \
          --acl bucket-owner-full-control \
          --recursive \
          --quiet \
          junit_reports/ "s3://$RESULT_BUCKET/$TARGET_DIR/"
    fi

    # enable cluster downscaling after running e2e
    ./toggle-scaledown.py enable

    exit "$TEST_RESULT"
fi

if [ "$stackset_e2e" = true ]; then
    namespace="stackset-e2e-$(date +'%H%M%S')"
    kubectl create namespace "$namespace"
    E2E_NAMESPACE="${namespace}" ./stackset-e2e -test.parallel 20
fi

if [ "$loadtest_e2e" = true ]; then
  >&2 echo "collect loadtest e2e data"
  prometheus=$(kubectl -n loadtest-e2e get ing prometheus -o json | jq -r '.spec.rules[0].host')

  >&2 echo "target prometheus: ${prometheus}"

  # get data for the last 30m
  curl --get -s -H"Accept: application/json" \
       --data-urlencode 'query=sum by(code) (rate(skipper_serve_host_count{application="e2e-vegeta"}[1m]))' \
       --data-urlencode "start=$(( $(date +%s) - (120*60) ))" \
       --data-urlencode "end=$(( $(date +%s) ))" \
       --data-urlencode "step=60" \
       "https://${prometheus}/api/v1/query_range" > /tmp/loadtest-e2e.json
  ls -l /tmp/loadtest-e2e.json
  cat /tmp/loadtest-e2e.json

  not_ok=$(jq -r '.data.result[] | select(.metric.code != "200") | .values[][1]' /tmp/loadtest-e2e.json \
    | awk 'BEGIN{cnt=0} {cnt=cnt+$1} END{print cnt}')
  ok=$(jq -r '.data.result[] | select(.metric.code == "200") | .values[][1]' /tmp/loadtest-e2e.json \
    | awk 'BEGIN{cnt=0} {cnt=cnt+$1} END{print cnt}')

  >&2 echo ""
  >&2 echo "DEBUG: e2e loadtest not OK: $not_ok"
  >&2 echo "DEBUG: e2e loadtest OK: $ok"

  if [ "${ok%.*}" -lt 1000 ]
  then
    >&2 echo "FAIL: e2e loadtest too few ok count $ok"
    exit 2
  elif [ "$( echo "scale=5; $not_ok / $ok > 0.000001" | bc )" -gt 0 ]; then
    >&2 echo "FAIL: e2e loadtest did not reach 99.999% OK rate"
    exit 2
  fi
fi

if [ "$decommission_cluster" = true ]; then
    existing_tags="$(aws --region "$REGION" cloudformation describe-stacks --stack-name "${LOCAL_ID}" --query "Stacks[0].Tags" | jq --sort-keys -c '[.[] | {key: .Key, value: .Value}] | from_entries')"
    updated_tags="$(printf "%s" "$existing_tags" | jq --sort-keys -c '.["decommission-requested"] = "true"')"
    if [[ "$existing_tags" != "$updated_tags" ]]; then
        aws --region "$REGION" cloudformation update-stack --stack-name "${LOCAL_ID}" \
            --use-previous-template \
            --capabilities CAPABILITY_NAMED_IAM \
            --tags "$(printf "%s" "$updated_tags" | jq -c 'to_entries | [.[] | {Key: .key, Value: .value}]')"
    else
        echo "Stack already marked for decommissioning"
    fi
fi
