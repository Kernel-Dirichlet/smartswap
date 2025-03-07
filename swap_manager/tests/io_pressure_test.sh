#!/bin/bash

# Default values
NUM_FILES=1000
FILE_SIZE=1  # Size in MB
OUTPUT_DIR="/tmp/io_pressure_test"
DURATION=60   # Test duration in seconds
THREADS=4     # Number of parallel I/O threads
CLEANUP=true
IO_PATTERN="random"  # I/O pattern: random, sequential, or mixed

# Function to display usage information
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Generate heavy I/O pressure by creating, reading, and deleting files"
    echo
    echo "Options:"
    echo "  --num_files NUM     Number of files to create (default: $NUM_FILES)"
    echo "  --file_size SIZE    Size of each file in MB (default: $FILE_SIZE)"
    echo "  --output_dir DIR    Directory to create files in (default: $OUTPUT_DIR)"
    echo "  --duration SEC      Duration of the test in seconds (default: $DURATION)"
    echo "  --threads NUM       Number of parallel I/O threads (default: $THREADS)"
    echo "  --io_pattern TYPE   I/O pattern: random, sequential, mixed (default: $IO_PATTERN)"
    echo "  --no_cleanup        Don't delete the files after the test"
    echo "  --help              Display this help message and exit"
    echo
    echo "Example: $0 --num_files 500 --file_size 20 --threads 8 --duration 120 --io_pattern mixed"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --num_files)
            NUM_FILES="$2"
            shift 2
            ;;
        --file_size)
            FILE_SIZE="$2"
            shift 2
            ;;
        --output_dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --duration)
            DURATION="$2"
            shift 2
            ;;
        --threads)
            THREADS="$2"
            shift 2
            ;;
        --io_pattern)
            IO_PATTERN="$2"
            shift 2
            ;;
        --no_cleanup)
            CLEANUP=false
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Validate numeric inputs
if ! [[ "$NUM_FILES" =~ ^[0-9]+$ ]]; then
    echo "Error: --num_files must be a positive integer"
    exit 1
fi

if ! [[ "$FILE_SIZE" =~ ^[0-9]+$ ]]; then
    echo "Error: --file_size must be a positive integer"
    exit 1
fi

if ! [[ "$DURATION" =~ ^[0-9]+$ ]]; then
    echo "Error: --duration must be a positive integer"
    exit 1
fi

if ! [[ "$THREADS" =~ ^[0-9]+$ ]]; then
    echo "Error: --threads must be a positive integer"
    exit 1
fi

# Validate IO pattern
if [[ ! "$IO_PATTERN" =~ ^(random|sequential|mixed)$ ]]; then
    echo "Error: --io_pattern must be 'random', 'sequential', or 'mixed'"
    exit 1
fi

# Create output directory if it doesn't exist
if [ ! -d "$OUTPUT_DIR" ]; then
    echo "Creating directory: $OUTPUT_DIR"
    mkdir -p "$OUTPUT_DIR"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to create directory $OUTPUT_DIR"
        exit 1
    fi
fi

echo "Starting intensive I/O pressure test..."
echo "Using $THREADS parallel threads"
echo "Creating and manipulating $NUM_FILES files of ${FILE_SIZE}MB each in $OUTPUT_DIR"
echo "I/O pattern: $IO_PATTERN"
echo "Test will run for approximately $DURATION seconds"

# Function to perform direct I/O operations (bypassing cache)
perform_direct_io() {
    local file="$1"
    local size_mb="$2"
    local pattern="$3"
    
    case "$pattern" in
        random)
            # Random I/O with direct flag to bypass cache
            dd if=/dev/urandom of="$file" bs=4K count=$((size_mb*256)) oflag=direct conv=fsync 2>/dev/null
            ;;
        sequential)
            # Sequential I/O with direct flag
            dd if=/dev/zero of="$file" bs=1M count="$size_mb" oflag=direct conv=fsync 2>/dev/null
            ;;
        mixed)
            # Mix of sequential and random I/O
            if [ $((RANDOM % 2)) -eq 0 ]; then
                dd if=/dev/urandom of="$file" bs=4K count=$((size_mb*256)) oflag=direct conv=fsync 2>/dev/null
            else
                dd if=/dev/zero of="$file" bs=1M count="$size_mb" oflag=direct conv=fsync 2>/dev/null
            fi
            ;;
    esac
}

# Function to force disk sync
force_sync() {
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
}

# Function to run intensive I/O operations in a single thread
run_io_thread() {
    local thread_id=$1
    local files_per_thread=$((NUM_FILES / THREADS))
    local start_file=$((thread_id * files_per_thread + 1))
    local end_file=$((start_file + files_per_thread - 1))
    local end_time=$(($(date +%s) + DURATION))
    
    # Adjust the last thread to handle any remaining files
    if [ $thread_id -eq $((THREADS - 1)) ]; then
        end_file=$NUM_FILES
    fi
    
    echo "Thread $thread_id: Processing files $start_file to $end_file"
    
    # Create a subdirectory for this thread
    local thread_dir="$OUTPUT_DIR/thread_$thread_id"
    mkdir -p "$thread_dir"
    
    # Continue running operations until the duration is reached
    while [ $(date +%s) -lt $end_time ]; do
        # Create phase - write files with direct I/O to bypass cache
        for i in $(seq $start_file $end_file); do
            perform_direct_io "$thread_dir/file_$i.dat" "$FILE_SIZE" "$IO_PATTERN"
        done
        
        # Force sync to ensure data is written to disk
        force_sync
        
        # Read phase with direct I/O to bypass cache
        for i in $(seq $start_file $end_file); do
            if [ -f "$thread_dir/file_$i.dat" ]; then
                # Use direct I/O for reading to bypass cache
                dd if="$thread_dir/file_$i.dat" of=/dev/null bs=4K iflag=direct 2>/dev/null
            fi
        done
        
        # Random access phase - seek to random positions and read/write
        for i in $(seq $start_file $end_file); do
            if [ -f "$thread_dir/file_$i.dat" ]; then
                # Perform random writes to existing files with direct I/O
                for j in {1..10}; do
                    local pos=$((RANDOM % (FILE_SIZE * 1024)))
                    dd if=/dev/urandom of="$thread_dir/file_$i.dat" bs=4K count=1 seek=$pos conv=notrunc oflag=direct 2>/dev/null
                done
            fi
        done
        
        # Force sync again
        force_sync
        
        # Create small files to increase inode pressure
        for i in $(seq 1 100); do
            echo "data" > "$thread_dir/small_file_$i.txt"
        done
        
        # Delete small files to increase inode operations
        rm -f "$thread_dir"/small_file_*.txt
        
        # Delete and recreate to maintain continuous I/O pressure
        for i in $(seq $start_file $end_file); do
            rm -f "$thread_dir/file_$i.dat"
        done
    done
    
    # Clean up thread directory at the end if cleanup is enabled
    if [ "$CLEANUP" = true ]; then
        rm -rf "$thread_dir"
    fi
    
    echo "Thread $thread_id completed"
}

# Start the I/O threads
echo "Starting $THREADS I/O threads..."
for ((i=0; i<THREADS; i++)); do
    run_io_thread $i &
done

# Display progress
start_time=$(date +%s)
while [ $(date +%s) -lt $((start_time + DURATION)) ]; do
    current_time=$(date +%s)
    elapsed=$((current_time - start_time))
    remaining=$((DURATION - elapsed))
    percent=$((elapsed * 100 / DURATION))
    
    # Create a progress bar
    bar="["
    for ((i=0; i<percent/5; i++)); do
        bar+="#"
    done
    for ((i=percent/5; i<20; i++)); do
        bar+="."
    done
    bar+="]"
    
    # Get current I/O stats
    if command -v iostat &>/dev/null; then
        io_stats=$(iostat -d -k 1 2 | tail -4 | head -1)
        echo -ne "Progress: $bar $percent% ($elapsed/$DURATION seconds) | I/O: $io_stats\r"
    else
        echo -ne "Progress: $bar $percent% ($elapsed/$DURATION seconds)\r"
    fi
    
    sleep 1
done

echo -e "\nWaiting for all I/O threads to complete..."
wait

# Final cleanup if enabled
if [ "$CLEANUP" = true ]; then
    echo "Cleaning up remaining files..."
    rm -rf "$OUTPUT_DIR"
else
    echo "Skipping cleanup as requested. Files remain in $OUTPUT_DIR"
fi

echo "Intensive I/O pressure test completed"

