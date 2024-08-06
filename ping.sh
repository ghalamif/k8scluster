#!/bin/bash



# Function to print in green
print_green() {
    echo -e "\e[32m$1\e[0m"
}

# Get the IP address from the user
read -p "Enter the IP address to check: " IP_ADDRESS

# Infinite loop to check the connection
while true
do
    # Ping the IP address with a single packet
    ping -c 1 $IP_ADDRESS &> /dev/null

    # Check if the ping was successful
    if [ $? -eq 0 ]; then
        print_green "Connection to $IP_ADDRESS is established."
        break
    else
        echo "Connection to $IP_ADDRESS is not established. Retrying..."
    fi

    # Wait for 5 seconds before retrying
    sleep 5
done
