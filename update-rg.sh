#!/bin/bash

if [ $# -ne 1 ]; then
    echo "Usage: $0 <replacement-text>"
    exit 1
fi

file_1="azure.yaml"
file_2="infra/main.bicep"
# For macOS (BSD sed)
# sed -i '' "s/CHANGEME/$1/g" $file_1 $file_2

# For Linux (GNU sed)
sed -i "s/CHANGEME/$1/g" $file_1 $file_2
