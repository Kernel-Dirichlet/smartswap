#!/usr/bin/env python3

import argparse
import os
import time
import psutil
import numpy as np
import threading
import subprocess
import json
from datetime import datetime, UTC
from swap_niceness_utils import calculate_disk_io_swappiness, calculate_network_swappiness, calculate_cpu_swappiness

# Default values
# ======================================================

DEFAULT_MAX_ENTRIES = 200
DEFAULT_SNAPSHOT_INTERVAL = 5
DEFAULT_SWAPFILE_SIZE = 1024  # 1GB in MB
DEFAULT_NICENESS = 0  # Default niceness if not specified
SWAPPINESS_PATH = "/proc/sys/vm/swappiness"
LOG_FILE = "/tmp/swap-mgr_log.txt"
SWAPFILE_PATH = "/swapfile"
CONFIG_FILE = "swp_mgr_cfg.json"

# ======================================================
# Default weights for different optimization targets (sum = 1.0)
DEFAULT_WEIGHTS = {
    'disk_latency': 0.25,
    'cpu_usage': 0.25,
    'ram_usage': 0.25,
    'network_bandwidth': 0.25
}

def load_config():
    try:
        with open(CONFIG_FILE, 'r') as f:
            config = json.load(f)
            weights = {
                'disk_latency': config.get('DISK_LATENCY', DEFAULT_WEIGHTS['disk_latency']),
                'cpu_usage': config.get('CPU_USAGE', DEFAULT_WEIGHTS['cpu_usage']),
                'ram_usage': config.get('RAM_USAGE', DEFAULT_WEIGHTS['ram_usage']),
                'network_bandwidth': config.get('NETWORK_BANDWIDTH', DEFAULT_WEIGHTS['network_bandwidth'])
            }
            
            # Load PID w/ or w/o niceness if exist
            process_settings = {
                'pid': config.get('PID', None),
                'niceness': config.get('NICENESS', DEFAULT_NICENESS)
            }
            
            if process_settings['pid']:
                try:
                    if psutil.pid_exists(process_settings['pid']):
                        print(f"Config: Found PID {process_settings['pid']} with niceness {process_settings['niceness']}")
                        try:
                            os.setpriority(os.PRIO_PROCESS, process_settings['pid'], process_settings['niceness'])
                            print(f"Updated niceness to {process_settings['niceness']} for PID {process_settings['pid']}")
                        except OSError as e:
                            print(f"Failed to update niceness: {e}")
                    else:
                        print(f"PID {process_settings['pid']} is no longer running")
                        process_settings['pid'] = None
                        process_settings['niceness'] = DEFAULT_NICENESS
                except psutil.NoSuchProcess:
                    print(f"PID {process_settings['pid']} is no longer running")
                    process_settings['pid'] = None
                    process_settings['niceness'] = DEFAULT_NICENESS
            else:
                print(f"Config: No PID specified, using default niceness {DEFAULT_NICENESS}")
                
            return weights, process_settings
            
    except Exception as e:
        print(f"Error loading config file: {e}")
        return DEFAULT_WEIGHTS, {'pid': None, 'niceness': DEFAULT_NICENESS}

def create_swapfile(size_mb):
    if os.path.exists(SWAPFILE_PATH):
        print(f"Swapfile {SWAPFILE_PATH} already exists")
        return True

    print(f"Creating {size_mb}MB swapfile at {SWAPFILE_PATH}")
    
    try:
        # Try fallocate - most file systems support this
        subprocess.run(['fallocate', '-l', f'{size_mb}M', SWAPFILE_PATH], check=True)
    except subprocess.CalledProcessError:
        print("fallocate failed, falling back to dd...")
        try:
            # Fall back to dd (BTRFS file system is an example)
            subprocess.run(['dd',
                            'if=/dev/zero',
                            f'of={SWAPFILE_PATH}', 
                          'bs=1M',
                            f'count={size_mb}',
                            'status=progress'], 
                          check = True,
                          stderr = subprocess.PIPE)
        except subprocess.CalledProcessError as e:
            print(f"Failed to create swapfile: {e}")
            # Clean up partial file
            if os.path.exists(SWAPFILE_PATH):
                os.remove(SWAPFILE_PATH)
            return False

    try:
        # Set permissions
        os.chmod(SWAPFILE_PATH, 0o600)
        subprocess.run(['mkswap', SWAPFILE_PATH], check=True)
        
        # Enable swap if off
        subprocess.run(['swapon',
                        SWAPFILE_PATH],
                        check = True)
        
        print(f"Successfully created and enabled {size_mb}MB swapfile")
        return True
        
    except (subprocess.CalledProcessError, OSError) as e:
        print(f"Error setting up swap: {e}")
        if os.path.exists(SWAPFILE_PATH):
            os.remove(SWAPFILE_PATH)
        return False

def get_swappiness():
    try:
        with open(SWAPPINESS_PATH, "r") as f:
            return int(f.read().strip())
    except Exception as e:
        print(f"Error reading swappiness: {e}")
        return None

def set_swappiness(value):
    try:
        with open(SWAPPINESS_PATH, "w") as f:
            f.write(str(value))
        print(f"Swappiness set to {value}")
    except Exception as e:
        print(f"Error setting swappiness: {e}")

def collect_metrics():
    try:
        # Get disk I/O stats
        disk_io = psutil.disk_io_counters()
        if disk_io.read_count > 0:
            disk_latency = disk_io.read_time / disk_io.read_count
        else:
            disk_latency = 0

        # Get swap memory stats
        swap = psutil.swap_memory()
        swap_total = swap.total / (1024 * 1024 * 1024)  # Convert to GB
        swap_used = swap.used / (1024 * 1024 * 1024)    # Convert to GB
        swap_percent = (swap_used / swap_total * 100) if swap_total > 0 else 0

        net_io = psutil.net_io_counters()
        return {
            "timestamp": datetime.now(UTC).isoformat(),  # Use timezone-aware UTC datetime
            "cpu_usage": psutil.cpu_percent(interval=1),  # 1 second interval for more accurate reading
            "ram_usage": psutil.virtual_memory().percent,
            "swap_usage": swap_percent,
            "swap_total_gb": round(swap_total, 2),
            "swap_used_gb": round(swap_used, 2),
            "disk_latency": round(disk_latency, 2),  # In milliseconds
            "disk_read_count": disk_io.read_count,
            "disk_write_count": disk_io.write_count,
            "network_bandwidth": round((net_io.bytes_sent + net_io.bytes_recv) / 1024 / 1024, 2)  # Convert to MB
        }
    except Exception as e:
        print(f"Error collecting metrics: {e}")
        return None

def write_to_log(metrics, old_swappiness, new_swappiness, interval, weights_changed=None):
    log_entry = f"""
Record: {interval}
Timestamp (UTC): {metrics['timestamp']}
CPU usage: {metrics['cpu_usage']:.2f}%
RAM usage: {metrics['ram_usage']:.2f}%
Swap usage: {metrics['swap_usage']:.2f}% ({metrics['swap_used_gb']:.2f}GB / {metrics['swap_total_gb']:.2f}GB)
Disk I/O latency: {metrics['disk_latency']:.2f}ms
Disk reads: {metrics['disk_read_count']}
Disk writes: {metrics['disk_write_count']}
Network bandwidth: {metrics['network_bandwidth']:.2f}MB
Old swappiness: {old_swappiness}
New swappiness: {new_swappiness}"""

    if weights_changed:
        log_entry += f"\nWeights changed from {weights_changed['old']} to {weights_changed['new']}"

    log_entry += f"\n{'-'*50}\n"
    
    os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    
    try:
        with open(LOG_FILE, "a") as f:
            f.write(log_entry)
            f.flush()
            os.fsync(f.fileno())
    except Exception as e:
        print(f"Error writing to log: {e}")

def calculate_swappiness(metrics, weights):
    # Normalize metrics to 0-1 range
    normalized_metrics = {
        'disk_latency': min(1.0, metrics['disk_latency'] / 100),  # Normalize against 100ms baseline
        'cpu_usage': metrics['cpu_usage'] / 100,
        'ram_usage': metrics['ram_usage'] / 100,
        'network_bandwidth': min(1.0, metrics['network_bandwidth'] / 1000)  # Normalize against 1000MB baseline
    }
    
    # Calculate weighted score (0-1 range)
    weighted_score = sum(weights[key] * normalized_metrics[key] for key in weights)
    
    # CPU usage should reduce swappiness
    cpu_factor = 1 - (metrics['cpu_usage'] / 100)
    
    # Base swappiness range 1-200, modified by CPU usage
    base_swappiness = 100 + (weighted_score - 0.5) * 200
    adjusted_swappiness = base_swappiness * cpu_factor
    
    return max(1, min(200, int(adjusted_swappiness)))

def adjust_swappiness(metrics_list, weights, weights_changed=None):
    if len(metrics_list) < 5:
        return  # Not enough data points

    # Compute moving averages
    averages = {key: np.mean([entry[key] for entry in metrics_list]) 
               for key in metrics_list[0] if key != "timestamp"}

    old_swappiness = get_swappiness()
    if old_swappiness is None:
        return

    new_swappiness = calculate_swappiness(averages, weights)

    if abs(new_swappiness - old_swappiness) >= 5:  # Only change if difference is >= 5
        set_swappiness(int(new_swappiness))
        write_to_log(metrics_list[-1], old_swappiness, new_swappiness, len(metrics_list), weights_changed)

def run_daemon(max_entries, snapshot_interval, weights):
    metrics_list = []
    start_time = time.time()
    previous_weights = weights.copy()
    previous_settings = None
    
    while True:
        try:
            # Reload weights from config file each interval
            current_weights, current_settings = load_config()
            
            # Check if weights have changed
            weights_changed = None
            if current_weights != previous_weights:
                weights_changed = {
                    'old': previous_weights.copy(),
                    'new': current_weights.copy()
                }
                print(f"Weights changed from {previous_weights} to {current_weights}")
                previous_weights = current_weights.copy()
            
            # Check if process settings have changed
            if current_settings != previous_settings:
                if current_settings['pid'] and current_settings['niceness'] is not None:
                    try:
                        # Check if process is still running
                        if psutil.pid_exists(current_settings['pid']):
                            os.setpriority(os.PRIO_PROCESS, current_settings['pid'], current_settings['niceness'])
                            print(f"Updated niceness to {current_settings['niceness']} for PID {current_settings['pid']}")
                        else:
                            print(f"PID {current_settings['pid']} is no longer running, stopping tracking")
                            current_settings['pid'] = None
                            current_settings['niceness'] = DEFAULT_NICENESS
                    except (OSError, psutil.NoSuchProcess) as e:
                        print(f"Failed to update niceness: {e}")
                previous_settings = current_settings.copy()
            
            metrics = collect_metrics()
            if metrics:
                metrics_list.append(metrics)

                if len(metrics_list) > max_entries:
                    metrics_list.pop(0)

                adjust_swappiness(metrics_list, current_weights, weights_changed)
                
                elapsed_intervals = int((time.time() - start_time) / snapshot_interval)
                write_to_log(metrics, get_swappiness(), get_swappiness(), elapsed_intervals, weights_changed)
            
            time.sleep(snapshot_interval)
            
        except Exception as e:
            print(f"Error in daemon loop: {e}")
            time.sleep(snapshot_interval)

def validate_weights(weights):
    """Validate that weights sum to 1.0"""
    total = sum(weights.values())
    if abs(total - 1.0) > 0.001:  # Allow for small floating point errors
        raise argparse.ArgumentTypeError(f"Weights must sum to 1.0 (current sum: {total})")
    return weights

def main():
    parser = argparse.ArgumentParser(description="Swappiness Adjustment Daemon")
    parser.add_argument("--max_entries", type=int, default=DEFAULT_MAX_ENTRIES,
                      help="Max number of entries before deleting old ones")
    parser.add_argument("--snapshot_interval", type=int, default=DEFAULT_SNAPSHOT_INTERVAL,
                      help="Interval (seconds) for snapshots")
    parser.add_argument("--swapfile_size", type=int, default=DEFAULT_SWAPFILE_SIZE,
                      help="Size of swapfile in MB (default 1GB)")
    parser.add_argument("--disk-latency-weight", type=float, default=DEFAULT_WEIGHTS['disk_latency'],
                      help="Weight for disk latency in swappiness calculation")
    parser.add_argument("--cpu-usage-weight", type=float, default=DEFAULT_WEIGHTS['cpu_usage'],
                      help="Weight for CPU usage in swappiness calculation")
    parser.add_argument("--ram-usage-weight", type=float, default=DEFAULT_WEIGHTS['ram_usage'],
                      help="Weight for RAM usage in swappiness calculation")
    parser.add_argument("--network-bandwidth-weight", type=float, default=DEFAULT_WEIGHTS['network_bandwidth'],
                      help="Weight for network bandwidth in swappiness calculation")
    parser.add_argument("--pid", type=int, help="Process ID to monitor")
    parser.add_argument("--niceness", type=int, help="Set niceness value for the specified PID (-20 to 19)")
    
    args = parser.parse_args()

    # Load initial weights from config file
    weights, process_settings = load_config()

    try:
        validate_weights(weights)
    except argparse.ArgumentTypeError as e:
        print(f"Error: {e}")
        return

    if args.pid:
        try:
            process = psutil.Process(args.pid)
            print(f"Monitoring process with PID {args.pid}")
            
            if args.niceness is not None:
                if args.niceness < -20 or args.niceness > 19:
                    print("Error: Niceness value must be between -20 and 19")
                    return
                try:
                    os.setpriority(os.PRIO_PROCESS, args.pid, args.niceness)
                    print(f"Set niceness to {args.niceness} for PID {args.pid}")
                except OSError as e:
                    print(f"Failed to set niceness: {e}")
                    return
            
            # Get current niceness for informational purposes
            current_niceness = process.nice()
            print(f"Process niceness is {current_niceness}")
            
        except psutil.NoSuchProcess:
            print(f"Process with PID {args.pid} not found")
            return
        except psutil.AccessDenied:
            print(f"Permission denied when accessing PID {args.pid}")
            return

    if not create_swapfile(args.swapfile_size):
        print("Failed to create/enable swapfile. Exiting.")
        return

    print(f"Starting swappiness daemon with max entries: {args.max_entries}, snapshot interval: {args.snapshot_interval}s")
    print(f"Using weights: {weights}")
    print(f"Logging to {LOG_FILE}")

    daemon_thread = threading.Thread(target=run_daemon, args=(args.max_entries, args.snapshot_interval, weights), daemon=True)
    daemon_thread.start()

    while True:
        time.sleep(1)

if __name__ == "__main__":
    main()

