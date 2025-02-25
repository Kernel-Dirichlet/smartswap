import os
import psutil
import time

# Process-specific optimization functions
def background_task(pid):
    """
    Optimizes for: Low-cost background tasks
    Sets high niceness and high swappiness.
    Good for tasks that can run slowly and don't need quick memory access.
    """
    try:
        # Set high niceness (19 is lowest priority)
        os.setpriority(os.PRIO_PROCESS, pid, 19)
        
        # Set high swappiness to allow aggressive swapping
        with open("/proc/sys/vm/swappiness", "w") as f:
            f.write("180")
            
    except Exception as e:
        print(f"Error configuring background task: {e}")

def memory_intensive(pid):
    """
    Optimizes for: Memory-intensive tasks
    Sets high niceness but low swappiness.
    Good for background tasks that need quick memory access.
    """
    try:
        # Set moderately high niceness (15)
        os.setpriority(os.PRIO_PROCESS, pid, 15)
        
        # Set low swappiness to keep memory in RAM
        with open("/proc/sys/vm/swappiness", "w") as f:
            f.write("10")
            
    except Exception as e:
        print(f"Error configuring memory intensive task: {e}")

def time_critical(pid):
    """
    Optimizes for: Time-critical tasks
    Sets low niceness and low swappiness.
    Good for tasks needing both CPU priority and quick memory access.
    """
    try:
        # Set low niceness (0 is default, -20 is highest priority)
        os.setpriority(os.PRIO_PROCESS, pid, -15)
        
        # Set very low swappiness to minimize memory latency
        with open("/proc/sys/vm/swappiness", "w") as f:
            f.write("5")
            
    except Exception as e:
        print(f"Error configuring time critical task: {e}")

def cpu_intensive(pid):
    """
    Optimizes for: CPU-intensive tasks
    Sets low niceness but allows swapping.
    Good for compute-heavy tasks that don't need fast memory access.
    """
    try:
        # Set low niceness for CPU priority
        os.setpriority(os.PRIO_PROCESS, pid, -10)
        
        # Set high swappiness since memory access isn't critical
        with open("/proc/sys/vm/swappiness", "w") as f:
            f.write("150")
            
    except Exception as e:
        print(f"Error configuring CPU intensive task: {e}")

def balanced_task(pid):
    """
    Optimizes for: Balanced workloads
    Sets neutral niceness and moderate swappiness.
    Good for general-purpose tasks with moderate CPU and memory needs.
    """
    try:
        # Set default niceness
        os.setpriority(os.PRIO_PROCESS, pid, 0)
        
        # Set moderate swappiness
        with open("/proc/sys/vm/swappiness", "w") as f:
            f.write("60")
            
    except Exception as e:
        print(f"Error configuring balanced task: {e}")

# System-wide weighted optimization functions
def calculate_disk_io_swappiness(metrics, weights):
    """
    Calculates optimal swappiness to minimize disk I/O latency
    weights = {
        'disk_latency': 0.5,    # Higher weight reduces swapping when disk is busy
        'cpu_usage': 0.2,       # Small weight allows some swapping if CPU is free
        'ram_usage': 0.3        # Moderate weight to prevent OOM
    }
    Returns calculated swappiness value between 1-200
    """
    weighted_score = (
        -weights['disk_latency'] * metrics['disk_latency'] +
        weights['cpu_usage'] * metrics['cpu_usage'] +
        weights['ram_usage'] * metrics['ram_usage']
    )
    
    return max(1, min(200, 100 + weighted_score * 100))

def calculate_network_swappiness(metrics, weights):
    """
    Calculates optimal swappiness to minimize network impact
    weights = {
        'network_bandwidth': 0.4,  # Higher weight reduces swapping during high network usage
        'ram_usage': 0.4,         # Balance with RAM pressure
        'cpu_usage': 0.2          # Small consideration for CPU load
    }
    Returns calculated swappiness value between 1-200
    """
    weighted_score = (
        -weights['network_bandwidth'] * metrics['network_bandwidth'] +
        weights['ram_usage'] * metrics['ram_usage'] +
        weights['cpu_usage'] * metrics['cpu_usage']
    )
    
    return max(1, min(200, 100 + weighted_score * 100))

def calculate_cpu_swappiness(metrics, weights):
    """
    Calculates optimal swappiness to minimize CPU overhead
    weights = {
        'cpu_usage': 0.6,        # Strong weight reduces swapping under CPU load
        'ram_usage': 0.3,        # Moderate consideration for RAM pressure
        'disk_latency': 0.1      # Small weight for disk conditions
    }
    Returns calculated swappiness value between 1-200
    """
    weighted_score = (
        -weights['cpu_usage'] * metrics['cpu_usage'] +
        weights['ram_usage'] * metrics['ram_usage'] +
        weights['disk_latency'] * metrics['disk_latency']
    )
    
    return max(1, min(200, 100 + weighted_score * 100))

