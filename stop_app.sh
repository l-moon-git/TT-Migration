#!/bin/bash


wait_for_pods_to_stop() {
    local app_name timeout
    app_name="$1"
    timeout="$2"

    SECONDS=0
    while k3s kubectl get pods -n ix-"$app_name" -o=name | grep -qv -- '-cnpg-'; do
        if [[ "$SECONDS" -gt $timeout ]]; then
            return 1
        fi
        sleep 1
    done
}


get_app_status() {
    local app_name
    app_name="$1"

    cli -m csv -c 'app chart_release query name,status' | \
            grep -- "^$app_name," | \
            awk -F ',' '{print $2}'
}


scale_down_resources() {
    local app_name timeout
    app_name="$1"
    timeout="$2"

    if ! k3s kubectl get deployments,statefulsets -n ix-"$app_name" | grep -vE -- "(NAME|^$|-cnpg-)" | awk '{print $1}' | xargs -I{} k3s kubectl scale --replicas=0 -n ix-"$app_name" {} &>/dev/null; then
        return 1
    fi
    wait_for_pods_to_stop "$app_name" "$timeout" && return 0 || return 1
}


handle_stop_code() {
    local stop_code
    stop_code="$1"

    case "$stop_code" in
        0)
            echo "Stopped"
            return 0
            ;;
        1)
            echo -e "Failed to stop\nManual intervention may be required"
            return 1
            ;;
        2)
            echo -e "Timeout reached\nManual intervention may be required"
            return 1
            ;;
        3)
            echo "HeavyScript doesn't have the ability to stop Prometheus"
            return 1
            ;;
    esac
}


stop_app() {
    # Return 1 if cli command outright fails
    # Return 2 if timeout is reached
    # Return 3 if app is a prometheus instance

    local app_name timeout status
    app_name="$1"
    timeout="50"

    # Grab chart info
    chart_info=$(midclt call chart.release.get_instance "$app_name")

    # Check if app has a cnpg pods
    if printf "%s" "$chart_info" | grep -sq -- \"cnpg\":;then
        scale_down_resources "$app_name" "$timeout" && return 0 || return 1
    # Check if app is a prometheus instance
    elif printf "%s" "$chart_info" | grep -sq -- \"prometheus\":;then
        return 3
    fi

    status=$(get_app_status "$app_name")
    if [[ "$status" == "STOPPED" ]]; then
        return 0
    fi

    timeout "${timeout}s" cli -c 'app chart_release scale release_name='\""$app_name"\"\ 'scale_options={"replica_count": 0}' &> /dev/null
    timeout_result=$?

    if [[ $timeout_result -eq 0 ]]; then
        return 0
    elif [[ $timeout_result -eq 124 ]]; then
        return 2
    fi

    return 1
}