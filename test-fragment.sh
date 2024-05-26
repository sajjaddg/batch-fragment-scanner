#!/bin/bash

read -p "Set-ExecutionPolicy Bypass -Scope Process is required to run this script. Would you like to proceed? (Y/N) " executionPolicyResponse
if [[ $executionPolicyResponse != "Y" && $executionPolicyResponse != "y" ]]; then
    echo "Execution policy not changed. Exiting script."
    exit 1
fi

# Path to the xray executable and config file in the same folder as the script
SCRIPT_DIR=$(dirname "$0")
XRAY_PATH="$SCRIPT_DIR/xray"
CONFIG_PATH="$SCRIPT_DIR/config.json"
LOG_FILE="$SCRIPT_DIR/pings.txt"

DEFAULT_HTTP_PROXY_PORT=$(jq -r '.inbounds[] | select(.tag == "http") | .port' "$CONFIG_PATH")


# Create pings.txt if it does not exist
if [[ ! -f $LOG_FILE ]]; then
    touch "$LOG_FILE"
fi

# Prompt user for input values with defaults
read -p "Enter the number of instances (default is 10): " InstancesInput
read -p "Enter the timeout for each ping test in seconds (default is 3): " TimeoutSecInput
read -p "Enter the HTTP proxy port (default is $DEFAULT_HTTP_PROXY_PORT): " HTTP_PROXY_PORTInput

# Set default values if inputs are empty
Instances=${InstancesInput:-10}
TimeoutSec=${TimeoutSecInput:-3}
HTTP_PROXY_PORT=${HTTP_PROXY_PORTInput:-$DEFAULT_HTTP_PROXY_PORT}

# HTTP Proxy server address
HTTP_PROXY_SERVER="127.0.0.1"

# Arrays of possible values for packets, length, and interval
packetsOptions=("tlshello" "1-2" "1-3" "1-5")
lengthOptions=("1-1" "1-2" "2-5" "1-5" "1-10" "3-5" "5-10" "3-10" "10-15" "10-30" "10-20" "20-50" "50-100" "100-150" "200-300" "600-800" "1000-2000" "5000-7000" "7000-9000")
intervalOptions=("1-1" "1-2" "3-5" "1-5" "5-10" "10-15" "10-20" "20-30" "20-50" "40-50" "50-100" "50-80" "100-150" "150-200" "100-200" "200-300")

# Array to store top three lowest average response times
topThree=()

# Function to randomly select a value from an array
get_random_value() {
    local array=("$@")
    local randomIndex=$((RANDOM % ${#array[@]}))
    echo "${array[$randomIndex]}"
}

# Function to modify config.json with random parameters
modify_config() {
    local packets=$1
    local length=$2
    local interval=$3

    jq --arg packets "$packets" --arg length "$length" --arg interval "$interval" '
        .outbounds[] |= if .tag == "fragment" then
            .settings.fragment.packets = $packets |
            .settings.fragment.length = $length |
            .settings.fragment.interval = $interval
        else . end
    ' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp" && mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"
}

# Function to stop the Xray process
stop_xray_process() {
    kill $(lsof -t -i :$HTTP_PROXY_PORT) || echo "Xray process not found."
}

# Function to perform HTTP requests with proxy and measure response time
send_http_request() {
    local pingCount=$1
    local timeout=$((TimeoutSec * 1000))  # Convert seconds to milliseconds
    local url="https://www.youtube.com/"

    local totalTime=0
    local individualTimes=()

    for ((i = 1; i <= pingCount; i++)); do
        echo "Ping $i:"

        local startTime=$(date +%s%3N)
        if response=$(curl -s -o /dev/null -w "%{time_total}" --max-time "$TimeoutSec" --proxy "$HTTP_PROXY_SERVER:$HTTP_PROXY_PORT" "$url"); then
            local elapsedTime=$(echo "$response" | awk '{print $1 * 1000}')
            echo "Elapsed time: ${elapsedTime} ms"
            totalTime=$(echo "$totalTime + $elapsedTime" | bc)
            individualTimes+=("$elapsedTime")
        else
            echo "Error: Request failed."
            individualTimes+=(-1)  # Mark failed requests with -1
        fi

        sleep 1
    done

    local averagePing=$(echo "$totalTime / $pingCount" | bc -l)
    echo "Average ping time: ${averagePing} ms"

    # Log individual ping times to pings.txt
    echo "Individual Ping Times: ${individualTimes[*]}" >> "$LOG_FILE"

    echo "$averagePing"
}

# Main script
# Clear the content of the log file before running the tests
> "$LOG_FILE"

for ((i = 0; i < Instances; i++)); do
    packets=$(get_random_value "${packetsOptions[@]}")
    length=$(get_random_value "${lengthOptions[@]}")
    interval=$(get_random_value "${intervalOptions[@]}")

    modify_config "$packets" "$length" "$interval"

    # Stop Xray process if running
    stop_xray_process

    "$XRAY_PATH" -c "$CONFIG_PATH" &

    sleep 1

    echo "Testing with packets=$packets, length=$length, interval=$interval..." >> "$LOG_FILE"
    averagePing=$(send_http_request 3)
    echo "Average Ping Time: $averagePing ms" >> "$LOG_FILE"

    topThree+=("$averagePing|$packets|$length|$interval")

    sleep 1
done
validResults=()
for entry in "${topThree[@]}"; do
    avgTime=$(echo "$entry" | cut -d'|' -f1)
    if (( $(echo "$avgTime > 0" | bc -l) )); then
        validResults+=("$entry")
    fi
done

# Sort the top three list by average response time in ascending order
IFS=$'\n' sortedTopThree=($(sort -t'|' -k1,1n <<<"${validResults[*]}"))
unset IFS

# Display the top three lowest average response times along with their corresponding fragment values
echo "Top three lowest average response times:"
for entry in "${sortedTopThree[@]:0:3}"; do
    avgTime=$(echo "$entry" | cut -d'|' -f1)
    packets=$(echo "$entry" | cut -d'|' -f2)
    length=$(echo "$entry" | cut -d'|' -f3)
    interval=$(echo "$entry" | cut -d'|' -f4)
    echo "Average Response Time: ${avgTime} ms"
    echo "Packets: $packets, Length: $length, Interval: $interval"
done

# Stop Xray process if running
stop_xray_process

# Prevent the Bash window from closing immediately
read -p "Press Enter to exit the script..."
