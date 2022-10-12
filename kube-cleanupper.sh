#!/usr/bin/env bash
# This file:
#
#  - Kubernetes deployment autocleanup
#

# Exit on error. Append "|| true" if you expect an error.
# Do not allow use of undefined vars. Use ${VAR:-} to use an undefined VAR
# Catch the error in case pipe fauks
# Exit on error inside any functions or subshells.
set -euo pipefail
# Turn on traces, useful while debugging but commented out by default
# set -o xtrace

# CONSTANTS
ONE_DAY_IN_SECONDS=86400
CLEANUP_LABEL="auto-clean"
RETENTION_LABEL="retention"

# Time and date at which to check if something is expired (in epoch seconds)
# We set this only once, so we don't start deleting half a deployment worth of stuff,
# if the time ticks over a retention period while we're running.
CUTOFF_TIME=$(date +%s)
DEBUG=false

debug() {
  if $DEBUG; then
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] - DEBUG: $*" >&2
  fi
}
info() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] - INFO:  $*" >&2
}
err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] - ERROR: $*" >&2
}

function find_deployments_ages {
    local namespace="$1"

    local replica_sets
    local current_gen_replicas
    local deployment_generation
    local deployment_creationTimestamps

    # Here we get all the replica sets, and print out their name, generation, and their owner deployment
    replica_sets=$(kubectl get replicasets -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.name}{", "}{.metadata.annotations.deployment\.kubernetes\.io/revision}{", "}{.metadata.ownerReferences[*].name}{"\n"}{end}')

    # Error checking
    if [ -z "$replica_sets" ]; then
        debug "No replica sets found in $namespace"
        echo ""
        return 0
    fi

    # Now we check a replicaset against its owner deployment, and record only the replicasets that are the current generation
    current_gen_replicas=()
    while IFS=', ' read -r rs gen owner_deployment; do
        deployment_generation=$(kubectl get deployment "$owner_deployment" -n "$namespace" -o jsonpath='{.metadata.generation}' )
        if [ "$gen" -eq "$deployment_generation" ]; then
          current_gen_replicas+=("$rs")
        fi
    done < <(echo "$replica_sets")

    # Now we can match the current-gen replicasets creation times with their owner deployments, telling us their 'true' age
    deployment_creationTimestamps=$(kubectl get replicasets "${current_gen_replicas[@]}" -n "$namespace" -o jsonpath='{range .items[*]}{.metadata.ownerReferences[*].name}{", "}{.metadata.creationTimestamp}{"\n"}{end}')

    echo "$deployment_creationTimestamps"
}

function find_deployments_that_need_cleaning {
    local namespace="$1"
    local artificial_retention_period="$2"
    local force_clean="$3"

    local deployment_ages
    local cleanup_status
    local cleanup_enabled
    local cleanup_retention
    local creation_date_in_sec
    local expiry_time_in_sec
    local expiry_date

    deployment_ages=$(find_deployments_ages "$namespace")

    # Error checking
    if [ -z "$deployment_ages" ]; then
        debug "No deployments to look at in $namespace"
        echo ""
        return 0
    fi

    while IFS=', ' read -r deployment creationTimestamp; do
        debug "$deployment $creationTimestamp"

        # Find the tags controlling cleanup from the deployments
        cleanup_status=$(kubectl get deployment "$deployment" -n "$namespace" -o jsonpath="{.metadata.labels.$CLEANUP_LABEL}{\",\"}{.metadata.labels.$RETENTION_LABEL}{\"\n\"}")
        cleanup_enabled=$(echo "$cleanup_status" | cut -f1 -d,)
        cleanup_retention=$(echo "$cleanup_status" | cut -f2 -d,)

        # Do some error checks and processing of the tags
        if [ "$cleanup_enabled" = "enabled" ]; then
            debug "Clean up enabled!"
        else
            debug "Clean up disabled, skipping..."
            continue
        fi

        if [ -z "$cleanup_retention" ] ; then
            if [ "$artificial_retention_period" -eq -1 ]; then
                info "No retention time set for deployment $deployment, and no -d parameter provided: skipping"
                continue
            elif ! $force_clean; then
                info "No retention time set for deployment $deployment, and no -f parameter provided: skipping"
                continue
            fi
        fi

        if [ "$artificial_retention_period" -ne -1 ]; then
            info "Using artificial retention period for deployment $deployment: setting to '${artificial_retention_period}d'"
            cleanup_retention="${artificial_retention_period}d"
        fi

        if [[ $cleanup_retention == *"d" ]]; then
          debug "Rentention: $cleanup_retention"
          cleanup_retention=$(echo "$cleanup_retention" | tr -d 'd')  # Remove the 'd'
        else
          err "Retention was not defined for deployment $deployment in days (e.g., 4d): skipping"
          continue
        fi
        # Done with error checking

        # Get the creation date in seconds since the epoc
        creation_date_in_sec=$(date --date "$creationTimestamp" +%s)
        expiry_time_in_sec=$(( cleanup_retention * ONE_DAY_IN_SECONDS ))
        # Get the expiry date in seconds since the epoc (by adding the retention time in seconds to the creation date)
        expiry_date=$(( creation_date_in_sec + expiry_time_in_sec ))

        # If the expiry time has already passed (i.e., it is less than now, in seconds), then it should be cleaned!
        if [ $expiry_date -le "$CUTOFF_TIME" ]; then
          info "We should delete: $deployment"
          echo "$deployment"
        else
          info "No need to delete: $deployment ($(( (expiry_date - CUTOFF_TIME) / ONE_DAY_IN_SECONDS )) days left)"
        fi

    done < <(echo "$deployment_ages")
}

function get_identifying_label_values_from_deployment {
    local namespace=$1
    local deployment=$2
    shift 2
    local identifying_labels=( "$@" )

    local id_labels=()

    for idl in "${identifying_labels[@]}"; do
        # Note we use bash to put a '\' in front of the dots that can be in labels
        value=$(kubectl get deployment "$deployment" -n "$namespace" -o jsonpath="{.metadata.labels.${idl//\./\\\.}}")
        id_labels+=("$idl=$value")
    done

    # Return the labels as a comma-separated list. Put in ( ) just to make sure the IFS doesn't escape ;)
    ( IFS=, ; echo "${id_labels[*]}" )
}


function delete_k8s_objs_with_labels {
    local labels="$1"
    shift 1
    local objects_to_clean=( "$@" )

    # Now we fetch all objects that have those identifying labels,
    # The result is a newline separated list of kubectl delete compatible strings
    all_objects_to_clean=$(kubectl get "$(IFS=, ; echo "${objects_to_clean[*]}")" --all-namespaces -l "$labels" -o jsonpath='{range .items[*]}{.kind}{" "}{.metadata.name}{" -n "}{.metadata.namespace}{"\n"}{end}')

    # And finally, we're ready to delete them!
    info "Printing all the items that should be deleted!"
    while read -r obj_delete_string; do
      kubectl delete "$obj_delete_string"  # this needs to be unquoted, so things expand out properly.
    done < <(echo "$all_objects_to_clean")
}


function main {

    # Retention
    local artificial_retention_period="$1"
    local force_clean="$2"

    # List of objects to delete
    objects_to_clean=("deployments" "services" "virtualservice" "gateway" "secret" "certificates" "authorizationpolicies")
    # List of labels used to find other objects related to a deployment
    identifying_labels=( "app.kubernetes.io/version" "app.kubernetes.io/part-of")

    # Getting all namespaces with the auto-clean label applied
    debug "Getting namespaces to clean ..."
    relevant_ns=$(kubectl get ns -l "$CLEANUP_LABEL" -o jsonpath='{.items[*].metadata.name}')

    for namespace_to_clean in $relevant_ns; do
        info "Investigating namespace: $namespace_to_clean"
        # Find all the deployments that need cleaning
        deployments_to_clean=$(find_deployments_that_need_cleaning "$namespace_to_clean" "$artificial_retention_period" "$force_clean")

        # Error checking
        if [ -z "$deployments_to_clean" ]; then
            info "No deployments to clean in $namespace_to_clean"
            continue
        fi

        # Now we start the cleaning process
        for d in $deployments_to_clean; do
            # We need to find all the objects relating to the deployment, so we use some specific labels that all relevant
            # objects should have on them (defined in $identifying_labels). Here we get those labels in a kubectl format
            labels=$(get_identifying_label_values_from_deployment "$namespace_to_clean" "$d" "${identifying_labels[@]}")

            # Using the labels as the identifier, go and delete the variables objects that need cleaning from the K8s cluster
            delete_k8s_objs_with_labels "$labels" "${objects_to_clean[@]}"
        done

    done
}

# Usage
usage() {
      echo "kube-cleaupper is a helper service that helps you to clean up kubernetes objects older than time period defined."
      echo ""
      echo "Usage: kube-cleanupper [-d <no_of_days>] [-f] "
      echo ""
      echo "Options:"
      echo "                    -h                     Display this help message."
      echo "                    -d <no_of_days>        Sets an artificial retention period, overriding the label attached to an object."
      echo "                                           This therefore simulates if the K8s object was labeled with a retention time of this no_of_days"
      echo "                    -f                     Forces all objects with no retention defined to use the -d param as their retention period."
}

force_clean_flag=false
days="-1"

# Get opts valye
while getopts "d:fh" opt; do
  case ${opt} in
    d )
      # banner
      re='^[0-9]+$'
      if ! [[ ${OPTARG} =~ $re ]] ; then
          echo "error: Provided input is not a positive integer" >&2; exit 1
      fi
      days=${OPTARG}
      ;;
    f )
      force_clean_flag=true
      ;;
    h )
      usage
      exit 0
      ;;
   \? )
     echo "Invalid Option: -${OPTARG}" 1>&2
     echo ""
     usage
     exit 1
     ;;
  esac
done

if $force_clean_flag && [ "$days" -eq -1 ]; then
    err "If you specify the -f option, you must provide a value for -d"
    usage
    exit 1
fi

main "$days" "$force_clean_flag"