#!/bin/sh

source $(dirname $0)/../vendor/github.com/knative/test-infra/scripts/e2e-tests.sh

set -x

readonly API_SERVER=$(oc config view --minify | grep server | awk -F'//' '{print $2}' | awk -F':' '{print $1}')
readonly OPENSHIFT_REGISTRY="${OPENSHIFT_REGISTRY:-"registry.svc.ci.openshift.org"}"
readonly TEST_NAMESPACE=build-pipeline-tests
readonly TEST_YAML_NAMESPACE=build-pipeline-tests-yaml
readonly BUILD_PIPELINE_NAMESPACE=knative-build-pipeline
readonly IGNORES="git-volume|gcs-archive|docker-basic"

env

function install_build_pipeline(){
  header "Installing Knative Build Pipeline"
  # Grant the necessary privileges to the service accounts Knative will use:
  oc adm policy add-scc-to-user anyuid -z build-pipeline-controller -n knative-build-pipeline
  oc adm policy add-cluster-role-to-user cluster-admin -z build-pipeline-controller -n knative-build-pipeline

  create_build_pipeline

  wait_until_pods_running $BUILD_PIPELINE_NAMESPACE || return 1

  header "Knative Build Pipeline Installed successfully"
}

function create_build_pipeline(){
  resolve_resources config/ build-pipeline-resolved.yaml
  oc apply -f build-pipeline-resolved.yaml
}

function resolve_resources(){
  local dir=$1
  local resolved_file_name=$2
  local registry_prefix="$OPENSHIFT_REGISTRY/$OPENSHIFT_BUILD_PIPELINE_NAMESPACE/stable"
  > $resolved_file_name
  for yaml in $(find $dir -name "*.yaml" | grep -vE $IGNORES); do
    echo "---" >> $resolved_file_name
    #first prefix all test images with "test-", then replace all image names with proper repository and prefix images with "knative-build-pipeline"
    sed -e 's%\(.* image: \)\(github.com\)\(.*\/\)\(test\/\)\(.*\)%\1\2 \3\4test-\5%' $yaml | \
    sed -e 's%\(.* image: \)\(github.com\)\(.*\/\)\(.*\)%\1 '"$registry_prefix"'\:knative-build-pipeline-\4%' | \
    # process these images separately as they're passed as arguments to other containers
    sed -e 's%github.com/knative/build-pipeline/cmd/creds-init%'"$registry_prefix"'\:knative-build-pipeline-creds-init%g' | \
    sed -e 's%github.com/knative/build-pipeline/cmd/git-init%'"$registry_prefix"'\:knative-build-pipeline-git-init%g' | \
    sed -e 's%github.com/knative/build-pipeline/cmd/nop%'"$registry_prefix"'\:knative-build-pipeline-nop%g' \
    >> $resolved_file_name
  done
}

function enable_docker_schema2(){
  oc set env -n default dc/docker-registry REGISTRY_MIDDLEWARE_REPOSITORY_OPENSHIFT_ACCEPTSCHEMA2=true
}

function create_test_namespace(){
  oc new-project $TEST_YAML_NAMESPACE
  oc policy add-role-to-group system:image-puller system:serviceaccounts:$TEST_YAML_NAMESPACE -n $OPENSHIFT_BUILD_PIPELINE_NAMESPACE
  oc new-project $TEST_NAMESPACE
  oc policy add-role-to-group system:image-puller system:serviceaccounts:$TEST_NAMESPACE -n $OPENSHIFT_BUILD_PIPELINE_NAMESPACE
}

function run_go_e2e_tests(){
  header "Running Go e2e tests"
  go_test_e2e ./test/e2e/... --kubeconfig $KUBECONFIG || return 1
}

function run_yaml_e2e_tests() {
  header "Running YAML e2e tests"
  oc project $TEST_YAML_NAMESPACE
  resolve_resources test/ tests-resolved.yaml
  oc apply -f tests-resolved.yaml

  # The rest of this function copied from test/e2e-common.sh#run_yaml_tests()
  # The only change is "kubectl get builds" -> "oc get builds.build.knative.dev"
  oc get project
  # Wait for tests to finish.
  echo ">> Waiting for tests to finish"
  local tests_finished=0
    for i in {1..60}; do
      sleep 10
      local finished="$(oc get builds.build.knative.dev --output=jsonpath='{.items[*].status.conditions[*].status}')"
      if [[ ! "$finished" == *"Unknown"* ]]; then
        tests_finished=1
        break
      fi
    done
  if (( ! tests_finished )); then
    echo "ERROR: tests timed out"
    return 1
  fi

  # Check that tests passed.
  local failed=0
  echo ">> Checking test results"
  for expected_status in succeeded failed; do
    results="$(oc get builds.build.knative.dev -l expect=${expected_status} \
	--output=jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[*].type}{.status.conditions[*].status}{" "}{end}')"
    case $expected_status in
      succeeded)
      want=succeededtrue
      ;;
          failed)
      want=succeededfalse
      ;;
          *)
      echo "ERROR: Invalid expected status '${expected_status}'"
      failed=1
      ;;
    esac
    for result in ${results}; do
      if [[ ! "${result,,}" == *"=${want}" ]]; then
        echo "ERROR: test ${result} but should be ${want}"
        failed=1
      fi
    done
  done
  (( failed )) && return 1
  echo ">> All YAML tests passed"
  return 0
}

function delete_build_pipeline_openshift() {
  echo ">> Bringing down Build"
  oc delete --ignore-not-found=true -f build-pipeline-resolved.yaml
  # Make sure that are no builds or build templates in the knative-build-pipeline namespace.
  oc delete --ignore-not-found=true builds.build.knative.dev --all -n $BUILD_PIPELINE_NAMESPACE
  oc delete --ignore-not-found=true buildtemplates.build.knative.dev --all -n $BUILD_PIPELINE_NAMESPACE
}

function delete_test_resources_openshift() {
  echo ">> Removing test resources (test/)"
  oc delete --ignore-not-found=true -f tests-resolved.yaml
}

 function delete_test_namespace(){
   echo ">> Deleting test namespace $TEST_NAMESPACE"
   oc policy remove-role-from-group system:image-puller system:serviceaccounts:$TEST_NAMESPACE -n $OPENSHIFT_BUILD_PIPELINE_NAMESPACE
   oc delete project $TEST_NAMESPACE
   oc policy remove-role-from-group system:image-puller system:serviceaccounts:$TEST_YAML_NAMESPACE -n $OPENSHIFT_BUILD_PIPELINE_NAMESPACE
   oc delete project $TEST_YAML_NAMESPACE
 }

function teardown() {
  delete_test_namespace
  delete_test_resources_openshift
  delete_build_pipeline_openshift
}

create_test_namespace

enable_docker_schema2

install_build_pipeline

failed=0

run_go_e2e_tests || failed=1

run_yaml_e2e_tests || failed=1

(( failed )) && dump_cluster_state

teardown

(( failed )) && exit 1

success