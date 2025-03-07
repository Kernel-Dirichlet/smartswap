#!/bin/bash

# Default values
DURATION=60       # Duration in seconds
THREADS=4         # Number of CPU threads to use
INTENSITY=75      # CPU intensity (percentage)
MAX_NUMBER=100000 # Maximum number to check for primality

# Function to display usage information
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Generate CPU pressure by finding prime numbers"
    echo
    echo "Options:"
    echo "  --duration SECONDS  Duration of the test in seconds (default: $DURATION)"
    echo "  --threads NUM       Number of CPU threads to use (default: $THREADS)"
    echo "  --intensity PERCENT CPU intensity percentage (default: $INTENSITY)"
    echo "  --max_number NUM    Maximum number to check for primality (default: $MAX_NUMBER)"
    echo "  --help              Display this help message and exit"
    echo
    echo "Example: $0 --duration 120 --threads 8 --intensity 90 --max_number 200000"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --duration)
            DURATION="$2"
            shift 2
            ;;
        --threads)
            THREADS="$2"
            shift 2
            ;;
        --intensity)
            INTENSITY="$2"
            shift 2
            ;;
        --max_number)
            MAX_NUMBER="$2"
            shift 2
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
if ! [[ "$DURATION" =~ ^[0-9]+$ ]]; then
    echo "Error: --duration must be a positive integer"
    exit 1
fi

if ! [[ "$THREADS" =~ ^[0-9]+$ ]]; then
    echo "Error: --threads must be a positive integer"
    exit 1
fi

if ! [[ "$INTENSITY" =~ ^[0-9]+$ ]] || [ "$INTENSITY" -gt 100 ]; then
    echo "Error: --intensity must be a positive integer between 0 and 100"
    exit 1
fi

if ! [[ "$MAX_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "Error: --max_number must be a positive integer"
    exit 1
fi

echo "Starting CPU pressure test (prime finding)..."
echo "Duration: $DURATION seconds"
echo "Threads: $THREADS"
echo "Intensity: $INTENSITY%"
echo "Maximum number: $MAX_NUMBER"

# Function to find prime numbers
run_prime_workload() {
    local thread_id=$1
    local end_time=$2
    local intensity=$3
    local max_number=$4
    local chunk_size=$((max_number / THREADS))
    local start_range=$((thread_id * chunk_size - chunk_size + 1))
    local end_range=$((thread_id * chunk_size))
    
    # Adjust the last thread to cover any remaining numbers
    if [ $thread_id -eq $THREADS ]; then
        end_range=$max_number
    fi
    
    local primes_found=0
    local sleep_time=$(( (100 - intensity) * 10 / intensity ))
    
    if [ $sleep_time -lt 1 ]; then
        sleep_time=1
    fi
    
    echo "Thread $thread_id started: checking range $start_range to $end_range"
    
    while [ $(date +%s) -lt $end_time ]; do
        # Find prime numbers using trial division
        for ((num=start_range; num<=end_range; num++)); do
            is_prime=1
            if [ $num -le 1 ]; then
                is_prime=0
            elif [ $num -eq 2 ] || [ $num -eq 3 ]; then
                is_prime=1
            elif [ $((num % 2)) -eq 0 ]; then
                is_prime=0
            else
                for (( i=3; i*i<=num; i+=2 )); do
                    if [ $((num % i)) -eq 0 ]; then
                        is_prime=0
                        break
                    fi
                done
            fi
            
            if [ $is_prime -eq 1 ]; then
                primes_found=$((primes_found + 1))
            fi
        done
        
        # Sleep based on intensity
        if [ $intensity -lt 100 ]; then
            sleep 0.$sleep_time
        fi
    done
    
    echo "Thread $thread_id completed with $primes_found primes found in range $start_range to $end_range"
}

# Calculate end time
END_TIME=$(($(date +%s) + DURATION))

# Start the workload threads
for ((i=1; i<=THREADS; i++)); do
    run_prime_workload $i $END_TIME $INTENSITY $MAX_NUMBER &
done

# Display progress
START_TIME=$(date +%s)
while [ $(date +%s) -lt $END_TIME ]; do
    current_time=$(date +%s)
    elapsed=$((current_time - START_TIME))
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
    
    echo -ne "Progress: $bar $percent% ($elapsed/$DURATION seconds)\r"
    sleep 1
done

echo -e "\nWaiting for all threads to complete..."
wait

echo "CPU pressure test completed"


