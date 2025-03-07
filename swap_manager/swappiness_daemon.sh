#!/bin/bash
######### SMARTSWAP ######################


#SWAPPINESS DAEMON FOR ARCH LINUX

#SmartSwap is a package which dynamically adjusts swappiness on Arch Linux systems based on system load and system objectives
# This script monitors and adjusts the swappiness parameter based on system memory usage.

#### CONFIG ####################################################################

CHECK_INTERVAL=5  # How often to measure (and potentially adjust) swappiness.
VERY_LOW_THRESHOLD=20   # Threshold for "VERY LOW" memory usage
LOW_THRESHOLD=40   # Threshold for "LOW" memory usage
MEDIUM_THRESHOLD=60  # Threshold for "MEDIUM" memory usage 
HIGH_THRESHOLD=80  # Treshold for "HIGH" memory usage
VERY_HIGH_THRESHOLD=90  # Threshold for "VERY HIGH" memory usage 
CRITICAL_THRESHOLD=95  # Threshold for "CRITICAL" memory usage


##### WORKLOAD WEIGHTS ##########
# These values should sum to 1 - they represent relative importance in how adjusted swappiness is calculated
# Example: a CPU heavy workload that involves a lot of repeated calculations might have 
# CPU_WEIGHT = 75 
# RAM_WEIGHT = 10
# IO_WEIGHT = 5
# NETWORK_WEIGHT = 5
# This means that minimizing CPU usage is the priority of the swappiness manager, with the other metrics being of much lower optimization 
# priority 

CPU_WEIGHT=25
RAM_WEIGHT=25
IO_WEIGHT=25
NETWORK_WEIGHT=25

# Log file configuration
LOG_FILE="/tmp/swap_daemon.log"

# Ensure we're running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root" >&2
    exit 1
fi

# Function to get current memory usage percentage
get_memory_usage() {
    free | grep Mem | awk '{print int($3/$2 * 100)}'
}

# Function to get current CPU usage percentage
get_cpu_usage() {
    top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print int(100 - $1)}'
}

# Function to get current IO usage (improved metric)
get_io_usage() {
    # Get disk utilization percentage using iostat
    if command -v iostat >/dev/null 2>&1; then
        # Sample for 2 seconds to get more accurate readings
        # Use the average of all disks' %util values, including HDDs, SSDs, and NVMe drives
        iostat -dx 2 1 | awk '
        BEGIN {sum=0; count=0;}
        /%util/ {header=1; next;}
        header==1 && $1 ~ /^[a-zA-Z]/ && $1 !~ /^loop/ {
            # Include all disk types but exclude loop devices
            sum+=$(NF); 
            count++;
        }
        END {
            if (count > 0) {
                util = int(sum/count);
                # Cap at 100%
                if (util > 100) util = 100;
                print util;
            }
            else print 50;
        }'
    else
        # Fallback method if iostat is not available
        # Check current disk activity using /proc/diskstats for all disk types
        local read_before=0
        local write_before=0
        
        # Get stats for all disk types (sda for SATA, nvme for NVMe, mmcblk for eMMC/SD)
        local disks=$(ls -l /dev/disk/by-path/ 2>/dev/null | grep -v "part[0-9]" | awk '{print $NF}' | sed 's/\.\.\/\.\.\///' | grep -E '^sd|^nvme|^mmcblk|^xvd|^vd')
        if [ -z "$disks" ]; then
            # Fallback to common patterns if by-path doesn't work
            disks=$(lsblk -d -o NAME | grep -E '^sd|^nvme|^mmcblk|^xvd|^vd')
        fi
        
        # If we still don't have disks, try a direct approach
        if [ -z "$disks" ]; then
            disks=$(grep -E ' sd[a-z] | nvme[0-9]n[0-9] | mmcblk[0-9] | xvd[a-z] | vd[a-z] ' /proc/diskstats | awk '{print $3}')
        fi
        
        # If we still don't have disks, use a generic pattern
        if [ -z "$disks" ]; then
            read_before=$(grep -E ' sd[a-z] | nvme[0-9]n[0-9] | mmcblk[0-9] | xvd[a-z] | vd[a-z] ' /proc/diskstats 2>/dev/null | awk '{sum += $6} END {print sum}')
            write_before=$(grep -E ' sd[a-z] | nvme[0-9]n[0-9] | mmcblk[0-9] | xvd[a-z] | vd[a-z] ' /proc/diskstats 2>/dev/null | awk '{sum += $10} END {print sum}')
        else
            # Process each disk individually
            for disk in $disks; do
                disk_stats=$(grep " ${disk} " /proc/diskstats 2>/dev/null)
                if [ -n "$disk_stats" ]; then
                    read_before=$((read_before + $(echo "$disk_stats" | awk '{print $6}')))
                    write_before=$((write_before + $(echo "$disk_stats" | awk '{print $10}')))
                fi
            done
        fi
        
        sleep 1
        
        local read_after=0
        local write_after=0
        
        # Same approach for after measurements
        if [ -z "$disks" ]; then
            read_after=$(grep -E ' sd[a-z] | nvme[0-9]n[0-9] | mmcblk[0-9] | xvd[a-z] | vd[a-z] ' /proc/diskstats 2>/dev/null | awk '{sum += $6} END {print sum}')
            write_after=$(grep -E ' sd[a-z] | nvme[0-9]n[0-9] | mmcblk[0-9] | xvd[a-z] | vd[a-z] ' /proc/diskstats 2>/dev/null | awk '{sum += $10} END {print sum}')
        else
            for disk in $disks; do
                disk_stats=$(grep " ${disk} " /proc/diskstats 2>/dev/null)
                if [ -n "$disk_stats" ]; then
                    read_after=$((read_after + $(echo "$disk_stats" | awk '{print $6}')))
                    write_after=$((write_after + $(echo "$disk_stats" | awk '{print $10}')))
                fi
            done
        fi
        
        # Calculate IO operations per second and convert to a percentage
        # Scale differently for different drive types (NVMe can handle more IOPS)
        local iops=$(( (read_after - read_before) + (write_after - write_before) ))
        local io_percent=0
        
        # Check if we have NVMe drives (they can handle more IOPS)
        if echo "$disks" | grep -q "nvme"; then
            # NVMe drives can handle ~500K IOPS, so scale accordingly (500 IOPS = ~1%)
            io_percent=$(( iops / 500 ))
        else
            # Traditional drives handle fewer IOPS, so scale differently (100 IOPS = ~1%)
            io_percent=$(( iops / 100 ))
        fi
        
        # Cap at 100%
        if [ "$io_percent" -gt 100 ]; then
            io_percent=100
        fi
        
        echo "$io_percent"
    fi
}

# Function to get current network usage (simplified metric)
get_network_usage() {
    # Get network utilization if available
    if command -v ifstat >/dev/null 2>&1; then
        # Get total network throughput and normalize to percentage (assuming 1Gbps max)
        # Fixed to use standard ifstat without -b option
        network_percent=$(ifstat 1 1 | tail -n 1 | awk '{print int(($1 + $2) * 8 / 10000000 * 100)}')
        
        # Cap at 100%
        if [ "$network_percent" -gt 100 ]; then
            network_percent=100
        fi
        
        echo "$network_percent"
    else
        # Default to 50% if ifstat not available
        echo 50
    fi
}

# Function to get current swappiness value
get_swappiness() {
    cat /proc/sys/vm/swappiness
}

# Function to set swappiness value
set_swappiness() {
    local new_value=$1
    echo "Setting swappiness to $new_value"
    echo $new_value > /proc/sys/vm/swappiness
    
    # Verify the change
    local current=$(get_swappiness)
    echo "Current swappiness is now: $current"
}

# Function to log system metrics and swappiness
log_metrics() {
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    local mem_usage=$1
    local cpu_usage=$2
    local io_usage=$3
    local network_usage=$4
    local swappiness=$5
    local original_swappiness=$6
    
    echo "$timestamp:" >> $LOG_FILE
    echo "CPU usage: $cpu_usage%" >> $LOG_FILE
    echo "RAM usage: $mem_usage%" >> $LOG_FILE
    echo "Disk I/O: $io_usage%" >> $LOG_FILE
    echo "Network: $network_usage%" >> $LOG_FILE
    echo "Original swappiness: $original_swappiness" >> $LOG_FILE
    echo "Current swappiness: $swappiness" >> $LOG_FILE
    echo "-------" >> $LOG_FILE
}

# Function to calculate optimal swappiness based on memory usage
# This uses a more granular approach with values from 0-200 in steps of 5
calculate_optimal_swappiness() {
    local mem_usage=$1
    local cpu_usage=$2
    local io_usage=$3
    local network_usage=$4
    local swappiness_value
    local memory_based_swappiness
    
    # Logic for determining memory-based swappiness:
    # - Very low memory usage (0-20%): Minimal swapping (0-15)
    # - Low memory usage (20-40%): Light swapping (20-40)
    # - Medium memory usage (40-60%): Moderate swapping (45-80)
    # - High memory usage (60-80%): Aggressive swapping (85-120)
    # - Very high memory usage (80-90%): Very aggressive swapping (125-160)
    # - Critical memory usage (90-100%): Maximum swapping (165-200)
    
    if [ "$mem_usage" -lt "$VERY_LOW_THRESHOLD" ]; then
        # Very low memory usage: Minimal swapping
        # Formula: 0 + (mem_usage * 15/20) = 0-15 range
        memory_based_swappiness=$(( (mem_usage * 15) / VERY_LOW_THRESHOLD ))
        
    elif [ "$mem_usage" -lt "$LOW_THRESHOLD" ]; then
        # Low memory usage: Light swapping
        # Formula: 20 + ((mem_usage - 20) * 20/20) = 20-40 range
        memory_based_swappiness=$(( 20 + ((mem_usage - VERY_LOW_THRESHOLD) * 20) / (LOW_THRESHOLD - VERY_LOW_THRESHOLD) ))
        
    elif [ "$mem_usage" -lt "$MEDIUM_THRESHOLD" ]; then
        # Medium memory usage: Moderate swapping
        # Formula: 45 + ((mem_usage - 40) * 35/20) = 45-80 range
        memory_based_swappiness=$(( 45 + ((mem_usage - LOW_THRESHOLD) * 35) / (MEDIUM_THRESHOLD - LOW_THRESHOLD) ))
        
    elif [ "$mem_usage" -lt "$HIGH_THRESHOLD" ]; then
        # High memory usage: Aggressive swapping
        # Formula: 85 + ((mem_usage - 60) * 35/20) = 85-120 range
        memory_based_swappiness=$(( 85 + ((mem_usage - MEDIUM_THRESHOLD) * 35) / (HIGH_THRESHOLD - MEDIUM_THRESHOLD) ))
        
    elif [ "$mem_usage" -lt "$VERY_HIGH_THRESHOLD" ]; then
        # Very high memory usage: Very aggressive swapping
        # Formula: 125 + ((mem_usage - 80) * 35/10) = 125-160 range
        memory_based_swappiness=$(( 125 + ((mem_usage - HIGH_THRESHOLD) * 35) / (VERY_HIGH_THRESHOLD - HIGH_THRESHOLD) ))
        
    else
        # Critical memory usage: Maximum swapping
        # Formula: 165 + ((mem_usage - 90) * 35/10) = 165-200 range
        # Capped at 200 maximum
        memory_based_swappiness=$(( 165 + ((mem_usage - VERY_HIGH_THRESHOLD) * 35) / (100 - VERY_HIGH_THRESHOLD) ))
        if [ "$memory_based_swappiness" -gt 200 ]; then
            memory_based_swappiness=200
        fi
    fi
    
    # CPU-based swappiness adjustment (high CPU usage = lower swappiness)
    local cpu_based_swappiness=$((200 - cpu_usage * 2))
    if [ "$cpu_based_swappiness" -lt 0 ]; then
        cpu_based_swappiness=0
    fi
    
    # IO-based swappiness adjustment (high IO = higher swappiness)
    local io_based_swappiness=$((io_usage * 2))
    if [ "$io_based_swappiness" -gt 200 ]; then
        io_based_swappiness=200
    fi
    
    # Network-based swappiness adjustment (high network = moderate swappiness)
    local network_based_swappiness=$((network_usage + 50))
    if [ "$network_based_swappiness" -gt 200 ]; then
        network_based_swappiness=200
    fi
    
    # Calculate weighted average swappiness based on workload weights
    # Using integer weights (out of 100) instead of floating point to avoid arithmetic errors
    swappiness_value=$(( 
        (memory_based_swappiness * RAM_WEIGHT + 
         cpu_based_swappiness * CPU_WEIGHT + 
         io_based_swappiness * IO_WEIGHT + 
         network_based_swappiness * NETWORK_WEIGHT) / 100 
    ))
    
    # Ensure swappiness is within valid range
    if [ "$swappiness_value" -lt 0 ]; then
        swappiness_value=0
    elif [ "$swappiness_value" -gt 200 ]; then
        swappiness_value=200
    fi
    
    # Round to nearest multiple of 5
    swappiness_value=$(( (swappiness_value + 2) / 5 * 5 ))
    
    echo $swappiness_value
}

# Save original swappiness to restore on exit
ORIGINAL_SWAPPINESS=$(get_swappiness)

# Handle script termination
cleanup() {
    echo "Restoring original swappiness value: $ORIGINAL_SWAPPINESS"
    set_swappiness $ORIGINAL_SWAPPINESS
    echo "$(date "+%Y-%m-%d %H:%M:%S"): Daemon stopped, swappiness restored to $ORIGINAL_SWAPPINESS" >> $LOG_FILE
    echo "-------" >> $LOG_FILE
    exit 0
}

# Set up trap for clean exit
trap cleanup SIGINT SIGTERM

# Main loop
echo "Starting swappiness daemon..."
echo "Monitoring memory usage every $CHECK_INTERVAL seconds"
echo "Memory thresholds: Very Low: $VERY_LOW_THRESHOLD%, Low: $LOW_THRESHOLD%, Medium: $MEDIUM_THRESHOLD%, High: $HIGH_THRESHOLD%, Very High: $VERY_HIGH_THRESHOLD%, Critical: $CRITICAL_THRESHOLD%"
echo "Workload weights: CPU: $CPU_WEIGHT, RAM: $RAM_WEIGHT, IO: $IO_WEIGHT, Network: $NETWORK_WEIGHT (out of 100)"
echo "Original swappiness: $ORIGINAL_SWAPPINESS"
echo "Logging to: $LOG_FILE"

# Initial log entry
echo "$(date "+%Y-%m-%d %H:%M:%S"): Swap daemon started" >> $LOG_FILE
echo "Original swappiness: $ORIGINAL_SWAPPINESS" >> $LOG_FILE
echo "-------" >> $LOG_FILE

while true; do
    # Get current system metrics
    mem_usage=$(get_memory_usage)
    cpu_usage=$(get_cpu_usage)
    io_usage=$(get_io_usage)
    network_usage=$(get_network_usage)
    current_swappiness=$(get_swappiness)
    
    # Calculate optimal swappiness for current system state
    optimal_swappiness=$(calculate_optimal_swappiness $mem_usage $cpu_usage $io_usage $network_usage)
    
    echo "Current metrics: Memory: $mem_usage%, CPU: $cpu_usage%, IO: $io_usage%, Network: $network_usage%"
    echo "Current swappiness: $current_swappiness, Optimal swappiness: $optimal_swappiness"
    
    # Only change swappiness if it differs from the optimal value by more than 5
    # This prevents frequent small adjustments that might not have meaningful impact
    if [ $(( current_swappiness - optimal_swappiness )) -gt 5 ] || [ $(( optimal_swappiness - current_swappiness )) -gt 5 ]; then
        echo "Adjusting swappiness from $current_swappiness to $optimal_swappiness based on weighted system metrics"
        set_swappiness $optimal_swappiness
        # Log the change
        log_metrics $mem_usage $cpu_usage $io_usage $network_usage $optimal_swappiness $ORIGINAL_SWAPPINESS
    else
        echo "Current swappiness ($current_swappiness) is already close to optimal ($optimal_swappiness), no change needed"
        # Log the current state even when no change is made
        log_metrics $mem_usage $cpu_usage $io_usage $network_usage $current_swappiness $ORIGINAL_SWAPPINESS
    fi
    
    # Wait before checking again
    sleep "$CHECK_INTERVAL"
done

