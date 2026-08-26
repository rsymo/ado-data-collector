#!/bin/bash

# -------- CONFIGURATION --------
ORG_URL="https://dev.azure.com/<org>"
PAT="<your-personal-access-token>"
CSV_FILE="azdo_all_repo_sizes_lfs_details.csv"

TMP_DIR="azdo_org_repo_tmp"
mkdir -p $TMP_DIR

# List all projects in the organization
projects=$(az devops project list --organization $ORG_URL --query "value[].name" -o tsv)

# CSV header
echo "project_name,repo_name,repo_id,size_bytes_no_lfs,size_bytes_with_lfs" > $CSV_FILE

for PROJECT in $projects; do
    repos=$(az repos list --organization $ORG_URL --project "$PROJECT" --query "[].{id:id,name:name,remoteUrl:remoteUrl}" -o json)

    echo "$repos" | jq -c '.[]' | while read repo; do
        repo_id=$(echo $repo | jq -r '.id')
        repo_name=$(echo $repo | jq -r '.name')
        remote_url=$(echo $repo | jq -r '.remoteUrl')
        clone_url=${remote_url/https:\/\//https:\/\/:$PAT@}

        repo_dir="$TMP_DIR/$repo_name"
        git clone --mirror "$clone_url" "$repo_dir" &> /dev/null

        if [ -d "$repo_dir" ]; then
            size_bytes_no_lfs=$(du -sb "$repo_dir" | cut -f1)
            (cd "$repo_dir" && git lfs fetch --all &> /dev/null)
            size_bytes_with_lfs=$(du -sb "$repo_dir" | cut -f1)
        else
            size_bytes_no_lfs=0
            size_bytes_with_lfs=0
        fi

        echo "$PROJECT,$repo_name,$repo_id,$size_bytes_no_lfs,$size_bytes_with_lfs" >> $CSV_FILE
        rm -rf "$repo_dir"
    done
done