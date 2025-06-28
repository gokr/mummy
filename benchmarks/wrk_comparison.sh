#!/bin/bash

# Performance comparison script using wrk
# This script tests both ThreadPool and TaskPools execution models

echo "=== MUMMY EXECUTION MODEL PERFORMANCE COMPARISON ==="
echo "Using wrk for professional benchmarking"
echo ""

# Check if wrk is installed
if ! command -v wrk &> /dev/null; then
    echo "ERROR: wrk is not installed. Please install wrk first:"
    echo "  Ubuntu/Debian: sudo apt-get install wrk"
    echo "  macOS: brew install wrk"
    echo "  Or build from source: https://github.com/wg/wrk"
    exit 1
fi

# Build both versions
echo "Building ThreadPool version..."
nim c -d:release tests/wrk_mummy.nim
if [ $? -ne 0 ]; then
    echo "Failed to build ThreadPool version"
    exit 1
fi

echo "Building TaskPools version..."
nim c -d:release tests/wrk_mummy_taskpools.nim
if [ $? -ne 0 ]; then
    echo "Failed to build TaskPools version"
    exit 1
fi

echo ""

# Test scenarios
declare -a scenarios=(
    "10 10s"     # 10 connections, 10 seconds
    "50 10s"     # 50 connections, 10 seconds
    "100 10s"    # 100 connections, 10 seconds
)

for scenario in "${scenarios[@]}"; do
    read -r connections duration <<< "$scenario"
    
    echo "=== SCENARIO: $connections connections, $duration duration ==="
    echo ""
    
    # Test ThreadPool
    echo "Testing ThreadPool execution model..."
    ./tests/wrk_mummy &
    SERVER_PID=$!
    sleep 2  # Give server time to start
    
    echo "Running wrk against ThreadPool (port 8080)..."
    wrk -t4 -c$connections -d$duration --latency http://localhost:8080/ > /tmp/threadpool_results.txt
    
    echo "ThreadPool Results:"
    cat /tmp/threadpool_results.txt
    echo ""
    
    # Stop ThreadPool server
    kill $SERVER_PID 2>/dev/null
    wait $SERVER_PID 2>/dev/null
    sleep 1
    
    # Test TaskPools
    echo "Testing TaskPools execution model..."
    ./tests/wrk_mummy_taskpools &
    SERVER_PID=$!
    sleep 2  # Give server time to start
    
    echo "Running wrk against TaskPools (port 8080)..."
    wrk -t4 -c$connections -d$duration --latency http://localhost:8080/ > /tmp/taskpools_results.txt
    
    echo "TaskPools Results:"
    cat /tmp/taskpools_results.txt
    echo ""
    
    # Stop TaskPools server
    kill $SERVER_PID 2>/dev/null
    wait $SERVER_PID 2>/dev/null
    sleep 1
    
    # Compare results
    echo "=== COMPARISON ==="
    
    # Extract key metrics
    threadpool_rps=$(grep "Requests/sec:" /tmp/threadpool_results.txt | awk '{print $2}')
    taskpools_rps=$(grep "Requests/sec:" /tmp/taskpools_results.txt | awk '{print $2}')
    
    threadpool_latency=$(grep "50.000%" /tmp/threadpool_results.txt | awk '{print $2}')
    taskpools_latency=$(grep "50.000%" /tmp/taskpools_results.txt | awk '{print $2}')
    
    echo "Requests/sec:"
    echo "  ThreadPool: $threadpool_rps"
    echo "  TaskPools:  $taskpools_rps"
    
    echo "Median Latency:"
    echo "  ThreadPool: $threadpool_latency"
    echo "  TaskPools:  $taskpools_latency"
    
    # Calculate improvement (if both values are numeric)
    if [[ $threadpool_rps =~ ^[0-9]+\.?[0-9]*$ ]] && [[ $taskpools_rps =~ ^[0-9]+\.?[0-9]*$ ]]; then
        improvement=$(echo "scale=2; ($taskpools_rps - $threadpool_rps) / $threadpool_rps * 100" | bc -l)
        if (( $(echo "$improvement > 0" | bc -l) )); then
            echo "TaskPools is ${improvement}% FASTER"
        else
            improvement=$(echo "scale=2; ($threadpool_rps - $taskpools_rps) / $threadpool_rps * 100" | bc -l)
            echo "ThreadPool is ${improvement}% FASTER"
        fi
    fi
    
    echo "=" | tr '\n' '=' | head -c 60; echo ""
    echo ""
done

echo "Benchmark completed!"
echo ""
echo "Summary:"
echo "- ThreadPool uses fixed worker threads (100 threads)"
echo "- TaskPools uses dynamic task scheduling (20 worker threads + taskpool)"
echo "- Both handle the same workload: 10ms sleep per request"
echo "- Results show performance characteristics under different load patterns"