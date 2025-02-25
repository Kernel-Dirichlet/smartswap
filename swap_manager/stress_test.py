import multiprocessing
import time
import os
import psutil
import random
import socket
import tempfile
from swap_niceness_utils import (calculate_disk_io_swappiness, 
                               calculate_network_swappiness,
                               calculate_cpu_swappiness)

def cpu_intensive_task():
    """Max out CPU with math operations"""
    while True:
        # Perform heavy math operations
        [pow(random.random(), 2) for _ in range(100000)]

def memory_intensive_task():
    """Consume memory in chunks"""
    chunks = []
    chunk_size = 100 * 1024 * 1024  # 100MB chunks
    
    while True:
        try:
            # Allocate memory in chunks
            chunks.append(bytearray(chunk_size))
            # Touch the memory to ensure it's allocated
            for i in range(0, len(chunks[-1]), 4096):
                chunks[-1][i] = 1
            
            # If using too much memory, release some
            if psutil.virtual_memory().percent > 90:
                chunks = chunks[len(chunks)//2:]
                
        except MemoryError:
            # If out of memory, free half
            chunks = chunks[len(chunks)//2:]

def disk_io_task():
    """Generate heavy disk I/O with varied file sizes"""
    sizes = [1024*1024, 10*1024*1024, 100*1024*1024]  # 1MB to 100MB
    temp_dir = tempfile.mkdtemp()  # Create unique temp directory
    
    while True:
        # Create multiple files of different sizes
        for size in sizes:
            filename = os.path.join(temp_dir, f"test_file_{size}")
            try:
                data = os.urandom(size)
                
                # Write file
                with open(filename, "wb") as f:
                    f.write(data)
                    f.flush()
                    os.fsync(f.fileno())
                
                # Read it back
                with open(filename, "rb") as f:
                    f.read()
                
                # Delete file
                if os.path.exists(filename):
                    os.remove(filename)
                    
            except (IOError, OSError) as e:
                print(f"IO Error in disk_io_task: {e}")
                # Ensure cleanup on error
                if os.path.exists(filename):
                    try:
                        os.remove(filename)
                    except:
                        pass

def network_intensive_task():
    """Generate heavy network I/O on loopback"""
    # Smaller chunk size to avoid message too long error
    chunk_size = 65000  # Max UDP datagram size
    
    # Create UDP socket pair for loopback traffic
    sock_send = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock_recv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    
    try:
        # Bind receive socket
        sock_recv.bind(('127.0.0.1', 0))
        recv_port = sock_recv.getsockname()[1]
        
        # Set socket buffer sizes
        sock_send.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, chunk_size * 2)
        sock_recv.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, chunk_size * 2)
        
        while True:
            # Generate and send random data
            data = os.urandom(chunk_size)
            sock_send.sendto(data, ('127.0.0.1', recv_port))
            
            # Receive data
            sock_recv.recv(chunk_size)
            
    except Exception as e:
        print(f"Network Error: {e}")
    finally:
        sock_send.close()
        sock_recv.close()

def mixed_workload_task():
    """Combine CPU, memory and I/O operations"""
    chunk_size = 50 * 1024 * 1024  # 50MB
    temp_dir = tempfile.mkdtemp()  # Create unique temp directory
    filename = os.path.join(temp_dir, "mixed_workload_test")
    
    while True:
        try:
            # CPU work
            [pow(random.random(), 2) for _ in range(50000)]
            
            # Memory work
            data = bytearray(chunk_size)
            for i in range(0, len(data), 4096):
                data[i] = 1
                
            # I/O work
            with open(filename, "wb") as f:
                f.write(os.urandom(1024 * 1024))
                f.flush()
            if os.path.exists(filename):
                os.remove(filename)
                
        except (IOError, OSError) as e:
            print(f"Error in mixed_workload_task: {e}")
            if os.path.exists(filename):
                try:
                    os.remove(filename)
                except:
                    pass

def main():
    # Map of process targets to track which task each process runs
    process_targets = {
        'cpu1': cpu_intensive_task,
        'cpu2': cpu_intensive_task,
        'memory1': memory_intensive_task,
        'memory2': memory_intensive_task,
        'disk1': disk_io_task,
        'disk2': disk_io_task,
        'network': network_intensive_task,
        'mixed1': mixed_workload_task,
        'mixed2': mixed_workload_task
    }
    
    processes = []
    weights = {
        'disk_latency': 0.25,
        'cpu_usage': 0.25,
        'ram_usage': 0.25,
        'network_bandwidth': 0.25
    }
    
    # Start with base processes
    for target in process_targets.values():
        processes.append(multiprocessing.Process(target=target))
    
    # Start all processes
    for p in processes:
        p.start()

    try:
        while True:
            # Collect metrics for swappiness calculation
            metrics = {
                'disk_latency': psutil.disk_io_counters().read_time / max(1, psutil.disk_io_counters().read_count),
                'cpu_usage': psutil.cpu_percent() / 100,
                'ram_usage': psutil.virtual_memory().percent / 100,
                'network_bandwidth': sum(nic.bytes_sent + nic.bytes_recv for nic in psutil.net_io_counters(pernic=True).values()) / 1e6
            }
            
            # Calculate theoretical optimal swappiness based on current workload
            disk_swappiness = calculate_disk_io_swappiness(metrics, weights)
            network_swappiness = calculate_network_swappiness(metrics, weights)
            cpu_swappiness = calculate_cpu_swappiness(metrics, weights)
            
            # Randomly stop/start processes to create different combinations
            for i, p in enumerate(processes):
                if random.random() < 0.2:  # 20% chance each check
                    if p.is_alive():
                        p.terminate()
                        # Get the original target function for this process
                        target = list(process_targets.values())[i]
                        # Restart the process with same target
                        new_p = multiprocessing.Process(target=target)
                        processes[i] = new_p
                        new_p.start()
            time.sleep(0.1)  # Small sleep to prevent excessive CPU usage in control loop
            
    except KeyboardInterrupt:
        print("\nShutting down...")
        for p in processes:
            if p.is_alive():
                p.terminate()
        
        # Clean up any leftover files
        temp_dir = tempfile.gettempdir()
        for size in [1024*1024, 10*1024*1024, 100*1024*1024]:
            filename = os.path.join(temp_dir, f"test_file_{size}")
            if os.path.exists(filename):
                os.remove(filename)
        mixed_workload_file = os.path.join(temp_dir, "mixed_workload_test")
        if os.path.exists(mixed_workload_file):
            os.remove(mixed_workload_file)

if __name__ == "__main__":
    main()

