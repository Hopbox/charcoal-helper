#!/bin/bash

HELPER_BIN=$1
API_KEY=$2
NUM_REQUESTS=2000  # Start with 500, then try 2000
DEBUG_LOG="debug.log"
OUTPUT_FILE="test_output.txt"

if [ -z "$HELPER_BIN" ] || [ ! -f "$HELPER_BIN" ] || [ -z "$API_KEY" ]; then
    echo "Usage: $0 ./charcoal-helper API_KEY"
    exit 1
fi

# Cleanup
> "$OUTPUT_FILE"
> "$DEBUG_LOG"

echo "Starting throttled stress test ($NUM_REQUESTS requests)..."
start_ns=$(date +%s%N)

# 1. Throttled Generator
# We pipe the generator directly into the helper to avoid massive temp files
(
    for i in $(seq 1 $NUM_REQUESTS); do
        # Format: [CHAN] [URI] [SRC] [IDENT] [METHOD] [%] [MYADDR] [MYPORT]
        echo "$i http://throttle-test-$i.com 1.2.3.4 - GET % 10.0.0.1 3128"
        
        # Throttle: adjust '0.001' (1ms) if the server still drops at 76
        # A 0.001s delay = 1000 requests per second capacity.
        if [[ $((i % 10)) -eq 0 ]]; then
            sleep 0.01 
        fi
    done
    
    # Keep the pipe open for 5 seconds to catch the last trailing responses
    sleep 10
) | "$HELPER_BIN" -d "$API_KEY" > "$OUTPUT_FILE" 2> "$DEBUG_LOG" &

HELPER_PID=$!

# 2. Progress Monitor
while true; do
    count=$(wc -l < "$OUTPUT_FILE")
    printf "\rSuccess: $count / $NUM_REQUESTS"
    
    if [ "$count" -ge "$NUM_REQUESTS" ]; then
        echo -e "\n[!] All requests completed successfully."
        break
    fi
    
    # Check if helper crashed or exited
    if ! kill -0 $HELPER_PID 2>/dev/null; then
        echo -e "\n[X] Helper exited early at $count requests. Check $DEBUG_LOG"
        break
    fi
    sleep 0.5
done

end_ns=$(date +%s%N)
kill $HELPER_PID 2>/dev/null

# 3. Stats
total_s=$(echo "scale=3; ($end_ns - $start_ns - 5000000000) / 1000000000" | bc -l)
echo "--------------------------------------------------"
echo " Execution Time: ${total_s}s (excluding 5s hold-open)"
echo " Avg Throughput: $(echo "scale=2; $NUM_REQUESTS / $total_s" | bc -l) req/sec"
echo "--------------------------------------------------"
