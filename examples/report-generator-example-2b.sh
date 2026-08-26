#!/bin/bash

CSV_FILE="repos.csv"
MIN_SIZE_MB=1024 # 1GB, change as needed

# CSV header
head -n 1 "$CSV_FILE"

# Filter: size > MIN_SIZE_MB
awk -F, -v limit="$MIN_SIZE_MB" 'NR>1 && $2 > limit' "$CSV_FILE"