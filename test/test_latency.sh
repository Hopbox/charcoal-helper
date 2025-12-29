#!/bin/bash
# latency_test_v3.sh

HELPER_BIN=$1
API_KEY=$2
NUM_REQUESTS=1000
DEBUG_LOG="debug.log"
LATENCY_CSV="latency.csv"
OUTPUT_FILE="test_output.txt"

if [ -z "$HELPER_BIN" ] || [ ! -f "$HELPER_BIN" ] || [ -z "$API_KEY" ]; then
    echo "Usage: $0 ./charcoal-helper API_KEY"
    exit 1
fi

# Cleanup
> "$OUTPUT_FILE"
> "$DEBUG_LOG"
echo "id,start_ts,rtt_ms" > "$LATENCY_CSV"

echo "Starting RTT stress test ($NUM_REQUESTS requests)..."
echo "Logging: STDOUT (Progress), $DEBUG_LOG (Helper stderr), $LATENCY_CSV (Data)"
echo "--------------------------------------------------"

# Start the helper as a background process with coproc
# This allows us to feed it and read from it persistently
coproc HELPER { "$HELPER_BIN" -d "$API_KEY" 2>>"$DEBUG_LOG"; }

start_ns_total=$(date +%s%N)
success_count=0

for i in $(seq 1 $NUM_REQUESTS); do
    # Format the request
    REQ="$i http://throttle-test-$i.com 1.2.3.4 - GET % 10.0.0.1 3128"
    
    # Mark start time
    start_ns=$(date +%s%N)
    
    # Send to helper
    echo "$REQ" >&"${HELPER[1]}"
    
    # Read response
    if read -r line <&"${HELPER[0]}"; then
        end_ns=$(date +%s%N)
        
        # Calculate RTT in milliseconds
        rtt_ms=$(echo "scale=3; ($end_ns - $start_ns) / 1000000" | bc -l)
        
        # 1. Log to STDOUT
        printf "\rID: %-4s | RTT: %7s ms | Success: %s/%s" "$i" "$rtt_ms" "$((++success_count))" "$NUM_REQUESTS"
        
        # 2. Log to CSV
        echo "$i,$(date +%H:%M:%S),${rtt_ms}" >> "$LATENCY_CSV"
        
        # 3. Store raw output
        echo "$line" >> "$OUTPUT_FILE"
    else
        echo -e "\n[X] Helper failed to respond at request $i"
        break
    fi

    # Optional small throttle to prevent saturation
    if [[ $((i % 50)) -eq 0 ]]; then sleep 0.01; fi
done

end_ns_total=$(date +%s%N)

# Cleanup
kill $HELPER_PID 2>/dev/null

# CORRECTED STATS CALCULATION
# We pass both nanosecond timestamps into bc to handle the high precision
total_s=$(echo "scale=3; ($end_ns_total - $start_ns_total) / 1000000000" | bc -l)

# Avoid division by zero if total_s is somehow 0
if (( $(echo "$total_s > 0" | bc -l) )); then
    throughput=$(echo "scale=2; $success_count / $total_s" | bc -l)
else
    throughput="0"
fi

STATS=$(awk -F, 'NR>1 {if(min=="" || $3<min) min=$3; if($3>max) max=$3; sum+=$3; cnt++}
    END {if(cnt>0) printf "%.3f %.3f %.3f", min, sum/cnt, max; else print "0 0 0"}' "$LATENCY_CSV")
read f_min f_avg f_max <<< "$STATS"

echo -e "\n--------------------------------------------------"
echo " Execution Summary:"
echo "   Success Rate: $success_count / $NUM_REQUESTS"
echo "   Total Time:   ${total_s}s"
echo "   Throughput:   ${throughput} req/sec"
echo "--------------------------------------------------"
echo " Latency Metrics (ms):"
echo "   Min: ${f_min}ms | Avg: ${f_avg}ms | Max: ${f_max}ms"
echo "--------------------------------------------------"
