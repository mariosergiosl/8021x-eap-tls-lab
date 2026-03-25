#!/bin/bash
# ======================================================================================
# FILE: /opt/hostapd_files/hostapd_run.bash
# USAGE: /opt/hostapd_files/hostapd_run.bash
# DESCRIPTION: Script to execute hostapd with maximum debug level, file logging,
#              and background execution (daemonize).
# OPTIONS: None.
# AUTHOR: Mario Luz
# VERSION: 1.1
# ======================================================================================

# --------------------------------------------------------------------------------------
# NAME: run_hostapd
# DESCRIPTION: Starts the hostapd daemon using short flags for extensive debug (-dd),
#              key material extraction (-K), timestamps (-t), log redirection (-f),
#              and background execution (-B).
# PARAMETER: None
# --------------------------------------------------------------------------------------
run_hostapd() {
    local bin_path="/usr/sbin/hostapd"
    local conf_file="/etc/hostapd/hostapd.conf"
    local log_file="/var/log/hostapd.log"

    if [ ! -f "${conf_file}" ]; then
        echo "Error: Configuration file ${conf_file} not found."
        exit 1
    fi

    echo "Starting hostapd..."
    echo "Configuration: ${conf_file}"
    echo "Log output: ${log_file}"
    echo "Execution mode: Background (Daemon)"

    "${bin_path}" -ddKt -B -f "${log_file}" "${conf_file}"
}

# --------------------------------------------------------------------------------------
# Main execution block
# --------------------------------------------------------------------------------------
run_hostapd
